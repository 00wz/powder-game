using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Rendering.RenderGraphModule;

/// <summary>
/// Kawase Blur Render Pass с поддержкой пирамиды разрешений (Dual Kawase).
/// Использует downsampling + upsampling для эффективного размытия большого радиуса.
/// </summary>
public class KawaseBlurPass : ScriptableRenderPass
{
    private const string PassName = "Kawase Blur Pass";
    
    // Индексы проходов в шейдере
    private const int PASS_DOWNSAMPLE = 0;
    private const int PASS_UPSAMPLE = 1;
     private const int PASS_SIMPLE = 2;
    
    private Material material;
    private KawaseBlurFeature.Settings settings;
    
    // Shader property IDs
    private static readonly int OffsetId = Shader.PropertyToID("_Offset");
    
    public KawaseBlurPass(Material material, KawaseBlurFeature.Settings settings)
    {
        this.material = material;
        this.settings = settings;
        requiresIntermediateTexture = true;
    }
    
    // ============================================
    // Pass Data для Render Graph
    // ============================================
    private class PassData
    {
        public Material material;
        public TextureHandle source;
        public int passIndex;
        public float offset;
    }
    
    public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
    {
        if (material == null) return;
        
        UniversalResourceData resourceData = frameData.Get<UniversalResourceData>();
        UniversalCameraData cameraData = frameData.Get<UniversalCameraData>();
        
        if (cameraData.cameraType == CameraType.Preview)
            return;
        
        TextureHandle cameraColor = resourceData.cameraColor;
        var desc = renderGraph.GetTextureDesc(cameraColor);
        desc.clearBuffer = false;
        
        if (settings.usePyramid)
        {
            RenderPyramidBlur(renderGraph, cameraColor, desc);
        }
        else
        {
            RenderSimpleBlur(renderGraph, cameraColor, desc);
        }
    }
    
    // ============================================
    // DUAL KAWASE (с пирамидой)
    // ============================================
    private void RenderPyramidBlur(RenderGraph renderGraph, TextureHandle cameraColor, TextureDesc baseDesc)
    {
        int pyramidLevels = settings.pyramidLevels;
        
        // Создаём текстуры для пирамиды
        TextureHandle[] downsampled = new TextureHandle[pyramidLevels];
        TextureHandle[] upsampled = new TextureHandle[pyramidLevels];
        
        int width = baseDesc.width;
        int height = baseDesc.height;
        
        // Создаём все текстуры заранее
        for (int i = 0; i < pyramidLevels; i++)
        {
            width = Mathf.Max(1, width / 2);
            height = Mathf.Max(1, height / 2);
            
            var downDesc = baseDesc;
            downDesc.width = width;
            downDesc.height = height;
            downDesc.name = $"_KawaseDown_{i}";
            downsampled[i] = renderGraph.CreateTexture(downDesc);
            
            var upDesc = baseDesc;
            upDesc.width = width;
            upDesc.height = height;
            upDesc.name = $"_KawaseUp_{i}";
            upsampled[i] = renderGraph.CreateTexture(upDesc);
        }
        
        // ===== DOWNSAMPLE PASSES =====
        // Первый downsample: cameraColor -> downsampled[0]
        AddKawasePass(renderGraph, cameraColor, downsampled[0], PASS_DOWNSAMPLE, 0, "Kawase Down 0");
        
        // Остальные downsample
        for (int i = 1; i < pyramidLevels; i++)
        {
            AddKawasePass(renderGraph, downsampled[i - 1], downsampled[i], 
                         PASS_DOWNSAMPLE, i * settings.blurSpread, $"Kawase Down {i}");
        }
        
        // ===== UPSAMPLE PASSES =====
        // Первый upsample: downsampled[last] -> upsampled[last-1]
        int last = pyramidLevels - 1;
        AddKawasePass(renderGraph, downsampled[last], upsampled[last - 1], 
                     PASS_UPSAMPLE, last * settings.blurSpread, $"Kawase Up {last}");
        
        // Остальные upsample
        for (int i = last - 1; i > 0; i--)
        {
            AddKawasePass(renderGraph, upsampled[i], upsampled[i - 1], 
                         PASS_UPSAMPLE, i * settings.blurSpread, $"Kawase Up {i}");
        }
        
        // Финальный upsample: upsampled[0] -> cameraColor
        AddKawasePass(renderGraph, upsampled[0], cameraColor, PASS_UPSAMPLE, 0, "Kawase Final");
    }
    
    // ============================================
    // SIMPLE KAWASE (без пирамиды)
    // ============================================
    private void RenderSimpleBlur(RenderGraph renderGraph, TextureHandle cameraColor, TextureDesc baseDesc)
    {
        int iterations = settings.iterations;
        
        // Создаём все временные текстуры заранее
        TextureHandle[] temps = new TextureHandle[iterations + 1];
        for (int i = 0; i < temps.Length; i++)
        {
            var desc = baseDesc;
            desc.name = $"_KawaseTemp_{i}";
            temps[i] = renderGraph.CreateTexture(desc);
        }
        
        // Копируем исходное изображение в temps[0]
        AddCopyPass(renderGraph, cameraColor, temps[0], "Kawase Copy Input");
        
        // Итерации blur
        for (int i = 0; i < iterations; i++)
        {
            AddKawasePass(renderGraph, temps[i], temps[i + 1], 
                         PASS_SIMPLE, i * settings.blurSpread, $"Kawase Iter {i}");
        }
        
        // Копируем результат обратно
        AddCopyPass(renderGraph, temps[iterations], cameraColor, "Kawase Copy Output");
    }
    
    // ============================================
    // Helper: Kawase Pass
    // ============================================
    private void AddKawasePass(RenderGraph renderGraph, TextureHandle source, TextureHandle destination,
                               int passIndex, float offset, string passName)
    {
        using (var builder = renderGraph.AddRasterRenderPass<PassData>(passName, out var passData))
        {
            passData.material = material;
            passData.source = source;
            passData.passIndex = passIndex;
            passData.offset = offset;
            
            builder.UseTexture(source, AccessFlags.Read);
            builder.SetRenderAttachment(destination, 0, AccessFlags.Write);
            builder.AllowGlobalStateModification(true);
            
            builder.SetRenderFunc((PassData data, RasterGraphContext context) =>
            {
                data.material.SetFloat(OffsetId, data.offset);
                Blitter.BlitTexture(context.cmd, data.source, new Vector4(1, 1, 0, 0), data.material, data.passIndex);
            });
        }
    }
    
    // ============================================
    // Helper: Copy Pass
    // ============================================
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
    
    public void Dispose()
    {
        // Материал управляется Feature
    }
}
