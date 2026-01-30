using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class BlurFeature : ScriptableRendererFeature
{
    [System.Serializable]
    public class Settings
    {
        public RenderPassEvent renderPassEvent = RenderPassEvent.AfterRenderingPostProcessing;
    }
    
    public Settings settings = new Settings();
    
    private BlurPass pass;
    private Material material;
    
    public override void Create()
    {
        var shader = Shader.Find("Hidden/SRP/GaussianBlur");
        if (shader == null)
        {
            Debug.LogError("BlurFeature: Shader not found!");
            return;
        }
        
        material = CoreUtils.CreateEngineMaterial(shader);
        pass = new BlurPass(material, settings.renderPassEvent);
    }
    
    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        if (material == null || pass == null)
            return;
        
        var stack = VolumeManager.instance.stack;
        var blurVolume = stack.GetComponent<BlurVolumeComponent>();
        
        if (blurVolume == null || !blurVolume.IsActive())
            return;
        
        renderer.EnqueuePass(pass);
    }
    
    protected override void Dispose(bool disposing)
    {
        CoreUtils.Destroy(material);
    }
}
