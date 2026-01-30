using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Rendering.RenderGraphModule;

public class VignettePass : ScriptableRenderPass
{
    private Material material;
    private float intensity;
    private float smoothness;
    private Color vignetteColor;
    private const string PassName = "Vignette Pass";
    
    private static readonly int IntensityId = Shader.PropertyToID("_Intensity");
    private static readonly int SmoothnessId = Shader.PropertyToID("_Smoothness");
    private static readonly int VignetteColorId = Shader.PropertyToID("_VignetteColor");
    
    public VignettePass(Material mat, RenderPassEvent evt)
    {
        material = mat;
        renderPassEvent = evt;
        requiresIntermediateTexture = true;
    }
    
    public void SetParameters(float intensity, float smoothness, Color color)
    {
        this.intensity = Mathf.Clamp01(intensity);
        this.smoothness = Mathf.Clamp(smoothness, 0.01f, 1f);
        this.vignetteColor = color;
    }
    
    private class PassData
    {
        public Material material;
        public TextureHandle source;
        public float intensity;
        public float smoothness;
        public Color vignetteColor;
    }
    
    public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
    {
        UniversalResourceData resourceData = frameData.Get<UniversalResourceData>();
        UniversalCameraData cameraData = frameData.Get<UniversalCameraData>();
        
        if (cameraData.cameraType == CameraType.Preview)
            return;
        
        // Оптимизация: пропускаем если эффект выключен
        if (intensity <= 0.001f)
            return;
        
        TextureHandle source = resourceData.cameraColor;
        var desc = renderGraph.GetTextureDesc(source);
        desc.name = "_TempVignette";
        desc.clearBuffer = false;
        
        TextureHandle destination = renderGraph.CreateTexture(desc);
        
        // Pass 1: Apply vignette
        using (var builder = renderGraph.AddRasterRenderPass<PassData>(PassName, out var passData))
        {
            passData.material = material;
            passData.source = source;
            passData.intensity = intensity;
            passData.smoothness = smoothness;
            passData.vignetteColor = vignetteColor;
            
            builder.UseTexture(source, AccessFlags.Read);
            builder.SetRenderAttachment(destination, 0, AccessFlags.Write);
            
            builder.SetRenderFunc((PassData data, RasterGraphContext context) =>
            {
                data.material.SetFloat(IntensityId, data.intensity);
                data.material.SetFloat(SmoothnessId, data.smoothness);
                data.material.SetColor(VignetteColorId, data.vignetteColor);
                
                Blitter.BlitTexture(context.cmd, data.source, new Vector4(1, 1, 0, 0), data.material, 0);
            });
        }
        
        // Pass 2: Copy back
        using (var builder = renderGraph.AddRasterRenderPass<PassData>("Copy Back Vignette", out var passData))
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
