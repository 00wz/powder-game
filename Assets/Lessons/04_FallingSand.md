# Этап 3: Базовая симуляция частиц — Падающий песок

## Концепция симуляции PowderGame

### Клеточный автомат

PowderGame — это **клеточный автомат**, где:
- Мир разбит на сетку ячеек (пикселей)
- Каждая ячейка содержит одну частицу или пуста
- Правила определяют, как частицы перемещаются

```
Каждый кадр:
┌───┬───┬───┬───┬───┐      ┌───┬───┬───┬───┬───┐
│   │   │ S │   │   │      │   │   │   │   │   │
├───┼───┼───┼───┼───┤      ├───┼───┼───┼───┼───┤
│   │   │   │   │   │  →   │   │   │ S │   │   │
├───┼───┼───┼───┼───┤      ├───┼───┼───┼───┼───┤
│   │   │   │   │   │      │   │   │   │   │   │
└───┴───┴───┴───┴───┘      └───┴───┴───┴───┴───┘
     Песок падает вниз
```

### Правила для песка

1. **Если снизу пусто** → падаем вниз
2. **Если снизу занято, но снизу-слева пусто** → падаем влево-вниз
3. **Если снизу занято, но снизу-справа пусто** → падаем вправо-вниз
4. **Иначе** → остаёмся на месте

```
     ┌───┐
     │ S │ ← Песок
     └───┘
┌───┬───┬───┐
│ 2 │ 1 │ 3 │ ← Приоритеты проверки
└───┴───┴───┘
```

### Представление данных в текстуре

```
Каждый пиксель (float4):
┌─────────────────────────────────────┐
│ R = Тип частицы (0=пусто, 1=песок) │
│ G = Резерв (для скорости)          │
│ B = Резерв (для температуры)       │
│ A = Резерв (для флагов)            │
└─────────────────────────────────────┘
```

## Проблема параллельного обновления

### Почему нужен Double Buffering?

Без двух буферов возникает проблема:

```
Потоки выполняются параллельно!

Поток A читает [10,10] = песок
Поток B читает [10,11] = пусто (под песком)

Поток A: "Снизу пусто, перемещаю песок вниз"
Поток B: "Я пустой, ничего не делаю"

Результат: Песок записан в [10,11], но [10,10] НЕ очищен!
(Поток A не может писать в [10,10], только в [10,11])
```

### Решение: Две текстуры

```
Input (только чтение)     Output (только запись)
┌───┬───┬───┐            ┌───┬───┬───┐
│   │ S │   │            │   │   │   │
├───┼───┼───┤     →      ├───┼───┼───┤
│   │   │   │            │   │ S │   │
├───┼───┼───┤            ├───┼───┼───┤
│   │   │   │            │   │   │   │
└───┴───┴───┘            └───┴───┴───┘

Следующий кадр: меняем местами Input и Output
```

### Другой подход: Каждый пиксель "тянет" к себе

Вместо "я песок, куда мне упасть?" используем:
**"Я пустой, есть ли песок сверху, который упадёт сюда?"**

```hlsl
// Для каждого пикселя:
if (я пустой)
{
    if (сверху песок) 
        → становлюсь песком
    else if (сверху-слева песок И под ним занято)
        → становлюсь песком
    else if (сверху-справа песок И под ним занято)
        → становлюсь песком
}
else if (я песок)
{
    if (снизу пусто ИЛИ снизу-слева пусто ИЛИ снизу-справа пусто)
        → становлюсь пустым (песок упал)
    else
        → остаюсь песком
}
```

---

## Реализация

### Шаг 1: Compute Shader для симуляции

Создай файл `Assets/Shaders/SandSimulation.compute`:

```hlsl
#pragma kernel SimulateSand
#pragma kernel InitializeTexture

// Текстуры
RWTexture2D<float4> _Output;    // Результат (запись)
Texture2D<float4> _Input;       // Текущее состояние (чтение)

// Параметры
int _Width;
int _Height;
int _Frame;  // Для рандомизации

// Типы частиц
#define EMPTY 0.0
#define SAND 1.0

// Генератор псевдослучайных чисел
float hash(float2 p)
{
    return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

// Проверка границ
bool InBounds(int2 pos)
{
    return pos.x >= 0 && pos.x < _Width && pos.y >= 0 && pos.y < _Height;
}

// Получить тип частицы (с проверкой границ)
float GetParticle(int2 pos)
{
    if (!InBounds(pos)) return SAND;  // Границы = твёрдые стены
    return _Input[pos].r;
}

[numthreads(8, 8, 1)]
void SimulateSand(uint3 id : SV_DispatchThreadID)
{
    int2 pos = int2(id.xy);
    
    if (!InBounds(pos)) return;
    
    float current = GetParticle(pos);
    
    // Соседние позиции
    int2 above = pos + int2(0, 1);       // Сверху
    int2 below = pos + int2(0, -1);      // Снизу
    int2 aboveLeft = pos + int2(-1, 1);  // Сверху-слева
    int2 aboveRight = pos + int2(1, 1);  // Сверху-справа
    int2 belowLeft = pos + int2(-1, -1);
    int2 belowRight = pos + int2(1, -1);
    
    float particleAbove = GetParticle(above);
    float particleBelow = GetParticle(below);
    float particleAboveLeft = GetParticle(aboveLeft);
    float particleAboveRight = GetParticle(aboveRight);
    float particleBelowLeft = GetParticle(belowLeft);
    float particleBelowRight = GetParticle(belowRight);
    
    float result = current;
    
    if (current == EMPTY)
    {
        // Пустая ячейка: проверяем, упадёт ли сюда песок
        
        // 1. Песок падает прямо сверху
        if (particleAbove == SAND)
        {
            result = SAND;
        }
        // 2. Песок падает сверху-слева (если под ним занято)
        else if (particleAboveLeft == SAND && GetParticle(aboveLeft + int2(0, -1)) != EMPTY)
        {
            // Случайный выбор между левым и правым (для симметрии)
            float rnd = hash(float2(pos) + _Frame * 0.1);
            if (rnd < 0.5 || particleAboveRight != SAND)
            {
                result = SAND;
            }
        }
        // 3. Песок падает сверху-справа (если под ним занято)
        else if (particleAboveRight == SAND && GetParticle(aboveRight + int2(0, -1)) != EMPTY)
        {
            result = SAND;
        }
    }
    else if (current == SAND)
    {
        // Песок: проверяем, может ли упасть
        
        bool canFallDown = particleBelow == EMPTY;
        bool canFallLeft = particleBelowLeft == EMPTY && particleBelow != EMPTY;
        bool canFallRight = particleBelowRight == EMPTY && particleBelow != EMPTY;
        
        if (canFallDown || canFallLeft || canFallRight)
        {
            result = EMPTY;  // Песок уходит отсюда
        }
        else
        {
            result = SAND;   // Песок остаётся
        }
    }
    
    _Output[pos] = float4(result, 0, 0, 1);
}

// Kernel для инициализации (заполнение пустой текстуры)
[numthreads(8, 8, 1)]
void InitializeTexture(uint3 id : SV_DispatchThreadID)
{
    if (id.x >= (uint)_Width || id.y >= (uint)_Height) return;
    _Output[id.xy] = float4(EMPTY, 0, 0, 1);
}
```

### Шаг 2: Шейдер для визуализации

Создай файл `Assets/Shaders/SandVisualizer.shader`:

```hlsl
Shader "PowderGame/SandVisualizer"
{
    Properties
    {
        _MainTex ("Simulation Texture", 2D) = "black" {}
        _SandColor ("Sand Color", Color) = (0.76, 0.70, 0.50, 1)
        _EmptyColor ("Empty Color", Color) = (0.1, 0.1, 0.15, 1)
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
            float4 _SandColor;
            float4 _EmptyColor;

            v2f vert (appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.uv = TRANSFORM_TEX(v.uv, _MainTex);
                return o;
            }

            fixed4 frag (v2f i) : SV_Target
            {
                float4 data = tex2D(_MainTex, i.uv);
                float particleType = data.r;
                
                // Интерполяция между пустым и песком
                fixed4 col = lerp(_EmptyColor, _SandColor, particleType);
                
                return col;
            }
            ENDCG
        }
    }
}
```

### Шаг 3: C# контроллер с Double Buffering

Создай файл `Assets/Scripts/SandSimulationController.cs`:

```csharp
using UnityEngine;

public class SandSimulationController : MonoBehaviour
{
    [Header("Compute Shader")]
    public ComputeShader sandCompute;
    
    [Header("Settings")]
    public int textureSize = 256;
    
    [Header("Visualization")]
    public Material displayMaterial;
    
    [Header("Spawning")]
    public bool spawnSand = true;
    public int spawnRadius = 3;
    public float spawnRate = 0.5f;  // Шанс спавна каждый кадр
    
    // Double buffering
    private RenderTexture[] buffers = new RenderTexture[2];
    private int currentBuffer = 0;
    
    // Kernel handles
    private int simulateKernel;
    private int initKernel;
    
    // Для спавна
    private Vector2Int spawnPosition;
    
    void Start()
    {
        CreateTextures();
        SetupComputeShader();
        InitializeSimulation();
        
        spawnPosition = new Vector2Int(textureSize / 2, textureSize - 10);
    }
    
    void CreateTextures()
    {
        for (int i = 0; i < 2; i++)
        {
            buffers[i] = new RenderTexture(textureSize, textureSize, 0, RenderTextureFormat.ARGBFloat);
            buffers[i].enableRandomWrite = true;
            buffers[i].filterMode = FilterMode.Point;
            buffers[i].wrapMode = TextureWrapMode.Clamp;
            buffers[i].Create();
        }
    }
    
    void SetupComputeShader()
    {
        simulateKernel = sandCompute.FindKernel("SimulateSand");
        initKernel = sandCompute.FindKernel("InitializeTexture");
        
        sandCompute.SetInt("_Width", textureSize);
        sandCompute.SetInt("_Height", textureSize);
    }
    
    void InitializeSimulation()
    {
        // Очищаем обе текстуры
        int groups = Mathf.CeilToInt(textureSize / 8.0f);
        
        sandCompute.SetTexture(initKernel, "_Output", buffers[0]);
        sandCompute.Dispatch(initKernel, groups, groups, 1);
        
        sandCompute.SetTexture(initKernel, "_Output", buffers[1]);
        sandCompute.Dispatch(initKernel, groups, groups, 1);
    }
    
    void Update()
    {
        // Спавн песка
        if (spawnSand && Random.value < spawnRate)
        {
            SpawnSand(spawnPosition.x, spawnPosition.y, spawnRadius);
        }
        
        // Симуляция
        SimulateStep();
        
        // Обновляем материал для отображения
        if (displayMaterial != null)
        {
            displayMaterial.mainTexture = buffers[currentBuffer];
        }
    }
    
    void SimulateStep()
    {
        int readBuffer = currentBuffer;
        int writeBuffer = 1 - currentBuffer;
        
        sandCompute.SetInt("_Frame", Time.frameCount);
        sandCompute.SetTexture(simulateKernel, "_Input", buffers[readBuffer]);
        sandCompute.SetTexture(simulateKernel, "_Output", buffers[writeBuffer]);
        
        int groups = Mathf.CeilToInt(textureSize / 8.0f);
        sandCompute.Dispatch(simulateKernel, groups, groups, 1);
        
        currentBuffer = writeBuffer;
    }
    
    // Спавн песка в позиции
    public void SpawnSand(int x, int y, int radius)
    {
        // Создаём временную текстуру для модификации
        Texture2D tempTex = new Texture2D(textureSize, textureSize, TextureFormat.RGBAFloat, false);
        
        // Копируем текущий буфер
        RenderTexture.active = buffers[currentBuffer];
        tempTex.ReadPixels(new Rect(0, 0, textureSize, textureSize), 0, 0);
        tempTex.Apply();
        RenderTexture.active = null;
        
        // Добавляем песок
        for (int dx = -radius; dx <= radius; dx++)
        {
            for (int dy = -radius; dy <= radius; dy++)
            {
                if (dx * dx + dy * dy <= radius * radius)
                {
                    int px = x + dx;
                    int py = y + dy;
                    if (px >= 0 && px < textureSize && py >= 0 && py < textureSize)
                    {
                        tempTex.SetPixel(px, py, new Color(1, 0, 0, 1)); // 1 = SAND
                    }
                }
            }
        }
        tempTex.Apply();
        
        // Копируем обратно в RenderTexture
        Graphics.Blit(tempTex, buffers[currentBuffer]);
        
        Destroy(tempTex);
    }
    
    void OnDestroy()
    {
        for (int i = 0; i < 2; i++)
        {
            if (buffers[i] != null)
            {
                buffers[i].Release();
            }
        }
    }
}
```

---

## Настройка в Unity

### Шаг 1: Создание файлов
1. Создай `Assets/Shaders/SandSimulation.compute`
2. Создай `Assets/Shaders/SandVisualizer.shader`
3. Создай `Assets/Scripts/SandSimulationController.cs`
4. Скопируй код из этого урока

### Шаг 2: Настройка сцены
1. **Удали или отключи** объекты от предыдущего урока
2. **Создай Quad:**
   - Hierarchy → 3D Object → Quad
   - Назови "SandDisplay"
   - Position: (0, 0, 0)
   - Scale: (5, 5, 1) — или другой размер
3. **Создай материал:**
   - Create → Material → "SandMaterial"
   - Shader: PowderGame/SandVisualizer
4. **Назначь материал** на Quad
5. **Создай контроллер:**
   - Create Empty → "SandController"
   - Добавь компонент SandSimulationController
   - Sand Compute: назначь SandSimulation.compute
   - Display Material: назначь SandMaterial
6. **Настрой камеру:**
   - Main Camera → Position: (0, 0, -10)
   - Projection: Orthographic
   - Size: 3-5

### Шаг 3: Запуск
1. Нажми **Play**
2. Должен появиться песок, падающий сверху
3. Песок должен накапливаться внизу экрана

---

## Возможные проблемы

| Проблема | Решение |
|----------|---------|
| Чёрный экран | Проверь, что материал назначен и шейдер компилируется |
| Песок не падает | Проверь kernel names в Compute Shader |
| Песок исчезает | Проверь границы в GetParticle() |
| Странные артефакты | Убедись, что filterMode = Point |

---

## Что дальше?

После успешного запуска:
1. Попробуй изменить **spawnPosition** (в Inspector или коде)
2. Измени **spawnRadius** и **spawnRate**
3. Поэкспериментируй с **цветами** в SandVisualizer

**Напиши "Готово" когда увидишь падающий и накапливающийся песок!**
