using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Rendering.RenderGraphModule;

public class SSRPass : ScriptableRenderPass
{
    private Material m_Material;
    private SSRFeature.Settings m_Settings;

    // Shader property IDs
    private static readonly int MaxStepsId = Shader.PropertyToID("_MaxSteps");
    private static readonly int StepSizeId = Shader.PropertyToID("_StepSize");
    private static readonly int ThicknessId = Shader.PropertyToID("_Thickness");
    private static readonly int MaxDistanceId = Shader.PropertyToID("_MaxDistance");
    private static readonly int IntensityId = Shader.PropertyToID("_Intensity");
    private static readonly int EdgeFadeId = Shader.PropertyToID("_EdgeFade");
    private static readonly int SkyCubeId = Shader.PropertyToID("_SSR_SkyCube");
    private static readonly int SkyCubeHDRId = Shader.PropertyToID("_SSR_SkyCube_HDR");
    private static readonly int UseSkyboxFallbackId = Shader.PropertyToID("_SSR_UseSkyboxFallback");

    public SSRPass(Material material, SSRFeature.Settings settings)
    {
        m_Material = material;
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

    public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
    {
        if (m_Material == null)
            return;

        var resourceData = frameData.Get<UniversalResourceData>();
        var cameraData = frameData.Get<UniversalCameraData>();

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
                    data.material.SetFloat(StepSizeId, data.settings.stepSize);
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

                    Blitter.BlitTexture(context.cmd, data.sourceTexture, new Vector4(1, 1, 0, 0), data.material, 0);
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
