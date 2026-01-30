using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class InvertColorsFeature : ScriptableRendererFeature
{
    [System.Serializable]
    public class Settings
    {
        [Tooltip("Когда применять эффект")]
        public RenderPassEvent renderPassEvent = RenderPassEvent.AfterRenderingPostProcessing;
        
        [Tooltip("Включить/выключить эффект")]
        public bool enabled = true;
    }
    
    public Settings settings = new Settings();
    
    private InvertColorsPass pass; 
    private Material material;
    
    public override void Create()
    {
        // Загружаем шейдер и создаём материал
        var shader = Shader.Find("Hidden/SRP/InvertColors");
        if (shader == null)
        {
            Debug.LogError("InvertColorsFeature: Shader not found!");
            return;
        }
        
        material = CoreUtils.CreateEngineMaterial(shader);
        pass = new InvertColorsPass(material, settings.renderPassEvent);
    }
    
    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        if (!settings.enabled || material == null || pass == null)
            return;
            
        renderer.EnqueuePass(pass);
    }
    
    protected override void Dispose(bool disposing)
    {
        if (material != null)
        {
            CoreUtils.Destroy(material);
            material = null;
        }
    }
}
