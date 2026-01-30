using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class PixelateFeature : ScriptableRendererFeature
{
    [System.Serializable]
    public class Settings
    {
        public RenderPassEvent renderPassEvent = RenderPassEvent.AfterRenderingPostProcessing;
        
        [Range(1f, 32f)]
        [Tooltip("Размер 'большого пикселя' в экранных пикселях")]
        public float pixelSize = 8f;
        
        public bool enabled = true;
    }
    
    public Settings settings = new Settings();
    
    private PixelatePass pass;
    private Material material;
    
    public override void Create()
    {
        var shader = Shader.Find("Hidden/SRP/Pixelate");
        if (shader == null)
        {
            Debug.LogError("PixelateFeature: Shader not found!");
            return;
        }
        
        material = CoreUtils.CreateEngineMaterial(shader);
        pass = new PixelatePass(material, settings.renderPassEvent);
    }
    
    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        if (!settings.enabled || material == null || pass == null)
            return;
        
        // Передаём текущее значение pixelSize
        pass.SetPixelSize(settings.pixelSize);
        renderer.EnqueuePass(pass);
    }
    
    protected override void Dispose(bool disposing)
    {
        CoreUtils.Destroy(material);
    }
}
