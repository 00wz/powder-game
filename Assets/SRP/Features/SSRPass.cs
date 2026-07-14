using UnityEngine;
using UnityEngine.Experimental.Rendering;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Rendering.RenderGraphModule;

public class SSRPass : ScriptableRenderPass
{
    // Must match HIZ_MAX_MIPS in HiZCommon.hlsl.
    public const int HiZMaxMips = 12;

    private const int HiZInitPassIndex = 0;
    private const int HiZDownsamplePassIndex = 1;
    private const int SSRMainPassIndex = 0;
    private const int SSRHiZDebugPassIndex = 1;

    private Material m_Material;
    private Material m_HiZMaterial;
    private SSRFeature.Settings m_Settings;

    // Shader property IDs
    private static readonly int MaxStepsId = Shader.PropertyToID("_MaxSteps");
    private static readonly int JitterStrengthId = Shader.PropertyToID("_JitterStrength");
    private static readonly int ThicknessId = Shader.PropertyToID("_Thickness");
    private static readonly int MaxDistanceId = Shader.PropertyToID("_MaxDistance");
    private static readonly int IntensityId = Shader.PropertyToID("_Intensity");
    private static readonly int EdgeFadeId = Shader.PropertyToID("_EdgeFade");
    private static readonly int SkyCubeId = Shader.PropertyToID("_SSR_SkyCube");
    private static readonly int SkyCubeHDRId = Shader.PropertyToID("_SSR_SkyCube_HDR");
    private static readonly int UseSkyboxFallbackId = Shader.PropertyToID("_SSR_UseSkyboxFallback");

    private static readonly int HiZLevelCountId = Shader.PropertyToID("_HiZLevelCount");
    private static readonly int HiZMipInfoArrayId = Shader.PropertyToID("_HiZMipInfo");
    private static readonly int HiZDebugMipIndexId = Shader.PropertyToID("_HiZDebugMipIndex");
    private static readonly int[] HiZMipTexIds = BuildHiZMipTexIds();

    private static readonly int SrcMipInfoId = Shader.PropertyToID("_SrcMipInfo");
    private static readonly int DstMipInfoId = Shader.PropertyToID("_DstMipInfo");
    private static readonly int BlitTextureId = Shader.PropertyToID("_BlitTexture");
    private static readonly int BlitScaleBiasId = Shader.PropertyToID("_BlitScaleBias");

    // Reused across the pyramid's sequential draws (mirrors how Core's own Blitter reuses a
    // single static MaterialPropertyBlock): a MaterialPropertyBlock passed straight into
    // DrawProcedural is captured with that specific draw call, unlike Material.SetXxx, so this
    // is the only construct we rely on for values that differ from one pyramid level to the next.
    private static readonly MaterialPropertyBlock s_PyramidPropertyBlock = new MaterialPropertyBlock();

    private static int[] BuildHiZMipTexIds()
    {
        var ids = new int[HiZMaxMips];
        for (int i = 0; i < HiZMaxMips; i++)
            ids[i] = Shader.PropertyToID($"_HiZMip{i}");
        return ids;
    }

    public SSRPass(Material material, Material hiZMaterial, SSRFeature.Settings settings)
    {
        m_Material = material;
        m_HiZMaterial = hiZMaterial;
        m_Settings = settings;
        renderPassEvent = settings.renderPassEvent;

        // SSR требует depth и normals
        ConfigureInput(ScriptableRenderPassInput.Depth | ScriptableRenderPassInput.Normal);
    }

    public void UpdateSettings(SSRFeature.Settings newSettings)
    {
        m_Settings = newSettings;
        renderPassEvent = newSettings.renderPassEvent;
    }

    private class PassData
    {
        public Material material;
        public TextureHandle sourceTexture;
        public TextureHandle destinationTexture;
        public SSRFeature.Settings settings;
    }

    private class PyramidPassData
    {
        public Material material;
        public int passIndex;
        public TextureHandle source;
        public Vector4 srcMipInfo;
        public Vector4 dstMipInfo;
    }

    private class HiZDebugPassData
    {
        public Material material;
        public TextureHandle destination;
        public TextureHandle[] mips;
        public Vector4[] mipInfos;
        public int levelCount;
        public int debugMipIndex;
    }

    // Полная точность важна: под reversed-Z самая "плотная" зона глубины (raw ~= 1) - это
    // объекты рядом с камерой, где артефакты трассировки заметнее всего, а RG16F там
    // ощутимо теряет точность. Используем RG32F везде, где render target такого формата
    // поддерживается (это практически все платформы, включая WebGL2/GLES3 с
    // EXT_color_buffer_float); откат на RG16F - только явный запасной вариант.
    private static GraphicsFormat GetHiZFormat()
    {
        if (SystemInfo.IsFormatSupported(GraphicsFormat.R32G32_SFloat, GraphicsFormatUsage.Render))
            return GraphicsFormat.R32G32_SFloat;
        return GraphicsFormat.R16G16_SFloat;
    }

    private static int ComputeLevelCount(int width, int height, int maxLevels)
    {
        int maxDim = Mathf.Max(Mathf.Max(width, height), 1);
        int levels = Mathf.FloorToInt(Mathf.Log(maxDim, 2)) + 1;
        return Mathf.Clamp(levels, 1, maxLevels);
    }

    // Строит Hi-Z min/max пирамиду через обычные fragment-shader passes (без compute shader'ов,
    // чтобы одинаково работать на всех платформах включая WebGL). Каждый уровень - отдельный
    // TextureHandle, поэтому ни один pass не читает и не пишет один и тот же GPU-ресурс
    // на разных мип-уровнях одновременно.
    private TextureHandle[] BuildHiZPyramid(RenderGraph renderGraph, UniversalCameraData cameraData, out Vector4[] mipInfos, out int levelCount)
    {
        var descriptor = cameraData.cameraTargetDescriptor;
        int realWidth = Mathf.Max(1, Mathf.RoundToInt(descriptor.width * m_Settings.pyramidResolutionScale));
        int realHeight = Mathf.Max(1, Mathf.RoundToInt(descriptor.height * m_Settings.pyramidResolutionScale));
        var realSize = new Vector4(realWidth, realHeight, 1f / realWidth, 1f / realHeight);

        // Pad up to a power of two so every level is exactly half the previous one in both
        // dimensions - see the comment at the top of HiZDepthPyramid.shader for why.
        int baseWidth = Mathf.NextPowerOfTwo(realWidth);
        int baseHeight = Mathf.NextPowerOfTwo(realHeight);

        int maxLevels = Mathf.Clamp(m_Settings.maxMipLevel, 1, HiZMaxMips);
        levelCount = ComputeLevelCount(baseWidth, baseHeight, maxLevels);

        GraphicsFormat format = GetHiZFormat();

        var mips = new TextureHandle[levelCount];
        mipInfos = new Vector4[levelCount];

        int w = baseWidth;
        int h = baseHeight;

        for (int i = 0; i < levelCount; i++)
        {
            mipInfos[i] = new Vector4(w, h, 1f / w, 1f / h);

            var texDesc = new TextureDesc(w, h)
            {
                name = $"_HiZPyramid_Mip{i}",
                colorFormat = format,
                filterMode = FilterMode.Point,
                wrapMode = TextureWrapMode.Clamp,
                clearBuffer = false,
                useMipMap = false
            };
            mips[i] = renderGraph.CreateTexture(texDesc);

            if (i == 0)
            {
                using (var builder = renderGraph.AddRasterRenderPass<PyramidPassData>("HiZ Pyramid Init", out var passData))
                {
                    passData.material = m_HiZMaterial;
                    passData.passIndex = HiZInitPassIndex;

                    // Init reuses srcMipInfo/dstMipInfo for a different purpose than Downsample:
                    // src = real (unpadded) camera size, dst = padded mip 0 canvas size - see
                    // InitFrag in HiZDepthPyramid.shader.
                    passData.srcMipInfo = realSize;
                    passData.dstMipInfo = mipInfos[0];

                    builder.SetRenderAttachment(mips[0], 0, AccessFlags.Write);

                    builder.SetRenderFunc((PyramidPassData data, RasterGraphContext context) =>
                    {
                        s_PyramidPropertyBlock.Clear();
                        s_PyramidPropertyBlock.SetVector(BlitScaleBiasId, new Vector4(1, 1, 0, 0));
                        s_PyramidPropertyBlock.SetVector(SrcMipInfoId, data.srcMipInfo);
                        s_PyramidPropertyBlock.SetVector(DstMipInfoId, data.dstMipInfo);
                        context.cmd.DrawProcedural(Matrix4x4.identity, data.material, data.passIndex,
                            MeshTopology.Triangles, 3, 1, s_PyramidPropertyBlock);
                    });
                }
            }
            else
            {
                using (var builder = renderGraph.AddRasterRenderPass<PyramidPassData>($"HiZ Pyramid Mip {i}", out var passData))
                {
                    passData.material = m_HiZMaterial;
                    passData.passIndex = HiZDownsamplePassIndex;
                    passData.source = mips[i - 1];
                    passData.srcMipInfo = mipInfos[i - 1];
                    passData.dstMipInfo = mipInfos[i];

                    builder.UseTexture(passData.source, AccessFlags.Read);
                    builder.SetRenderAttachment(mips[i], 0, AccessFlags.Write);

                    // _SrcMipInfo/_DstMipInfo and _BlitTexture are supplied through this
                    // per-draw MaterialPropertyBlock rather than Material.SetVector/SetTexture -
                    // see the comment on _SrcMipInfo/_DstMipInfo in HiZDepthPyramid.shader for
                    // why: this pyramid is a chain of RenderGraph passes that all reuse the same
                    // Material, and plain material-property mutation is not reliably captured
                    // per-draw once RenderGraph batches/merges raster passes.
                    builder.SetRenderFunc((PyramidPassData data, RasterGraphContext context) =>
                    {
                        s_PyramidPropertyBlock.Clear();
                        s_PyramidPropertyBlock.SetVector(BlitScaleBiasId, new Vector4(1, 1, 0, 0));
                        s_PyramidPropertyBlock.SetTexture(BlitTextureId, data.source);
                        s_PyramidPropertyBlock.SetVector(SrcMipInfoId, data.srcMipInfo);
                        s_PyramidPropertyBlock.SetVector(DstMipInfoId, data.dstMipInfo);
                        context.cmd.DrawProcedural(Matrix4x4.identity, data.material, data.passIndex,
                            MeshTopology.Triangles, 3, 1, s_PyramidPropertyBlock);
                    });
                }
            }

            w = Mathf.Max(1, w / 2);
            h = Mathf.Max(1, h / 2);
        }

        return mips;
    }

    public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
    {
        if (m_Material == null || m_HiZMaterial == null)
            return;

        var resourceData = frameData.Get<UniversalResourceData>();
        var cameraData = frameData.Get<UniversalCameraData>();

        if (m_Settings.debugMode == SSRFeature.HiZDebugMode.ShowPyramidMip)
        {
            TextureHandle[] debugMips = BuildHiZPyramid(renderGraph, cameraData, out Vector4[] debugMipInfos, out int debugLevelCount);

            using (var builder = renderGraph.AddRasterRenderPass<HiZDebugPassData>("SSR HiZ Debug View", out var passData))
            {
                passData.material = m_Material;
                passData.destination = resourceData.activeColorTexture;
                passData.mips = debugMips;
                passData.mipInfos = debugMipInfos;
                passData.levelCount = debugLevelCount;
                passData.debugMipIndex = Mathf.Clamp(m_Settings.debugMipIndex, 0, debugLevelCount - 1);

                for (int i = 0; i < debugMips.Length; i++)
                    builder.UseTexture(debugMips[i], AccessFlags.Read);

                builder.SetRenderAttachment(passData.destination, 0, AccessFlags.Write);
                builder.AllowGlobalStateModification(true);

                builder.SetRenderFunc((HiZDebugPassData data, RasterGraphContext context) =>
                {
                    for (int i = 0; i < data.mips.Length; i++)
                        data.material.SetTexture(HiZMipTexIds[i], data.mips[i]);

                    var infoArray = new Vector4[HiZMaxMips];
                    for (int i = 0; i < data.mipInfos.Length; i++)
                        infoArray[i] = data.mipInfos[i];
                    data.material.SetVectorArray(HiZMipInfoArrayId, infoArray);

                    data.material.SetFloat(HiZLevelCountId, data.levelCount);
                    data.material.SetFloat(HiZDebugMipIndexId, data.debugMipIndex);

                    Blitter.BlitTexture(context.cmd, new Vector4(1, 1, 0, 0), data.material, SSRHiZDebugPassIndex);
                });
            }

            return;
        }

        // Создаём временную текстуру для результата
        var descriptor = cameraData.cameraTargetDescriptor;
        descriptor.depthBufferBits = 0;
        descriptor.msaaSamples = 1;

        var texDesc = new TextureDesc(descriptor)
        {
            clearBuffer = false,
            filterMode = FilterMode.Bilinear,
            wrapMode = TextureWrapMode.Clamp
        };

        int passCount = Mathf.Max(1, m_Settings.passCount);

        texDesc.name = "_SSRTexture_A";
        TextureHandle texA = renderGraph.CreateTexture(texDesc);
        texDesc.name = "_SSRTexture_B";
        TextureHandle texB = passCount > 1 ? renderGraph.CreateTexture(texDesc) : texA;

        TextureHandle[] pingPong = { texA, texB };

        for (int i = 0; i < passCount; i++)
        {
            TextureHandle src = i == 0 ? resourceData.activeColorTexture : pingPong[(i - 1) % 2];
            TextureHandle dst = pingPong[i % 2];

            int passIndex = i;
            using (var builder = renderGraph.AddRasterRenderPass<PassData>($"SSR Pass {i + 1}", out var passData))
            {
                passData.material = m_Material;
                passData.sourceTexture = src;
                passData.destinationTexture = dst;
                passData.settings = m_Settings;

                builder.UseTexture(passData.sourceTexture, AccessFlags.Read);
                builder.SetRenderAttachment(dst, 0, AccessFlags.Write);
                builder.AllowGlobalStateModification(true);

                builder.SetRenderFunc((PassData data, RasterGraphContext context) =>
                {
                    data.material.SetFloat(MaxStepsId, data.settings.maxSteps);
                    data.material.SetFloat(JitterStrengthId, data.settings.jitterStrength);
                    data.material.SetFloat(ThicknessId, data.settings.thickness);
                    data.material.SetFloat(MaxDistanceId, data.settings.maxDistance);
                    data.material.SetFloat(IntensityId, data.settings.intensity);
                    data.material.SetFloat(EdgeFadeId, data.settings.edgeFade);

                    data.material.SetFloat(UseSkyboxFallbackId, data.settings.useSkyboxFallback ? 1f : 0f);
                    if (data.settings.useSkyboxFallback)
                    {
                        Texture cubemapTex = null;

                        if (data.settings.fallbackCubemap != null)
                            cubemapTex = data.settings.fallbackCubemap;
                        else if (ReflectionProbe.defaultTexture != null)
                            cubemapTex = ReflectionProbe.defaultTexture;
                        else if (RenderSettings.skybox != null)
                        {
                            if (RenderSettings.skybox.HasProperty("_Tex"))
                                cubemapTex = RenderSettings.skybox.GetTexture("_Tex");
                            else if (RenderSettings.skybox.HasProperty("_MainTex"))
                                cubemapTex = RenderSettings.skybox.GetTexture("_MainTex");
                            else if (RenderSettings.skybox.HasProperty("_Cubemap"))
                                cubemapTex = RenderSettings.skybox.GetTexture("_Cubemap");
                        }

                        if (cubemapTex != null)
                        {
                            data.material.SetTexture(SkyCubeId, cubemapTex);
                            data.material.SetVector(SkyCubeHDRId, new Vector4(1f, 1f, 0f, 0f));
                        }
                        else
                        {
                            data.material.SetFloat(UseSkyboxFallbackId, 0f);
                        }
                    }

                    Blitter.BlitTexture(context.cmd, data.sourceTexture, new Vector4(1, 1, 0, 0), data.material, SSRMainPassIndex);
                });
            }
        }

        // Копируем финальный результат обратно в активную текстуру
        TextureHandle finalResult = pingPong[(passCount - 1) % 2];
        using (var builder = renderGraph.AddRasterRenderPass<PassData>("SSR Copy Back", out var passData))
        {
            passData.sourceTexture = finalResult;
            passData.destinationTexture = resourceData.activeColorTexture;

            builder.UseTexture(passData.sourceTexture, AccessFlags.Read);
            builder.SetRenderAttachment(passData.destinationTexture, 0, AccessFlags.Write);

            builder.SetRenderFunc((PassData data, RasterGraphContext context) =>
            {
                Blitter.BlitTexture(context.cmd, data.sourceTexture, new Vector4(1, 1, 0, 0), 0, false);
            });
        }
    }

    public void Dispose()
    {
        // Cleanup if needed
    }
}
