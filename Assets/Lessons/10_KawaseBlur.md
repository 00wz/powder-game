# Урок 10: Kawase Blur — оптимизированный размытие

## Что такое Kawase Blur?

**Kawase Blur** — это эффективный алгоритм размытия, разработанный Masaki Kawase для игр. В отличие от Gaussian Blur, который требует много сэмплов на пиксель, Kawase использует всего 4 сэмпла за проход.

### Сравнение алгоритмов:

| Алгоритм | Сэмплов на пиксель | Проходов | Качество |
|----------|-------------------|----------|----------|
| Box Blur | 9-25 | 1-2 | Низкое |
| Gaussian | 9-25+ | 1-2 (separable) | Высокое |
| Kawase | 4 | 4-8 | Среднее-Высокое |
| Dual Kawase | 4-8 | 4-8 (пирамида) | Высокое |

---

## Принцип работы Kawase Blur

Kawase Blur сэмплирует 4 точки по диагонали от текущего пикселя:

```
     ╭───╮
   ┌─┤ S ├─┐
   │ ╰───╯ │
 ╭─┴─╮   ╭─┴─╮
 │ S │   │ S │     S = sample point
 ╰─┬─╯   ╰─┬─╯     P = current pixel
   │ ╭───╮ │
   └─┤ P ├─┘
     ╰───╯
   ╭─┴─╮   ╭─┴─╮
   │ S │   │ S │
   ╰───╯   ╰───╯
```

### Формула:
```
offset = (iteration + 0.5) * texelSize
color = (sample(-1, -1) + sample(1, -1) + sample(-1, 1) + sample(1, 1)) / 4
```

С каждой итерацией offset увеличивается, расширяя область размытия.

---

## Dual Kawase Blur (Оптимизированная версия)

**Dual Kawase** добавляет пирамиду разрешений (downsampling + upsampling):

```
Исходное изображение (1920x1080)
         ↓ Downsample + Kawase
      960x540
         ↓ Downsample + Kawase  
      480x270
         ↓ Downsample + Kawase
      240x135
         ↑ Upsample + Kawase
      480x270
         ↑ Upsample + Kawase
      960x540
         ↑ Upsample + Kawase
Результат (1920x1080)
```

### Преимущества:
- Меньше пикселей обрабатывается на нижних уровнях
- Большой радиус blur без увеличения сэмплов
- Основа для **Bloom** эффекта

---
## Реализация: Kawase Blur Shader

Создадим шейдер с тремя проходами — Downsample, Upsample и Simple.

### Созданные файлы:

1. **`Assets/SRP/Shaders/KawaseBlur.shader`** — шейдер с 3 проходами
2. **`Assets/SRP/Features/KawaseBlurFeature.cs`** — Renderer Feature
3. **`Assets/SRP/Features/KawaseBlurPass.cs`** — Render Pass с логикой пирамиды

---

## Разбор шейдера KawaseBlur.shader

### Структура:

```hlsl
// Pass 0: Downsample — уменьшение разрешения + blur
// Pass 1: Upsample — увеличение разрешения + blur
// Pass 2: Simple — blur без изменения разрешения
```

### Ключевой код Downsample:

```hlsl
half4 FragDownsample(Varyings input) : SV_Target
{
    float2 uv = input.texcoord;
    float2 texelSize = _MainTex_TexelSize.xy;
    
    // Смещение = половина пикселя + offset для blur
    float2 offset = texelSize * (_Offset + 0.5);
    
    // 4 диагональных сэмпла
    half4 color = half4(0, 0, 0, 0);
    color += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2(-offset.x, -offset.y));
    color += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2( offset.x, -offset.y));
    color += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2(-offset.x,  offset.y));
    color += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2( offset.x,  offset.y));
    
    return color * 0.25; // Среднее
}
```

### Upsample использует 8 сэмплов (крест + диагонали):

```hlsl
// Диагонали (вес 1)
color += sample(-offset, -offset);
color += sample( offset, -offset);
color += sample(-offset,  offset);
color += sample( offset,  offset);

// Крест (вес 2 для лучшего качества)
color += sample(-offset, 0) * 2;
color += sample( offset, 0) * 2;
color += sample(0, -offset) * 2;
color += sample(0,  offset) * 2;

return color / 12.0; // 4*1 + 4*2 = 12
```

---

## Разбор KawaseBlurPass.cs

### Два режима работы:

#### 1. Pyramid Mode (Dual Kawase):

```
Исходное → [Downsample] → 1/2 → [Downsample] → 1/4 → [Downsample] → 1/8
                                                                      ↓
Результат ← [Upsample] ← 1/2 ← [Upsample] ← 1/4 ← [Upsample] ← 1/8 ←
```

```csharp
// Downsample проходы
for (int i = 0; i < pyramidLevels; i++)
{
    width /= 2; height /= 2;
    // Blit с PASS_DOWNSAMPLE
}

// Upsample проходы (в обратном порядке)
for (int i = pyramidLevels - 2; i >= 0; i--)
{
    // Blit с PASS_UPSAMPLE
}
```

#### 2. Simple Mode:

```csharp
// Несколько итераций на полном разрешении
for (int i = 0; i < iterations; i++)
{
    offset = i * blurSpread;
    // Blit с PASS_SIMPLE, ping-pong между буферами
}
```

---

## Настройки KawaseBlurFeature

| Параметр | Описание |
|----------|----------|
| `enabled` | Включить/выключить эффект |
| `renderPassEvent` | Когда применять (обычно AfterRenderingTransparents) |
| `usePyramid` | Использовать Dual Kawase (эффективнее для большого blur) |
| `pyramidLevels` | Количество уровней пирамиды (2-8) |
| `iterations` | Итерации для Simple режима (1-10) |
| `blurSpread` | Множитель смещения (0.5-3) |

---

## Как тестировать

### Шаг 1: Добавь Feature в Renderer

1. Открой **UniversalRenderer** asset
2. **Add Renderer Feature** → **Kawase Blur Feature**
3. Настрой параметры:
   - ✓ Enabled
   - ✓ Use Pyramid
   - Pyramid Levels: 4
   - Blur Spread: 1.0

### Шаг 2: Наблюдай результат

Весь экран должен размыться. Изменяй параметры:
- **Pyramid Levels** — больше = сильнее blur
- **Blur Spread** — больше = сильнее blur на каждом уровне

### Шаг 3: Сравни режимы

1. Включи `Use Pyramid = false`
2. Установи `Iterations = 4`
3. Сравни качество и производительность с Pyramid режимом

---

## Сравнение Kawase vs Gaussian

| Аспект | Gaussian | Kawase |
|--------|----------|--------|
| Качество | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ |
| Скорость | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| Большой радиус | Дорого | Дешево (пирамида) |
| Артефакты | Нет | Возможны на краях |

**Когда использовать Kawase:**
- Bloom эффект
- DOF (Depth of Field) blur
- UI blur (frosted glass)
- Любой случай где нужен большой радиус blur

---

## Применение: Bloom эффект

Kawase Blur — основа для Bloom:

```
1. Выделить яркие пиксели (threshold)
2. Применить Kawase Blur к ярким пикселям
3. Сложить с исходным изображением (additive blend)
```

### Простой Bloom шейдер:

```hlsl
// Pass 1: Threshold
half4 FragThreshold(Varyings input) : SV_Target
{
    half4 color = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, input.texcoord);
    float brightness = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    return brightness > _Threshold ? color : 0;
}

// Pass 2: Kawase Blur (несколько проходов)

// Pass 3: Composite
half4 FragComposite(Varyings input) : SV_Target
{
    half4 original = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, input.texcoord);
    half4 bloom = SAMPLE_TEXTURE2D(_BloomTex, sampler_BloomTex, input.texcoord);
    return original + bloom * _BloomIntensity;
}
```

---

## Следующие шаги

1. **Протестируй** Kawase Blur Feature с разными настройками
2. **Проверь Frame Debugger** — посмотри на пирамиду текстур
3. **Готов к 4.4**: Доступ к Depth и Normals буферам

---

## Полезные ссылки

- [Dual Kawase Blur - SIGGRAPH 2015](https://community.arm.com/cfs-file/__key/communityserver-blogs-components-weblogfiles/00-00-00-20-66/siggraph2015_2D00_mmg_2D00_marius_2D00_notes.pdf)
- [Intel Blur Techniques](https://www.intel.com/content/www/us/en/developer/articles/technical/an-investigation-of-fast-real-time-gpu-based-image-blur-algorithms.html)

