# Урок 12: Screen Space Reflections (SSR)

## Содержание
1. [Введение](#введение)
2. [Теория Ray Marching](#теория-ray-marching)
3. [Алгоритм SSR](#алгоритм-ssr)
4. [Математика отражений](#математика-отражений)
5. [Оптимизации](#оптимизации)
6. [Ограничения SSR](#ограничения-ssr)
7. [Реализация](#реализация)

---

## Введение

**Screen Space Reflections (SSR)** — техника создания отражений, использующая уже отрендеренное изображение. В отличие от planar reflections или cubemaps, SSR работает с реальной геометрией сцены.

### Преимущества SSR
- ✅ Отражает динамические объекты
- ✅ Не требует дополнительного рендеринга сцены
- ✅ Работает с любой геометрией
- ✅ Низкая стоимость памяти

### Недостатки SSR
- ❌ Отражает только видимое на экране
- ❌ Проблемы на границах экрана
- ❌ Требует depth и normals буферов
- ❌ Может быть дорогим по производительности

---

## Теория Ray Marching

**Ray Marching** — техника трассировки лучей по шагам фиксированной или адаптивной длины.

### Базовый алгоритм

```hlsl
// Псевдокод ray marching
float3 RayMarch(float3 origin, float3 direction, int maxSteps, float stepSize)
{
    float3 currentPos = origin;
    
    for (int i = 0; i < maxSteps; i++)
    {
        currentPos += direction * stepSize;
        
        if (HitSomething(currentPos))
            return currentPos;
    }
    
    return float3(0, 0, 0); // Ничего не нашли
}
```

### Screen Space vs World Space Ray Marching

| Аспект | World Space | Screen Space |
|--------|-------------|--------------|
| Координаты луча | 3D мировые | 2D экранные + глубина |
| Проверка пересечения | Сложная | Простая (depth buffer) |
| Шаг | Фиксированный в метрах | Фиксированный в пикселях |
| Перспектива | Учтена | Требует коррекции |

Для SSR используем **Screen Space Ray Marching** — луч движется по 2D экрану, а глубина проверяется через depth buffer.

---

## Алгоритм SSR

### Шаг 1: Получение данных пикселя

```hlsl
// UV координаты текущего пикселя
float2 uv = input.texcoord;

// Глубина пикселя
float depth = SampleSceneDepth(uv);

// Нормаль поверхности
float3 normal = SampleSceneNormals(uv);

// Позиция в view space
float3 viewPos = ReconstructViewPosition(uv, depth);
```

### Шаг 2: Вычисление направления отражения

```hlsl
// Направление взгляда (от камеры к пикселю)
float3 viewDir = normalize(viewPos);

// Направление отражения
float3 reflectDir = reflect(viewDir, normal);
```

### Шаг 3: Ray Marching в Screen Space

```hlsl
float3 startPos = viewPos;
float3 endPos = viewPos + reflectDir * _MaxDistance;

// Проецируем в screen space
float2 startUV = ViewToScreenUV(startPos);
float2 endUV = ViewToScreenUV(endPos);

// Шагаем по линии
for (int i = 0; i < _MaxSteps; i++)
{
    float t = (float)i / _MaxSteps;
    float2 currentUV = lerp(startUV, endUV, t);
    
    // Проверяем пересечение с геометрией
    float sceneDepth = SampleSceneDepth(currentUV);
    float rayDepth = GetRayDepth(t, startPos, endPos);
    
    if (rayDepth > sceneDepth)
    {
        // Нашли пересечение!
        return SampleSceneColor(currentUV);
    }
}
```

### Шаг 4: Проверка пересечения

Ключевая идея: **луч пересёк геометрию, когда его глубина стала больше глубины сцены**.

```
Камера
  │
  │    Луч (ray)
  │  ↗
  │ ↗        ┌──────────┐
  │↗         │ Объект   │
  ●══════════█══════════│
  │          │          │
             └──────────┘
             
Точка пересечения: где ray depth > scene depth
```

---

## Математика отражений

### Формула отражения

```hlsl
// reflect(I, N) = I - 2 * dot(I, N) * N
// где I - входящий вектор, N - нормаль
float3 R = reflect(viewDir, normal);
```

Визуально:
```
        N (нормаль)
        ↑
        │
   I    │    R
    ↘   │   ↗
     ↘  │  ↗
      ↘ │ ↗
       ↘│↗
────────●────────
      Surface
```

### Реконструкция позиции из глубины

```hlsl
float3 ReconstructViewPosition(float2 uv, float depth)
{
    // UV → NDC (Normalized Device Coordinates)
    float2 ndc = uv * 2.0 - 1.0;
    
    // Для orthographic камеры
    if (unity_OrthoParams.w > 0.5)
    {
        float3 viewPos;
        viewPos.xy = ndc * unity_OrthoParams.xy;
        viewPos.z = -lerp(_ProjectionParams.y, _ProjectionParams.z, depth);
        return viewPos;
    }
    
    // Для perspective камеры
    float4 clipPos = float4(ndc, depth, 1.0);
    float4 viewPos = mul(unity_CameraInvProjection, clipPos);
    return viewPos.xyz / viewPos.w;
}
```

### Проекция View → Screen

```hlsl
float2 ViewToScreenUV(float3 viewPos)
{
    float4 clipPos = mul(unity_CameraProjection, float4(viewPos, 1.0));
    float2 ndc = clipPos.xy / clipPos.w;
    return ndc * 0.5 + 0.5;
}
```

---

## Оптимизации

### 1. Hierarchical Ray Marching

Начинаем с больших шагов, уточняем при приближении к пересечению:

```hlsl
float stepSize = _InitialStepSize;

for (int i = 0; i < _MaxSteps; i++)
{
    // ... ray march ...
    
    if (NearHit(rayDepth, sceneDepth))
    {
        // Уменьшаем шаг для точности
        stepSize *= 0.5;
    }
}
```

### 2. Binary Search Refinement

После грубого нахождения пересечения — бинарный поиск:

```hlsl
float3 BinarySearchRefinement(float3 start, float3 end, int iterations)
{
    float3 mid;
    
    for (int i = 0; i < iterations; i++)
    {
        mid = (start + end) * 0.5;
        float2 midUV = ViewToScreenUV(mid);
        float sceneDepth = SampleSceneDepth(midUV);
        
        if (GetDepth(mid) > sceneDepth)
            end = mid;
        else
            start = mid;
    }
    
    return mid;
}
```

### 3. Jittered Sampling

Добавляем случайное смещение для уменьшения артефактов:

```hlsl
float jitter = InterleavedGradientNoise(uv * _ScreenParams.xy, 0);
float3 startPos = viewPos + reflectDir * jitter * _StepSize;
```

### 4. Ранний выход

```hlsl
// Пропускаем пиксели без отражений
if (dot(normal, float3(0, 1, 0)) < _MinReflectivity)
    return sceneColor;

// Пропускаем, если луч направлен от камеры
if (reflectDir.z > 0)
    return sceneColor;
```

---

## Ограничения SSR

### 1. Off-Screen Information

SSR не может отразить то, что не видно на экране:

```
     Камера FOV
    ┌─────────┐
    │ Видимая │
    │  часть  │
    └─────────┘
         │
    Объект A    Объект B (за кадром)
        ○           ○
        │           │
    ────┴───────────┴────
    
Отражение объекта B невозможно!
```

### 2. Self-Reflection Artifacts

Объект может отражать сам себя неправильно:

```hlsl
// Решение: минимальное расстояние от начала луча
if (distance(currentPos, startPos) < _MinDistance)
    continue;
```

### 3. Thickness Problem

Depth buffer — это "тонкая оболочка", нет информации о толщине:

```
Вид сбоку:
          
    Луч → ═══════════█═══════════
                     │ Тонкая стена
    Должен пройти    │ (depth buffer
    насквозь?        │  видит только
                     │  переднюю грань)
```

**Решение:** Thickness threshold

```hlsl
float thickness = rayDepth - sceneDepth;
if (thickness > 0 && thickness < _MaxThickness)
{
    // Валидное пересечение
}
```

### 4. Grazing Angles

На пологих углах отражения работают плохо:

```hlsl
// Затухание на пологих углах
float fresnel = pow(1.0 - saturate(dot(-viewDir, normal)), 5.0);
float reflectionStrength = fresnel;
```

---

## Реализация

### Настраиваемые параметры

| Параметр | Описание | Типичное значение |
|----------|----------|-------------------|
| `_MaxSteps` | Максимум шагов ray marching | 32-64 |
| `_StepSize` | Размер шага в UV | 0.01-0.05 |
| `_MaxDistance` | Максимальная дистанция отражения | 10-100 |
| `_Thickness` | Порог толщины для пересечения | 0.1-1.0 |
| `_Intensity` | Интенсивность отражений | 0-1 |
| `_EdgeFade` | Затухание к краям экрана | 0.1-0.3 |

### Структура шейдера

```hlsl
// 1. Получаем данные пикселя
float depth = SampleSceneDepth(uv);
float3 normal = SampleSceneNormals(uv);
float3 viewPos = ReconstructViewPosition(uv, depth);

// 2. Вычисляем направление отражения
float3 viewDir = normalize(viewPos);
float3 reflectDir = reflect(viewDir, normal);

// 3. Ray marching
float2 hitUV;
bool hit = RayMarch(viewPos, reflectDir, hitUV);

// 4. Сэмплируем цвет отражения
float4 reflection = hit ? SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, hitUV) : float4(0,0,0,0);

// 5. Смешиваем с исходным цветом
float3 result = lerp(sceneColor.rgb, reflection.rgb, reflection.a * _Intensity);
```

### Fade Effects

```hlsl
// Затухание к краям экрана
float2 edgeFade = smoothstep(0, _EdgeFade, hitUV) * 
                  smoothstep(0, _EdgeFade, 1.0 - hitUV);
float screenFade = edgeFade.x * edgeFade.y;

// Затухание по расстоянию
float distFade = 1.0 - saturate(rayLength / _MaxDistance);

// Итоговая альфа
float alpha = screenFade * distFade * _Intensity;
```

---

## Упрощённая версия для 2D/Orthographic

Для ортографической камеры SSR упрощается:

1. **Нет перспективной коррекции** — лучи остаются параллельными
2. **Линейная глубина** — не нужна конвертация
3. **Простое отражение** — часто только по горизонтали/вертикали

```hlsl
// Упрощённый SSR для 2D
float2 reflectUV = uv;
reflectUV.y = 1.0 - reflectUV.y; // Отражение по вертикали

// Поиск "пола" по глубине
for (int i = 0; i < _MaxSteps; i++)
{
    float stepDepth = SampleSceneDepth(reflectUV);
    if (stepDepth < _FloorThreshold)
    {
        // Нашли отражающую поверхность
        return SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, reflectUV);
    }
    reflectUV.y -= _StepSize;
}
```

---

## Дополнительные материалы

### Связанные концепции
- **Ray Tracing** — полноценная трассировка лучей (DXR, RTX)
- **Planar Reflections** — отражения в плоскости (дополнительный рендер)
- **Reflection Probes** — запечённые отражения в cubemap

### Комбинирование техник

```hlsl
// SSR + Cubemap fallback
float4 ssrReflection = SSR(uv, normal, viewPos);
float4 cubeReflection = SampleReflectionProbe(reflectDir);

// Используем SSR где возможно, иначе cubemap
float4 finalReflection = lerp(cubeReflection, ssrReflection, ssrReflection.a);
```

---

## Итоги

✅ **Изучили:**
- Теорию ray marching
- Алгоритм Screen Space Reflections
- Математику отражений и реконструкции позиции
- Оптимизации (hierarchical, binary search, jitter)
- Ограничения техники

✅ **Ключевые формулы:**
- `reflect(I, N)` — направление отражения
- `ViewToScreenUV()` — проекция в экранные координаты
- `rayDepth > sceneDepth` — условие пересечения

**Следующий шаг:** Реализация SSR в виде Renderer Feature!
