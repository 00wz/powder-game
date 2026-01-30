using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Rendering.RenderGraphModule;

public class OutlinePass : ScriptableRenderPass
{
    private Material material;
    private const string PassName = "Outline Pass";
    
    private static readonly int ThicknessId = Shader.PropertyToID("_Thickness");
    private static readonly int ThresholdId = Shader.PropertyToID("_Threshold");
    private static readonly int OutlineColorId = Shader.PropertyToID("_OutlineColor");
    private static readonly int BackgroundColorId = Shader.PropertyToID("_BackgroundColor");
    private static readonly int ColorMixId = Shader.PropertyToID("_ColorMix");
    
    public OutlinePass(Material mat, RenderPassEvent evt)
    {
        material = mat;
        renderPassEvent = evt;
        requiresIntermediateTexture = true;
    }
    
    private class PassData
    {
        public Material material;
        public TextureHandle source;
        public float thickness;
        public float threshold;
        public Color outlineColor;
        public Color backgroundColor;
        public float colorMix;
    }
    
    public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
    {
        UniversalResourceData resourceData = frameData.Get<UniversalResourceData>();
        UniversalCameraData cameraData = frameData.Get<UniversalCameraData>();
        
        if (cameraData.cameraType == CameraType.Preview)
            return;
        
        var stack = VolumeManager.instance.stack;
        var outlineVolume = stack.GetComponent<OutlineVolumeComponent>();
        
        if (outlineVolume == null || !outlineVolume.IsActive())
            return;
        
        TextureHandle source = resourceData.cameraColor;
        var desc = renderGraph.GetTextureDesc(source);
        desc.name = "_TempOutline";
        desc.clearBuffer = false;
        
        TextureHandle destination = renderGraph.CreateTexture(desc);
        
        // Apply outline
        using (var builder = renderGraph.AddRasterRenderPass<PassData>(PassName, out var passData))
        {
            passData.material = material;
            passData.source = source;
            passData.thickness = outlineVolume.thickness.value;
            passData.threshold = outlineVolume.threshold.value;
            passData.outlineColor = outlineVolume.outlineColor.value;
            passData.backgroundColor = outlineVolume.backgroundColor.value;
            passData.colorMix = outlineVolume.colorMix.value;
            
            builder.UseTexture(source, AccessFlags.Read);
            builder.SetRenderAttachment(destination, 0, AccessFlags.Write);
            builder.AllowGlobalStateModification(true);
            
            builder.SetRenderFunc((PassData data, RasterGraphContext context) =>
            {
                context.cmd.SetGlobalFloat(ThicknessId, data.thickness);
                context.cmd.SetGlobalFloat(ThresholdId, data.threshold);
                context.cmd.SetGlobalColor(OutlineColorId, data.outlineColor);
                context.cmd.SetGlobalColor(BackgroundColorId, data.backgroundColor);
                context.cmd.SetGlobalFloat(ColorMixId, data.colorMix);
                
                Blitter.BlitTexture(context.cmd, data.source, new Vector4(1, 1, 0, 0), data.material, 0);
            });
        }
        
        // Copy back
        using (var builder = renderGraph.AddRasterRenderPass<PassData>("Copy Back Outline", out var passData))
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
