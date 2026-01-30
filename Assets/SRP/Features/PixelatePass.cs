using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Rendering.RenderGraphModule;

public class PixelatePass : ScriptableRenderPass
{
    private Material material;
    private float pixelSize;
    private const string PassName = "Pixelate Pass";
    
    // Shader property IDs (кэшируем для производительности)
    private static readonly int PixelSizeId = Shader.PropertyToID("_PixelSize");
    private static readonly int ScreenSizeId = Shader.PropertyToID("_PixelateScreenSize"); // Переименовано
    
    public PixelatePass(Material mat, RenderPassEvent evt)
    {
        material = mat;
        renderPassEvent = evt;
        requiresIntermediateTexture = true;
    }
    
    public void SetPixelSize(float size)
    {
        pixelSize = size;
    }
    
    private class PassData
    {
        public Material material;
        public TextureHandle source;
        public float pixelSize;
        public Vector2 screenSize;
    }
    
    public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
    {
        UniversalResourceData resourceData = frameData.Get<UniversalResourceData>();
        UniversalCameraData cameraData = frameData.Get<UniversalCameraData>();
        
        if (cameraData.cameraType == CameraType.Preview)
            return;
        
        TextureHandle source = resourceData.cameraColor;
        var desc = renderGraph.GetTextureDesc(source);
        desc.name = "_TempPixelate";
        desc.clearBuffer = false;
        
        TextureHandle destination = renderGraph.CreateTexture(desc);
        
        // Pass 1: Apply pixelation
        using (var builder = renderGraph.AddRasterRenderPass<PassData>(PassName, out var passData))
        {
            passData.material = material;
            passData.source = source;
            passData.pixelSize = pixelSize;
            passData.screenSize = new Vector2(desc.width, desc.height);
            
            builder.UseTexture(source, AccessFlags.Read);
            builder.SetRenderAttachment(destination, 0, AccessFlags.Write);
            
            builder.SetRenderFunc((PassData data, RasterGraphContext context) =>
            {
                // Устанавливаем параметры шейдера
                data.material.SetFloat(PixelSizeId, data.pixelSize);
                data.material.SetVector(ScreenSizeId, data.screenSize);
                
                Blitter.BlitTexture(context.cmd, data.source, new Vector4(1, 1, 0, 0), data.material, 0);
            });
        }
        
        // Pass 2: Copy back
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
