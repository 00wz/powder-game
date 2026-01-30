using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Rendering.RenderGraphModule;

public class InvertColorsPass : ScriptableRenderPass
{
    private Material material;
    private const string PassName = "Invert Colors Pass";
    
    public InvertColorsPass(Material mat, RenderPassEvent evt)
    {
        material = mat;
        renderPassEvent = evt;
        requiresIntermediateTexture = true; // Нужна временная текстура
    }
    
    // Данные для Render Graph
    private class PassData
    {
        public Material material;
        public TextureHandle source;
    }
    
    public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
    {
        // Получаем ресурсы кадра
        UniversalResourceData resourceData = frameData.Get<UniversalResourceData>();
        UniversalCameraData cameraData = frameData.Get<UniversalCameraData>();
        
        // Пропускаем для Preview и Reflection камер
        if (cameraData.cameraType == CameraType.Preview || 
            cameraData.cameraType == CameraType.Reflection)
            return;
        
        // Используем cameraColor как источник
        TextureHandle source = resourceData.cameraColor;
        
        // Получаем описание текстуры для создания временной
        var desc = renderGraph.GetTextureDesc(source);
        desc.name = "_TempInvertColors";
        desc.clearBuffer = false;
        
        // Создаём временную текстуру для результата
        TextureHandle destination = renderGraph.CreateTexture(desc);
        
        // Создаём Raster Pass
        using (var builder = renderGraph.AddRasterRenderPass<PassData>(PassName, out var passData))
        {
            passData.material = material;
            passData.source = source;
            
            // Объявляем что читаем source
            builder.UseTexture(source, AccessFlags.Read);
            
            // Объявляем что пишем в destination
            builder.SetRenderAttachment(destination, 0, AccessFlags.Write);
            
            // Устанавливаем функцию рендеринга
            builder.SetRenderFunc((PassData data, RasterGraphContext context) =>
            {
                // Blitter.BlitTexture рисует full-screen quad с нашим материалом
                Blitter.BlitTexture(context.cmd, data.source, new Vector4(1, 1, 0, 0), data.material, 0);
            });
        }
        
        // Копируем результат обратно в cameraColor
        using (var builder = renderGraph.AddRasterRenderPass<PassData>("Copy Back", out var passData))
        {
            passData.source = destination;
            
            builder.UseTexture(destination, AccessFlags.Read);
            builder.SetRenderAttachment(source, 0, AccessFlags.Write);
            
            builder.SetRenderFunc((PassData data, RasterGraphContext context) =>
            {
                Blitter.BlitTexture(context.cmd, data.source, new Vector4(1, 1, 0, 0), 0, false);
            });
        }
    }
}
