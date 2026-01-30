using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

/// <summary>
/// Renderer Feature для рендеринга глубины порталов в отдельную текстуру.
/// Эта текстура используется шейдером PortalContent для отсечения объектов перед порталом.
/// </summary>
public class PortalDepthFeature : ScriptableRendererFeature
{
    [System.Serializable]
    public class Settings
    {
        [Tooltip("На какой стадии рендеринга выполнять проход")]
        public RenderPassEvent renderPassEvent = RenderPassEvent.BeforeRenderingOpaques;
        
        [Tooltip("Layer маска для порталов")]
        public LayerMask portalLayerMask = -1;
        
        [Tooltip("Имя shader tag для порталов (например, 'PortalMask')")]
        public string shaderTagId = "PortalMask";
    }
    
    public Settings settings = new Settings();
    
    private PortalDepthPass pass;
    
    public override void Create()
    {
        pass = new PortalDepthPass(settings);
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
