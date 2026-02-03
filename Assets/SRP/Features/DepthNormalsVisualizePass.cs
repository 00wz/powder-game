using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Rendering.RenderGraphModule;

/// <summary>
/// Render Pass для визуализации Depth и Normals буферов.
/// </summary>
public class DepthNormalsVisualizePass : ScriptableRenderPass
{
    private const string PassName = "Depth Normals Visualize Pass";
    
    private Material material;
    private DepthNormalsVisualizeFeature.Settings settings;
    
    // Shader property IDs
    private static readonly int DepthThresholdId = Shader.PropertyToID("_DepthThreshold");
    private static readonly int NormalThresholdId = Shader.PropertyToID("_NormalThreshold");
    private static readonly int MaxDepthDistanceId = Shader.PropertyToID("_MaxDepthDistance");
    
    public DepthNormalsVisualizePass(Material material, DepthNormalsVisualizeFeature.Settings settings)
    {
        this.material = material;
        this.settings = settings;
        
        // Указываем что нам нужны depth и normals текстуры
        ConfigureInput(ScriptableRenderPassInput.Depth | ScriptableRenderPassInput.Normal);
    }
    
    public void UpdateSettings(DepthNormalsVisualizeFeature.Settings newSettings)
    {
        settings = newSettings;
    }
    
    private class PassData
    {
        public Material material;
        public TextureHandle source;
        public int passIndex;
        public float depthThreshold;
        public float normalThreshold;
        public float maxDepthDistance;
    }
    
    public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
    {
        if (material == null) return;
        
        UniversalResourceData resourceData = frameData.Get<UniversalResourceData>();
        UniversalCameraData cameraData = frameData.Get<UniversalCameraData>();
        
        if (cameraData.cameraType == CameraType.Preview)
            return;
        
        TextureHandle cameraColor = resourceData.activeColorTexture;
        
        // Создаём временную текстуру
        var desc = renderGraph.GetTextureDesc(cameraColor);
        desc.name = "_DepthNormalsVisTemp";
        desc.clearBuffer = false;
        
        TextureHandle tempTexture = renderGraph.CreateTexture(desc);
        
        // Копируем исходное изображение
        using (var builder = renderGraph.AddRasterRenderPass<PassData>("Copy Input", out var passData))
        {
            passData.source = cameraColor;
            
            builder.UseTexture(cameraColor, AccessFlags.Read);
            builder.SetRenderAttachment(tempTexture, 0, AccessFlags.Write);
            
            builder.SetRenderFunc((PassData data, RasterGraphContext context) =>
            {
                Blitter.BlitTexture(context.cmd, data.source, new Vector4(1, 1, 0, 0), 0, false);
            });
        }
        
        // Применяем визуализацию
        using (var builder = renderGraph.AddRasterRenderPass<PassData>(PassName, out var passData))
        {
            passData.material = material;
            passData.source = tempTexture;
            passData.passIndex = (int)settings.mode;
            passData.depthThreshold = settings.depthThreshold;
            passData.normalThreshold = settings.normalThreshold;
            passData.maxDepthDistance = settings.maxDepthDistance;
            
            builder.UseTexture(tempTexture, AccessFlags.Read);
            builder.SetRenderAttachment(cameraColor, 0, AccessFlags.Write);
            builder.AllowGlobalStateModification(true);
            
            builder.SetRenderFunc((PassData data, RasterGraphContext context) =>
            {
                data.material.SetFloat(DepthThresholdId, data.depthThreshold);
                data.material.SetFloat(NormalThresholdId, data.normalThreshold);
                data.material.SetFloat(MaxDepthDistanceId, data.maxDepthDistance);
                Blitter.BlitTexture(context.cmd, data.source, new Vector4(1, 1, 0, 0), data.material, data.passIndex);
            });
        }
    }
    
    public void Dispose()
    {
        // Материал управляется Feature
    }
}
