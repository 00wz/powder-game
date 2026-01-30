using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Rendering.RenderGraphModule;

public class BlurPass : ScriptableRenderPass
{
    private Material material;
    private const string PassName = "Blur Pass";
    
    private static readonly int BlurDirectionId = Shader.PropertyToID("_BlurDirection");
    private static readonly int BlurSizeId = Shader.PropertyToID("_BlurSize");
    
    public BlurPass(Material mat, RenderPassEvent evt)
    {
        material = mat;
        renderPassEvent = evt;
        requiresIntermediateTexture = true;
    }
    
    private class PassData
    {
        public Material material;
        public TextureHandle source;
        public Vector4 direction;
        public float blurSize;
    }
    
    public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
    {
        UniversalResourceData resourceData = frameData.Get<UniversalResourceData>();
        UniversalCameraData cameraData = frameData.Get<UniversalCameraData>();
        
        if (cameraData.cameraType == CameraType.Preview)
            return;
        
        var stack = VolumeManager.instance.stack;
        var blurVolume = stack.GetComponent<BlurVolumeComponent>();
        
        if (blurVolume == null || !blurVolume.IsActive())
            return;
        
        float blurSize = blurVolume.intensity.value;
        int iterations = blurVolume.iterations.value;
        
        TextureHandle cameraColor = resourceData.cameraColor;
        var desc = renderGraph.GetTextureDesc(cameraColor);
        desc.clearBuffer = false;
        
        // Создаём все необходимые текстуры заранее
        TextureHandle[] temps = new TextureHandle[iterations * 2 + 1];
        for (int i = 0; i < temps.Length; i++)
        {
            desc.name = $"_TempBlur_{i}";
            temps[i] = renderGraph.CreateTexture(desc);
        }
        
        // Первый проход: копируем из cameraColor в temps[0]
        AddCopyPass(renderGraph, cameraColor, temps[0], "Blur Copy Input");
        
        int currentIndex = 0;
        
        for (int i = 0; i < iterations; i++)
        {
            // Horizontal pass: temps[currentIndex] -> temps[currentIndex + 1]
            AddBlurPass(renderGraph, temps[currentIndex], temps[currentIndex + 1], 
                       new Vector4(1, 0, 0, 0), blurSize, $"Blur H {i}");
            currentIndex++;
            
            // Vertical pass: temps[currentIndex] -> temps[currentIndex + 1]
            AddBlurPass(renderGraph, temps[currentIndex], temps[currentIndex + 1], 
                       new Vector4(0, 1, 0, 0), blurSize, $"Blur V {i}");
            currentIndex++;
        }
        
        // Финальный проход: копируем результат обратно в cameraColor
        AddCopyPass(renderGraph, temps[currentIndex], cameraColor, "Blur Copy Output");
    }
    
    private void AddBlurPass(RenderGraph renderGraph, TextureHandle source, TextureHandle destination, 
                             Vector4 direction, float blurSize, string passName)
    {
        using (var builder = renderGraph.AddRasterRenderPass<PassData>(passName, out var passData))
        {
            passData.material = material;
            passData.source = source;
            passData.direction = direction;
            passData.blurSize = blurSize;
            
            builder.UseTexture(source, AccessFlags.Read);
            builder.SetRenderAttachment(destination, 0, AccessFlags.Write);
            
            // Разрешаем модификацию global state
            builder.AllowGlobalStateModification(true);
            
            builder.SetRenderFunc((PassData data, RasterGraphContext context) =>
            {
                context.cmd.SetGlobalVector(BlurDirectionId, data.direction);
                context.cmd.SetGlobalFloat(BlurSizeId, data.blurSize);
                Blitter.BlitTexture(context.cmd, data.source, new Vector4(1, 1, 0, 0), data.material, 0);
            });
        }
    }
    
    private void AddCopyPass(RenderGraph renderGraph, TextureHandle source, TextureHandle destination, string passName)
    {
        using (var builder = renderGraph.AddRasterRenderPass<PassData>(passName, out var passData))
        {
            passData.source = source;
            
            builder.UseTexture(source, AccessFlags.Read);
            builder.SetRenderAttachment(destination, 0, AccessFlags.Write);
            
            builder.SetRenderFunc((PassData data, RasterGraphContext context) =>
            {
                Blitter.BlitTexture(context.cmd, data.source, new Vector4(1, 1, 0, 0), 0, false);
            });
        }
    }
}
