using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class SSRFeature : ScriptableRendererFeature
{
    public enum TracingMethod
    {
        Linear,
        HiZMinMax
    }

    public enum HiZDebugMode
    {
        Off,
        ShowPyramidMip
    }

    [System.Serializable]
    public class Settings
    {
        [Header("Rendering")]
        public RenderPassEvent renderPassEvent = RenderPassEvent.AfterRenderingTransparents;

        [Header("Tracing Method")]
        [Tooltip("Linear = обычный ray marching. HiZMinMax = трассировка через Hi-Z min/max пирамиду.")]
        public TracingMethod tracingMethod = TracingMethod.Linear;

        [Header("Ray Marching")]
        [Tooltip("Максимальное количество шагов ray marching")]
        [Range(8, 128)]
        public int maxSteps = 32;

        [Tooltip("Максимальная дистанция отражения в world units")]
        [Range(1f, 100f)]
        public float maxDistance = 50f;

        [Header("Quality")]
        [Tooltip("Толщина для определения пересечения")]
        [Range(0.01f, 2f)]
        public float thickness = 0.5f;

        [Tooltip("Сила джиттера (рандомизация стартовой позиции луча, уменьшает бандинг)")]
        [Range(0f, 1f)]
        public float jitterStrength = 0.2f;

        [Header("Appearance")]
        [Tooltip("Интенсивность отражений")]
        [Range(0f, 1f)]
        public float intensity = 0.5f;

        [Tooltip("Затухание к краям экрана")]
        [Range(0.01f, 0.5f)]
        public float edgeFade = 0.1f;

        [Header("Multi-Pass")]
        [Tooltip("Количество проходов SSR (больше = вторичные отражения, но дороже)")]
        [Range(1, 4)]
        public int passCount = 1;

        [Header("Skybox Fallback")]
        [Tooltip("Использовать skybox когда SSR не находит пересечение")]
        public bool useSkyboxFallback = true;

        [Tooltip("Cubemap для отражений (если не задан - используется Reflection Probe или Lighting Skybox)")]
        public Cubemap fallbackCubemap;

        [Header("Hi-Z Pyramid")]
        [Tooltip("Максимальное число уровней Hi-Z пирамиды (ограничивает и качество, и стоимость построения)")]
        [Range(1, SSRPass.HiZMaxMips)]
        public int maxMipLevel = 8;

        [Tooltip("Масштаб разрешения, с которым строится Hi-Z пирамида относительно экрана")]
        [Range(0.25f, 1f)]
        public float pyramidResolutionScale = 1f;

        [Header("Hi-Z Debug")]
        [Tooltip("Показать содержимое Hi-Z пирамиды вместо результата SSR (левая половина экрана = min, правая = max)")]
        public HiZDebugMode debugMode = HiZDebugMode.Off;

        [Tooltip("Индекс отображаемого уровня пирамиды")]
        [Range(0, SSRPass.HiZMaxMips - 1)]
        public int debugMipIndex = 0;
    }

    public Settings settings = new Settings();

    [SerializeField]
    private Shader m_Shader;

    [SerializeField]
    private Shader m_HiZShader;

    private Material m_Material;
    private Material m_HiZMaterial;
    private SSRPass m_Pass;

    public override void Create()
    {
        // Загружаем шейдеры
        if (m_Shader == null)
        {
            m_Shader = Shader.Find("Hidden/SSR");
        }

        if (m_Shader == null)
        {
            Debug.LogError("SSRFeature: Shader 'Hidden/SSR' not found!");
            return;
        }

        if (m_HiZShader == null)
        {
            m_HiZShader = Shader.Find("Hidden/HiZDepthPyramid");
        }

        if (m_HiZShader == null)
        {
            Debug.LogError("SSRFeature: Shader 'Hidden/HiZDepthPyramid' not found!");
            return;
        }

        // Создаём материалы
        if (m_Material == null)
        {
            m_Material = CoreUtils.CreateEngineMaterial(m_Shader);
        }

        if (m_HiZMaterial == null)
        {
            m_HiZMaterial = CoreUtils.CreateEngineMaterial(m_HiZShader);
        }

        // Создаём pass
        if (m_Material != null && m_HiZMaterial != null)
        {
            m_Pass = new SSRPass(m_Material, m_HiZMaterial, settings);
        }
    }

    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        if (m_Pass == null || m_Material == null)
            return;

        // Пропускаем для preview камер
        if (renderingData.cameraData.cameraType == CameraType.Preview)
            return;

        // Пропускаем для reflection камер
        if (renderingData.cameraData.cameraType == CameraType.Reflection)
            return;

        // Обновляем настройки
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

        if (m_HiZMaterial != null)
        {
            CoreUtils.Destroy(m_HiZMaterial);
            m_HiZMaterial = null;
        }
    }
}
