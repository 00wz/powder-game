using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class OutlineFeature : ScriptableRendererFeature
{
    [System.Serializable]
    public class Settings
    {
        public RenderPassEvent renderPassEvent = RenderPassEvent.AfterRenderingPostProcessing;
    }
    
    public Settings settings = new Settings();
    
    private OutlinePass pass;
    private Material material;
    
    public override void Create()
    {
        var shader = Shader.Find("Hidden/SRP/SobelOutline");
        if (shader == null)
        {
            Debug.LogError("OutlineFeature: Shader not found!");
            return;
        }
        
        material = CoreUtils.CreateEngineMaterial(shader);
        pass = new OutlinePass(material, settings.renderPassEvent);
    }
    
    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        if (material == null || pass == null)
            return;
        
        var stack = VolumeManager.instance.stack;
        var outlineVolume = stack.GetComponent<OutlineVolumeComponent>();
        
        if (outlineVolume == null || !outlineVolume.IsActive())
            return;
        
        renderer.EnqueuePass(pass);
    }
    
    protected override void Dispose(bool disposing)
    {
        CoreUtils.Destroy(material);
    }
}
