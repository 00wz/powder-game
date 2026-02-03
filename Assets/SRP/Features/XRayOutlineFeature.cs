using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Rendering.RenderGraphModule;

/// <summary>
/// Renderer Feature для рендеринга третьего прохода X-Ray контура.
/// Рендерит объекты с LightMode = "XRayOutline" после основных проходов.
/// </summary>
public class XRayOutlineFeature : ScriptableRendererFeature
{
    [System.Serializable]
    public class Settings
    {
        [Tooltip("На какой стадии выполнять проход")]
        public RenderPassEvent renderPassEvent = RenderPassEvent.AfterRenderingTransparents;
        
        [Tooltip("Layer маска для X-Ray объектов")]
        public LayerMask layerMask = -1;
        
        [Tooltip("Shader Tag для прохода контура")]
        public string shaderTagId = "XRayOutline";
    }
    
    public Settings settings = new Settings();
    
    private XRayOutlinePass pass;
    
    public override void Create()
    {
        pass = new XRayOutlinePass(settings);
        pass.renderPassEvent = settings.renderPassEvent;
    }
    
    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        if (pass == null)
            return;
            
        // Не рендерим для preview камер
        if (renderingData.cameraData.cameraType == CameraType.Preview)
            return;
            
        renderer.EnqueuePass(pass);
    }
    
    protected override void Dispose(bool disposing)
    {
        pass?.Dispose();
    }
}

/// <summary>
/// Render Pass для X-Ray контура.
/// Рендерит объекты с указанным ShaderTagId.
/// </summary>
public class XRayOutlinePass : ScriptableRenderPass
{
    private const string PassName = "X-Ray Outline Pass";
    
    private XRayOutlineFeature.Settings settings;
    private ShaderTagId shaderTagId;
    private FilteringSettings filteringSettings;
    
    public XRayOutlinePass(XRayOutlineFeature.Settings settings)
    {
        this.settings = settings;
        this.shaderTagId = new ShaderTagId(settings.shaderTagId);
        
        // Рендерим все очереди (Opaque + Transparent)
        filteringSettings = new FilteringSettings(RenderQueueRange.all, settings.layerMask);
    }
    
    private class PassData
    {
        public RendererListHandle rendererListHandle;
    }
    
    public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
    {
        UniversalResourceData resourceData = frameData.Get<UniversalResourceData>();
        UniversalRenderingData renderingData = frameData.Get<UniversalRenderingData>();
        UniversalCameraData cameraData = frameData.Get<UniversalCameraData>();
        UniversalLightData lightData = frameData.Get<UniversalLightData>();
        
        // Настраиваем отрисовку
        var sortingCriteria = SortingCriteria.CommonTransparent;
        var drawingSettings = RenderingUtils.CreateDrawingSettings(
            shaderTagId,
            renderingData,
            cameraData,
            lightData,
            sortingCriteria);
        
        var rendererListParams = new RendererListParams(
            renderingData.cullResults,
            drawingSettings,
            filteringSettings);
        
        using (var builder = renderGraph.AddRasterRenderPass<PassData>(PassName, out var passData))
        {
            passData.rendererListHandle = renderGraph.CreateRendererList(rendererListParams);
            
            // Рисуем в текущий color buffer с использованием depth + stencil
            builder.SetRenderAttachment(resourceData.activeColorTexture, 0, AccessFlags.Write);
            builder.SetRenderAttachmentDepth(resourceData.activeDepthTexture, AccessFlags.Read);
            
            builder.UseRendererList(passData.rendererListHandle);
            
            builder.SetRenderFunc((PassData data, RasterGraphContext context) =>
            {
                context.cmd.DrawRendererList(data.rendererListHandle);
            });
        }
    }
    
    public void Dispose()
    {
        // Cleanup if needed
    }
}
