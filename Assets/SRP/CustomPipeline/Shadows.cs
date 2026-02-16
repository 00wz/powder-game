using UnityEngine;
using UnityEngine.Rendering;
using Unity.Collections;

/// <summary>
/// Класс для управления тенями в Custom SRP.
/// 
/// Реализация теней включает следующие этапы:
/// 1. Поиск главного directional light с включёнными тенями
/// 2. Расчёт shadow matrices через Unity API (ComputeDirectionalShadowMatricesAndCullingPrimitives)
/// 3. Рендеринг shadow casters в shadow map с GPU-уровневым depth bias
/// 4. Передача shadow map и матриц в шейдер для сэмплирования
/// 
/// Ключевые моменты:
/// - Используем BatchCullingProjectionType.Orthographic для directional light
/// - Bias применяется через SetGlobalDepthBias (не в шейдере!)
/// - World-to-Shadow матрица включает преобразование clip space -> UV space [0,1]
/// 
/// Урок 15: Тени в Custom SRP
/// </summary>
public class Shadows
{
    // === Shader Property IDs ===
    private static readonly int ShadowMapId = Shader.PropertyToID("_ShadowMap");
    private static readonly int WorldToShadowMatrixId = Shader.PropertyToID("_WorldToShadowMatrix");
    private static readonly int ShadowStrengthId = Shader.PropertyToID("_ShadowStrength");
    private static readonly int ShadowMapSizeId = Shader.PropertyToID("_ShadowMapSize");
    
    // === Настройки ===
    private int shadowMapSize = 2048;
    private float shadowBias = 0.005f;
    private float shadowStrength = 1f;
    
    // === Ресурсы ===
    private RenderTexture shadowMap;
    
    // === Состояние ===
    private bool shadowsRendered = false;
    private int mainLightIndex = -1;
    
    /// <summary>
    /// Настраивает параметры теней.
    /// </summary>
    /// <param name="mapSize">Разрешение shadow map (512, 1024, 2048, 4096)</param>
    /// <param name="bias">Depth bias для борьбы с shadow acne</param>
    /// <param name="strength">Сила тени (0 = прозрачная, 1 = полная)</param>
    public void Setup(int mapSize, float bias, float strength)
    {
        shadowMapSize = Mathf.Max(256, mapSize);
        shadowBias = Mathf.Max(0f, bias);
        shadowStrength = Mathf.Clamp01(strength);
    }
    
    /// <summary>
    /// Рендерит shadow map для главного directional light.
    /// 
    /// Порядок операций:
    /// 1. Найти directional light с тенями
    /// 2. Вычислить view/projection матрицы через Unity API
    /// 3. Создать shadow map texture
    /// 4. Установить render target на shadow map
    /// 5. Применить GPU depth bias
    /// 6. Отрисовать shadow casters
    /// 7. Сбросить depth bias
    /// 8. Передать текстуру и матрицы в шейдеры
    /// </summary>
    /// <returns>true если тени были отрендерены</returns>
    public bool Render(
        ScriptableRenderContext context,
        ref CullingResults cullingResults,
        CommandBuffer cmd)
    {
        shadowsRendered = false;
        mainLightIndex = -1;
        
        // === ШАГ 1: Поиск источника света ===
        mainLightIndex = FindMainLightWithShadows(ref cullingResults);
        
        if (mainLightIndex < 0)
        {
            SetDefaultShadowGlobals(cmd);
            return false;
        }
        
        // === ШАГ 2: Расчёт матриц через Unity API ===
        // ComputeDirectionalShadowMatricesAndCullingPrimitives вычисляет:
        // - viewMatrix: матрица вида из позиции света
        // - projMatrix: ортографическая проекция
        // - shadowSplitData: данные для culling (включая culling sphere)
        
        if (!cullingResults.ComputeDirectionalShadowMatricesAndCullingPrimitives(
            mainLightIndex,
            0,              // cascadeIndex (один каскад)
            1,              // cascadeCount
            new Vector3(1f, 0f, 0f),  // cascade ratios
            shadowMapSize,
            cullingResults.visibleLights[mainLightIndex].light.shadowNearPlane,
            out Matrix4x4 viewMatrix,
            out Matrix4x4 projMatrix,
            out ShadowSplitData shadowSplitData))
        {
            SetDefaultShadowGlobals(cmd);
            return false;
        }
        
        // === ШАГ 3: Создание shadow map ===
        CreateShadowMapIfNeeded();
        
        // === ШАГ 4: Вычисление World-to-Shadow матрицы ===
        // Преобразует world position → shadow map UV + depth
        Matrix4x4 worldToShadowMatrix = GetShadowTransform(projMatrix, viewMatrix);
        
        // === ШАГ 5: Настройка render target ===
        cmd.BeginSample("Shadow Map");
        cmd.SetRenderTarget(shadowMap, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
        cmd.ClearRenderTarget(true, false, Color.clear);
        cmd.SetViewProjectionMatrices(viewMatrix, projMatrix);
        
        // === ШАГ 6: Применение GPU depth bias ===
        // SetGlobalDepthBias - правильный способ борьбы с shadow acne!
        // depthBias: константное смещение глубины
        // slopeBias: смещение пропорциональное наклону поверхности
        float depthBias = shadowBias * 10000f;
        float slopeBias = shadowBias * 3f;
        cmd.SetGlobalDepthBias(depthBias, slopeBias);
        
        context.ExecuteCommandBuffer(cmd);
        cmd.Clear();
        
        // === ШАГ 7: Отрисовка shadow casters ===
        // ВАЖНО: BatchCullingProjectionType.Orthographic для directional light!
        ShadowDrawingSettings shadowDrawingSettings = new ShadowDrawingSettings(
            cullingResults,
            mainLightIndex,
            BatchCullingProjectionType.Orthographic
        )
        {
            splitData = shadowSplitData
        };
        
        RendererList shadowList = context.CreateShadowRendererList(ref shadowDrawingSettings);
        cmd.DrawRendererList(shadowList);
        
        // === ШАГ 8: Сброс depth bias ===
        cmd.SetGlobalDepthBias(0f, 0f);
        cmd.EndSample("Shadow Map");
        
        context.ExecuteCommandBuffer(cmd);
        cmd.Clear();
        
        // === ШАГ 9: Передача данных в шейдеры ===
        cmd.SetGlobalTexture(ShadowMapId, shadowMap);
        cmd.SetGlobalMatrix(WorldToShadowMatrixId, worldToShadowMatrix);
        cmd.SetGlobalFloat(ShadowStrengthId, shadowStrength);
        cmd.SetGlobalVector(ShadowMapSizeId, new Vector4(
            shadowMapSize,
            shadowMapSize,
            1f / shadowMapSize,
            1f / shadowMapSize
        ));
        
        context.ExecuteCommandBuffer(cmd);
        cmd.Clear();
        
        shadowsRendered = true;
        return true;
    }
    
    /// <summary>
    /// Вычисляет матрицу преобразования world position → shadow UV.
    /// 
    /// Матрица включает:
    /// 1. View transform (world → light space)
    /// 2. Projection (light space → clip space)
    /// 3. Scale/bias (clip space [-1,1] → UV space [0,1])
    /// 
    /// Также учитывает reversed Z buffer (DirectX, Metal, Vulkan).
    /// </summary>
    private Matrix4x4 GetShadowTransform(Matrix4x4 proj, Matrix4x4 view)
    {
        // Инвертируем Z для reversed Z buffer
        if (SystemInfo.usesReversedZBuffer)
        {
            proj.m20 = -proj.m20;
            proj.m21 = -proj.m21;
            proj.m22 = -proj.m22;
            proj.m23 = -proj.m23;
        }
        
        // Матрица преобразования clip space → UV space:
        // | 0.5  0    0    0.5 |   X: [-1,1] → [0,1]
        // | 0    0.5  0    0.5 |   Y: [-1,1] → [0,1]
        // | 0    0    0.5  0.5 |   Z: [-1,1] → [0,1]
        // | 0    0    0    1   |
        Matrix4x4 textureScaleAndBias = Matrix4x4.identity;
        textureScaleAndBias.m00 = 0.5f;
        textureScaleAndBias.m11 = 0.5f;
        textureScaleAndBias.m22 = 0.5f;
        textureScaleAndBias.m03 = 0.5f;
        textureScaleAndBias.m13 = 0.5f;
        textureScaleAndBias.m23 = 0.5f;
        
        // Итоговое преобразование: World → View → Clip → UV
        return textureScaleAndBias * proj * view;
    }
    
    /// <summary>
    /// Ищет самый яркий directional light с включёнными тенями.
    /// </summary>
    private int FindMainLightWithShadows(ref CullingResults cullingResults)
    {
        NativeArray<VisibleLight> visibleLights = cullingResults.visibleLights;
        
        int bestIndex = -1;
        float bestIntensity = 0f;
        
        for (int i = 0; i < visibleLights.Length; i++)
        {
            VisibleLight light = visibleLights[i];
            
            if (light.lightType != LightType.Directional)
                continue;
            
            Light unityLight = light.light;
            if (unityLight == null || unityLight.shadows == LightShadows.None)
                continue;
            
            float intensity = unityLight.intensity;
            if (intensity > bestIntensity)
            {
                bestIntensity = intensity;
                bestIndex = i;
            }
        }
        
        return bestIndex;
    }
    
    /// <summary>
    /// Создаёт RenderTexture для shadow map.
    /// Формат: RenderTextureFormat.Shadowmap (depth-only texture)
    /// </summary>
    private void CreateShadowMapIfNeeded()
    {
        if (shadowMap != null && 
            shadowMap.width == shadowMapSize && 
            shadowMap.height == shadowMapSize)
        {
            return;
        }
        
        if (shadowMap != null)
        {
            shadowMap.Release();
            Object.DestroyImmediate(shadowMap);
        }
        
        shadowMap = new RenderTexture(shadowMapSize, shadowMapSize, 32, RenderTextureFormat.Shadowmap);
        shadowMap.name = "Shadow Map";
        shadowMap.filterMode = FilterMode.Bilinear;
        shadowMap.wrapMode = TextureWrapMode.Clamp;
        shadowMap.Create();
    }
    
    /// <summary>
    /// Устанавливает значения по умолчанию когда тени отключены.
    /// </summary>
    private void SetDefaultShadowGlobals(CommandBuffer cmd)
    {
        cmd.SetGlobalTexture(ShadowMapId, Texture2D.whiteTexture);
        cmd.SetGlobalMatrix(WorldToShadowMatrixId, Matrix4x4.identity);
        cmd.SetGlobalFloat(ShadowStrengthId, 0f);
    }
    
    /// <summary>
    /// Возвращает индекс главного источника света.
    /// </summary>
    public int GetMainLightIndex() => mainLightIndex;
    
    /// <summary>
    /// Возвращает true если тени были отрендерены.
    /// </summary>
    public bool AreShadowsRendered() => shadowsRendered;
    
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
