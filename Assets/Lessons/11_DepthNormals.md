# Урок 11: Доступ к Depth и Normals буферам

## Зачем нужны Depth и Normals?

Многие продвинутые эффекты требуют информации о геометрии сцены:

| Эффект | Требует |
|--------|---------|
| Depth of Field | Depth |
| Fog | Depth |
| Depth-based outline | Depth |
| SSAO | Depth + Normals |
| Screen Space Reflections | Depth + Normals |
| Decals | Depth |
| Soft particles | Depth |

---

## Depth Buffer

### Что хранится в Depth Buffer?

Глубина каждого пикселя — расстояние от камеры до поверхности.

```
Depth Buffer (normalized):
┌────────────────────────┐
│ 0.9  0.9  0.8  0.7 ... │  ← Далеко (небо)
│ 0.9  0.5  0.5  0.7 ... │  ← Объект ближе
│ 0.9  0.5  0.5  0.7 ... │
│ 0.1  0.1  0.1  0.1 ... │  ← Близко (земля)
└────────────────────────┘
```

### Unity и Reversed-Z

На большинстве платформ Unity использует **Reversed-Z**:
- `1.0` = ближняя плоскость (near plane)
- `0.0` = дальняя плоскость (far plane)

Это даёт лучшую точность для близких объектов.

---

## Доступ к Depth в URP

### Шаг 1: Включить Depth Texture в URP Asset

1. Выбери **UniversalRP** asset
2. Включи **Depth Texture** ✓

Или в Universal Renderer:
- **Rendering** → **Depth Priming Mode** → Auto/Forced

### Шаг 2: В шейдере

```hlsl
// Объявление текстуры
TEXTURE2D(_CameraDepthTexture);
SAMPLER(sampler_CameraDepthTexture);

// Сэмплирование
float depth = SAMPLE_TEXTURE2D(_CameraDepthTexture, sampler_CameraDepthTexture, uv).r;

// Преобразование в линейную глубину (0 = near, 1 = far)
float linearDepth = Linear01Depth(depth, _ZBufferParams);

// Преобразование в мировые единицы
float eyeDepth = LinearEyeDepth(depth, _ZBufferParams);
```

### Важные функции:

| Функция | Описание |
|---------|----------|
| `Linear01Depth(depth, _ZBufferParams)` | Глубина 0-1 (near-far) |
| `LinearEyeDepth(depth, _ZBufferParams)` | Глубина в мировых единицах |
| `_ZBufferParams` | Параметры z-буфера камеры |

---

## Normals Buffer

### Что хранится в Normals Buffer?

Направление поверхности (нормаль) для каждого пикселя в screen space.

```
Normals (RGB = XYZ направление):
- R = X компонент нормали
- G = Y компонент нормали  
- B = Z компонент нормали
```

### Доступ к Normals в URP

В URP нормали генерируются через **DepthNormals Prepass**:

1. В Universal Renderer включи:
   - **Rendering** → **Depth Priming Mode** → Auto/Forced
   
2. Или создай Renderer Feature который требует нормали

### В шейдере:

```hlsl
// Объявление
TEXTURE2D(_CameraNormalsTexture);
SAMPLER(sampler_CameraNormalsTexture);

// Сэмплирование
float3 normalWS = SAMPLE_TEXTURE2D(_CameraNormalsTexture, sampler_CameraNormalsTexture, uv).rgb;

// Нормали уже в world space, диапазон [0,1] → [-1,1]
normalWS = normalWS * 2.0 - 1.0;
```

---

## Практика: Depth Visualization Shader

Создадим шейдер который визуализирует глубину разными способами.

### Режимы визуализации:

1. **Raw Depth** — сырое значение из буфера
2. **Linear 01** — линейная глубина 0-1
3. **Eye Depth** — глубина в метрах
4. **Normals** — нормали как цвет

---

## Применение: Depth-based Edge Detection

Outline по разнице глубины работает лучше для архитектуры:

```hlsl
float depthCenter = SampleDepth(uv);
float depthLeft   = SampleDepth(uv + float2(-texelSize.x, 0));
float depthRight  = SampleDepth(uv + float2( texelSize.x, 0));
float depthUp     = SampleDepth(uv + float2(0,  texelSize.y));
float depthDown   = SampleDepth(uv + float2(0, -texelSize.y));

// Разница глубины
float edgeDepth = abs(depthLeft - depthRight) + abs(depthUp - depthDown);

// Порог для определения края
float isEdge = step(_DepthThreshold, edgeDepth);
```

### Normal-based Edge Detection:

```hlsl
float3 normalCenter = SampleNormal(uv);
float3 normalLeft   = SampleNormal(uv + float2(-texelSize.x, 0));
float3 normalRight  = SampleNormal(uv + float2( texelSize.x, 0));
float3 normalUp     = SampleNormal(uv + float2(0,  texelSize.y));
float3 normalDown   = SampleNormal(uv + float2(0, -texelSize.y));

// Разница нормалей через dot product
float edgeNormal = 0;
edgeNormal += 1.0 - dot(normalCenter, normalLeft);
edgeNormal += 1.0 - dot(normalCenter, normalRight);
edgeNormal += 1.0 - dot(normalCenter, normalUp);
edgeNormal += 1.0 - dot(normalCenter, normalDown);

float isEdge = step(_NormalThreshold, edgeNormal);
```

---

## Комбинированный Outline

Лучший результат — комбинация Depth + Normals + Color:

```hlsl
float edgeDepth = DetectDepthEdge(uv);
float edgeNormal = DetectNormalEdge(uv);
float edgeColor = DetectColorEdge(uv); // Sobel

// Взвешенная комбинация
float edge = saturate(edgeDepth * _DepthWeight + 
                      edgeNormal * _NormalWeight + 
                      edgeColor * _ColorWeight);
```

---

## Fog через Depth

Простой distance fog:

```hlsl
float depth = LinearEyeDepth(SampleDepth(uv), _ZBufferParams);

// Линейный fog
float fogFactor = saturate((depth - _FogStart) / (_FogEnd - _FogStart));

// Экспоненциальный fog
float fogFactor = 1.0 - exp(-depth * _FogDensity);

// Применение
color = lerp(color, _FogColor, fogFactor);
```

---

## SSAO Preparation

Screen Space Ambient Occlusion требует:

1. **Depth** — для реконструкции позиции
2. **Normals** — для определения направления сэмплирования
3. **Random samples** — случайные направления в полусфере

Базовая идея SSAO:
```hlsl
// Для каждого пикселя:
float3 position = ReconstructPosition(uv, depth);
float3 normal = SampleNormal(uv);

float occlusion = 0;
for (int i = 0; i < SAMPLE_COUNT; i++)
{
    // Случайная точка в полусфере вдоль нормали
    float3 samplePos = position + RandomHemisphereDir(normal) * _Radius;
    
    // Проецируем обратно на экран
    float2 sampleUV = ProjectToScreen(samplePos);
    float sampleDepth = SampleDepth(sampleUV);
    
    // Если сэмпл "закрыт" геометрией - добавляем occlusion
    if (sampleDepth < samplePos.z)
        occlusion += 1.0;
}

occlusion /= SAMPLE_COUNT;
```

---

## Soft Particles

Частицы которые плавно исчезают при пересечении с геометрией:

```hlsl
// В fragment shader частицы:
float sceneDepth = LinearEyeDepth(SampleDepth(screenUV), _ZBufferParams);
float particleDepth = input.positionCS.w; // Линейная глубина частицы

float depthDiff = sceneDepth - particleDepth;
float softFactor = saturate(depthDiff / _SoftDistance);

// Применяем к альфе
return float4(color.rgb, color.a * softFactor);
```

---

## Реконструкция World Position из Depth

Полезно для многих эффектов:

```hlsl
float3 ReconstructWorldPosition(float2 uv, float depth)
{
    // NDC координаты
    float4 ndc = float4(uv * 2.0 - 1.0, depth, 1.0);
    
    // В некоторых API нужно инвертировать Y
    #if UNITY_UV_STARTS_AT_TOP
    ndc.y = -ndc.y;
    #endif
    
    // Обратная проекция
    float4 worldPos = mul(UNITY_MATRIX_I_VP, ndc);
    worldPos /= worldPos.w;
    
    return worldPos.xyz;
}
```

---

## Следующие шаги

После освоения Depth/Normals можно реализовать:
- [ ] Depth-based Outline (лучше для архитектуры)
- [ ] Distance Fog
- [ ] Soft Particles
- [ ] Простой SSAO
