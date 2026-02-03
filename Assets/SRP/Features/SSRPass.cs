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
    
    private static readonly int InverseProjectionMatrixId = Shader.PropertyToID("_SSR_InverseProjectionMatrix");
    private static readonly int ProjectionMatrixId = Shader.PropertyToID("_SSR_ProjectionMatrix");
    private static readonly int ViewMatrixId = Shader.PropertyToID("_SSR_ViewMatrix");
    private static readonly int InverseViewMatrixId = Shader.PropertyToID("_SSR_InverseViewMatrix");

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
        public Matrix4x4 inverseProjectionMatrix;
        public Matrix4x4 projectionMatrix;
        public Matrix4x4 viewMatrix;
        public Matrix4x4 inverseViewMatrix;
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

        // Получаем матрицы камеры
        Camera camera = cameraData.camera;
        Matrix4x4 projMatrix = GL.GetGPUProjectionMatrix(camera.projectionMatrix, true);
        Matrix4x4 viewMatrix = camera.worldToCameraMatrix;

        using (var builder = renderGraph.AddRasterRenderPass<PassData>("SSR Pass", out var passData))
        {
            passData.material = m_Material;
            passData.sourceTexture = resourceData.activeColorTexture;
            passData.destinationTexture = destinationTexture;
            passData.settings = m_Settings;
            passData.projectionMatrix = projMatrix;
            passData.inverseProjectionMatrix = projMatrix.inverse;
            passData.viewMatrix = viewMatrix;
            passData.inverseViewMatrix = viewMatrix.inverse;

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
                
                // Матрицы для реконструкции позиции
                data.material.SetMatrix(InverseProjectionMatrixId, data.inverseProjectionMatrix);
                data.material.SetMatrix(ProjectionMatrixId, data.projectionMatrix);
                data.material.SetMatrix(ViewMatrixId, data.viewMatrix);
                data.material.SetMatrix(InverseViewMatrixId, data.inverseViewMatrix);

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
