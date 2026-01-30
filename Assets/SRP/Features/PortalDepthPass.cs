using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Rendering.RenderGraphModule;

/// <summary>
/// Render Pass который рендерит глубину порталов в отдельную текстуру.
/// Эта текстура затем используется шейдером PortalContent для отсечения.
/// </summary>
public class PortalDepthPass : ScriptableRenderPass
{
    private const string PassName = "Portal Depth Pass";
    private const string PortalDepthTextureName = "_PortalDepthTexture";
    
    private static readonly int PortalDepthTextureId = Shader.PropertyToID(PortalDepthTextureName);
    
    private PortalDepthFeature.Settings settings;
    private ShaderTagId shaderTagId;
    private FilteringSettings filteringSettings;
    
    public PortalDepthPass(PortalDepthFeature.Settings settings)
    {
        this.settings = settings;
        this.shaderTagId = new ShaderTagId(settings.shaderTagId);
        
        // Настройка фильтрации - рендерим только объекты на определённом layer
        filteringSettings = new FilteringSettings(RenderQueueRange.all, settings.portalLayerMask);
    }
    
    private class PassData
    {
        public RendererListHandle rendererListHandle;
        public TextureHandle portalDepthTexture;
    }
    
    public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
    {
        UniversalResourceData resourceData = frameData.Get<UniversalResourceData>();
        UniversalRenderingData renderingData = frameData.Get<UniversalRenderingData>();
        UniversalCameraData cameraData = frameData.Get<UniversalCameraData>();
        UniversalLightData lightData = frameData.Get<UniversalLightData>();
        
        // Создаём текстуру глубины для порталов
        var depthDesc = new TextureDesc(cameraData.cameraTargetDescriptor.width, 
                                        cameraData.cameraTargetDescriptor.height);
        depthDesc.depthBufferBits = DepthBits.Depth32;
        depthDesc.name = PortalDepthTextureName;
        depthDesc.clearBuffer = true;
        depthDesc.clearColor = Color.clear;
        
        TextureHandle portalDepthTexture = renderGraph.CreateTexture(depthDesc);
        
        // Настраиваем отрисовку объектов с tag "PortalMask"
        var sortingCriteria = SortingCriteria.CommonOpaque;
        var drawingSettings = RenderingUtils.CreateDrawingSettings(
            shaderTagId, 
            renderingData, 
            cameraData, 
            lightData, 
            sortingCriteria);
        
        // Создаём параметры для RendererList
        var renderListParams = new RendererListParams(
            renderingData.cullResults, 
            drawingSettings, 
            filteringSettings);
        
        using (var builder = renderGraph.AddRasterRenderPass<PassData>(PassName, out var passData))
        {
            // Создаём RendererList
            passData.rendererListHandle = renderGraph.CreateRendererList(renderListParams);
            passData.portalDepthTexture = portalDepthTexture;
            
            // Используем только depth attachment (без color)
            builder.SetRenderAttachmentDepth(portalDepthTexture, AccessFlags.Write);
            
            // Используем RendererList
            builder.UseRendererList(passData.rendererListHandle);
            
            // Разрешаем изменение глобального состояния для установки текстуры
            builder.AllowGlobalStateModification(true);
            
            // Устанавливаем глобальную текстуру после этого прохода
            builder.SetGlobalTextureAfterPass(portalDepthTexture, PortalDepthTextureId);
            
            builder.SetRenderFunc((PassData data, RasterGraphContext context) =>
            {
                // Рендерим все порталы
                context.cmd.DrawRendererList(data.rendererListHandle);
            });
        }
    }
    
    public void Dispose()
    {
        // Очистка ресурсов если нужно
    }
}
