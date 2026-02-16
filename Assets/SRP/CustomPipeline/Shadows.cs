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
        
        // 4. Вычисляем матрицы для рендеринга с точки зрения света
        VisibleLight light = cullingResults.visibleLights[mainLightIndex];
        CalculateLightMatrices(light, out Matrix4x4 viewMatrix, out Matrix4x4 projMatrix);
        
        // Сохраняем View-Projection для использования в основном проходе
        lightViewProjection = projMatrix * viewMatrix;
        
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
        
        // 7. Рисуем shadow casters используя RendererList API
        SortingSettings sortingSettings = new SortingSettings
        {
            criteria = SortingCriteria.CommonOpaque
        };
        
        DrawingSettings drawingSettings = new DrawingSettings(
            new ShaderTagId("ShadowCaster"),
            sortingSettings
        )
        {
            enableDynamicBatching = false,
            enableInstancing = true
        };
        
        FilteringSettings filteringSettings = new FilteringSettings(RenderQueueRange.opaque);
        
        // Создаём RendererList
        RendererListParams shadowParams = new RendererListParams(
            cullingResults,
            drawingSettings,
            filteringSettings
        );
        RendererList shadowList = context.CreateRendererList(ref shadowParams);
        
        cmd.DrawRendererList(shadowList);
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
    /// Вычисляет матрицы View и Projection для directional light.
    /// </summary>
    private void CalculateLightMatrices(
        VisibleLight light,
        out Matrix4x4 viewMatrix,
        out Matrix4x4 projMatrix)
    {
        // Направление света (инвертированное — в сторону источника)
        Vector3 lightDir = light.localToWorldMatrix.GetColumn(2);
        
        // Позиция "источника" — достаточно далеко, чтобы охватить всю сцену
        Vector3 lightPos = -lightDir * shadowDistance;
        
        // View matrix — смотрим в направлении света
        viewMatrix = Matrix4x4.LookAt(lightPos, Vector3.zero, Vector3.up);
        // LookAt возвращает матрицу для правой системы координат, 
        // но Unity использует левую, поэтому инвертируем Z
        viewMatrix.m20 = -viewMatrix.m20;
        viewMatrix.m21 = -viewMatrix.m21;
        viewMatrix.m22 = -viewMatrix.m22;
        viewMatrix.m23 = -viewMatrix.m23;
        
        // Orthographic projection для directional light
        float orthoSize = shadowDistance;
        float nearPlane = 0.1f;
        float farPlane = shadowDistance * 2f;
        
        projMatrix = Matrix4x4.Ortho(
            -orthoSize, orthoSize,    // left, right
            -orthoSize, orthoSize,    // bottom, top
            nearPlane, farPlane       // near, far
        );
        
        // Корректируем для reversed Z buffer (если используется)
        if (SystemInfo.usesReversedZBuffer)
        {
            projMatrix.m20 = -projMatrix.m20;
            projMatrix.m21 = -projMatrix.m21;
            projMatrix.m22 = -projMatrix.m22;
            projMatrix.m23 = -projMatrix.m23;
        }
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
