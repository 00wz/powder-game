# Этап 4: Field-Based Gas Simulation

## Два подхода к симуляции газа/жидкости

### 1. Лагранжев подход (Particle-based)
- Отслеживаем отдельные **частицы**
- Каждая частица имеет позицию, скорость
- Пример: SPH (Smoothed Particle Hydrodynamics)
- ❌ Дорого для больших объёмов газа

### 2. Эйлеров подход (Field-based) ✅ НАШ ВЫБОР
- Сетка **фиксированных ячеек**
- Каждая ячейка хранит свойства: плотность, скорость, давление
- Вещество "течёт" между ячейками
- ✅ Эффективно на GPU, хорошо масштабируется

```
Particle-based:                Field-based:
┌─────────────────┐           ┌───┬───┬───┬───┐
│  •      •       │           │0.1│0.3│0.5│0.2│ ← плотность
│    •        •   │           ├───┼───┼───┼───┤
│ •    •   •      │           │0.4│0.8│0.9│0.3│
│      •      •   │           ├───┼───┼───┼───┤
└─────────────────┘           │0.2│0.5│0.7│0.1│
                              └───┴───┴───┴───┘
```

## Уравнения Навье-Стокса (упрощённо)

Полные уравнения сложны, но для игры достаточно упрощённой модели:

```
∂ρ/∂t + ∇·(ρv) = 0           // Сохранение массы
∂v/∂t + (v·∇)v = -∇p + ν∇²v  // Сохранение импульса
```

Мы разбиваем на шаги:
1. **Advection** — перенос вещества скоростью
2. **Diffusion** — рассеивание (диффузия)
3. **Forces** — внешние силы (гравитация, источники)
4. **Pressure** — выравнивание давления (опционально)

## Данные в текстурах

### Текстура газового поля (RGBAFloat)
```
R = плотность газа (0-1)
G = скорость X (-1 до 1)
B = скорость Y (-1 до 1)
A = резерв (температура, тип газа)
```

## Шаг 1: Advection (Перенос)

Advection — перемещение свойств поля вдоль скорости.

### Semi-Lagrangian метод
Вместо "куда уйдёт это значение?" спрашиваем:
**"Откуда пришло значение в эту ячейку?"**

```
Для ячейки (x, y) со скоростью (vx, vy):
1. Вычисляем откуда "пришло" значение:
   sourcePos = (x, y) - (vx, vy) * dt
2. Интерполируем значение из sourcePos
3. Записываем в (x, y)
```

```hlsl
float4 Advect(int2 pos, float dt)
{
    float4 current = _Input[pos];
    float2 velocity = current.gb;  // G и B = скорость
    
    // Откуда пришло значение?
    float2 sourcePos = float2(pos) - velocity * dt * _Speed;
    
    // Читаем с интерполяцией (билинейная)
    return SampleBilinear(sourcePos);
}
```

## Шаг 2: Diffusion (Диффузия)

Газ рассеивается — соседние ячейки обмениваются значениями.

```
Простая диффузия = усреднение с соседями:
newValue = current * (1 - diff) + average(neighbors) * diff
```

```hlsl
float4 Diffuse(int2 pos, float diffusion)
{
    float4 current = _Input[pos];
    float4 sum = float4(0,0,0,0);
    
    // 4 соседа
    sum += GetGas(pos + int2(1, 0));
    sum += GetGas(pos + int2(-1, 0));
    sum += GetGas(pos + int2(0, 1));
    sum += GetGas(pos + int2(0, -1));
    
    float4 average = sum / 4.0;
    return lerp(current, average, diffusion);
}
```

## Шаг 3: Внешние силы

Добавляем гравитацию, источники газа, взаимодействие с частицами.

```hlsl
// Гравитация влияет на скорость (канал B = Y-скорость)
velocity.y -= gravity * dt;

// Плавучесть (горячий газ поднимается)
velocity.y += density * buoyancy * dt;
```

---

## Практическая реализация

### Создай Compute Shader: `Assets/Shaders/GasSimulation.compute`

```hlsl
#pragma kernel AdvectGas
#pragma kernel DiffuseGas
#pragma kernel ApplyForces
#pragma kernel AddGasSource

// Текстуры газа (double buffering)
RWTexture2D<float4> _GasOutput;
Texture2D<float4> _GasInput;

// Текстура частиц (для взаимодействия)
Texture2D<float4> _ParticlesTex;

// Сэмплер для билинейной интерполяции
SamplerState sampler_linear_clamp;

// Параметры
int _Width;
int _Height;
float _DeltaTime;
float _AdvectionSpeed;
float _Diffusion;
float _Dissipation;    // Затухание
float _Gravity;
float _Buoyancy;

// Источник газа
int2 _SourcePosition;
float _SourceRadius;
float _SourceStrength;
float2 _SourceVelocity;

// ===== ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ =====

bool InBounds(int2 pos)
{
    return pos.x >= 0 && pos.x < _Width && pos.y >= 0 && pos.y < _Height;
}

float4 GetGas(int2 pos)
{
    if (!InBounds(pos)) return float4(0, 0, 0, 0);
    return _GasInput[pos];
}

// Билинейная интерполяция для advection
float4 SampleGasBilinear(float2 pos)
{
    // Ограничиваем координаты
    pos = clamp(pos, float2(0.5, 0.5), float2(_Width - 1.5, _Height - 1.5));
    
    // Целые координаты углов
    int2 p00 = int2(floor(pos));
    int2 p10 = p00 + int2(1, 0);
    int2 p01 = p00 + int2(0, 1);
    int2 p11 = p00 + int2(1, 1);
    
    // Дробная часть для интерполяции
    float2 f = frac(pos);
    
    // Читаем 4 угла
    float4 v00 = GetGas(p00);
    float4 v10 = GetGas(p10);
    float4 v01 = GetGas(p01);
    float4 v11 = GetGas(p11);
    
    // Билинейная интерполяция
    float4 v0 = lerp(v00, v10, f.x);
    float4 v1 = lerp(v01, v11, f.x);
    return lerp(v0, v1, f.y);
}

// ===== KERNEL: ADVECTION =====
[numthreads(8, 8, 1)]
void AdvectGas(uint3 id : SV_DispatchThreadID)
{
    int2 pos = int2(id.xy);
    if (!InBounds(pos)) return;
    
    float4 current = GetGas(pos);
    float2 velocity = current.gb * 2.0 - 1.0;  // Декодируем: 0-1 → -1..1
    
    // Semi-Lagrangian: откуда пришло значение?
    float2 sourcePos = float2(pos) - velocity * _DeltaTime * _AdvectionSpeed;
    
    // Интерполируем
    float4 advected = SampleGasBilinear(sourcePos);
    
    // Затухание плотности
    advected.r *= (1.0 - _Dissipation * _DeltaTime);
    
    _GasOutput[pos] = advected;
}

// ===== KERNEL: DIFFUSION =====
[numthreads(8, 8, 1)]
void DiffuseGas(uint3 id : SV_DispatchThreadID)
{
    int2 pos = int2(id.xy);
    if (!InBounds(pos)) return;
    
    float4 current = GetGas(pos);
    
    // Сумма соседей
    float4 neighbors = float4(0,0,0,0);
    neighbors += GetGas(pos + int2(1, 0));
    neighbors += GetGas(pos + int2(-1, 0));
    neighbors += GetGas(pos + int2(0, 1));
    neighbors += GetGas(pos + int2(0, -1));
    float4 average = neighbors / 4.0;
    
    // Смешиваем текущее с соседями
    float4 diffused = lerp(current, average, _Diffusion);
    
    _GasOutput[pos] = diffused;
}

// ===== KERNEL: FORCES =====
[numthreads(8, 8, 1)]
void ApplyForces(uint3 id : SV_DispatchThreadID)
{
    int2 pos = int2(id.xy);
    if (!InBounds(pos)) return;
    
    float4 current = GetGas(pos);
    float density = current.r;
    float2 velocity = current.gb * 2.0 - 1.0;  // Декодируем
    
    // Проверяем, есть ли здесь твёрдая частица
    float particleType = _ParticlesTex[pos].r;
    if (particleType > 0.5)
    {
        // Твёрдая частица блокирует газ
        _GasOutput[pos] = float4(0, 0.5, 0.5, 0);  // Нет газа, нулевая скорость
        return;
    }
    
    // Гравитация (газ слегка опускается)
    velocity.y -= _Gravity * _DeltaTime;
    
    // Плавучесть (плотный газ поднимается - инвертировано для эффекта)
    velocity.y += density * _Buoyancy * _DeltaTime;
    
    // Ограничиваем скорость
    velocity = clamp(velocity, float2(-1, -1), float2(1, 1));
    
    // Кодируем обратно: -1..1 → 0-1
    current.gb = velocity * 0.5 + 0.5;
    
    _GasOutput[pos] = current;
}

// ===== KERNEL: ADD SOURCE =====
[numthreads(8, 8, 1)]
void AddGasSource(uint3 id : SV_DispatchThreadID)
{
    int2 pos = int2(id.xy);
    if (!InBounds(pos)) return;
    
    float4 current = _GasOutput[pos];  // Читаем из Output (уже обновлённый)
    
    // Расстояние до источника
    float dist = length(float2(pos) - float2(_SourcePosition));
    
    if (dist < _SourceRadius)
    {
        // Плавный спад от центра
        float falloff = 1.0 - (dist / _SourceRadius);
        falloff = falloff * falloff;  // Квадратичный спад
        
        // Добавляем плотность
        current.r += _SourceStrength * falloff * _DeltaTime;
        current.r = saturate(current.r);
        
        // Добавляем начальную скорость
        float2 velocity = current.gb * 2.0 - 1.0;
        velocity += _SourceVelocity * falloff * _DeltaTime;
        velocity = clamp(velocity, float2(-1, -1), float2(1, 1));
        current.gb = velocity * 0.5 + 0.5;
    }
    
    _GasOutput[pos] = current;
}
```

### C# Controller: `Assets/Scripts/GasSimulationController.cs`

```csharp
using UnityEngine;

public class GasSimulationController : MonoBehaviour
{
    [Header("Compute Shaders")]
    public ComputeShader gasCompute;
    public ComputeShader sandCompute;  // Для частиц
    
    [Header("Settings")]
    public int textureSize = 256;
    
    [Header("Gas Parameters")]
    [Range(0, 50)] public float advectionSpeed = 20f;
    [Range(0, 0.5f)] public float diffusion = 0.1f;
    [Range(0, 1f)] public float dissipation = 0.02f;
    [Range(-1, 1)] public float gravity = 0.1f;
    [Range(-5, 5)] public float buoyancy = 1f;
    
    [Header("Source")]
    public bool emitGas = true;
    public Vector2Int sourcePosition = new Vector2Int(128, 20);
    public float sourceRadius = 10f;
    public float sourceStrength = 5f;
    public Vector2 sourceVelocity = new Vector2(0, 1);
    
    [Header("Visualization")]
    public Material displayMaterial;
    
    // Текстуры
    private RenderTexture[] gasBuffers = new RenderTexture[2];
    private RenderTexture[] particleBuffers = new RenderTexture[2];
    private int currentGasBuffer = 0;
    private int currentParticleBuffer = 0;
    
    // Kernels
    private int advectKernel, diffuseKernel, forcesKernel, sourceKernel;
    private int sandSimulateKernel, sandInitKernel;
    
    void Start()
    {
        CreateTextures();
        SetupKernels();
        InitializeSimulation();
    }
    
    void CreateTextures()
    {
        // Газовые буферы
        for (int i = 0; i < 2; i++)
        {
            gasBuffers[i] = CreateRenderTexture();
            particleBuffers[i] = CreateRenderTexture();
        }
    }
    
    RenderTexture CreateRenderTexture()
    {
        RenderTexture rt = new RenderTexture(textureSize, textureSize, 0, RenderTextureFormat.ARGBFloat);
        rt.enableRandomWrite = true;
        rt.filterMode = FilterMode.Bilinear;  // Для газа можно Bilinear
        rt.wrapMode = TextureWrapMode.Clamp;
        rt.Create();
        return rt;
    }
    
    void SetupKernels()
    {
        // Gas kernels
        advectKernel = gasCompute.FindKernel("AdvectGas");
        diffuseKernel = gasCompute.FindKernel("DiffuseGas");
        forcesKernel = gasCompute.FindKernel("ApplyForces");
        sourceKernel = gasCompute.FindKernel("AddGasSource");
        
        // Sand kernels
        sandSimulateKernel = sandCompute.FindKernel("SimulateSand");
        sandInitKernel = sandCompute.FindKernel("InitializeTexture");
        
        // Установка размеров
        gasCompute.SetInt("_Width", textureSize);
        gasCompute.SetInt("_Height", textureSize);
        sandCompute.SetInt("_Width", textureSize);
        sandCompute.SetInt("_Height", textureSize);
    }
    
    void InitializeSimulation()
    {
        int groups = Mathf.CeilToInt(textureSize / 8.0f);
        
        // Инициализируем газ (пусто)
        for (int i = 0; i < 2; i++)
        {
            // Можно использовать тот же InitializeTexture из sandCompute
            sandCompute.SetTexture(sandInitKernel, "_Output", gasBuffers[i]);
            sandCompute.Dispatch(sandInitKernel, groups, groups, 1);
            
            sandCompute.SetTexture(sandInitKernel, "_Output", particleBuffers[i]);
            sandCompute.Dispatch(sandInitKernel, groups, groups, 1);
        }
    }
    
    void Update()
    {
        float dt = Mathf.Min(Time.deltaTime, 0.033f);  // Максимум ~30 FPS для стабильности
        int groups = Mathf.CeilToInt(textureSize / 8.0f);
        
        // 1. Симуляция частиц (песок)
        SimulateSand(groups);
        
        // 2. Симуляция газа
        SimulateGas(dt, groups);
        
        // 3. Обновляем материал
        UpdateDisplay();
    }
    
    void SimulateSand(int groups)
    {
        int read = currentParticleBuffer;
        int write = 1 - currentParticleBuffer;
        
        sandCompute.SetInt("_Frame", Time.frameCount);
        sandCompute.SetTexture(sandSimulateKernel, "_Input", particleBuffers[read]);
        sandCompute.SetTexture(sandSimulateKernel, "_Output", particleBuffers[write]);
        sandCompute.Dispatch(sandSimulateKernel, groups, groups, 1);
        
        currentParticleBuffer = write;
    }
    
    void SimulateGas(float dt, int groups)
    {
        // Общие параметры
        gasCompute.SetFloat("_DeltaTime", dt);
        gasCompute.SetFloat("_AdvectionSpeed", advectionSpeed);
        gasCompute.SetFloat("_Diffusion", diffusion);
        gasCompute.SetFloat("_Dissipation", dissipation);
        gasCompute.SetFloat("_Gravity", gravity);
        gasCompute.SetFloat("_Buoyancy", buoyancy);
        
        // Текстура частиц для взаимодействия
        gasCompute.SetTexture(forcesKernel, "_ParticlesTex", particleBuffers[currentParticleBuffer]);
        
        int read = currentGasBuffer;
        int write = 1 - currentGasBuffer;
        
        // Шаг 1: Advection
        gasCompute.SetTexture(advectKernel, "_GasInput", gasBuffers[read]);
        gasCompute.SetTexture(advectKernel, "_GasOutput", gasBuffers[write]);
        gasCompute.Dispatch(advectKernel, groups, groups, 1);
        SwapGasBuffers(ref read, ref write);
        
        // Шаг 2: Diffusion (несколько итераций для лучшего качества)
        for (int i = 0; i < 2; i++)
        {
            gasCompute.SetTexture(diffuseKernel, "_GasInput", gasBuffers[read]);
            gasCompute.SetTexture(diffuseKernel, "_GasOutput", gasBuffers[write]);
            gasCompute.Dispatch(diffuseKernel, groups, groups, 1);
            SwapGasBuffers(ref read, ref write);
        }
        
        // Шаг 3: Forces
        gasCompute.SetTexture(forcesKernel, "_GasInput", gasBuffers[read]);
        gasCompute.SetTexture(forcesKernel, "_GasOutput", gasBuffers[write]);
        gasCompute.Dispatch(forcesKernel, groups, groups, 1);
        
        // Шаг 4: Add source (работает с Output)
        if (emitGas)
        {
            gasCompute.SetInts("_SourcePosition", sourcePosition.x, sourcePosition.y);
            gasCompute.SetFloat("_SourceRadius", sourceRadius);
            gasCompute.SetFloat("_SourceStrength", sourceStrength);
            gasCompute.SetFloats("_SourceVelocity", sourceVelocity.x, sourceVelocity.y);
            
            gasCompute.SetTexture(sourceKernel, "_GasOutput", gasBuffers[write]);
            gasCompute.Dispatch(sourceKernel, groups, groups, 1);
        }
        
        currentGasBuffer = write;
    }
    
    void SwapGasBuffers(ref int read, ref int write)
    {
        int temp = read;
        read = write;
        write = temp;
    }
    
    void UpdateDisplay()
    {
        if (displayMaterial != null)
        {
            displayMaterial.SetTexture("_GasTex", gasBuffers[currentGasBuffer]);
            displayMaterial.SetTexture("_ParticleTex", particleBuffers[currentParticleBuffer]);
        }
    }
    
    // Публичные методы для спавна
    public void SpawnSandAt(int x, int y, int radius)
    {
        // Используем тот же метод что в SandSimulationController
        Texture2D temp = new Texture2D(textureSize, textureSize, TextureFormat.RGBAFloat, false);
        RenderTexture.active = particleBuffers[currentParticleBuffer];
        temp.ReadPixels(new Rect(0, 0, textureSize, textureSize), 0, 0);
        temp.Apply();
        RenderTexture.active = null;
        
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
                        temp.SetPixel(px, py, new Color(1, 0, 0, 1));
                    }
                }
            }
        }
        temp.Apply();
        Graphics.Blit(temp, particleBuffers[currentParticleBuffer]);
        Destroy(temp);
    }
    
    void OnDestroy()
    {
        foreach (var rt in gasBuffers) if (rt != null) rt.Release();
        foreach (var rt in particleBuffers) if (rt != null) rt.Release();
    }
}
```

### Шейдер визуализации: `Assets/Shaders/GasParticleVisualizer.shader`

```hlsl
Shader "PowderGame/GasParticleVisualizer"
{
    Properties
    {
        _ParticleTex ("Particles", 2D) = "black" {}
        _GasTex ("Gas", 2D) = "black" {}
        _SandColor ("Sand Color", Color) = (0.76, 0.70, 0.50, 1)
        _EmptyColor ("Background", Color) = (0.05, 0.05, 0.08, 1)
        _GasColor ("Gas Color", Color) = (0.3, 0.5, 0.8, 1)
        _GasOpacity ("Gas Opacity", Range(0, 1)) = 0.5
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
            float4 _SandColor;
            float4 _EmptyColor;
            float4 _GasColor;
            float _GasOpacity;

            v2f vert (appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.uv = v.uv;
                return o;
            }

            fixed4 frag (v2f i) : SV_Target
            {
                // Читаем данные
                float4 particle = tex2D(_ParticleTex, i.uv);
                float4 gas = tex2D(_GasTex, i.uv);
                
                float particleType = particle.r;
                float gasDensity = gas.r;
                
                // Базовый цвет (фон или частица)
                fixed4 baseColor = lerp(_EmptyColor, _SandColor, particleType);
                
                // Накладываем газ поверх
                fixed4 gasOverlay = _GasColor * gasDensity * _GasOpacity;
                
                // Финальный цвет
                fixed4 finalColor = baseColor + gasOverlay;
                finalColor.a = 1;
                
                return finalColor;
            }
            ENDCG
        }
    }
}
```

---

## Настройка в Unity

1. **Создай файлы:**
   - `Assets/Shaders/GasSimulation.compute`
   - `Assets/Scripts/GasSimulationController.cs`
   - `Assets/Shaders/GasParticleVisualizer.shader`

2. **Создай материал:**
   - Create → Material → "GasVisMaterial"
   - Shader: PowderGame/GasParticleVisualizer

3. **Настрой сцену:**
   - Отключи старый SandSimulationController (если есть)
   - Создай пустой объект "SimulationController"
   - Добавь GasSimulationController
   - Назначь:
     - Gas Compute: GasSimulation.compute
     - Sand Compute: SandSimulation.compute (существующий)
     - Display Material: GasVisMaterial

4. **Назначь материал** на Quad

5. **Запусти** и наблюдай газ!

---

## Параметры для экспериментов

| Параметр | Эффект |
|----------|--------|
| **Advection Speed** | Как быстро газ перемещается |
| **Diffusion** | Как быстро рассеивается |
| **Dissipation** | Как быстро исчезает |
| **Gravity** | Газ опускается или поднимается |
| **Buoyancy** | Плавучесть (плотный поднимается) |
| **Source Velocity** | Направление выброса газа |

**Напиши "Готово" когда увидишь движущийся газ!**
