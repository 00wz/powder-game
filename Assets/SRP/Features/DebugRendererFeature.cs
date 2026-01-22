using UnityEngine;
using UnityEngine.Rendering.Universal;

public class DebugRendererFeature : ScriptableRendererFeature
{
    [System.Serializable]
    public class Settings
    {
        public RenderPassEvent renderPassEvent = RenderPassEvent.AfterRenderingPostProcessing;
        public string passName = "Debug Pass";
    }
    
    public Settings settings = new Settings();
    private DebugRenderPass debugPass;
    
    // Вызывается при инициализации Feature
    public override void Create()
    {
        debugPass = new DebugRenderPass(settings.passName, settings.renderPassEvent);
        Debug.Log($"[DebugRendererFeature] Create() - Pass created");
    }
    
    // Вызывается каждый кадр для добавления passes в очередь
    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        // Добавляем наш pass в очередь рендеринга
        renderer.EnqueuePass(debugPass);
    }
    
    // Cleanup при уничтожении
    protected override void Dispose(bool disposing)
    {
        Debug.Log($"[DebugRendererFeature] Dispose()");
    }
}
