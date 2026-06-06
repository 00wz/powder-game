using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

/// <summary>
/// Screen Space Path Tracing — ScriptableRendererFeature.
/// Добавьте в Renderer Asset рядом с SSR (или вместо него).
///
/// SSPT vs SSR:
///   SSR  — один specular луч по направлению отражения → зеркальные отражения
///   SSPT — N стохастических лучей по hemisphere над normal → diffuse GI
///
/// Пайплайн:
///   Trace → Temporal Accumulate → A-Trous Denoise (×N) → Composite
/// </summary>
public class SSPTFeature : ScriptableRendererFeature
{
    [System.Serializable]
    public class Settings
    {
        [Header("Rendering")]
        public RenderPassEvent renderPassEvent = RenderPassEvent.AfterRenderingTransparents;

        [Header("Tracing")]
        [Range(1, 8)]
        [Tooltip("Лучей на пиксель за кадр. 1 = максимальная скорость, temporal сгладит. " +
                 "4–8 = меньше шума, но дороже GPU.")]
        public int samplesPerPixel = 1;

        [Range(8, 128)]
        [Tooltip("Шагов ray march на луч. Больше = дальше видим сквозь экран, дороже.")]
        public int maxSteps = 48;

        [Range(1f, 100f)]
        [Tooltip("Макс. расстояние луча в world units.")]
        public float maxDistance = 25f;

        [Range(0.01f, 2f)]
        [Tooltip("Толщина поверхности для определения хита. " +
                 "Больше = меньше пропущенных хитов, но хуже точность.")]
        public float thickness = 0.3f;

        [Range(0.01f, 0.5f)]
        [Tooltip("Ширина зоны затухания у краёв экрана.")]
        public float edgeFade = 0.12f;

        [Header("Temporal Accumulation")]
        [Range(0.02f, 1f)]
        [Tooltip("Blend с историей. 0.05 = медленная сходимость, мало ghosting. " +
                 "0.5 = быстро, но ghosting при движении.")]
        public float temporalAlpha = 0.1f;

        [Header("Spatial Denoising")]
        [Range(0, 4)]
        [Tooltip("Итераций A-Trous wavelet denoise. " +
                 "0 = только temporal. 3–4 = сглаженный результат.")]
        public int denoiseIterations = 3;

        [Header("Composite")]
        [Range(0f, 3f)]
        [Tooltip("Интенсивность добавляемого GI (цветовой отблеск от соседних поверхностей). " +
                 "Типичные значения: 0.3–0.6.")]
        public float indirectIntensity = 0.5f;

        [Range(0f, 1f)]
        [Tooltip("Сила AO-коррекции: снижает яркость в перекрытых зонах, компенсируя " +
                 "SH-ambient URP. 0 = только color bleeding. 0.3–0.5 — рекомендуется.")]
        public float aoStrength = 0.3f;

    }

    public Settings settings = new Settings();

    [SerializeField] private Shader m_Shader;

    private Material m_Material;
    private SSPTPass m_Pass;

    public override void Create()
    {
        if (m_Shader == null)
            m_Shader = Shader.Find("Hidden/SSPT");

        if (m_Shader == null)
        {
            Debug.LogError("SSPTFeature: шейдер 'Hidden/SSPT' не найден!");
            return;
        }

        if (m_Material == null)
            m_Material = CoreUtils.CreateEngineMaterial(m_Shader);

        if (m_Material != null)
            m_Pass = new SSPTPass(m_Material, settings);
    }

    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        if (m_Pass == null || m_Material == null) return;
        if (renderingData.cameraData.cameraType == CameraType.Preview) return;
        if (renderingData.cameraData.cameraType == CameraType.Reflection) return;

        m_Pass.UpdateSettings(settings);
        renderer.EnqueuePass(m_Pass);
    }

    protected override void Dispose(bool disposing)
    {
        m_Pass?.Dispose();
        if (m_Material != null)
        {
            CoreUtils.Destroy(m_Material);
            m_Material = null;
        }
    }
}
