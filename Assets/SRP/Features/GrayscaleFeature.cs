using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class GrayscaleFeature : ScriptableRendererFeature
{
    [System.Serializable]
    public class Settings
    {
        public RenderPassEvent renderPassEvent = RenderPassEvent.AfterRenderingPostProcessing;
    }
    
    public Settings settings = new Settings();
    
    private GrayscalePass pass;
    private Material material;
    
    public override void Create()
    {
        var shader = Shader.Find("Hidden/SRP/Grayscale");
        if (shader == null)
        {
            Debug.LogError("GrayscaleFeature: Shader not found!");
            return;
        }
        
        material = CoreUtils.CreateEngineMaterial(shader);
        pass = new GrayscalePass(material, settings.renderPassEvent);
    }
    
    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        if (material == null || pass == null)
            return;
        
        // Проверяем есть ли активный VolumeComponent
        var stack = VolumeManager.instance.stack;
        var grayscaleVolume = stack.GetComponent<GrayscaleVolumeComponent>();
        
        if (grayscaleVolume == null || !grayscaleVolume.IsActive())
            return;
        
        renderer.EnqueuePass(pass);
    }
    
    protected override void Dispose(bool disposing)
    {
        CoreUtils.Destroy(material);
    }
}
