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

        TextureHandle destinationTexture = renderGraph.CreateTexture(new TextureDesc(descriptor)
        {
            name = "_SSRTexture",
            clearBuffer = false,
            filterMode = FilterMode.Bilinear,
            wrapMode = TextureWrapMode.Clamp
        });

        using (var builder = renderGraph.AddRasterRenderPass<PassData>("SSR Pass", out var passData))
        {
            passData.material = m_Material;
            passData.sourceTexture = resourceData.activeColorTexture;
            passData.destinationTexture = destinationTexture;
            passData.settings = m_Settings;

            builder.UseTexture(passData.sourceTexture, AccessFlags.Read);
            builder.SetRenderAttachment(destinationTexture, 0, AccessFlags.Write);
            builder.AllowGlobalStateModification(true);

            builder.SetRenderFunc((PassData data, RasterGraphContext context) =>
            {
                // Устанавливаем параметры шейдера
                data.material.SetFloat(MaxStepsId, data.settings.maxSteps);
                data.material.SetFloat(StepSizeId, data.settings.stepSize);
                data.material.SetFloat(ThicknessId, data.settings.thickness);
                data.material.SetFloat(MaxDistanceId, data.settings.maxDistance);
                data.material.SetFloat(IntensityId, data.settings.intensity);
                data.material.SetFloat(EdgeFadeId, data.settings.edgeFade);
                
                // Skybox fallback
                data.material.SetFloat(UseSkyboxFallbackId, data.settings.useSkyboxFallback ? 1f : 0f);
                if (data.settings.useSkyboxFallback)
                {
                    Texture cubemapTex = null;
                    
                    // 1. Сначала проверяем указанный в настройках cubemap
                    if (data.settings.fallbackCubemap != null)
                    {
                        cubemapTex = data.settings.fallbackCubemap;
                    }
                    // 2. Пытаемся использовать default reflection probe
                    else if (ReflectionProbe.defaultTexture != null)
                    {
                        cubemapTex = ReflectionProbe.defaultTexture;
                    }
                    // 3. Пытаемся получить из skybox материала (если это cubemap-based skybox)
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
                        // HDR decode параметры (RGBM: x=multiplier, y=1, z=0, w=0)
                        data.material.SetVector(SkyCubeHDRId, new Vector4(1f, 1f, 0f, 0f));
                    }
                    else
                    {
                        // Нет доступного cubemap - отключаем fallback
                        data.material.SetFloat(UseSkyboxFallbackId, 0f);
                    }
                }

                Blitter.BlitTexture(context.cmd, data.sourceTexture, new Vector4(1, 1, 0, 0), data.material, 0);
            });
        }

        // Копируем результат обратно в активную текстуру
        using (var builder = renderGraph.AddRasterRenderPass<PassData>("SSR Copy Back", out var passData))
        {
            passData.sourceTexture = destinationTexture;
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
