using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class VignetteFeature : ScriptableRendererFeature
{
    [System.Serializable]
    public class Settings
    {
        public RenderPassEvent renderPassEvent = RenderPassEvent.AfterRenderingPostProcessing;
        
        [Range(0f, 1f)]
        [Tooltip("Интенсивность эффекта. 0 = нет эффекта, 1 = максимальное затемнение")]
        public float intensity = 0.5f;
        
        [Range(0.01f, 1f)]
        [Tooltip("Плавность перехода от яркого к тёмному")]
        public float smoothness = 0.3f;
        
        [Tooltip("Цвет виньетки (обычно чёрный)")]
        public Color vignetteColor = Color.black;
        
        public bool enabled = true;
    }
    
    public Settings settings = new Settings();
    
    private VignettePass pass;
    private Material material;
    
    public override void Create()
    {
        var shader = Shader.Find("Hidden/SRP/Vignette");
        if (shader == null)
        {
            Debug.LogError("VignetteFeature: Shader not found!");
            return;
        }
        
        material = CoreUtils.CreateEngineMaterial(shader);
        pass = new VignettePass(material, settings.renderPassEvent);
    }
    
    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        if (!settings.enabled || material == null || pass == null)
            return;
        
        pass.SetParameters(settings.intensity, settings.smoothness, settings.vignetteColor);
        renderer.EnqueuePass(pass);
    }
    
    protected override void Dispose(bool disposing)
    {
        CoreUtils.Destroy(material);
    }
}
