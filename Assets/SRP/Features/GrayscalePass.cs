using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Rendering.RenderGraphModule;

public class GrayscalePass : ScriptableRenderPass
{
    private Material material;
    private const string PassName = "Grayscale Pass";
    
    private static readonly int IntensityId = Shader.PropertyToID("_Intensity");
    
    public GrayscalePass(Material mat, RenderPassEvent evt)
    {
        material = mat;
        renderPassEvent = evt;
        requiresIntermediateTexture = true;
    }
    
    private class PassData
    {
        public Material material;
        public TextureHandle source;
        public float intensity;
    }
    
    public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
    {
        UniversalResourceData resourceData = frameData.Get<UniversalResourceData>();
        UniversalCameraData cameraData = frameData.Get<UniversalCameraData>();
        
        if (cameraData.cameraType == CameraType.Preview)
            return;
        
        // Получаем VolumeComponent из стека
        var stack = VolumeManager.instance.stack;
        var grayscaleVolume = stack.GetComponent<GrayscaleVolumeComponent>();
        
        // Если компонент не найден или не активен — пропускаем
        if (grayscaleVolume == null || !grayscaleVolume.IsActive())
            return;
        
        float intensity = grayscaleVolume.intensity.value;
        
        TextureHandle source = resourceData.cameraColor;
        var desc = renderGraph.GetTextureDesc(source);
        desc.name = "_TempGrayscale";
        desc.clearBuffer = false;
        
        TextureHandle destination = renderGraph.CreateTexture(desc);
        
        // Pass 1: Apply grayscale
        using (var builder = renderGraph.AddRasterRenderPass<PassData>(PassName, out var passData))
        {
            passData.material = material;
            passData.source = source;
            passData.intensity = intensity;
            
            builder.UseTexture(source, AccessFlags.Read);
            builder.SetRenderAttachment(destination, 0, AccessFlags.Write);
            
            builder.SetRenderFunc((PassData data, RasterGraphContext context) =>
            {
                data.material.SetFloat(IntensityId, data.intensity);
                Blitter.BlitTexture(context.cmd, data.source, new Vector4(1, 1, 0, 0), data.material, 0);
            });
        }
        
        // Pass 2: Copy back
        using (var builder = renderGraph.AddRasterRenderPass<PassData>("Copy Back Grayscale", out var passData))
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
