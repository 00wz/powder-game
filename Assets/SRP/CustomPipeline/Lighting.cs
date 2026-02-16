using UnityEngine;
using UnityEngine.Rendering;
using Unity.Collections;

/// <summary>
/// Класс для управления освещением в Custom SRP.
/// Собирает данные об источниках света и передаёт их в шейдеры.
/// 
/// Урок 14: Освещение в Custom SRP
/// </summary>
public class Lighting
{
    // === Shader Property IDs для быстрого доступа ===
    
    // Main Directional Light
    private static readonly int MainLightDirectionId = Shader.PropertyToID("_MainLightDirection");
    private static readonly int MainLightColorId = Shader.PropertyToID("_MainLightColor");
    
    // Additional Lights
    private static readonly int AdditionalLightCountId = Shader.PropertyToID("_AdditionalLightCount");
    private static readonly int AdditionalLightPositionsId = Shader.PropertyToID("_AdditionalLightPositions");
    private static readonly int AdditionalLightColorsId = Shader.PropertyToID("_AdditionalLightColors");
    
    // Ambient
    private static readonly int AmbientLightId = Shader.PropertyToID("_AmbientLight");
    
    // === Константы ===
    
    /// <summary>
    /// Максимальное количество дополнительных источников света.
    /// Должно совпадать с размером массива в шейдере!
    /// </summary>
    private const int MaxAdditionalLights = 16;
    
    // === Буферы для данных ===
    
    private Vector4[] additionalLightPositions = new Vector4[MaxAdditionalLights];
    private Vector4[] additionalLightColors = new Vector4[MaxAdditionalLights];
    
    // === Настройки ===
    
    private Color ambientColor = new Color(0.1f, 0.1f, 0.12f, 1f);
    
    /// <summary>
    /// Устанавливает ambient color.
    /// </summary>
    public void SetAmbientColor(Color color)
    {
        ambientColor = color;
    }
    
    /// <summary>
    /// Настраивает освещение для текущего кадра.
    /// Вызывать ПЕРЕД рендерингом объектов!
    /// </summary>
    public void Setup(CommandBuffer cmd, ref CullingResults cullingResults)
    {
        // Устанавливаем ambient
        cmd.SetGlobalVector(AmbientLightId, ambientColor);
        
        // Настраиваем directional light
        SetupMainLight(cmd, ref cullingResults);
        
        // Настраиваем дополнительные источники
        SetupAdditionalLights(cmd, ref cullingResults);
    }
    
    /// <summary>
    /// Настраивает главный directional light.
    /// </summary>
    private void SetupMainLight(CommandBuffer cmd, ref CullingResults cullingResults)
    {
        // Ищем главный directional light
        int mainLightIndex = -1;
        float maxIntensity = 0f;
        
        NativeArray<VisibleLight> visibleLights = cullingResults.visibleLights;
        
        // Находим самый яркий directional light
        for (int i = 0; i < visibleLights.Length; i++)
        {
            VisibleLight light = visibleLights[i];
            if (light.lightType == LightType.Directional)
            {
                float intensity = light.light.intensity;
                if (intensity > maxIntensity)
                {
                    maxIntensity = intensity;
                    mainLightIndex = i;
                }
            }
        }
        
        if (mainLightIndex >= 0)
        {
            VisibleLight mainLight = visibleLights[mainLightIndex];
            
            // Направление света — это forward direction матрицы (инвертированное)
            // В Unity свет "светит" в направлении -Z локальной системы координат
            Vector4 direction = -mainLight.localToWorldMatrix.GetColumn(2);
            direction.w = 0f; // Это направление, не позиция
            
            // Цвет света с учётом интенсивности
            // finalColor уже включает интенсивность
            Color color = mainLight.finalColor;
            
            cmd.SetGlobalVector(MainLightDirectionId, direction);
            cmd.SetGlobalVector(MainLightColorId, color);
        }
        else
        {
            // Нет directional light — устанавливаем значения по умолчанию
            cmd.SetGlobalVector(MainLightDirectionId, new Vector4(0f, 1f, 0f, 0f)); // Направление вверх
            cmd.SetGlobalVector(MainLightColorId, Color.black);
        }
    }
    
    /// <summary>
    /// Настраивает дополнительные источники света (Point, Spot).
    /// </summary>
    private void SetupAdditionalLights(CommandBuffer cmd, ref CullingResults cullingResults)
    {
        NativeArray<VisibleLight> visibleLights = cullingResults.visibleLights;
        
        int additionalLightCount = 0;
        
        for (int i = 0; i < visibleLights.Length && additionalLightCount < MaxAdditionalLights; i++)
        {
            VisibleLight light = visibleLights[i];
            
            // Пропускаем directional lights (они обрабатываются отдельно)
            if (light.lightType == LightType.Directional)
                continue;
            
            if (light.lightType == LightType.Point)
            {
                SetupPointLight(ref light, additionalLightCount);
                additionalLightCount++;
            }
            else if (light.lightType == LightType.Spot)
            {
                // Spot lights обрабатываем как point с направлением
                // Для простоты пока как point light
                SetupPointLight(ref light, additionalLightCount);
                additionalLightCount++;
            }
        }
        
        // Передаём данные в шейдер
        cmd.SetGlobalInt(AdditionalLightCountId, additionalLightCount);
        
        if (additionalLightCount > 0)
        {
            cmd.SetGlobalVectorArray(AdditionalLightPositionsId, additionalLightPositions);
            cmd.SetGlobalVectorArray(AdditionalLightColorsId, additionalLightColors);
        }
    }
    
    /// <summary>
    /// Заполняет данные для point light.
    /// </summary>
    private void SetupPointLight(ref VisibleLight light, int index)
    {
        // Позиция — 4-й столбец матрицы localToWorld
        Vector4 position = light.localToWorldMatrix.GetColumn(3);
        
        // В W компоненте храним радиус влияния (range)
        position.w = light.range;
        
        additionalLightPositions[index] = position;
        
        // Цвет с интенсивностью
        additionalLightColors[index] = light.finalColor;
    }
}
