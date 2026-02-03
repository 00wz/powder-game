using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

/// <summary>
/// Kawase Blur Renderer Feature — оптимизированное размытие для пост-обработки.
/// Поддерживает два режима:
/// 1. Simple — несколько итераций на полном разрешении
/// 2. Pyramid (Dual Kawase) — downsampling + upsampling для эффективного blur большого радиуса
/// </summary>
public class KawaseBlurFeature : ScriptableRendererFeature
{
    [System.Serializable]
    public class Settings
    {
        [Header("Основные настройки")]
        [Tooltip("Включить эффект")]
        public bool enabled = true;
        
        [Tooltip("На какой стадии рендеринга применять эффект")]
        public RenderPassEvent renderPassEvent = RenderPassEvent.AfterRenderingTransparents;
        
        [Header("Blur настройки")]
        [Tooltip("Использовать пирамиду разрешений (Dual Kawase) — эффективнее для большого blur")]
        public bool usePyramid = true;
        
        [Tooltip("Количество уровней пирамиды (только для Pyramid режима)")]
        [Range(2, 8)]
        public int pyramidLevels = 4;
        
        [Tooltip("Количество итераций (только для Simple режима)")]
        [Range(1, 10)]
        public int iterations = 4;
        
        [Tooltip("Множитель смещения — влияет на силу размытия")]
        [Range(0.5f, 3f)]
        public float blurSpread = 1f;
    }
    
    [SerializeField]
    private Settings settings = new Settings();
    
    private Material material;
    private KawaseBlurPass pass;
    
    private const string ShaderName = "Hidden/SRP/KawaseBlur";
    
    public override void Create()
    {
        // Создаём материал
        var shader = Shader.Find(ShaderName);
        if (shader == null)
        {
            Debug.LogError($"[KawaseBlurFeature] Shader '{ShaderName}' not found!");
            return;
        }
        
        material = CoreUtils.CreateEngineMaterial(shader);
        
        // Создаём pass
        pass = new KawaseBlurPass(material, settings);
        pass.renderPassEvent = settings.renderPassEvent;
    }
    
    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        if (!settings.enabled || pass == null || material == null)
            return;
        
        // Не применяем к preview камерам
        if (renderingData.cameraData.cameraType == CameraType.Preview)
            return;
        
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
