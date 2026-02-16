using UnityEngine;
using UnityEngine.Rendering;

/// <summary>
/// ScriptableObject, который хранит настройки нашего рендер-пайплайна.
/// Назначается в Project Settings → Graphics → Scriptable Render Pipeline Settings.
///
/// Используем generic версию RenderPipelineAsset<T> для совместимости с Unity 6+
///
/// Урок 13-15: Custom SRP - Архитектура, освещение и тени
/// </summary>
[CreateAssetMenu(menuName = "Rendering/Custom Render Pipeline Asset")]
public class CustomRenderPipelineAsset : RenderPipelineAsset<CustomRenderPipeline>
{
    [Header("General")]
    [Tooltip("Включает SRP Batcher для оптимизации")]
    [SerializeField] private bool useSRPBatcher = true;
    
    [Header("Camera Defaults")]
    [Tooltip("Цвет очистки по умолчанию (если камера не задаёт свой)")]
    [SerializeField] private Color defaultClearColor = new Color(0.1f, 0.1f, 0.15f, 1f);
    
    [Header("Rendering")]
    [Tooltip("Рендерить Skybox")]
    [SerializeField] private bool renderSkybox = true;
    
    [Tooltip("Рендерить прозрачные объекты")]
    [SerializeField] private bool renderTransparent = true;
    
    [Header("Shadows")]
    [Tooltip("Разрешение shadow map (512, 1024, 2048, 4096)")]
    [SerializeField] private int shadowMapSize = 2048;
    
    [Tooltip("Дальность отрисовки теней")]
    [SerializeField] private float shadowDistance = 50f;
    
    [Tooltip("Bias для уменьшения shadow acne")]
    [Range(0f, 0.1f)]
    [SerializeField] private float shadowBias = 0.005f;
    
    [Tooltip("Сила тени (0 = нет тени, 1 = полная тень)")]
    [Range(0f, 1f)]
    [SerializeField] private float shadowStrength = 1f;
    
    [Header("Debug")]
    [Tooltip("Показывать объекты с неподдерживаемыми шейдерами")]
    [SerializeField] private bool showUnsupportedShaders = true;
    
    // Публичные свойства для доступа из пайплайна
    public bool UseSRPBatcher => useSRPBatcher;
    public Color DefaultClearColor => defaultClearColor;
    public bool RenderSkybox => renderSkybox;
    public bool RenderTransparent => renderTransparent;
    public bool ShowUnsupportedShaders => showUnsupportedShaders;
    
    // Свойства теней
    public int ShadowMapSize => shadowMapSize;
    public float ShadowDistance => shadowDistance;
    public float ShadowBias => shadowBias;
    public float ShadowStrength => shadowStrength;
    
    /// <summary>
    /// Уникальный тег для шейдеров этого пайплайна.
    /// Используется для strip'а неиспользуемых вариантов при билде.
    /// </summary>
    public override string renderPipelineShaderTag => "CustomPipeline";
    
    /// <summary>
    /// Unity вызывает этот метод при активации пайплайна.
    /// Создаёт экземпляр CustomRenderPipeline.
    /// </summary>
    protected override RenderPipeline CreatePipeline()
    {
        return new CustomRenderPipeline(this);
    }
}
