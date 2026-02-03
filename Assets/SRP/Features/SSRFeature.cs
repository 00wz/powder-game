using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class SSRFeature : ScriptableRendererFeature
{
    [System.Serializable]
    public class Settings
    {
        [Header("Rendering")]
        public RenderPassEvent renderPassEvent = RenderPassEvent.AfterRenderingTransparents;
        
        [Header("Ray Marching")]
        [Tooltip("Максимальное количество шагов ray marching")]
        [Range(8, 128)]
        public int maxSteps = 32;
        
        [Tooltip("Размер шага в screen space (меньше = точнее, но дороже)")]
        [Range(0.001f, 0.1f)]
        public float stepSize = 0.02f;
        
        [Tooltip("Максимальная дистанция отражения в world units")]
        [Range(1f, 100f)]
        public float maxDistance = 50f;
        
        [Header("Quality")]
        [Tooltip("Толщина для определения пересечения")]
        [Range(0.01f, 2f)]
        public float thickness = 0.5f;
        
        [Header("Appearance")]
        [Tooltip("Интенсивность отражений")]
        [Range(0f, 1f)]
        public float intensity = 0.5f;
        
        [Tooltip("Затухание к краям экрана")]
        [Range(0.01f, 0.5f)]
        public float edgeFade = 0.1f;
    }

    public Settings settings = new Settings();
    
    [SerializeField]
    private Shader m_Shader;
    
    private Material m_Material;
    private SSRPass m_Pass;

    public override void Create()
    {
        // Загружаем шейдер
        if (m_Shader == null)
        {
            m_Shader = Shader.Find("Hidden/SSR");
        }

        if (m_Shader == null)
        {
            Debug.LogError("SSRFeature: Shader 'Hidden/SSR' not found!");
            return;
        }

        // Создаём материал
        if (m_Material == null)
        {
            m_Material = CoreUtils.CreateEngineMaterial(m_Shader);
        }

        // Создаём pass
        if (m_Material != null)
        {
            m_Pass = new SSRPass(m_Material, settings);
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
    }
}
