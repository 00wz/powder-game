# Этап 5: Продвинутая визуализация

## Что мы улучшим

Сейчас у нас базовая визуализация — просто цвета для частиц и газа. Сделаем её красивее:

1. **Color Gradients** — плавные переходы цветов по плотности
2. **Ambient Occlusion** — затенение в "углах" между частицами  
3. **Glow/Bloom** — свечение газа
4. **Velocity Visualization** — отображение движения
5. **Temperature/Pressure** — визуализация дополнительных данных

---

## Концепция: Multi-Pass Rendering

Вместо одного шейдера используем несколько проходов:

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Particles  │ ──► │  Effects    │ ──► │  Composite  │
│  Render     │     │  (Blur,AO)  │     │  (Final)    │
└─────────────┘     └─────────────┘     └─────────────┘
```

---

## 1. Color Gradients — Цветовые градиенты

### Идея
Вместо фиксированного цвета используем **градиент** на основе свойства (плотность, скорость, температура).

### Реализация в шейдере

```hlsl
// Функция для выборки цвета из градиента
fixed4 SampleGradient(float t, fixed4 colorA, fixed4 colorB, fixed4 colorC)
{
    // t: 0-1, три цвета
    if (t < 0.5)
        return lerp(colorA, colorB, t * 2.0);
    else
        return lerp(colorB, colorC, (t - 0.5) * 2.0);
}

// Использование:
float density = gas.r;
fixed4 gasColor = SampleGradient(density, 
    fixed4(0.1, 0.2, 0.4, 1),   // Низкая плотность - синий
    fixed4(0.5, 0.3, 0.7, 1),   // Средняя - фиолетовый  
    fixed4(0.9, 0.4, 0.3, 1));  // Высокая - оранжевый
```

---

## 2. Ambient Occlusion для частиц

### Идея
Частицы рядом с другими частицами должны быть **темнее** (как в углах комнаты).

### Алгоритм
1. Для каждого пикселя считаем соседей
2. Больше соседей = темнее пиксель

```hlsl
float CalculateAO(int2 pos, Texture2D<float4> particles, int width, int height)
{
    float ao = 0;
    float current = particles[pos].r;
    
    if (current < 0.5) return 1.0;  // Пустая ячейка - нет AO
    
    // Проверяем 8 соседей
    int2 offsets[8] = {
        int2(-1, -1), int2(0, -1), int2(1, -1),
        int2(-1,  0),              int2(1,  0),
        int2(-1,  1), int2(0,  1), int2(1,  1)
    };
    
    int neighbors = 0;
    for (int i = 0; i < 8; i++)
    {
        int2 npos = pos + offsets[i];
        if (npos.x >= 0 && npos.x < width && npos.y >= 0 && npos.y < height)
        {
            if (particles[npos].r > 0.5)
                neighbors++;
        }
    }
    
    // Больше соседей = темнее
    ao = 1.0 - (neighbors / 8.0) * 0.4;  // Максимум 40% затемнения
    return ao;
}
```

---

## 3. Blur для газа (Glow эффект)

### Идея
Размытый газ выглядит как свечение. Используем **Gaussian Blur**.

### Простой Box Blur (3x3)

```hlsl
float4 BoxBlur(int2 pos, Texture2D<float4> tex, int width, int height)
{
    float4 sum = float4(0,0,0,0);
    int count = 0;
    
    for (int y = -1; y <= 1; y++)
    {
        for (int x = -1; x <= 1; x++)
        {
            int2 npos = pos + int2(x, y);
            if (npos.x >= 0 && npos.x < width && npos.y >= 0 && npos.y < height)
            {
                sum += tex[npos];
                count++;
            }
        }
    }
    
    return sum / count;
}
```

### Separable Gaussian Blur (эффективнее)

Два прохода: горизонтальный и вертикальный.

```hlsl
// Веса для 5-tap Gaussian
static const float weights[5] = { 0.0625, 0.25, 0.375, 0.25, 0.0625 };

float4 GaussianBlurH(int2 pos, Texture2D<float4> tex)
{
    float4 result = float4(0,0,0,0);
    for (int i = -2; i <= 2; i++)
    {
        result += tex[pos + int2(i, 0)] * weights[i + 2];
    }
    return result;
}

float4 GaussianBlurV(int2 pos, Texture2D<float4> tex)
{
    float4 result = float4(0,0,0,0);
    for (int i = -2; i <= 2; i++)
    {
        result += tex[pos + int2(0, i)] * weights[i + 2];
    }
    return result;
}
```

---

## 4. Velocity Visualization — Визуализация скорости

### Идея
Показываем направление движения газа цветом или линиями.

```hlsl
// Скорость → Цвет
float2 velocity = gas.gb * 2.0 - 1.0;  // Декодируем
float speed = length(velocity);
float angle = atan2(velocity.y, velocity.x);

// Angle to Hue (цветовой круг)
float hue = (angle + 3.14159) / (2.0 * 3.14159);  // 0-1
fixed4 velColor = HSVtoRGB(hue, speed, 1.0);
```

### HSV to RGB функция

```hlsl
fixed4 HSVtoRGB(float h, float s, float v)
{
    float c = v * s;
    float x = c * (1.0 - abs(fmod(h * 6.0, 2.0) - 1.0));
    float m = v - c;
    
    float3 rgb;
    if (h < 1.0/6.0)      rgb = float3(c, x, 0);
    else if (h < 2.0/6.0) rgb = float3(x, c, 0);
    else if (h < 3.0/6.0) rgb = float3(0, c, x);
    else if (h < 4.0/6.0) rgb = float3(0, x, c);
    else if (h < 5.0/6.0) rgb = float3(x, 0, c);
    else                  rgb = float3(c, 0, x);
    
    return fixed4(rgb + m, 1.0);
}
```

---

## Практика: Улучшенный визуализатор

### Создай: `Assets/Shaders/AdvancedVisualizer.shader`

```hlsl
Shader "PowderGame/AdvancedVisualizer"
{
    Properties
    {
        _ParticleTex ("Particles", 2D) = "black" {}
        _GasTex ("Gas", 2D) = "black" {}
        
        [Header(Sand Colors)]
        _SandColorLight ("Sand Light", Color) = (0.85, 0.78, 0.55, 1)
        _SandColorDark ("Sand Dark", Color) = (0.65, 0.55, 0.35, 1)
        
        [Header(Gas Colors)]
        _GasColorLow ("Gas Low Density", Color) = (0.1, 0.3, 0.6, 1)
        _GasColorMid ("Gas Mid Density", Color) = (0.4, 0.2, 0.7, 1)
        _GasColorHigh ("Gas High Density", Color) = (0.8, 0.3, 0.2, 1)
        
        [Header(Background)]
        _BgColorTop ("Background Top", Color) = (0.02, 0.02, 0.05, 1)
        _BgColorBottom ("Background Bottom", Color) = (0.08, 0.06, 0.12, 1)
        
        [Header(Effects)]
        _AOStrength ("AO Strength", Range(0, 1)) = 0.3
        _GlowStrength ("Glow Strength", Range(0, 2)) = 0.5
        _GasOpacity ("Gas Opacity", Range(0, 1)) = 0.7
        
        [Header(Debug)]
        [Toggle] _ShowVelocity ("Show Velocity", Float) = 0
    }
    
    SubShader
    {
        Tags { "RenderType"="Opaque" }

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #include "UnityCG.cginc"

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct v2f
            {
                float2 uv : TEXCOORD0;
                float4 vertex : SV_POSITION;
            };

            sampler2D _ParticleTex;
            sampler2D _GasTex;
            float4 _ParticleTex_TexelSize;  // (1/width, 1/height, width, height)
            
            fixed4 _SandColorLight;
            fixed4 _SandColorDark;
            fixed4 _GasColorLow;
            fixed4 _GasColorMid;
            fixed4 _GasColorHigh;
            fixed4 _BgColorTop;
            fixed4 _BgColorBottom;
            
            float _AOStrength;
            float _GlowStrength;
            float _GasOpacity;
            float _ShowVelocity;

            v2f vert (appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.uv = v.uv;
                return o;
            }

            // ===== ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ =====
            
            // Градиент из 3 цветов
            fixed4 SampleGradient3(float t, fixed4 a, fixed4 b, fixed4 c)
            {
                t = saturate(t);
                if (t < 0.5)
                    return lerp(a, b, t * 2.0);
                else
                    return lerp(b, c, (t - 0.5) * 2.0);
            }
            
            // HSV to RGB
            fixed3 HSVtoRGB(float h, float s, float v)
            {
                float c = v * s;
                float x = c * (1.0 - abs(fmod(h * 6.0, 2.0) - 1.0));
                float m = v - c;
                
                float3 rgb;
                if (h < 1.0/6.0)      rgb = float3(c, x, 0);
                else if (h < 2.0/6.0) rgb = float3(x, c, 0);
                else if (h < 3.0/6.0) rgb = float3(0, c, x);
                else if (h < 4.0/6.0) rgb = float3(0, x, c);
                else if (h < 5.0/6.0) rgb = float3(x, 0, c);
                else                  rgb = float3(c, 0, x);
                
                return rgb + m;
            }
            
            // Подсчёт соседних частиц для AO
            float CalculateAO(float2 uv)
            {
                float2 texel = _ParticleTex_TexelSize.xy;
                float current = tex2D(_ParticleTex, uv).r;
                
                if (current < 0.5) return 1.0;  // Нет частицы - нет AO
                
                float neighbors = 0;
                // 8 направлений
                neighbors += tex2D(_ParticleTex, uv + float2(-texel.x, -texel.y)).r > 0.5 ? 1 : 0;
                neighbors += tex2D(_ParticleTex, uv + float2(0, -texel.y)).r > 0.5 ? 1 : 0;
                neighbors += tex2D(_ParticleTex, uv + float2(texel.x, -texel.y)).r > 0.5 ? 1 : 0;
                neighbors += tex2D(_ParticleTex, uv + float2(-texel.x, 0)).r > 0.5 ? 1 : 0;
                neighbors += tex2D(_ParticleTex, uv + float2(texel.x, 0)).r > 0.5 ? 1 : 0;
                neighbors += tex2D(_ParticleTex, uv + float2(-texel.x, texel.y)).r > 0.5 ? 1 : 0;
                neighbors += tex2D(_ParticleTex, uv + float2(0, texel.y)).r > 0.5 ? 1 : 0;
                neighbors += tex2D(_ParticleTex, uv + float2(texel.x, texel.y)).r > 0.5 ? 1 : 0;
                
                // Больше соседей = темнее, но только если "зажат"
                float ao = 1.0 - (neighbors / 8.0) * _AOStrength;
                return ao;
            }
            
            // Простой blur для газа (5 samples)
            float4 BlurGas(float2 uv)
            {
                float2 texel = _ParticleTex_TexelSize.xy * 2.0;  // Больше радиус
                float4 sum = float4(0,0,0,0);
                
                sum += tex2D(_GasTex, uv) * 0.4;
                sum += tex2D(_GasTex, uv + float2(texel.x, 0)) * 0.15;
                sum += tex2D(_GasTex, uv - float2(texel.x, 0)) * 0.15;
                sum += tex2D(_GasTex, uv + float2(0, texel.y)) * 0.15;
                sum += tex2D(_GasTex, uv - float2(0, texel.y)) * 0.15;
                
                return sum;
            }

            fixed4 frag (v2f i) : SV_Target
            {
                // Читаем данные
                float4 particle = tex2D(_ParticleTex, i.uv);
                float4 gas = tex2D(_GasTex, i.uv);
                float4 gasBlurred = BlurGas(i.uv);
                
                float particleType = particle.r;
                float gasDensity = gas.r;
                float gasBlurredDensity = gasBlurred.r;
                float2 velocity = gas.gb * 2.0 - 1.0;
                
                // ===== ФОНОВЫЙ ГРАДИЕНТ =====
                fixed4 bgColor = lerp(_BgColorBottom, _BgColorTop, i.uv.y);
                
                // ===== ГАЗОВОЕ СВЕЧЕНИЕ (glow) =====
                fixed4 gasGlow = SampleGradient3(gasBlurredDensity * 2.0, 
                    fixed4(0,0,0,0), _GasColorLow, _GasColorMid);
                gasGlow *= gasBlurredDensity * _GlowStrength;
                
                // ===== ОСНОВНОЙ ЦВЕТ ГАЗА =====
                fixed4 gasColor = SampleGradient3(gasDensity, 
                    _GasColorLow, _GasColorMid, _GasColorHigh);
                gasColor.a = gasDensity * _GasOpacity;
                
                // ===== VELOCITY VISUALIZATION (debug) =====
                if (_ShowVelocity > 0.5 && gasDensity > 0.01)
                {
                    float speed = length(velocity);
                    float angle = atan2(velocity.y, velocity.x);
                    float hue = (angle + 3.14159) / (2.0 * 3.14159);
                    gasColor.rgb = HSVtoRGB(hue, 1.0, speed * 2.0);
                }
                
                // ===== ЦВЕТ ЧАСТИЦЫ С AO =====
                float ao = CalculateAO(i.uv);
                fixed4 sandColor = lerp(_SandColorDark, _SandColorLight, ao);
                
                // Добавляем небольшой шум для текстуры песка
                float noise = frac(sin(dot(i.uv * 100.0, float2(12.9898, 78.233))) * 43758.5453);
                sandColor.rgb += (noise - 0.5) * 0.05;
                
                // ===== КОМПОЗИТИНГ =====
                // Начинаем с фона
                fixed4 finalColor = bgColor;
                
                // Добавляем glow газа
                finalColor.rgb += gasGlow.rgb;
                
                // Смешиваем основной газ
                finalColor.rgb = lerp(finalColor.rgb, gasColor.rgb, gasColor.a);
                
                // Частица поверх всего
                finalColor = lerp(finalColor, sandColor, particleType);
                
                finalColor.a = 1.0;
                return finalColor;
            }
            ENDCG
        }
    }
}
```

---

## Настройка

1. **Создай шейдер** `Assets/Shaders/AdvancedVisualizer.shader`

2. **Создай материал** "AdvancedVisMaterial"
   - Shader: PowderGame/AdvancedVisualizer
   - Назначь на Quad

3. **Обнови GasSimulationController** — измени ссылку на материал

4. **Экспериментируй с параметрами:**
   - **AO Strength** — интенсивность затенения в углах
   - **Glow Strength** — яркость свечения газа
   - **Gas Opacity** — прозрачность газа
   - **Show Velocity** — debug режим (направление = цвет)

---

## Дополнительно: Эффект "тепловой карты"

Если хочешь добавить отображение давления или температуры:

```hlsl
// В Properties:
[Toggle] _ShowHeatmap ("Show Heatmap", Float) = 0
_HeatmapMin ("Heatmap Min", Float) = 0
_HeatmapMax ("Heatmap Max", Float) = 1

// Heatmap цвета: синий → зелёный → жёлтый → красный
fixed4 Heatmap(float value)
{
    value = saturate((value - _HeatmapMin) / (_HeatmapMax - _HeatmapMin));
    
    fixed4 colors[5];
    colors[0] = fixed4(0, 0, 0.5, 1);    // Тёмно-синий
    colors[1] = fixed4(0, 0.5, 1, 1);    // Голубой
    colors[2] = fixed4(0, 1, 0, 1);      // Зелёный
    colors[3] = fixed4(1, 1, 0, 1);      // Жёлтый
    colors[4] = fixed4(1, 0, 0, 1);      // Красный
    
    float t = value * 4.0;
    int i = (int)floor(t);
    i = clamp(i, 0, 3);
    return lerp(colors[i], colors[i+1], frac(t));
}
```

---

## Результат

После этого урока у тебя будет:
- ✅ Градиентные цвета по плотности газа
- ✅ Ambient Occlusion для частиц (глубина)
- ✅ Свечение (glow) вокруг газа
- ✅ Фоновый градиент
- ✅ Текстурированный песок (шум)
- ✅ Debug режим для визуализации скорости

**Напиши "Готово" когда визуализация станет красивее!**
