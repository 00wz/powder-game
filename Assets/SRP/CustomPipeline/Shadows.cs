using UnityEngine;
using UnityEngine.Rendering;
using Unity.Collections;

/// <summary>
/// Класс для управления тенями в Custom SRP.
/// Реализует Shadow Mapping для Directional Light.
/// 
/// Урок 15: Тени в Custom SRP
/// </summary>
public class Shadows
{
    // === Shader Property IDs ===
    private static readonly int ShadowMapId = Shader.PropertyToID("_ShadowMap");
    private static readonly int LightViewProjectionId = Shader.PropertyToID("_LightViewProjection");
    private static readonly int ShadowBiasId = Shader.PropertyToID("_ShadowBias");
    private static readonly int ShadowStrengthId = Shader.PropertyToID("_ShadowStrength");
    private static readonly int ShadowMapSizeId = Shader.PropertyToID("_ShadowMapSize");
    
    // === Настройки ===
    private int shadowMapSize = 2048;
    private float shadowDistance = 50f;
    private float shadowBias = 0.005f;
    private float shadowStrength = 1f;
    
    // === Ресурсы ===
    private RenderTexture shadowMap;
    private Matrix4x4 lightViewProjection;
    
    // === Состояние ===
    private bool shadowsEnabled = false;
    private int mainLightIndex = -1;
    
    /// <summary>
    /// Настраивает параметры теней.
    /// </summary>
    public void Setup(int mapSize, float distance, float bias, float strength)
    {
        shadowMapSize = Mathf.Max(256, mapSize);
        shadowDistance = Mathf.Max(1f, distance);
        shadowBias = Mathf.Max(0f, bias);
        shadowStrength = Mathf.Clamp01(strength);
    }
    
    /// <summary>
    /// Рендерит shadow map для главного directional light.
    /// Возвращает true если тени были отрендерены.
    /// </summary>
    public bool Render(
        ScriptableRenderContext context,
        ref CullingResults cullingResults,
        CommandBuffer cmd)
    {
        shadowsEnabled = false;
        mainLightIndex = -1;
        
        // 1. Ищем главный directional light с тенями
        mainLightIndex = FindMainLightWithShadows(ref cullingResults);
        
        if (mainLightIndex < 0)
        {
            // Нет источника с тенями — устанавливаем значения по умолчанию
            SetDefaultShadowGlobals(cmd);
            return false;
        }
        
        // 2. Проверяем, есть ли объекты, отбрасывающие тени
        if (!cullingResults.GetShadowCasterBounds(mainLightIndex, out Bounds bounds))
        {
            SetDefaultShadowGlobals(cmd);
            return false;
        }
        
        // 3. Создаём shadow map если ещё не создан
        CreateShadowMapIfNeeded();
        
        // 4. Вычисляем матрицы с помощью Unity API
        // ComputeDirectionalShadowMatricesAndCullingPrimitives корректно строит
        // view/projection матрицы на основе камеры и направления света
        bool success = cullingResults.ComputeDirectionalShadowMatricesAndCullingPrimitives(
            mainLightIndex,
            0, 1, Vector3.one,  // cascadeIndex, cascadeCount, cascadeRatios (1 каскад)
            shadowMapSize,
            cullingResults.visibleLights[mainLightIndex].light.shadowNearPlane,
            out Matrix4x4 viewMatrix,
            out Matrix4x4 projMatrix,
            out ShadowSplitData splitData
        );
        
        if (!success)
        {
            SetDefaultShadowGlobals(cmd);
            return false;
        }
        
        // Сохраняем View-Projection для использования в основном проходе
        // Применяем преобразование из NDC [-1,1] в UV [0,1] прямо в матрицу,
        // чтобы шейдер мог сразу получить shadow map координаты
        lightViewProjection = ConvertToShadowAtlasMatrix(projMatrix * viewMatrix);
        
        // 5. Настраиваем render target — shadow map
        cmd.BeginSample("Shadow Map");
        cmd.SetRenderTarget(shadowMap, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
        cmd.ClearRenderTarget(true, false, Color.clear);
        
        // 6. Устанавливаем VP матрицы для shadow pass
        cmd.SetViewProjectionMatrices(viewMatrix, projMatrix);
        
        // Устанавливаем bias для shadow caster pass
        cmd.SetGlobalFloat(ShadowBiasId, shadowBias);
        
        context.ExecuteCommandBuffer(cmd);
        cmd.Clear();
        
        // 7. Рисуем shadow casters используя CreateShadowRendererList API (Unity 6+)
        ShadowDrawingSettings shadowDrawingSettings = new ShadowDrawingSettings(
            cullingResults, mainLightIndex
        );
        shadowDrawingSettings.useRenderingLayerMaskTest = false;
        
        RendererList shadowRendererList = context.CreateShadowRendererList(ref shadowDrawingSettings);
        cmd.DrawRendererList(shadowRendererList);
        
        cmd.EndSample("Shadow Map");
        
        context.ExecuteCommandBuffer(cmd);
        cmd.Clear();
        
        // 8. Устанавливаем глобальные переменные для основного прохода
        SetShadowGlobals(cmd);
        context.ExecuteCommandBuffer(cmd);
        cmd.Clear();
        
        shadowsEnabled = true;
        return true;
    }
    
    /// <summary>
    /// Ищет главный directional light с включёнными тенями.
    /// </summary>
    private int FindMainLightWithShadows(ref CullingResults cullingResults)
    {
        NativeArray<VisibleLight> visibleLights = cullingResults.visibleLights;
        
        int bestIndex = -1;
        float bestIntensity = 0f;
        
        for (int i = 0; i < visibleLights.Length; i++)
        {
            VisibleLight light = visibleLights[i];
            
            // Только directional lights
            if (light.lightType != LightType.Directional)
                continue;
            
            // Проверяем, включены ли тени
            Light unityLight = light.light;
            if (unityLight == null || unityLight.shadows == LightShadows.None)
                continue;
            
            // Выбираем самый яркий
            float intensity = light.light.intensity;
            if (intensity > bestIntensity)
            {
                bestIntensity = intensity;
                bestIndex = i;
            }
        }
        
        return bestIndex;
    }
    
    /// <summary>
    /// Создаёт текстуру shadow map.
    /// </summary>
    private void CreateShadowMapIfNeeded()
    {
        // Проверяем, нужно ли пересоздать текстуру
        if (shadowMap != null && 
            shadowMap.width == shadowMapSize && 
            shadowMap.height == shadowMapSize)
        {
            return;
        }
        
        // Освобождаем старую текстуру
        if (shadowMap != null)
        {
            shadowMap.Release();
            Object.DestroyImmediate(shadowMap);
        }
        
        // Создаём новую
        shadowMap = new RenderTexture(shadowMapSize, shadowMapSize, 32, RenderTextureFormat.Shadowmap);
        shadowMap.name = "Shadow Map";
        shadowMap.filterMode = FilterMode.Bilinear;
        shadowMap.wrapMode = TextureWrapMode.Clamp;
        shadowMap.Create();
    }
    
    /// <summary>
    /// Преобразует VP матрицу из clip space [-1,1] в текстурные координаты [0,1].
    /// Результат: worldPos -> shadowMapUV (xy = UV, z = depth для сравнения).
    /// </summary>
    private static Matrix4x4 ConvertToShadowAtlasMatrix(Matrix4x4 m)
    {
        // Применяем преобразование: result = T * m, где T — матрица scale+bias
        // T преобразует x,y,z из clip space в текстурные координаты
        //   x' = 0.5 * x + 0.5  =>  row0' = 0.5 * row0 + 0.5 * row3
        //   y' = 0.5 * y + 0.5  =>  row1' = 0.5 * row1 + 0.5 * row3
        //   w' = w              =>  row3 без изменений
        
        // Remap X: [-1,1] -> [0,1]
        m.m00 = 0.5f * (m.m00 + m.m30);
        m.m01 = 0.5f * (m.m01 + m.m31);
        m.m02 = 0.5f * (m.m02 + m.m32);
        m.m03 = 0.5f * (m.m03 + m.m33);
        
        // Remap Y: [-1,1] -> [0,1]
        m.m10 = 0.5f * (m.m10 + m.m30);
        m.m11 = 0.5f * (m.m11 + m.m31);
        m.m12 = 0.5f * (m.m12 + m.m32);
        m.m13 = 0.5f * (m.m13 + m.m33);
        
        // Remap Z:
        // На reversed Z (DirectX): Z уже в [1,0] после projection.
        // Shadow map хранит глубину в том же пространстве [1,0].
        // SAMPLE_TEXTURE2D_SHADOW использует GREATER comparison.
        // НЕ ремапим Z — оставляем в том же пространстве что и shadow map.
        if (!SystemInfo.usesReversedZBuffer)
        {
            // OpenGL: Z в [-1,1], ремапим в [0,1]
            // Shadow map хранит глубину в [0,1], LESS comparison.
            m.m20 = 0.5f * (m.m20 + m.m30);
            m.m21 = 0.5f * (m.m21 + m.m31);
            m.m22 = 0.5f * (m.m22 + m.m32);
            m.m23 = 0.5f * (m.m23 + m.m33);
        }
        
        return m;
    }
    
    /// <summary>
    /// Устанавливает глобальные переменные для шейдеров.
    /// </summary>
    private void SetShadowGlobals(CommandBuffer cmd)
    {
        cmd.SetGlobalTexture(ShadowMapId, shadowMap);
        cmd.SetGlobalMatrix(LightViewProjectionId, lightViewProjection);
        cmd.SetGlobalFloat(ShadowBiasId, shadowBias);
        cmd.SetGlobalFloat(ShadowStrengthId, shadowStrength);
        cmd.SetGlobalVector(ShadowMapSizeId, new Vector4(
            shadowMapSize,
            shadowMapSize,
            1f / shadowMapSize,
            1f / shadowMapSize
        ));
    }
    
    /// <summary>
    /// Устанавливает значения по умолчанию когда тени отключены.
    /// </summary>
    private void SetDefaultShadowGlobals(CommandBuffer cmd)
    {
        cmd.SetGlobalTexture(ShadowMapId, Texture2D.whiteTexture);
        cmd.SetGlobalMatrix(LightViewProjectionId, Matrix4x4.identity);
        cmd.SetGlobalFloat(ShadowStrengthId, 0f);
    }
    
    /// <summary>
    /// Возвращает индекс главного источника света.
    /// </summary>
    public int GetMainLightIndex()
    {
        return mainLightIndex;
    }
    
    /// <summary>
    /// Возвращает true если тени активны.
    /// </summary>
    public bool AreShadowsEnabled()
    {
        return shadowsEnabled;
    }
    
    /// <summary>
    /// Освобождает ресурсы.
    /// </summary>
    public void Cleanup()
    {
        if (shadowMap != null)
        {
            shadowMap.Release();
            Object.DestroyImmediate(shadowMap);
            shadowMap = null;
        }
    }
}
