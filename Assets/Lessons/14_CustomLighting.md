# Урок 14: Освещение в Custom SRP

## Введение

В предыдущем уроке мы создали минимальный рендер-пайплайн, который рендерит Unlit объекты. Теперь добавим **освещение** — ключевую часть любого реалистичного рендеринга.

---

## Цели урока

1. Понять, как передавать данные об источниках света в шейдеры
2. Реализовать простой Lit шейдер с Lambert diffuse
3. Добавить поддержку Directional Light

---

## Архитектура освещения в SRP

```
┌─────────────────────────────────────────────────────────────┐
│                    Custom Render Pipeline                    │
│                                                             │
│  ┌─────────────────┐    ┌─────────────────────────────┐    │
│  │  CullingResults │───▶│  visibleLights              │    │
│  │                 │    │  (список видимых источников) │    │
│  └─────────────────┘    └─────────────┬───────────────┘    │
│                                       │                     │
│                                       ▼                     │
│                    ┌──────────────────────────────┐        │
│                    │  SetGlobalVector/Buffer      │        │
│                    │  - _MainLightDirection       │        │
│                    │  - _MainLightColor           │        │
│                    │  - _AdditionalLights[]       │        │
│                    └──────────────────────────────┘        │
│                                       │                     │
│                                       ▼                     │
│                    ┌──────────────────────────────┐        │
│                    │  Custom Lit Shader           │        │
│                    │  - Читает глобальные данные  │        │
│                    │  - Вычисляет освещение       │        │
│                    └──────────────────────────────┘        │
└─────────────────────────────────────────────────────────────┘
```

---

## Типы источников света

### 1. Directional Light (Направленный)
- Бесконечно далёкий источник (как солнце)
- Все лучи параллельны
- Нет затухания (attenuation)
- Только **направление** и **цвет**

### 2. Point Light (Точечный)
- Излучает во все стороны из точки
- Есть затухание по расстоянию
- **Позиция**, **цвет**, **радиус**

### 3. Spot Light (Прожектор)
- Конус света из точки
- **Позиция**, **направление**, **угол конуса**, **цвет**

---

## Реализация: Шаг за шагом

### Шаг 1: Получаем видимые источники света

После culling у нас есть `CullingResults`, который содержит `visibleLights`:

```csharp
CullingResults cullingResults = context.Cull(ref cullingParams);

// Получаем видимые источники света
NativeArray<VisibleLight> visibleLights = cullingResults.visibleLights;
```

### Шаг 2: Создаём класс для управления освещением

```csharp
// Lighting.cs - вспомогательный класс
using UnityEngine;
using UnityEngine.Rendering;
using Unity.Collections;

public class Lighting
{
    // Shader property IDs для быстрого доступа
    private static readonly int MainLightDirectionId = Shader.PropertyToID("_MainLightDirection");
    private static readonly int MainLightColorId = Shader.PropertyToID("_MainLightColor");
    
    // Максимальное количество дополнительных источников
    private const int MaxAdditionalLights = 16;
    
    // Буферы для дополнительных источников
    private static readonly int AdditionalLightCountId = Shader.PropertyToID("_AdditionalLightCount");
    private static readonly int AdditionalLightPositionsId = Shader.PropertyToID("_AdditionalLightPositions");
    private static readonly int AdditionalLightColorsId = Shader.PropertyToID("_AdditionalLightColors");
    
    private Vector4[] additionalLightPositions = new Vector4[MaxAdditionalLights];
    private Vector4[] additionalLightColors = new Vector4[MaxAdditionalLights];
    
    /// <summary>
    /// Настраивает освещение для текущего кадра.
    /// </summary>
    public void Setup(CommandBuffer cmd, ref CullingResults cullingResults)
    {
        // Сначала устанавливаем значения по умолчанию
        SetupMainLight(cmd, ref cullingResults);
        SetupAdditionalLights(cmd, ref cullingResults);
    }
    
    private void SetupMainLight(CommandBuffer cmd, ref CullingResults cullingResults)
    {
        // Ищем главный directional light
        int mainLightIndex = -1;
        
        NativeArray<VisibleLight> visibleLights = cullingResults.visibleLights;
        
        for (int i = 0; i < visibleLights.Length; i++)
        {
            VisibleLight light = visibleLights[i];
            if (light.lightType == LightType.Directional)
            {
                mainLightIndex = i;
                break; // Берём первый directional light
            }
        }
        
        if (mainLightIndex >= 0)
        {
            VisibleLight mainLight = visibleLights[mainLightIndex];
            
            // Направление света — это forward direction матрицы (но инвертированное)
            // В Unity свет "светит" в направлении -Z локальной системы координат
            Vector4 direction = -mainLight.localToWorldMatrix.GetColumn(2);
            
            // Цвет света с учётом интенсивности
            Color color = mainLight.finalColor;
            
            cmd.SetGlobalVector(MainLightDirectionId, direction);
            cmd.SetGlobalVector(MainLightColorId, color);
        }
        else
        {
            // Нет directional light — устанавливаем значения по умолчанию
            cmd.SetGlobalVector(MainLightDirectionId, Vector4.zero);
            cmd.SetGlobalVector(MainLightColorId, Color.black);
        }
    }
    
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
                // Позиция + радиус затухания в W компоненте
                Vector4 position = light.localToWorldMatrix.GetColumn(3);
                position.w = light.range;
                
                additionalLightPositions[additionalLightCount] = position;
                additionalLightColors[additionalLightCount] = light.finalColor;
                additionalLightCount++;
            }
            // Spot lights можно добавить аналогично
        }
        
        // Передаём данные в шейдер
        cmd.SetGlobalInt(AdditionalLightCountId, additionalLightCount);
        
        if (additionalLightCount > 0)
        {
            cmd.SetGlobalVectorArray(AdditionalLightPositionsId, additionalLightPositions);
            cmd.SetGlobalVectorArray(AdditionalLightColorsId, additionalLightColors);
        }
    }
}
```

### Шаг 3: Интеграция в пайплайн

```csharp
// В CustomRenderPipeline.cs
public class CustomRenderPipeline : RenderPipeline
{
    private Lighting lighting = new Lighting();
    
    private void RenderCamera(ScriptableRenderContext context, Camera camera)
    {
        // ... setup camera, culling ...
        
        // Настраиваем освещение ПЕРЕД рендерингом объектов
        lighting.Setup(cmd, ref cullingResults);
        context.ExecuteCommandBuffer(cmd);
        cmd.Clear();
        
        // ... draw opaque, skybox, transparent ...
    }
}
```

### Шаг 4: Custom Lit Shader

```hlsl
Shader "Custom/Lit"
{
    Properties
    {
        _BaseColor ("Base Color", Color) = (1, 1, 1, 1)
        _BaseMap ("Base Map", 2D) = "white" {}
    }
    
    SubShader
    {
        Tags { "RenderType" = "Opaque" "RenderPipeline" = "CustomPipeline" }
        
        Pass
        {
            Tags { "LightMode" = "CustomLit" }
            
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
            
            // Глобальные переменные освещения (устанавливаются из C#)
            float4 _MainLightDirection;
            float4 _MainLightColor;
            
            // Дополнительные источники
            int _AdditionalLightCount;
            float4 _AdditionalLightPositions[16];
            float4 _AdditionalLightColors[16];
            
            // Свойства материала
            TEXTURE2D(_BaseMap);
            SAMPLER(sampler_BaseMap);
            
            CBUFFER_START(UnityPerMaterial)
                float4 _BaseColor;
                float4 _BaseMap_ST;
            CBUFFER_END
            
            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
                float2 uv : TEXCOORD0;
            };
            
            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 normalWS : TEXCOORD0;
                float3 positionWS : TEXCOORD1;
                float2 uv : TEXCOORD2;
            };
            
            // Матрицы трансформации
            float4x4 unity_ObjectToWorld;
            float4x4 unity_WorldToObject;
            float4x4 unity_MatrixVP;
            
            Varyings vert(Attributes input)
            {
                Varyings output;
                
                // Object to World
                float3 positionWS = mul(unity_ObjectToWorld, float4(input.positionOS.xyz, 1.0)).xyz;
                output.positionWS = positionWS;
                
                // World to Clip
                output.positionCS = mul(unity_MatrixVP, float4(positionWS, 1.0));
                
                // Transform normal to world space
                // Используем inverse transpose для корректной трансформации нормалей
                output.normalWS = normalize(mul((float3x3)unity_ObjectToWorld, input.normalOS));
                
                output.uv = input.uv * _BaseMap_ST.xy + _BaseMap_ST.zw;
                
                return output;
            }
            
            // Lambert diffuse
            float3 LambertDiffuse(float3 normal, float3 lightDir)
            {
                return max(0.0, dot(normal, lightDir));
            }
            
            // Затухание по расстоянию (inverse square law)
            float DistanceAttenuation(float distance, float range)
            {
                // Smooth falloff
                float attenuation = saturate(1.0 - (distance * distance) / (range * range));
                return attenuation * attenuation;
            }
            
            float4 frag(Varyings input) : SV_Target
            {
                // Нормализуем после интерполяции
                float3 normalWS = normalize(input.normalWS);
                
                // Базовый цвет
                float4 baseMap = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, input.uv);
                float3 albedo = baseMap.rgb * _BaseColor.rgb;
                
                // === ОСВЕЩЕНИЕ ===
                
                float3 totalLight = float3(0, 0, 0);
                
                // 1. Main Directional Light
                if (any(_MainLightColor.rgb > 0))
                {
                    float3 lightDir = normalize(_MainLightDirection.xyz);
                    float NdotL = LambertDiffuse(normalWS, lightDir);
                    totalLight += _MainLightColor.rgb * NdotL;
                }
                
                // 2. Additional Point Lights
                for (int i = 0; i < _AdditionalLightCount; i++)
                {
                    float4 lightPos = _AdditionalLightPositions[i];
                    float3 lightColor = _AdditionalLightColors[i].rgb;
                    
                    // Направление к источнику
                    float3 lightVec = lightPos.xyz - input.positionWS;
                    float distance = length(lightVec);
                    float3 lightDir = lightVec / distance;
                    
                    // Затухание
                    float range = lightPos.w;
                    float attenuation = DistanceAttenuation(distance, range);
                    
                    // Diffuse
                    float NdotL = LambertDiffuse(normalWS, lightDir);
                    
                    totalLight += lightColor * NdotL * attenuation;
                }
                
                // 3. Ambient (простой constant ambient)
                float3 ambient = float3(0.1, 0.1, 0.12); // Слегка голубоватый ambient
                
                // Итоговый цвет
                float3 finalColor = albedo * (totalLight + ambient);
                
                return float4(finalColor, 1.0);
            }
            ENDHLSL
        }
    }
}
```

---

## Модели освещения

### 1. Lambert (Diffuse)

Самая простая модель — свет рассеивается равномерно во все стороны:

```
Diffuse = max(0, N · L)
```

Где:
- **N** — нормаль поверхности
- **L** — направление к источнику света

```hlsl
float NdotL = max(0.0, dot(normalWS, lightDir));
float3 diffuse = lightColor * NdotL;
```

### 2. Half-Lambert (Valve)

Модификация Lambert для более мягких теней:

```hlsl
float NdotL = dot(normalWS, lightDir) * 0.5 + 0.5;
float3 diffuse = lightColor * NdotL * NdotL;
```

### 3. Blinn-Phong (Specular)

Добавляет блики:

```hlsl
float3 viewDir = normalize(_WorldSpaceCameraPos - positionWS);
float3 halfDir = normalize(lightDir + viewDir);
float NdotH = max(0.0, dot(normalWS, halfDir));
float specular = pow(NdotH, _Shininess) * _SpecularStrength;
```

### 4. PBR (Physically Based Rendering)

Современный подход — Cook-Torrance BRDF. Рассмотрим в следующих уроках.

---

## Затухание света (Attenuation)

### Inverse Square Law (физически корректное)

```hlsl
float attenuation = 1.0 / (distance * distance);
```

### Smooth Falloff (для игр)

```hlsl
float attenuation = saturate(1.0 - distance / range);
attenuation *= attenuation; // Квадратичный falloff
```

### Unity-style Attenuation

```hlsl
float distanceSqr = max(dot(lightVec, lightVec), 0.0001);
float attenuation = 1.0 / distanceSqr;

// Smooth range fade
float factor = distanceSqr / (range * range);
float smoothFactor = saturate(1.0 - factor * factor);
attenuation *= smoothFactor * smoothFactor;
```

---

## Полная интеграция

### Обновлённый CustomRenderPipeline.cs

```csharp
public class CustomRenderPipeline : RenderPipeline
{
    private CustomRenderPipelineAsset settings;
    private Lighting lighting = new Lighting();
    
    // Добавляем "CustomLit" в поддерживаемые теги
    private static readonly ShaderTagId[] supportedShaderTagIds = 
    {
        new ShaderTagId("SRPDefaultUnlit"),
        new ShaderTagId("CustomLit"),  // Наш Lit шейдер
        new ShaderTagId("UniversalForward"),
    };
    
    private void RenderCamera(ScriptableRenderContext context, Camera camera)
    {
        // 1. Setup
        context.SetupCameraProperties(camera);
        
        // 2. Culling
        if (!camera.TryGetCullingParameters(out var cullingParams))
            return;
        CullingResults cullingResults = context.Cull(ref cullingParams);
        
        // 3. Command Buffer
        CommandBuffer cmd = new CommandBuffer { name = camera.name };
        cmd.BeginSample(camera.name);
        context.ExecuteCommandBuffer(cmd);
        cmd.Clear();
        
        // 4. Clear
        // ...
        
        // 5. НАСТРОЙКА ОСВЕЩЕНИЯ — перед рендерингом!
        lighting.Setup(cmd, ref cullingResults);
        context.ExecuteCommandBuffer(cmd);
        cmd.Clear();
        
        // 6. Draw opaque
        // ...
        
        // 7. Skybox, transparent
        // ...
        
        // 8. Submit
        cmd.EndSample(camera.name);
        context.ExecuteCommandBuffer(cmd);
        cmd.Release();
        context.Submit();
    }
}
```

---

## Практические задания

### Задание 1: Добавьте освещение в пайплайн

1. Создайте файл `Lighting.cs` в `Assets/SRP/CustomPipeline/`
2. Добавьте класс `Lighting` с методом `Setup()`
3. Интегрируйте в `CustomRenderPipeline.RenderCamera()`

### Задание 2: Создайте Lit шейдер

1. Создайте `CustomLit.shader` в `Assets/SRP/Shaders/`
2. Реализуйте Lambert diffuse
3. Добавьте поддержку Directional Light

### Задание 3: Тестирование

1. Создайте новый материал с шейдером `Custom/Lit`
2. Добавьте на сцену Directional Light
3. Проверьте, что объекты освещаются

### Задание 4: Дополнительные источники

1. Добавьте поддержку Point Light в `Lighting.cs`
2. Обновите шейдер для обработки массива источников
3. Проверьте с несколькими Point Light на сцене

---

## Типичные ошибки

### 1. Чёрные объекты

```csharp
// ❌ Забыли вызвать lighting.Setup()
private void RenderCamera(...)
{
    // ... culling ...
    // НЕТ lighting.Setup() 
    // ... draw ...  // Объекты чёрные!
}

// ✅ Правильно
private void RenderCamera(...)
{
    // ... culling ...
    lighting.Setup(cmd, ref cullingResults);
    context.ExecuteCommandBuffer(cmd);
    cmd.Clear();
    // ... draw ...
}
```

### 2. Направление света инвертировано

```csharp
// ❌ Неправильное направление
Vector4 direction = mainLight.localToWorldMatrix.GetColumn(2);  // Z axis

// ✅ Правильно — инвертируем, так как свет "светит" в -Z
Vector4 direction = -mainLight.localToWorldMatrix.GetColumn(2);
```

### 3. Шейдер не рендерится

Убедитесь, что `LightMode` тег добавлен в `supportedShaderTagIds`:

```csharp
// В пайплайне:
private static readonly ShaderTagId[] supportedShaderTagIds = 
{
    new ShaderTagId("SRPDefaultUnlit"),
    new ShaderTagId("CustomLit"),  // Добавьте ваш тег!
};
```

```hlsl
// В шейдере:
Pass
{
    Tags { "LightMode" = "CustomLit" }  // Этот же тег!
    // ...
}
```

---

## Итоги

В этом уроке мы изучили:

1. **Архитектуру освещения** — данные передаются через глобальные переменные
2. **CullingResults.visibleLights** — список видимых источников
3. **Directional Light** — параллельные лучи, только направление
4. **Point Light** — позиция + радиус + затухание
5. **Lambert diffuse** — простейшая модель освещения
6. **Attenuation** — затухание по расстоянию

В следующем уроке добавим **тени** — Shadow Maps для Directional Light.
