using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

/// <summary>
/// Renderer Feature для визуализации Depth и Normals буферов.
/// Полезно для отладки и обучения.
/// </summary>
public class DepthNormalsVisualizeFeature : ScriptableRendererFeature
{
    public enum VisualizeMode
    {
        RawDepth = 0,       // Сырое значение из буфера
        Linear01Depth = 1,  // Линейная глубина 0-1
        EyeDepth = 2,       // Глубина в метрах (нормализованная)
        Normals = 3,        // Нормали как RGB
        DepthEdge = 4,      // Edge detection по глубине
        NormalEdge = 5,     // Edge detection по нормалям
        CombinedEdge = 6    // Комбинированный edge (R=depth, G=normal)
    }
    
    [System.Serializable]
    public class Settings
    {
        [Header("Основные настройки")]
        public bool enabled = true;
        public RenderPassEvent renderPassEvent = RenderPassEvent.AfterRenderingPostProcessing;
        
        [Header("Режим визуализации")]
        public VisualizeMode mode = VisualizeMode.Linear01Depth;
        
        [Header("Настройки Eye Depth")]
        [Tooltip("Максимальная дистанция для визуализации Eye Depth (в метрах)")]
        public float maxDepthDistance = 100f;
        
        [Header("Настройки Edge Detection")]
        [Range(0.001f, 0.1f)]
        public float depthThreshold = 0.01f;
        
        [Range(0.1f, 2.0f)]
        public float normalThreshold = 0.5f;
    }
    
    [SerializeField]
    private Settings settings = new Settings();
    
    private Material material;
    private DepthNormalsVisualizePass pass;
    
    private const string ShaderName = "Hidden/SRP/DepthNormalsVisualize";
    
    public override void Create()
    {
        var shader = Shader.Find(ShaderName);
        if (shader == null)
        {
            Debug.LogError($"[DepthNormalsVisualize] Shader '{ShaderName}' not found!");
            return;
        }
        
        material = CoreUtils.CreateEngineMaterial(shader);
        pass = new DepthNormalsVisualizePass(material, settings);
        pass.renderPassEvent = settings.renderPassEvent;
    }
    
    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        if (!settings.enabled || pass == null || material == null)
            return;
        
        if (renderingData.cameraData.cameraType == CameraType.Preview)
            return;
        
        // Обновляем настройки в pass
        pass.UpdateSettings(settings);
        
        renderer.EnqueuePass(pass);
    }
    
    protected override void Dispose(bool disposing)
    {
        pass?.Dispose();
        
        if (material != null)
        {
            CoreUtils.Destroy(material);
            material = null;
        }
    }
}
