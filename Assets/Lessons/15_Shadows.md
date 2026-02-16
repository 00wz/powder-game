# Урок 15: Тени в Custom SRP

## Введение

Тени — один из важнейших визуальных эффектов, который добавляет глубину и реализм сцене. В этом уроке мы реализуем систему теней для directional light в нашем Custom SRP.

## Теория: Shadow Mapping

### Принцип работы

Shadow mapping — двухпроходная техника:

1. **Shadow Pass**: Рендерим сцену с точки зрения источника света, записывая глубину в shadow map
2. **Main Pass**: При рендеринге основной картинки сравниваем глубину каждого пикселя с shadow map

Если глубина пикселя больше, чем в shadow map — пиксель в тени.

### Ключевые понятия

- **Shadow Map** — depth texture, хранящая глубину сцены из позиции света
- **World-to-Shadow Matrix** — матрица преобразования world position → shadow map UV + depth
- **Shadow Bias** — смещение глубины для борьбы с shadow acne
- **PCF (Percentage Closer Filtering)** — техника для мягких краёв теней

## Реализация

### Шаг 1: Структура файлов

```
Assets/SRP/CustomPipeline/
├── Shadows.cs                  # Управление тенями
├── CustomRenderPipeline.cs     # Интеграция теней в пайплайн
└── CustomRenderPipelineAsset.cs # Настройки теней

Assets/SRP/Shaders/
└── CustomLit.shader            # Шейдер с поддержкой теней
```

### Шаг 2: Shadows.cs — Основной класс

```csharp
public class Shadows
{
    // Shader property IDs
    private static readonly int ShadowMapId = Shader.PropertyToID("_ShadowMap");
    private static readonly int WorldToShadowMatrixId = Shader.PropertyToID("_WorldToShadowMatrix");
    private static readonly int ShadowStrengthId = Shader.PropertyToID("_ShadowStrength");
    private static readonly int ShadowMapSizeId = Shader.PropertyToID("_ShadowMapSize");
    
    // Настройки
    private int shadowMapSize = 2048;
    private float shadowBias = 0.005f;
    private float shadowStrength = 1f;
    
    // Ресурсы
    private RenderTexture shadowMap;
```

### Шаг 3: Рендеринг Shadow Map

Порядок операций в методе `Render()`:

```csharp
public bool Render(ScriptableRenderContext context, ref CullingResults cullingResults, CommandBuffer cmd)
{
    // 1. Найти directional light с тенями
    mainLightIndex = FindMainLightWithShadows(ref cullingResults);
    
    // 2. Вычислить матрицы через Unity API
    cullingResults.ComputeDirectionalShadowMatricesAndCullingPrimitives(
        mainLightIndex, 0, 1,
        new Vector3(1f, 0f, 0f),
        shadowMapSize,
        light.shadowNearPlane,
        out Matrix4x4 viewMatrix,
        out Matrix4x4 projMatrix,
        out ShadowSplitData shadowSplitData
    );
    
    // 3. Создать shadow map
    CreateShadowMapIfNeeded();
    
    // 4. Вычислить World-to-Shadow матрицу
    Matrix4x4 worldToShadowMatrix = GetShadowTransform(projMatrix, viewMatrix);
    
    // 5. Настроить render target
    cmd.SetRenderTarget(shadowMap);
    cmd.ClearRenderTarget(true, false, Color.clear);
    cmd.SetViewProjectionMatrices(viewMatrix, projMatrix);
    
    // 6. Применить GPU depth bias (КРИТИЧЕСКИ ВАЖНО!)
    cmd.SetGlobalDepthBias(shadowBias * 10000f, shadowBias * 3f);
    
    // 7. Отрисовать shadow casters
    ShadowDrawingSettings settings = new ShadowDrawingSettings(
        cullingResults, mainLightIndex,
        BatchCullingProjectionType.Orthographic  // Важно для directional light!
    ) { splitData = shadowSplitData };
    
    RendererList shadowList = context.CreateShadowRendererList(ref settings);
    cmd.DrawRendererList(shadowList);
    
    // 8. Сбросить bias
    cmd.SetGlobalDepthBias(0f, 0f);
    
    // 9. Передать данные в шейдеры
    cmd.SetGlobalTexture(ShadowMapId, shadowMap);
    cmd.SetGlobalMatrix(WorldToShadowMatrixId, worldToShadowMatrix);
}
```

### Шаг 4: World-to-Shadow Matrix

```csharp
private Matrix4x4 GetShadowTransform(Matrix4x4 proj, Matrix4x4 view)
{
    // Инвертируем Z для reversed Z buffer (DirectX, Metal, Vulkan)
    if (SystemInfo.usesReversedZBuffer)
    {
        proj.m20 = -proj.m20;
        proj.m21 = -proj.m21;
        proj.m22 = -proj.m22;
        proj.m23 = -proj.m23;
    }
    
    // Clip space [-1,1] → UV space [0,1]
    Matrix4x4 textureScaleAndBias = Matrix4x4.identity;
    textureScaleAndBias.m00 = 0.5f;  // scale X
    textureScaleAndBias.m11 = 0.5f;  // scale Y
    textureScaleAndBias.m22 = 0.5f;  // scale Z
    textureScaleAndBias.m03 = 0.5f;  // bias X
    textureScaleAndBias.m13 = 0.5f;  // bias Y
    textureScaleAndBias.m23 = 0.5f;  // bias Z
    
    // World → View → Clip → UV
    return textureScaleAndBias * proj * view;
}
```

### Шаг 5: Шейдер — Shadow Caster Pass

```hlsl
Pass
{
    Name "ShadowCaster"
    Tags { "LightMode" = "ShadowCaster" }
    
    ZWrite On
    ZTest LEqual
    ColorMask 0  // Только глубина
    Cull Back
    
    HLSLPROGRAM
    #pragma vertex ShadowVert
    #pragma fragment ShadowFrag
    
    float4x4 unity_ObjectToWorld;
    float4x4 unity_MatrixVP;
    
    struct ShadowVaryings
    {
        float4 positionCS : SV_POSITION;
    };
    
    // Простой vertex shader — bias применяется через SetGlobalDepthBias!
    ShadowVaryings ShadowVert(float4 positionOS : POSITION)
    {
        ShadowVaryings output;
        float3 positionWS = mul(unity_ObjectToWorld, float4(positionOS.xyz, 1.0)).xyz;
        output.positionCS = mul(unity_MatrixVP, float4(positionWS, 1.0));
        return output;
    }
    
    float4 ShadowFrag(ShadowVaryings input) : SV_Target
    {
        return 0;  // GPU записывает глубину автоматически
    }
    ENDHLSL
}
```

### Шаг 6: Шейдер — Сэмплирование теней

```hlsl
// Объявления
TEXTURE2D_SHADOW(_ShadowMap);
SAMPLER_CMP(sampler_ShadowMap);

float4x4 _WorldToShadowMatrix;
float _ShadowStrength;
float4 _ShadowMapSize;  // xy = size, zw = 1/size

// PCF 3x3 для мягких теней
float SampleShadowMapPCF(float3 positionWS)
{
    // World → Shadow UV + depth
    float4 shadowCoord = mul(_WorldToShadowMatrix, float4(positionWS, 1.0));
    shadowCoord.xyz /= shadowCoord.w;
    
    // Проверка границ
    if (shadowCoord.x < 0 || shadowCoord.x > 1 ||
        shadowCoord.y < 0 || shadowCoord.y > 1)
        return 1.0;
    
    // PCF 3x3
    float2 texelSize = _ShadowMapSize.zw;
    float shadow = 0.0;
    
    [unroll]
    for (int x = -1; x <= 1; x++)
    {
        [unroll]
        for (int y = -1; y <= 1; y++)
        {
            float2 offset = float2(x, y) * texelSize;
            float3 sampleCoord = float3(saturate(shadowCoord.xy + offset), shadowCoord.z);
            shadow += SAMPLE_TEXTURE2D_SHADOW(_ShadowMap, sampler_ShadowMap, sampleCoord);
        }
    }
    
    shadow /= 9.0;
    return lerp(1.0, shadow, _ShadowStrength);
}
```

## Борьба с артефактами

### Shadow Acne

**Проблема**: Поверхность затеняет сама себя из-за погрешности глубины.

**Решение**: GPU-уровневый depth bias через `SetGlobalDepthBias(depthBias, slopeBias)`:
- `depthBias` — константное смещение
- `slopeBias` — смещение пропорциональное наклону поверхности

```csharp
// ПРАВИЛЬНО: bias на GPU
cmd.SetGlobalDepthBias(shadowBias * 10000f, shadowBias * 3f);
cmd.DrawRendererList(shadowList);
cmd.SetGlobalDepthBias(0f, 0f);

// НЕПРАВИЛЬНО: bias в шейдере (меняет геометрию!)
// positionWS += normalWS * bias;  // НЕ ДЕЛАТЬ ТАК!
```

### Peter Panning

**Проблема**: Слишком большой bias отрывает тень от объекта.

**Решение**: Использовать минимально необходимый bias + slope-scale bias.

## Интеграция в Pipeline

```csharp
// CustomRenderPipeline.RenderCamera()

// 1. Culling
cullingParams.shadowDistance = shadowDistance;
CullingResults cullingResults = context.Cull(ref cullingParams);

// 2. Shadow Pass (до основного рендеринга!)
shadows.Render(context, ref cullingResults, cmd);

// 3. Восстановить camera render target
cmd.SetRenderTarget(BuiltinRenderTextureType.CameraTarget);
context.SetupCameraProperties(camera);
cmd.ClearRenderTarget(clearDepth, clearColor, backgroundColor);

// 4. Main Pass — тени уже доступны в шейдере
```

## Ключевые моменты

1. **BatchCullingProjectionType.Orthographic** — обязателен для directional light
2. **SetGlobalDepthBias** — правильный способ борьбы с shadow acne
3. **Reversed Z Buffer** — нужно инвертировать Z в World-to-Shadow матрице
4. **PCF** — сэмплируем несколько точек для мягких краёв
5. **Shadow Distance** — устанавливается в culling parameters

## Настройки в Inspector

- **Shadow Map Size**: 512-4096 (больше = качественнее, но дороже)
- **Shadow Distance**: Дальность отрисовки теней
- **Shadow Bias**: 0.001-0.01 (минимальное значение без acne)
- **Shadow Strength**: 0-1 (прозрачность тени)

## Что дальше?

- Cascaded Shadow Maps (каскадные тени для больших сцен)
- Point/Spot light shadows
- Soft shadows (PCSS, VSM)
- Screen-space shadows
