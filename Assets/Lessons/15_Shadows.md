# Урок 15: Тени в Custom SRP — Shadow Maps

## Введение

Тени — критически важный элемент реалистичного рендеринга. Они добавляют глубину, показывают пространственные отношения между объектами и делают сцену "заземлённой".

В этом уроке мы реализуем **Shadow Mapping** — стандартную технику для рендеринга теней в реальном времени.

---

## Как работают Shadow Maps

### Концепция

Shadow Mapping — двухпроходная техника:

```
┌─────────────────────────────────────────────────────────────┐
│                     PASS 1: Shadow Caster                    │
│                                                             │
│  1. Рендерим сцену С ТОЧКИ ЗРЕНИЯ ИСТОЧНИКА СВЕТА          │
│  2. Записываем только ГЛУБИНУ в текстуру (Shadow Map)      │
│  3. Каждый пиксель = расстояние до ближайшей поверхности   │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                     PASS 2: Shadow Receiver                  │
│                                                             │
│  1. Рендерим сцену с основной камеры                       │
│  2. Для каждого пикселя:                                   │
│     a) Трансформируем позицию в пространство света         │
│     b) Сравниваем глубину с Shadow Map                     │
│     c) Если глубина > shadow map → пиксель в тени          │
└─────────────────────────────────────────────────────────────┘
```

### Визуализация

```
        Directional Light
              │
              │ Light View
              ▼
         ┌─────────┐
         │ Shadow  │  ← Текстура глубины
         │   Map   │     (расстояние до объектов)
         └─────────┘
              │
              │ Sample
              ▼
    ┌─────────────────────┐
    │   Main Camera View  │
    │                     │
    │  ░░░▓▓▓░░░░░░░░░░  │  ← Объект в тени
    │  ░░░░░░░░░░░░░░░░  │
    │  ░░░░░░░░░░░░░░░░  │
    └─────────────────────┘
```

---

## Архитектура теней

### Компоненты системы

```
┌─────────────────────────────────────────────────────────────┐
│                    Shadow System                             │
│                                                             │
│  ┌───────────────┐    ┌───────────────┐                    │
│  │   Shadows.cs  │───▶│  Shadow Map   │                    │
│  │               │    │  (RTHandle)   │                    │
│  │ - Setup()     │    └───────────────┘                    │
│  │ - Render()    │            │                            │
│  │ - Cleanup()   │            ▼                            │
│  └───────────────┘    ┌───────────────┐                    │
│                       │ _ShadowMap    │                    │
│                       │ _LightVP      │  ← Глобальные     │
│                       │ _ShadowParams │    переменные      │
│                       └───────────────┘                    │
└─────────────────────────────────────────────────────────────┘
```

### Shader Passes

```hlsl
// CustomLit.shader

// Pass 0: CustomLit — основной рендеринг с получением теней
Pass
{
    Tags { "LightMode" = "CustomLit" }
    // Сэмплирует _ShadowMap и применяет тени
}

// Pass 1: ShadowCaster — рендеринг в shadow map
Pass
{
    Tags { "LightMode" = "ShadowCaster" }
    // Записывает только глубину
}
```

---

## Реализация: Шаг за шагом

### Шаг 1: Создаём класс Shadows.cs

```csharp
using UnityEngine;
using UnityEngine.Rendering;

public class Shadows
{
    // Shader property IDs
    private static readonly int ShadowMapId = Shader.PropertyToID("_ShadowMap");
    private static readonly int LightViewProjectionId = Shader.PropertyToID("_LightViewProjection");
    private static readonly int ShadowBiasId = Shader.PropertyToID("_ShadowBias");
    private static readonly int ShadowStrengthId = Shader.PropertyToID("_ShadowStrength");
    
    // Shadow map параметры
    private int shadowMapSize = 2048;
    private float shadowDistance = 100f;
    private float shadowBias = 0.005f;
    private float shadowNormalBias = 0.4f;
    private float shadowStrength = 1f;
    
    // Временная текстура для shadow map
    private RTHandle shadowMap;
    
    // Матрица View-Projection для света
    private Matrix4x4 lightViewProjection;
    
    /// <summary>
    /// Настраивает параметры теней.
    /// </summary>
    public void Setup(int mapSize, float distance, float bias, float strength)
    {
        shadowMapSize = mapSize;
        shadowDistance = distance;
        shadowBias = bias;
        shadowStrength = strength;
    }
    
    /// <summary>
    /// Рендерит shadow map для directional light.
    /// </summary>
    public void Render(
        ScriptableRenderContext context, 
        ref CullingResults cullingResults,
        int lightIndex,
        CommandBuffer cmd)
    {
        // 1. Проверяем, есть ли свет с тенями
        if (lightIndex < 0)
            return;
        
        // 2. Получаем параметры тени от света
        if (!cullingResults.GetShadowCasterBounds(lightIndex, out Bounds bounds))
        {
            // Нет объектов, отбрасывающих тень
            return;
        }
        
        // 3. Создаём shadow map texture
        CreateShadowMap(cmd);
        
        // 4. Вычисляем матрицы для рендеринга с точки зрения света
        var light = cullingResults.visibleLights[lightIndex];
        CalculateLightMatrices(light, out Matrix4x4 viewMatrix, out Matrix4x4 projMatrix);
        
        // 5. Сохраняем VP матрицу для использования в основном проходе
        lightViewProjection = projMatrix * viewMatrix;
        
        // 6. Настраиваем render target
        cmd.SetRenderTarget(shadowMap, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
        cmd.ClearRenderTarget(true, false, Color.clear);
        
        // 7. Устанавливаем VP матрицы для shadow pass
        cmd.SetViewProjectionMatrices(viewMatrix, projMatrix);
        
        context.ExecuteCommandBuffer(cmd);
        cmd.Clear();
        
        // 8. Рисуем shadow casters
        SortingSettings sortingSettings = new SortingSettings
        {
            criteria = SortingCriteria.CommonOpaque
        };
        
        DrawingSettings drawingSettings = new DrawingSettings(
            new ShaderTagId("ShadowCaster"),
            sortingSettings
        );
        
        FilteringSettings filteringSettings = new FilteringSettings(RenderQueueRange.opaque);
        
        // Создаём RendererList для shadow casters
        RendererListParams shadowParams = new RendererListParams(
            cullingResults, 
            drawingSettings, 
            filteringSettings
        );
        RendererList shadowList = context.CreateRendererList(ref shadowParams);
        
        cmd.DrawRendererList(shadowList);
        context.ExecuteCommandBuffer(cmd);
        cmd.Clear();
        
        // 9. Передаём данные для основного прохода
        SetShadowGlobals(cmd);
        context.ExecuteCommandBuffer(cmd);
        cmd.Clear();
    }
    
    /// <summary>
    /// Создаёт текстуру shadow map.
    /// </summary>
    private void CreateShadowMap(CommandBuffer cmd)
    {
        if (shadowMap != null)
            return;
        
        RenderTextureDescriptor desc = new RenderTextureDescriptor(
            shadowMapSize, 
            shadowMapSize,
            RenderTextureFormat.Shadowmap, 
            32  // depth bits
        );
        desc.shadowSamplingMode = ShadowSamplingMode.CompareDepths;
        
        shadowMap = RTHandles.Alloc(desc, name: "_ShadowMap");
    }
    
    /// <summary>
    /// Вычисляет матрицы View и Projection для directional light.
    /// </summary>
    private void CalculateLightMatrices(
        VisibleLight light, 
        out Matrix4x4 viewMatrix, 
        out Matrix4x4 projMatrix)
    {
        // Для directional light используем orthographic projection
        // Размер frustum зависит от shadowDistance
        
        // View matrix — смотрим в направлении света
        Vector3 lightDir = -light.localToWorldMatrix.GetColumn(2);
        Vector3 lightPos = -lightDir * shadowDistance * 0.5f; // Позиция "позади" сцены
        
        viewMatrix = Matrix4x4.LookAt(lightPos, lightPos + lightDir, Vector3.up);
        
        // Orthographic projection
        float orthoSize = shadowDistance * 0.5f;
        projMatrix = Matrix4x4.Ortho(
            -orthoSize, orthoSize,    // left, right
            -orthoSize, orthoSize,    // bottom, top
            0.1f, shadowDistance      // near, far
        );
        
        // Корректируем для платформы (reversed Z на некоторых платформах)
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
    }
    
    /// <summary>
    /// Освобождает ресурсы.
    /// </summary>
    public void Cleanup()
    {
        if (shadowMap != null)
        {
            RTHandles.Release(shadowMap);
            shadowMap = null;
        }
    }
}
```

### Шаг 2: Shadow Caster Pass в шейдере

```hlsl
// В CustomLit.shader добавляем новый Pass

Pass
{
    Name "ShadowCaster"
    Tags { "LightMode" = "ShadowCaster" }
    
    ZWrite On
    ZTest LEqual
    ColorMask 0  // Не пишем цвет, только глубину
    Cull Back
    
    HLSLPROGRAM
    #pragma vertex ShadowVert
    #pragma fragment ShadowFrag
    
    #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
    
    float4x4 unity_ObjectToWorld;
    float4x4 unity_MatrixVP;
    
    float _ShadowBias;
    
    struct ShadowAttributes
    {
        float4 positionOS : POSITION;
        float3 normalOS : NORMAL;
    };
    
    struct ShadowVaryings
    {
        float4 positionCS : SV_POSITION;
    };
    
    // Применяем bias для уменьшения shadow acne
    float3 ApplyShadowBias(float3 positionWS, float3 normalWS, float3 lightDir)
    {
        // Depth bias — сдвигаем вдоль направления света
        positionWS += lightDir * _ShadowBias;
        
        // Normal bias — сдвигаем вдоль нормали
        // (уменьшает acne на поверхностях под углом к свету)
        float NdotL = dot(normalWS, lightDir);
        float normalBias = _ShadowBias * (1.0 - NdotL);
        positionWS += normalWS * normalBias;
        
        return positionWS;
    }
    
    ShadowVaryings ShadowVert(ShadowAttributes input)
    {
        ShadowVaryings output;
        
        float3 positionWS = mul(unity_ObjectToWorld, float4(input.positionOS.xyz, 1.0)).xyz;
        float3 normalWS = normalize(mul((float3x3)unity_ObjectToWorld, input.normalOS));
        
        // Получаем направление света из VP матрицы (для directional light)
        // Упрощённо — используем bias
        positionWS += normalWS * _ShadowBias;
        
        output.positionCS = mul(unity_MatrixVP, float4(positionWS, 1.0));
        
        return output;
    }
    
    float4 ShadowFrag(ShadowVaryings input) : SV_Target
    {
        return 0;  // Не важно, пишем только глубину
    }
    ENDHLSL
}
```

### Шаг 3: Получение теней в основном шейдере

```hlsl
// В основном Pass шейдера CustomLit

// Глобальные переменные теней
TEXTURE2D_SHADOW(_ShadowMap);
SAMPLER_CMP(sampler_ShadowMap);

float4x4 _LightViewProjection;
float _ShadowBias;
float _ShadowStrength;

/// <summary>
/// Сэмплирует shadow map и возвращает коэффициент освещённости.
/// </summary>
float SampleShadowMap(float3 positionWS)
{
    // 1. Трансформируем в пространство света
    float4 shadowCoord = mul(_LightViewProjection, float4(positionWS, 1.0));
    
    // 2. Perspective divide (для directional light не нужен, но для spot/point — да)
    shadowCoord.xyz /= shadowCoord.w;
    
    // 3. Преобразуем из NDC [-1,1] в UV [0,1]
    shadowCoord.xy = shadowCoord.xy * 0.5 + 0.5;
    
    // 4. Инвертируем Y для некоторых платформ
    #if UNITY_UV_STARTS_AT_TOP
    shadowCoord.y = 1.0 - shadowCoord.y;
    #endif
    
    // 5. Проверяем, находится ли точка в пределах shadow map
    if (shadowCoord.x < 0 || shadowCoord.x > 1 || 
        shadowCoord.y < 0 || shadowCoord.y > 1 ||
        shadowCoord.z < 0 || shadowCoord.z > 1)
    {
        return 1.0;  // Вне shadow map — нет тени
    }
    
    // 6. Сэмплируем shadow map с аппаратным сравнением
    float shadow = SAMPLE_TEXTURE2D_SHADOW(_ShadowMap, sampler_ShadowMap, shadowCoord.xyz);
    
    // 7. Применяем силу тени
    return lerp(1.0, shadow, _ShadowStrength);
}

// В fragment shader:
float4 frag(Varyings input) : SV_Target
{
    // ... освещение ...
    
    // Получаем коэффициент тени
    float shadowAttenuation = SampleShadowMap(input.positionWS);
    
    // Применяем тень к освещению
    float3 finalLight = (diffuseLight + specularLight) * shadowAttenuation + ambient;
    
    return float4(albedo * finalLight, 1.0);
}
```

---

## Shadow Bias — борьба с артефактами

### Shadow Acne

**Проблема:** Полосатые артефакты на освещённых поверхностях.

**Причина:** Из-за ограниченной точности shadow map, поверхность может "затенять саму себя".

```
Поверхность без bias:
█████░░░█████░░░█████  ← "полоски" тени на освещённой поверхности

Поверхность с bias:
██████████████████████  ← чистое освещение
```

**Решение:** Depth Bias + Normal Bias

```hlsl
// Depth bias — сдвигаем в сторону света
positionWS += lightDir * depthBias;

// Normal bias — сдвигаем вдоль нормали
// Особенно важен для поверхностей под углом
positionWS += normalWS * normalBias * (1.0 - NdotL);
```

### Peter Panning

**Проблема:** Слишком большой bias → тени "отрываются" от объектов.

```
Нормальная тень:        Peter Panning:
    ██                      ██
    ██                      ██
   ████                    ████
  ██████  ← касается      ██████
▓▓▓▓▓▓▓▓▓▓              ▓▓░░▓▓▓▓▓▓  ← отрыв!
```

**Решение:** Балансировать bias — достаточно для устранения acne, но не слишком много.

---

## Soft Shadows — размытие теней

### Percentage Closer Filtering (PCF)

Вместо одного сэмпла — несколько вокруг, затем усредняем:

```hlsl
float SampleShadowMapPCF(float3 positionWS)
{
    float4 shadowCoord = mul(_LightViewProjection, float4(positionWS, 1.0));
    shadowCoord.xyz /= shadowCoord.w;
    shadowCoord.xy = shadowCoord.xy * 0.5 + 0.5;
    
    // Размер текселя shadow map
    float2 texelSize = 1.0 / float2(2048, 2048);
    
    float shadow = 0.0;
    
    // 3x3 kernel
    for (int x = -1; x <= 1; x++)
    {
        for (int y = -1; y <= 1; y++)
        {
            float2 offset = float2(x, y) * texelSize;
            float3 sampleCoord = float3(shadowCoord.xy + offset, shadowCoord.z);
            shadow += SAMPLE_TEXTURE2D_SHADOW(_ShadowMap, sampler_ShadowMap, sampleCoord);
        }
    }
    
    return shadow / 9.0;  // Усредняем
}
```

### Результат PCF:

```
Без PCF (hard shadows):     С PCF (soft shadows):
████████░░░░░░░░░░░░        ████████▓▓▒▒░░░░░░░░
████████░░░░░░░░░░░░        ████████▓▓▒▒░░░░░░░░
████████░░░░░░░░░░░░        ████████▓▓▒▒░░░░░░░░
```

---

## Cascaded Shadow Maps (CSM)

Для больших сцен с directional light одного shadow map недостаточно — качество падает с расстоянием.

### Концепция

Разбиваем frustum камеры на несколько "каскадов":

```
Camera Frustum:

Near ─────────────────────────────────► Far
 │                                       │
 │ Cascade 0 │ Cascade 1 │   Cascade 2   │
 │ (2048x2048)│(2048x2048)│  (2048x2048)  │
 │  Детально │  Средне   │    Грубо     │
 │                                       │
```

Каждый каскад имеет свой shadow map, покрывающий разную область.

### Выбор каскада в шейдере

```hlsl
int SelectCascade(float3 positionWS, float3 cameraPos)
{
    float distance = length(positionWS - cameraPos);
    
    if (distance < _CascadeDistances.x)
        return 0;
    else if (distance < _CascadeDistances.y)
        return 1;
    else if (distance < _CascadeDistances.z)
        return 2;
    else
        return 3;
}
```

---

## Интеграция в пайплайн

### Порядок рендеринга

```
┌──────────────────────────────────────┐
│  1. Setup Camera                     │
├──────────────────────────────────────┤
│  2. Culling                          │
├──────────────────────────────────────┤
│  3. SHADOW PASS ← Новый!             │
│     - Рендерим shadow map            │
│     - Устанавливаем глобальные       │
├──────────────────────────────────────┤
│  4. Setup Lighting                   │
├──────────────────────────────────────┤
│  5. Clear                            │
├──────────────────────────────────────┤
│  6. Draw Opaque (с тенями)           │
├──────────────────────────────────────┤
│  7. Skybox                           │
├──────────────────────────────────────┤
│  8. Draw Transparent                 │
├──────────────────────────────────────┤
│  9. Submit                           │
└──────────────────────────────────────┘
```

### В CustomRenderPipeline.cs

```csharp
private Shadows shadows = new Shadows();

private void RenderCamera(ScriptableRenderContext context, Camera camera)
{
    // ... setup, culling ...
    
    // SHADOW PASS
    int mainLightIndex = GetMainLightIndex(ref cullingResults);
    shadows.Render(context, ref cullingResults, mainLightIndex, cmd);
    
    // ... lighting setup ...
    
    // ... draw opaque (теперь с тенями) ...
}
```

---

## Практические задания

### Задание 1: Базовые тени

1. Создайте `Shadows.cs` с методами `Setup()`, `Render()`, `Cleanup()`
2. Добавьте ShadowCaster pass в `CustomLit.shader`
3. Интегрируйте в `CustomRenderPipeline.cs`
4. Проверьте тени от Directional Light

### Задание 2: Настройка bias

1. Добавьте параметры bias в `CustomRenderPipelineAsset`
2. Экспериментируйте с разными значениями
3. Найдите баланс между acne и peter panning

### Задание 3: PCF soft shadows

1. Реализуйте 3x3 PCF в шейдере
2. Сравните с hard shadows
3. Попробуйте 5x5 PCF — какова цена производительности?

---

## Типичные ошибки

### 1. Чёрный экран после shadow pass

```csharp
// ❌ Забыли восстановить render target
shadows.Render(...);
// ... сразу рисуем opaque — но target всё ещё shadow map!

// ✅ Восстанавливаем camera target
shadows.Render(...);
cmd.SetRenderTarget(BuiltinRenderTextureType.CameraTarget);
context.ExecuteCommandBuffer(cmd);
cmd.Clear();
```

### 2. Тени везде чёрные

```csharp
// ❌ Неправильная матрица
lightViewProjection = viewMatrix * projMatrix;  // Неправильный порядок!

// ✅ Правильный порядок
lightViewProjection = projMatrix * viewMatrix;
```

### 3. Shadow acne не уходит

```hlsl
// ❌ Bias слишком мал
_ShadowBias = 0.0001;

// ✅ Увеличиваем
_ShadowBias = 0.005;  // Начинаем отсюда
```

---

## Итоги

В этом уроке мы изучили:

1. **Shadow Mapping** — двухпроходная техника рендеринга теней
2. **Shadow Caster Pass** — рендеринг глубины с точки зрения света
3. **Light View-Projection** — матрицы для трансформации в пространство света
4. **Shadow Bias** — борьба с shadow acne и peter panning
5. **PCF** — soft shadows через множественные сэмплы
6. **CSM** — каскадные shadow maps для больших сцен

В следующем уроке реализуем **пост-обработку** в Custom SRP — Bloom эффект.
