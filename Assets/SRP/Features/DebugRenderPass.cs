using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Rendering.RenderGraphModule;

public class DebugRenderPass : ScriptableRenderPass
{
    private string debugPassName;
    
    public DebugRenderPass(string name, RenderPassEvent evt)
    {
        debugPassName = name;
        renderPassEvent = evt;
        
        // Указываем, что этот pass не требует intermediate texture
        requiresIntermediateTexture = false;
    }
    
    // Класс для хранения данных pass (обязателен для Render Graph)
    private class PassData
    {
        public string passName;
        public int frameCount;
    }
    
    // Новый метод для Render Graph API (Unity 6+)
    public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
    {
        // Получаем данные о камере
        UniversalCameraData cameraData = frameData.Get<UniversalCameraData>();
        
        // Создаём raster pass (для рисования на экран)
        using (var builder = renderGraph.AddRasterRenderPass<PassData>(debugPassName, out var passData))
        {
            // Сохраняем данные для использования в render function
            passData.passName = debugPassName;
            passData.frameCount = Time.frameCount;
            
            // Устанавливаем функцию рендеринга
            builder.SetRenderFunc((PassData data, RasterGraphContext context) =>
            {
                // Это выполняется на GPU timeline
                Debug.Log($"[{data.passName}] RecordRenderGraph Execute - Frame: {data.frameCount}, Camera: {context.cmd}");
            });
            
            // Разрешаем pass без render targets (для debug)
            builder.AllowPassCulling(false);
        }
        
        Debug.Log($"[{debugPassName}] RecordRenderGraph() - Camera: {cameraData.camera.name}, Resolution: {cameraData.cameraTargetDescriptor.width}x{cameraData.cameraTargetDescriptor.height}");
    }
    
    // Cleanup при уничтожении камеры (опционально)
    public override void OnCameraCleanup(CommandBuffer cmd)
    {
        // Debug.Log($"[{debugPassName}] OnCameraCleanup()");
        // Закомментировано чтобы не спамить в консоль
    }
}
