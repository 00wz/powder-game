# Этап 1.1 (Часть 2): Разбор Unlit Shader

Разберём построчно созданный тобой шейдер [`TestShader.shader`](Assets/Shaders/TestShader.shader).

## Полная структура с комментариями

```hlsl
Shader "Unlit/TestShader"           // 1. Путь в меню выбора шейдера
{
    Properties                       // 2. БЛОК СВОЙСТВ
    {
        _MainTex ("Texture", 2D) = "white" {}
    }
    SubShader                        // 3. БЛОК ПОДШЕЙДЕРА
    {
        Tags { "RenderType"="Opaque" }
        LOD 100

        Pass                         // 4. ПРОХОД РЕНДЕРИНГА
        {
            CGPROGRAM                // 5. НАЧАЛО КОДА ШЕЙДЕРА
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_fog

            #include "UnityCG.cginc"

            // 6. СТРУКТУРЫ ДАННЫХ
            struct appdata { ... };
            struct v2f { ... };

            // 7. ОБЪЯВЛЕНИЕ ПЕРЕМЕННЫХ
            sampler2D _MainTex;
            float4 _MainTex_ST;

            // 8. VERTEX SHADER
            v2f vert (appdata v) { ... }

            // 9. FRAGMENT SHADER
            fixed4 frag (v2f i) : SV_Target { ... }

            ENDCG
        }
    }
}
```

---

## Детальный разбор каждой части

### 1. Имя шейдера
```hlsl
Shader "Unlit/TestShader"
```
- Определяет путь в меню Material → Shader
- `"Unlit/TestShader"` = категория "Unlit", имя "TestShader"
- Можно использовать любую структуру: `"PowderGame/Simulation/ParticleDisplay"`

### 2. Properties (Свойства)
```hlsl
Properties
{
    _MainTex ("Texture", 2D) = "white" {}
}
```
- **_MainTex** — имя переменной в коде (обязательно с `_`)
- **"Texture"** — название в Inspector
- **2D** — тип (двумерная текстура)
- **"white"** — значение по умолчанию (встроенная белая текстура)

**Другие типы свойств:**
```hlsl
_Color ("Color", Color) = (1,1,1,1)      // Цвет
_Speed ("Speed", Float) = 1.0             // Число
_Range ("Range", Range(0,1)) = 0.5        // Слайдер
_Vector ("Vector", Vector) = (0,0,0,0)    // 4D вектор
```

### 3. SubShader и Tags
```hlsl
SubShader
{
    Tags { "RenderType"="Opaque" }
    LOD 100
```
- **SubShader** — вариант рендеринга (можно иметь несколько для разных платформ)
- **Tags** — метаданные для рендер пайплайна
  - `"RenderType"="Opaque"` — непрозрачный объект
  - `"RenderType"="Transparent"` — прозрачный
- **LOD** — Level of Detail (для выбора между вариантами)

### 4. Pass (Проход)
```hlsl
Pass
{
    CGPROGRAM
    ...
    ENDCG
}
```
- Один проход = один draw call
- Можно иметь несколько Pass для многопроходного рендеринга
- **CGPROGRAM/ENDCG** — границы кода на CG/HLSL

### 5. Pragma директивы
```hlsl
#pragma vertex vert      // Функция vertex shader называется "vert"
#pragma fragment frag    // Функция fragment shader называется "frag"
#pragma multi_compile_fog // Поддержка тумана (можно удалить)
```

### 6. Include и структуры
```hlsl
#include "UnityCG.cginc"  // Встроенные функции Unity
```

**Структура appdata** — входные данные для vertex shader:
```hlsl
struct appdata
{
    float4 vertex : POSITION;   // Позиция вершины в object space
    float2 uv : TEXCOORD0;      // UV координаты текстуры
};
```
- **POSITION, TEXCOORD0** — это **семантики** (semantics)
- Они указывают GPU, какие данные подавать

**Структура v2f** — данные от vertex к fragment shader:
```hlsl
struct v2f
{
    float2 uv : TEXCOORD0;           // UV для передачи
    UNITY_FOG_COORDS(1)              // Координаты тумана (макрос)
    float4 vertex : SV_POSITION;     // Позиция на экране
};
```
- **v2f** = "vertex to fragment"
- **SV_POSITION** — специальная семантика для позиции пикселя

### 7. Переменные
```hlsl
sampler2D _MainTex;      // Сама текстура
float4 _MainTex_ST;      // Scale & Tiling (автоматически)
```
- **_MainTex_ST** — Unity автоматически создаёт для каждой текстуры
  - `.xy` = tiling (масштаб)
  - `.zw` = offset (смещение)

### 8. Vertex Shader
```hlsl
v2f vert (appdata v)
{
    v2f o;
    o.vertex = UnityObjectToClipPos(v.vertex);  // Object → Clip space
    o.uv = TRANSFORM_TEX(v.uv, _MainTex);       // Применить tiling/offset
    UNITY_TRANSFER_FOG(o,o.vertex);             // Туман
    return o;
}
```

**UnityObjectToClipPos** — ключевая функция:
- Преобразует позицию из локальных координат объекта
- В координаты экрана (clip space)
- Это делается через матрицы Model-View-Projection

### 9. Fragment Shader
```hlsl
fixed4 frag (v2f i) : SV_Target
{
    fixed4 col = tex2D(_MainTex, i.uv);  // Читаем цвет из текстуры
    UNITY_APPLY_FOG(i.fogCoord, col);    // Применяем туман
    return col;                           // Возвращаем цвет пикселя
}
```

- **SV_Target** — семантика, означающая "записать в render target"
- **tex2D** — функция чтения из 2D текстуры
- **fixed4** — 4-компонентный цвет низкой точности (достаточно для цвета)

---

## Практическое задание

Теперь модифицируем шейдер! Замени содержимое [`TestShader.shader`](Assets/Shaders/TestShader.shader:1) на:

```hlsl
Shader "PowderGame/TestShader"
{
    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
        _Color ("Tint Color", Color) = (1,1,1,1)
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

            sampler2D _MainTex;
            float4 _MainTex_ST;
            float4 _Color;  // Новая переменная для цвета

            v2f vert (appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.uv = TRANSFORM_TEX(v.uv, _MainTex);
                return o;
            }

            fixed4 frag (v2f i) : SV_Target
            {
                fixed4 col = tex2D(_MainTex, i.uv);
                
                // ЭКСПЕРИМЕНТ 1: Умножаем на tint color
                col *= _Color;
                
                // ЭКСПЕРИМЕНТ 2: Раскомментируй для эффекта UV-градиента
                // col.r = i.uv.x;  // Красный = горизонтальная позиция
                // col.g = i.uv.y;  // Зелёный = вертикальная позиция
                // col.b = 0.5;
                
                return col;
            }
            ENDCG
        }
    }
}
```

## Что нужно сделать:

1. **Скопируй код** выше в файл TestShader.shader
2. **Создай материал:**
   - ПКМ в папке Assets → Create → Material
   - Назови его "TestMaterial"
3. **Назначь шейдер:**
   - Выбери материал
   - В Inspector: Shader → PowderGame → TestShader
4. **Создай объект для теста:**
   - Hierarchy → 2D Object → Sprite (или Quad для 3D)
   - Назначь TestMaterial на Sprite Renderer (или Mesh Renderer)
5. **Экспериментируй:**
   - Меняй цвет Tint Color в Inspector
   - Раскомментируй ЭКСПЕРИМЕНТ 2 и посмотри результат

**Сообщи "Готово" когда:**
- Увидишь объект на сцене с применённым шейдером
- Попробуешь менять Tint Color
- Попробуешь ЭКСПЕРИМЕНТ 2 (UV-градиент)

**Вопросы приветствуются!**
