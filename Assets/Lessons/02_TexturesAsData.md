# Этап 1.3: Текстуры как данные (Ключевой концепт!)

## Почему это важно для PowderGame?

В нашей симуляции **текстура — это не картинка, а массив данных**:
- Каждый пиксель = одна частица или ячейка поля
- RGBA каналы хранят информацию о частице
- GPU обрабатывает миллионы пикселей параллельно

```
Обычное использование:        Наше использование:
┌─────────────────┐           ┌─────────────────┐
│  R = Красный    │           │  R = Тип частицы│
│  G = Зелёный    │    →      │  G = Скорость X │
│  B = Синий      │           │  B = Скорость Y │
│  A = Прозрачн.  │           │  A = Температура│
└─────────────────┘           └─────────────────┘
```

## RenderTexture — ключевой инструмент

**RenderTexture** — текстура, в которую GPU может записывать:
- Обычная Texture2D — только для чтения на GPU
- RenderTexture — чтение И запись на GPU
- Это позволяет Compute Shader'у изменять данные

```
┌──────────────┐    Compute Shader    ┌──────────────┐
│ Текстура A   │ ─────────────────→   │ Текстура B   │
│ (входные     │   (обработка)        │ (результат)  │
│  данные)     │                      │              │
└──────────────┘                      └──────────────┘
```

## Типы текстур и их форматы

### Форматы для симуляции

| Формат | Описание | Применение |
|--------|----------|------------|
| **RGBAFloat** | 4×32 бит float | Высокая точность, физика |
| **RGBAHalf** | 4×16 бит float | Хороший баланс |
| **RGBA32** | 4×8 бит int (0-255) | Типы частиц, индексы |
| **RFloat** | 1×32 бит float | Поле давления, плотность |

### Фильтрация

```csharp
// Point — без интерполяции (ВАЖНО для симуляции!)
texture.filterMode = FilterMode.Point;

// Bilinear — плавное смешивание (для визуализации)
texture.filterMode = FilterMode.Bilinear;
```

**Для симуляции ВСЕГДА используем Point!** Иначе данные будут испорчены интерполяцией.

## Координаты и адресация

### UV координаты (0-1)
```hlsl
float2 uv = float2(0.5, 0.5);  // Центр текстуры
float4 data = tex2D(_DataTex, uv);
```

### Пиксельные координаты
```hlsl
// В Compute Shader используем целые координаты
uint2 id = uint2(128, 64);  // Пиксель [128, 64]
float4 data = _DataTex[id];
```

### Преобразование
```hlsl
// UV → Пиксель
uint2 pixel = uint2(uv * _TextureSize);

// Пиксель → UV
float2 uv = (float2(pixel) + 0.5) / _TextureSize;
// +0.5 чтобы попасть в центр пикселя!
```

## Доступ к соседним пикселям

Для симуляции часто нужны соседи:

```hlsl
// Размер одного пикселя в UV
float2 texelSize = 1.0 / _TextureSize;  // например 1/512 = 0.00195

// Соседи текущего пикселя
float4 current = tex2D(_Tex, uv);
float4 right   = tex2D(_Tex, uv + float2(texelSize.x, 0));
float4 left    = tex2D(_Tex, uv - float2(texelSize.x, 0));
float4 up      = tex2D(_Tex, uv + float2(0, texelSize.y));
float4 down    = tex2D(_Tex, uv - float2(0, texelSize.y));
```

## Граничные условия

Что делать на краях текстуры?

```hlsl
// 1. Wrap (повторение) — частица выходит слева, появляется справа
texture.wrapMode = TextureWrapMode.Repeat;

// 2. Clamp (ограничение) — частица останавливается на краю
texture.wrapMode = TextureWrapMode.Clamp;

// 3. Ручная проверка в шейдере
if (uv.x < 0 || uv.x > 1 || uv.y < 0 || uv.y > 1)
{
    // Обработка границы
}
```

---

## Практическое задание: Визуализация данных

Создадим шейдер, который показывает "данные" текстуры как визуализацию.

### Шаг 1: Создай новый шейдер

Создай файл `Assets/Shaders/DataVisualizer.shader`:

```hlsl
Shader "PowderGame/DataVisualizer"
{
    Properties
    {
        _DataTex ("Data Texture", 2D) = "black" {}
        _VisMode ("Visualization Mode", Range(0, 3)) = 0
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

            sampler2D _DataTex;
            float4 _DataTex_ST;
            float4 _DataTex_TexelSize; // Unity автоматически: (1/width, 1/height, width, height)
            float _VisMode;

            v2f vert (appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.uv = TRANSFORM_TEX(v.uv, _DataTex);
                return o;
            }

            fixed4 frag (v2f i) : SV_Target
            {
                float4 data = tex2D(_DataTex, i.uv);
                fixed4 col = fixed4(0, 0, 0, 1);
                
                int mode = (int)_VisMode;
                
                if (mode == 0)
                {
                    // Режим 0: Показать как обычную картинку
                    col = data;
                }
                else if (mode == 1)
                {
                    // Режим 1: Только R канал (тип частицы)
                    col.rgb = data.r;
                }
                else if (mode == 2)
                {
                    // Режим 2: Показать UV как цвет (отладка координат)
                    col.r = i.uv.x;
                    col.g = i.uv.y;
                    col.b = 0;
                }
                else if (mode == 3)
                {
                    // Режим 3: Показать разницу с соседями (edge detection)
                    float2 texel = _DataTex_TexelSize.xy;
                    
                    float4 right = tex2D(_DataTex, i.uv + float2(texel.x, 0));
                    float4 up    = tex2D(_DataTex, i.uv + float2(0, texel.y));
                    
                    float edge = length(data.rgb - right.rgb) + length(data.rgb - up.rgb);
                    col.rgb = edge;
                }
                
                return col;
            }
            ENDCG
        }
    }
}
```

### Шаг 2: Создай тестовую текстуру

В Unity:
1. **Найди любую картинку** (или создай в Paint простой рисунок)
2. **Импортируй в Assets**
3. **Настрой Import Settings:**
   - Filter Mode: **Point (no filter)**
   - Compression: **None**
   - Read/Write: **Enabled** (если планируешь менять из C#)

### Шаг 3: Настрой материал

1. Создай материал **DataVisMaterial**
2. Назначь шейдер **PowderGame/DataVisualizer**
3. Назначь текстуру в **Data Texture**
4. Создай **Quad** (3D Object → Quad) или используй Sprite
5. Назначь материал

### Шаг 4: Экспериментируй

- **Mode 0**: Обычная картинка
- **Mode 1**: Только яркость (grayscale)
- **Mode 2**: UV координаты (градиент от чёрного к жёлтому)
- **Mode 3**: Границы объектов (edge detection)

---

## Ключевые концепции для запоминания

| Концепция | Описание |
|-----------|----------|
| **Текстура = массив данных** | Не картинка, а хранилище для симуляции |
| **RenderTexture** | Текстура с возможностью записи на GPU |
| **Point filtering** | Обязательно для симуляции, без интерполяции |
| **_TexelSize** | Автоматическая переменная размера пикселя |
| **Соседние пиксели** | Доступ через смещение UV на texelSize |

---

**Когда выполнишь - напиши "Готово".**

Если есть вопросы по концепциям - задавай!

В следующем уроке перейдём к **Compute Shaders** — сердцу нашей симуляции.
