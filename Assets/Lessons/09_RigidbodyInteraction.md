# Взаимодействие частиц/газа с Rigidbody

## Три подхода

| Подход | Плюсы | Минусы |
|--------|-------|--------|
| **1. StructuredBuffer** | Простой | Только простые формы |
| **2. GPU Picking (ID Render)** | Любые формы, всё на GPU | Сложнее настройка |
| **3. ComputeBuffer Reduction** | Самый быстрый | Требует понимания reduction |

---

# ПОДХОД 2: GPU Picking + Render Pass (Рекомендуемый!)

## Идея

```
┌─────────────────────────────────────────────────────────┐
│ Render Pass 1: ID Texture                               │
│ ┌─────────────────┐                                     │
│ │  ████           │  Объект 1 = ID 1 (красный)         │
│ │      ████       │  Объект 2 = ID 2 (зелёный)         │
│ │          ████   │  Фон = ID 0 (чёрный)               │
│ └─────────────────┘                                     │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│ Compute Shader: Force Calculation                       │
│                                                         │
│ Для каждого пикселя:                                   │
│   - Читаем ID объекта                                   │
│   - Читаем газ/давление                                 │
│   - Добавляем силу в ComputeBuffer[ID]                 │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│ CPU: Apply Forces                                       │
│                                                         │
│ forces = buffer.GetData()                               │
│ foreach body: body.AddForce(forces[id])                │
└─────────────────────────────────────────────────────────┘
```

---

## Шаг 1: Шейдер для отрисовки ID

### `Assets/Shaders/ObjectIDShader.shader`

```hlsl
Shader "PowderGame/ObjectID"
{
    Properties
    {
        _ObjectID ("Object ID", Float) = 0
    }
    
    SubShader
    {
        Tags { "RenderType"="Opaque" }
        
        Pass
        {
            // Отключаем освещение, блендинг — нам нужен чистый ID
            Lighting Off
            ZWrite On
            ZTest LEqual
            Blend Off
            
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            
            #include "UnityCG.cginc"
            
            float _ObjectID;
            
            struct appdata
            {
                float4 vertex : POSITION;
            };
            
            struct v2f
            {
                float4 vertex : SV_POSITION;
            };
            
            v2f vert(appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                return o;
            }
            
            // Выводим ID как цвет
            // ID закодирован в R канал (0-255 объектов)
            // Или используем RG для 65536 объектов
            float4 frag(v2f i) : SV_Target
            {
                // Кодируем ID: low byte в R, high byte в G
                float id = _ObjectID;
                float lowByte = fmod(id, 256.0) / 255.0;
                float highByte = floor(id / 256.0) / 255.0;
                
                return float4(lowByte, highByte, 0, 1);
            }
            ENDCG
        }
    }
}
```

---

## Шаг 2: Отдельная камера для ID Pass

### `Assets/Scripts/IDRenderPass.cs`

```csharp
using UnityEngine;
using System.Collections.Generic;

public class IDRenderPass : MonoBehaviour
{
    [Header("Render Settings")]
    public int textureSize = 256;
    public LayerMask physicsLayer;  // Слой для физических объектов
    
    [Header("World Bounds (должны совпадать с симуляцией)")]
    public Vector2 worldMin = new Vector2(-5, -5);
    public Vector2 worldMax = new Vector2(5, 5);
    
    // ID текстура
    public RenderTexture IDTexture { get; private set; }
    
    // Маппинг ID → Rigidbody
    private Dictionary<int, Rigidbody2D> idToBody = new Dictionary<int, Rigidbody2D>();
    private Dictionary<Rigidbody2D, int> bodyToId = new Dictionary<Rigidbody2D, int>();
    private Material[] idMaterials;
    private int nextID = 1;  // 0 зарезервирован для "нет объекта"
    
    // Отдельная камера
    private Camera idCamera;
    
    void Start()
    {
        CreateIDTexture();
        CreateIDCamera();
        
        // Материалы для каждого ID
        idMaterials = new Material[256];
        Shader idShader = Shader.Find("PowderGame/ObjectID");
        
        for (int i = 0; i < 256; i++)
        {
            idMaterials[i] = new Material(idShader);
            idMaterials[i].SetFloat("_ObjectID", i);
        }
    }
    
    void CreateIDTexture()
    {
        IDTexture = new RenderTexture(textureSize, textureSize, 16, RenderTextureFormat.RGFloat);
        IDTexture.enableRandomWrite = true;
        IDTexture.filterMode = FilterMode.Point;  // Без интерполяции!
        IDTexture.Create();
    }
    
    void CreateIDCamera()
    {
        // Создаём дочерний объект с камерой
        GameObject camObj = new GameObject("ID Camera");
        camObj.transform.SetParent(transform);
        
        idCamera = camObj.AddComponent<Camera>();
        idCamera.orthographic = true;
        idCamera.clearFlags = CameraClearFlags.SolidColor;
        idCamera.backgroundColor = Color.black;  // ID = 0 для фона
        idCamera.cullingMask = physicsLayer;
        idCamera.targetTexture = IDTexture;
        idCamera.enabled = false;  // Рендерим вручную
        
        // Настраиваем ортографическую проекцию под мировые границы
        float worldWidth = worldMax.x - worldMin.x;
        float worldHeight = worldMax.y - worldMin.y;
        
        idCamera.orthographicSize = worldHeight / 2f;
        idCamera.aspect = worldWidth / worldHeight;
        
        Vector3 center = new Vector3(
            (worldMin.x + worldMax.x) / 2f,
            (worldMin.y + worldMax.y) / 2f,
            -10f
        );
        camObj.transform.position = center;
    }
    
    /// <summary>
    /// Регистрирует Rigidbody и возвращает его ID
    /// </summary>
    public int RegisterBody(Rigidbody2D body)
    {
        if (bodyToId.ContainsKey(body))
            return bodyToId[body];
        
        int id = nextID++;
        idToBody[id] = body;
        bodyToId[body] = id;
        
        // Назначаем материал с нужным ID
        var renderer = body.GetComponent<SpriteRenderer>();
        if (renderer != null && id < idMaterials.Length)
        {
            // Сохраняем оригинальный материал для основного рендеринга
            // Для ID pass используем замену
        }
        
        return id;
    }
    
    public Rigidbody2D GetBodyByID(int id)
    {
        return idToBody.TryGetValue(id, out var body) ? body : null;
    }
    
    public int GetIDByBody(Rigidbody2D body)
    {
        return bodyToId.TryGetValue(body, out var id) ? id : 0;
    }
    
    /// <summary>
    /// Рендерит ID текстуру
    /// </summary>
    public void RenderIDPass()
    {
        // Временно заменяем материалы на ID материалы
        var renderers = new List<(Renderer, Material)>();
        
        foreach (var kvp in bodyToId)
        {
            var body = kvp.Key;
            var id = kvp.Value;
            
            var renderer = body.GetComponent<Renderer>();
            if (renderer != null && id < idMaterials.Length)
            {
                renderers.Add((renderer, renderer.sharedMaterial));
                renderer.sharedMaterial = idMaterials[id];
            }
        }
        
        // Рендерим
        idCamera.Render();
        
        // Восстанавливаем материалы
        foreach (var (renderer, originalMat) in renderers)
        {
            renderer.sharedMaterial = originalMat;
        }
    }
    
    void OnDestroy()
    {
        if (IDTexture != null) IDTexture.Release();
        foreach (var mat in idMaterials)
            if (mat != null) Destroy(mat);
    }
}
```

---

## Шаг 3: Compute Shader для расчёта сил

### `Assets/Shaders/ForceCalculation.compute`

```hlsl
#pragma kernel CalculateForces
#pragma kernel ReduceForces

// Входные данные
Texture2D<float4> _IDTexture;      // R = low byte, G = high byte
Texture2D<float4> _GasTexture;     // R = density, GB = velocity
Texture2D<float4> _ParticleTexture; // Опционально: давление частиц

// Выходные данные — силы для каждого объекта
// x = force.x, y = force.y, z = torque, w = count (для усреднения)
RWStructuredBuffer<float4> _ForceBuffer;

// Параметры
int _Width;
int _Height;
int _MaxObjects;
float _ForceMultiplier;
float _PressureMultiplier;

// Центры объектов (для расчёта момента)
StructuredBuffer<float2> _ObjectCenters;

// Декодирование ID из текстуры
int DecodeID(float4 color)
{
    int lowByte = (int)(color.r * 255.0 + 0.5);
    int highByte = (int)(color.g * 255.0 + 0.5);
    return lowByte + highByte * 256;
}

// Основной kernel: вычисляем силу для каждого пикселя
[numthreads(8, 8, 1)]
void CalculateForces(uint3 id : SV_DispatchThreadID)
{
    int2 pos = int2(id.xy);
    if (pos.x >= _Width || pos.y >= _Height) return;
    
    // Читаем ID объекта в этом пикселе
    float4 idColor = _IDTexture[pos];
    int objectID = DecodeID(idColor);
    
    if (objectID == 0 || objectID >= _MaxObjects) return;  // Нет объекта
    
    // Читаем данные газа
    float4 gas = _GasTexture[pos];
    float density = gas.r;
    float2 velocity = gas.gb * 2.0 - 1.0;  // Декодируем скорость
    
    // Опционально: читаем частицы для давления
    float4 particle = _ParticleTexture[pos];
    float particleDensity = particle.r;
    
    // === ВЫЧИСЛЕНИЕ СИЛЫ ===
    
    // 1. Сила от потока газа (momentum transfer)
    float2 flowForce = velocity * density * _ForceMultiplier;
    
    // 2. Сила давления (направлена наружу от объекта)
    // Для этого нужно знать нормаль поверхности
    // Упрощённо: используем градиент ID текстуры
    float2 gradient = float2(0, 0);
    
    // Проверяем соседей — где заканчивается объект
    int idLeft = DecodeID(_IDTexture[pos + int2(-1, 0)]);
    int idRight = DecodeID(_IDTexture[pos + int2(1, 0)]);
    int idDown = DecodeID(_IDTexture[pos + int2(0, -1)]);
    int idUp = DecodeID(_IDTexture[pos + int2(0, 1)]);
    
    // Градиент указывает "наружу" от объекта
    if (idLeft != objectID) gradient.x -= 1;
    if (idRight != objectID) gradient.x += 1;
    if (idDown != objectID) gradient.y -= 1;
    if (idUp != objectID) gradient.y += 1;
    
    float2 normal = normalize(gradient + 0.0001);  // Избегаем деления на 0
    
    // Сила давления: давление * нормаль
    float pressure = density + particleDensity * 0.5;
    float2 pressureForce = normal * pressure * _PressureMultiplier;
    
    // 3. Суммарная сила
    float2 totalForce = flowForce + pressureForce;
    
    // 4. Момент силы (torque) для вращения
    float2 center = _ObjectCenters[objectID];
    float2 pixelWorld = float2(pos) / float2(_Width, _Height);  // Нормализованные координаты
    float2 r = pixelWorld - center;  // Радиус-вектор от центра
    float torque = r.x * totalForce.y - r.y * totalForce.x;  // Cross product в 2D
    
    // === АТОМАРНОЕ ДОБАВЛЕНИЕ В БУФЕР ===
    // Используем InterlockedAdd для float через int интерпретацию
    // Или просто накапливаем и усредняем позже
    
    // Простой вариант: пишем в буфер (будет race condition!)
    // Для корректности нужен InterlockedAdd или reduction pass
    
    // Временное решение: записываем во временный буфер,
    // потом делаем reduction
    int bufferIndex = objectID;
    
    // Atomic add для float не поддерживается напрямую
    // Используем InterlockedAdd с fixed-point
    int forceXInt = (int)(totalForce.x * 1000000.0);
    int forceYInt = (int)(totalForce.y * 1000000.0);
    int torqueInt = (int)(torque * 1000000.0);
    
    InterlockedAdd(_ForceBufferInt[bufferIndex * 4 + 0], forceXInt);
    InterlockedAdd(_ForceBufferInt[bufferIndex * 4 + 1], forceYInt);
    InterlockedAdd(_ForceBufferInt[bufferIndex * 4 + 2], torqueInt);
    InterlockedAdd(_ForceBufferInt[bufferIndex * 4 + 3], 1);  // Счётчик
}

// Буфер для атомарных операций (int)
RWStructuredBuffer<int> _ForceBufferInt;

// Финализация: конвертируем int обратно в float
[numthreads(64, 1, 1)]
void FinalizeForces(uint3 id : SV_DispatchThreadID)
{
    int objectID = id.x;
    if (objectID >= _MaxObjects) return;
    
    int baseIndex = objectID * 4;
    
    float forceX = _ForceBufferInt[baseIndex + 0] / 1000000.0;
    float forceY = _ForceBufferInt[baseIndex + 1] / 1000000.0;
    float torque = _ForceBufferInt[baseIndex + 2] / 1000000.0;
    int count = _ForceBufferInt[baseIndex + 3];
    
    if (count > 0)
    {
        // Усредняем (опционально)
        // forceX /= count;
        // forceY /= count;
        // torque /= count;
    }
    
    _ForceBuffer[objectID] = float4(forceX, forceY, torque, count);
    
    // Очищаем int буфер для следующего кадра
    _ForceBufferInt[baseIndex + 0] = 0;
    _ForceBufferInt[baseIndex + 1] = 0;
    _ForceBufferInt[baseIndex + 2] = 0;
    _ForceBufferInt[baseIndex + 3] = 0;
}
```

---

## Шаг 4: Главный контроллер

### `Assets/Scripts/GPUPhysicsController.cs`

```csharp
using UnityEngine;
using UnityEngine.Rendering;
using System.Collections.Generic;

public class GPUPhysicsController : MonoBehaviour
{
    [Header("Components")]
    public IDRenderPass idRenderPass;
    public ComputeShader forceCompute;
    
    [Header("Simulation Textures")]
    public RenderTexture gasTexture;
    public RenderTexture particleTexture;
    
    [Header("Settings")]
    public int maxObjects = 256;
    public float forceMultiplier = 10f;
    public float pressureMultiplier = 5f;
    public float torqueMultiplier = 1f;
    
    [Header("Tracked Bodies")]
    public List<Rigidbody2D> bodies = new List<Rigidbody2D>();
    
    // Буферы
    private ComputeBuffer forceBuffer;
    private ComputeBuffer forceBufferInt;
    private ComputeBuffer centersBuffer;
    private Vector4[] forceData;
    private Vector2[] centersData;
    
    // Kernels
    private int calculateKernel;
    private int finalizeKernel;
    
    void Start()
    {
        InitializeBuffers();
        RegisterBodies();
        
        calculateKernel = forceCompute.FindKernel("CalculateForces");
        finalizeKernel = forceCompute.FindKernel("FinalizeForces");
    }
    
    void InitializeBuffers()
    {
        // float4 буфер для финальных сил
        forceBuffer = new ComputeBuffer(maxObjects, sizeof(float) * 4);
        forceData = new Vector4[maxObjects];
        
        // int буфер для атомарных операций
        forceBufferInt = new ComputeBuffer(maxObjects * 4, sizeof(int));
        int[] zeros = new int[maxObjects * 4];
        forceBufferInt.SetData(zeros);
        
        // Центры объектов
        centersBuffer = new ComputeBuffer(maxObjects, sizeof(float) * 2);
        centersData = new Vector2[maxObjects];
    }
    
    void RegisterBodies()
    {
        foreach (var body in bodies)
        {
            if (body != null)
            {
                idRenderPass.RegisterBody(body);
            }
        }
    }
    
    void Update()
    {
        // 1. Обновляем центры объектов
        UpdateCenters();
        
        // 2. Рендерим ID текстуру
        idRenderPass.RenderIDPass();
        
        // 3. Вычисляем силы на GPU
        CalculateForcesGPU();
        
        // 4. Читаем результаты
        RequestForceData();
    }
    
    void UpdateCenters()
    {
        foreach (var body in bodies)
        {
            if (body == null) continue;
            
            int id = idRenderPass.GetIDByBody(body);
            if (id > 0 && id < maxObjects)
            {
                // Преобразуем мировую позицию в нормализованные координаты (0-1)
                Vector2 worldPos = body.position;
                Vector2 normalized = new Vector2(
                    (worldPos.x - idRenderPass.worldMin.x) / (idRenderPass.worldMax.x - idRenderPass.worldMin.x),
                    (worldPos.y - idRenderPass.worldMin.y) / (idRenderPass.worldMax.y - idRenderPass.worldMin.y)
                );
                centersData[id] = normalized;
            }
        }
        
        centersBuffer.SetData(centersData);
    }
    
    void CalculateForcesGPU()
    {
        int width = idRenderPass.IDTexture.width;
        int height = idRenderPass.IDTexture.height;
        
        // Устанавливаем параметры
        forceCompute.SetInt("_Width", width);
        forceCompute.SetInt("_Height", height);
        forceCompute.SetInt("_MaxObjects", maxObjects);
        forceCompute.SetFloat("_ForceMultiplier", forceMultiplier);
        forceCompute.SetFloat("_PressureMultiplier", pressureMultiplier);
        
        // Текстуры
        forceCompute.SetTexture(calculateKernel, "_IDTexture", idRenderPass.IDTexture);
        forceCompute.SetTexture(calculateKernel, "_GasTexture", gasTexture);
        forceCompute.SetTexture(calculateKernel, "_ParticleTexture", particleTexture);
        
        // Буферы
        forceCompute.SetBuffer(calculateKernel, "_ForceBufferInt", forceBufferInt);
        forceCompute.SetBuffer(calculateKernel, "_ObjectCenters", centersBuffer);
        
        // Dispatch: один поток на пиксель
        int groupsX = Mathf.CeilToInt(width / 8.0f);
        int groupsY = Mathf.CeilToInt(height / 8.0f);
        forceCompute.Dispatch(calculateKernel, groupsX, groupsY, 1);
        
        // Финализация: конвертируем int → float
        forceCompute.SetBuffer(finalizeKernel, "_ForceBufferInt", forceBufferInt);
        forceCompute.SetBuffer(finalizeKernel, "_ForceBuffer", forceBuffer);
        forceCompute.Dispatch(finalizeKernel, Mathf.CeilToInt(maxObjects / 64.0f), 1, 1);
    }
    
    void RequestForceData()
    {
        // Асинхронное чтение
        AsyncGPUReadback.Request(forceBuffer, OnForceDataReady);
    }
    
    private bool forceDataReady = false;
    
    void OnForceDataReady(AsyncGPUReadbackRequest request)
    {
        if (request.hasError)
        {
            Debug.LogError("Force readback failed!");
            return;
        }
        
        request.GetData<Vector4>().CopyTo(forceData);
        forceDataReady = true;
    }
    
    void FixedUpdate()
    {
        if (!forceDataReady) return;
        
        ApplyForces();
        forceDataReady = false;
    }
    
    void ApplyForces()
    {
        foreach (var body in bodies)
        {
            if (body == null) continue;
            
            int id = idRenderPass.GetIDByBody(body);
            if (id <= 0 || id >= maxObjects) continue;
            
            Vector4 forceInfo = forceData[id];
            
            if (forceInfo.w < 1) continue;  // Нет данных
            
            // Применяем линейную силу
            Vector2 force = new Vector2(forceInfo.x, forceInfo.y);
            body.AddForce(force, ForceMode2D.Force);
            
            // Применяем момент (вращение)
            float torque = forceInfo.z * torqueMultiplier;
            body.AddTorque(torque, ForceMode2D.Force);
        }
    }
    
    void OnDestroy()
    {
        forceBuffer?.Release();
        forceBufferInt?.Release();
        centersBuffer?.Release();
    }
    
    // Публичный метод для добавления новых объектов
    public void AddBody(Rigidbody2D body)
    {
        if (!bodies.Contains(body))
        {
            bodies.Add(body);
            idRenderPass.RegisterBody(body);
        }
    }
}
```

---

## Альтернатива: Используем CommandBuffer и SRP

Для URP можно использовать `ScriptableRenderPass`:

```csharp
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class IDRenderFeature : ScriptableRendererFeature
{
    class IDRenderPass : ScriptableRenderPass
    {
        private RenderTexture idTexture;
        private Material idMaterial;
        private List<(Renderer, int)> objects = new List<(Renderer, int)>();
        
        public void Setup(RenderTexture target, List<(Renderer, int)> objs)
        {
            idTexture = target;
            objects = objs;
        }
        
        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            CommandBuffer cmd = CommandBufferPool.Get("ID Render");
            
            cmd.SetRenderTarget(idTexture);
            cmd.ClearRenderTarget(true, true, Color.black);
            
            foreach (var (renderer, id) in objects)
            {
                // Создаём MaterialPropertyBlock для ID
                MaterialPropertyBlock props = new MaterialPropertyBlock();
                props.SetFloat("_ObjectID", id);
                
                cmd.DrawRenderer(renderer, idMaterial, 0, 0);
            }
            
            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }
    }
    
    // ... настройка feature ...
}
```

---

## Преимущества этого подхода

| Аспект | StructuredBuffer | ID Render + Compute |
|--------|------------------|---------------------|
| Формы объектов | Только круги/прямоугольники | Любые меши! |
| Вычисления | Частично CPU | Полностью GPU |
| Масштабируемость | До ~100 объектов | Тысячи объектов |
| Вращение (torque) | Сложно | Легко |
| Сложные границы | Нет | Да (gradient от ID) |

---

## Итог

Подход с ID Render Pass:
1. ✅ Рендерим каждый объект своим цветом-ID
2. ✅ Compute Shader читает ID и газ, вычисляет силы атомарно
3. ✅ Результаты читаем через AsyncGPUReadback
4. ✅ Применяем силы и моменты к Rigidbody

Это **правильный** подход для production-качества!

---

# ПОДХОД 1: Простой (StructuredBuffer)

## Два направления взаимодействия

```
┌─────────────────┐        ┌─────────────────┐
│    Rigidbody    │ ←────→ │    Simulation   │
│  (Unity Physics)│        │  (GPU Texture)  │
└─────────────────┘        └─────────────────┘
         │                          │
         ▼                          ▼
   1. Блокирует частицы      2. Толкает Rigidbody
   (рисует препятствие)      (читаем давление/плотность)
```

---

## Направление 1: Rigidbody → Симуляция

Rigidbody "рисует" себя как препятствие в текстуре симуляции.

### Идея
1. Получаем позицию и форму Rigidbody
2. Преобразуем в координаты текстуры
3. Записываем как SOLID/OBSTACLE в симуляцию

### Compute Shader: Рисование препятствий

```hlsl
#pragma kernel DrawObstacles

RWTexture2D<float4> _ObstaclesTex;  // Текстура препятствий
StructuredBuffer<float4> _Obstacles;  // x, y, radius, type
int _ObstacleCount;
int _Width;
int _Height;

// Преобразование мировых координат в текстурные
float2 WorldToTex(float2 worldPos, float2 simMin, float2 simMax)
{
    return (worldPos - simMin) / (simMax - simMin) * float2(_Width, _Height);
}

[numthreads(8, 8, 1)]
void DrawObstacles(uint3 id : SV_DispatchThreadID)
{
    int2 pos = int2(id.xy);
    if (pos.x >= _Width || pos.y >= _Height) return;
    
    float4 result = float4(0, 0, 0, 0);  // Нет препятствия
    
    for (int i = 0; i < _ObstacleCount; i++)
    {
        float4 obs = _Obstacles[i];
        float2 obsCenter = obs.xy;  // Уже в текстурных координатах
        float radius = obs.z;
        float type = obs.w;  // 1 = круг, 2 = прямоугольник
        
        float dist = length(float2(pos) - obsCenter);
        
        if (dist < radius)
        {
            result = float4(1, 0, 0, 1);  // Solid obstacle
        }
    }
    
    _ObstaclesTex[pos] = result;
}
```

### C# Controller: Синхронизация Rigidbody → Текстура

```csharp
using UnityEngine;
using System.Collections.Generic;

public class RigidbodyToSimulation : MonoBehaviour
{
    [Header("Simulation")]
    public ComputeShader obstacleCompute;
    public int textureSize = 256;
    
    [Header("World Bounds")]
    public Vector2 simWorldMin = new Vector2(-5, -5);
    public Vector2 simWorldMax = new Vector2(5, 5);
    
    [Header("Tracked Objects")]
    public List<Rigidbody2D> trackedBodies = new List<Rigidbody2D>();
    
    private RenderTexture obstacleTexture;
    private ComputeBuffer obstacleBuffer;
    private int drawKernel;
    
    // Данные препятствия: x, y (текстурные), radius, type
    private Vector4[] obstacleData;
    
    void Start()
    {
        // Создаём текстуру препятствий
        obstacleTexture = new RenderTexture(textureSize, textureSize, 0, RenderTextureFormat.ARGBFloat);
        obstacleTexture.enableRandomWrite = true;
        obstacleTexture.Create();
        
        // Буфер для данных препятствий
        obstacleData = new Vector4[100];  // Максимум 100 объектов
        obstacleBuffer = new ComputeBuffer(100, sizeof(float) * 4);
        
        drawKernel = obstacleCompute.FindKernel("DrawObstacles");
        
        obstacleCompute.SetInt("_Width", textureSize);
        obstacleCompute.SetInt("_Height", textureSize);
    }
    
    void FixedUpdate()
    {
        UpdateObstacleData();
        DrawObstaclesToTexture();
    }
    
    void UpdateObstacleData()
    {
        for (int i = 0; i < trackedBodies.Count && i < obstacleData.Length; i++)
        {
            Rigidbody2D rb = trackedBodies[i];
            if (rb == null) continue;
            
            // Мировая позиция → текстурная позиция
            Vector2 worldPos = rb.position;
            Vector2 texPos = WorldToTexturePos(worldPos);
            
            // Радиус в текстурных единицах
            float worldRadius = GetRadius(rb);
            float texRadius = WorldToTextureScale(worldRadius);
            
            obstacleData[i] = new Vector4(texPos.x, texPos.y, texRadius, 1);
        }
    }
    
    Vector2 WorldToTexturePos(Vector2 worldPos)
    {
        float x = (worldPos.x - simWorldMin.x) / (simWorldMax.x - simWorldMin.x) * textureSize;
        float y = (worldPos.y - simWorldMin.y) / (simWorldMax.y - simWorldMin.y) * textureSize;
        return new Vector2(x, y);
    }
    
    float WorldToTextureScale(float worldSize)
    {
        float worldWidth = simWorldMax.x - simWorldMin.x;
        return worldSize / worldWidth * textureSize;
    }
    
    float GetRadius(Rigidbody2D rb)
    {
        CircleCollider2D circle = rb.GetComponent<CircleCollider2D>();
        if (circle != null)
            return circle.radius * rb.transform.localScale.x;
        
        BoxCollider2D box = rb.GetComponent<BoxCollider2D>();
        if (box != null)
            return Mathf.Max(box.size.x, box.size.y) * 0.5f * rb.transform.localScale.x;
        
        return 0.5f;  // Default
    }
    
    void DrawObstaclesToTexture()
    {
        // Очищаем текстуру
        RenderTexture.active = obstacleTexture;
        GL.Clear(true, true, Color.clear);
        RenderTexture.active = null;
        
        // Загружаем данные
        obstacleBuffer.SetData(obstacleData);
        
        obstacleCompute.SetTexture(drawKernel, "_ObstaclesTex", obstacleTexture);
        obstacleCompute.SetBuffer(drawKernel, "_Obstacles", obstacleBuffer);
        obstacleCompute.SetInt("_ObstacleCount", Mathf.Min(trackedBodies.Count, obstacleData.Length));
        
        int groups = Mathf.CeilToInt(textureSize / 8.0f);
        obstacleCompute.Dispatch(drawKernel, groups, groups, 1);
    }
    
    // Предоставляем текстуру для основной симуляции
    public RenderTexture GetObstacleTexture()
    {
        return obstacleTexture;
    }
    
    void OnDestroy()
    {
        if (obstacleTexture != null) obstacleTexture.Release();
        if (obstacleBuffer != null) obstacleBuffer.Release();
    }
}
```

### Интеграция с симуляцией частиц

В основном Compute Shader симуляции:

```hlsl
Texture2D<float4> _ObstaclesTex;  // Добавляем

bool IsObstacle(int2 pos)
{
    return _ObstaclesTex[pos].r > 0.5;
}

[numthreads(8, 8, 1)]
void SimulateSand(uint3 id : SV_DispatchThreadID)
{
    int2 pos = int2(id.xy);
    
    // Частица не может находиться внутри препятствия
    if (IsObstacle(pos))
    {
        _Output[pos] = float4(0, 0, 0, 0);  // Пусто
        return;
    }
    
    // Частица не может упасть в препятствие
    int2 below = pos + int2(0, -1);
    if (IsObstacle(below))
    {
        // Остаёмся на месте
        _Output[pos] = _Input[pos];
        return;
    }
    
    // ... обычная логика падения
}
```

---

## Направление 2: Симуляция → Rigidbody

Частицы/газ толкают Rigidbody. Нужно читать данные из GPU!

### Проблема
GPU → CPU transfer медленный. Решения:
1. **AsyncGPUReadback** — асинхронное чтение (с задержкой 1-2 кадра)
2. **Локальное сэмплирование** — читаем только область вокруг Rigidbody

### Метод 1: AsyncGPUReadback (рекомендуется)

```csharp
using UnityEngine;
using UnityEngine.Rendering;

public class SimulationToRigidbody : MonoBehaviour
{
    [Header("References")]
    public Rigidbody2D targetBody;
    public RenderTexture gasTexture;  // Газовая текстура из симуляции
    
    [Header("Settings")]
    public int textureSize = 256;
    public Vector2 simWorldMin = new Vector2(-5, -5);
    public Vector2 simWorldMax = new Vector2(5, 5);
    public float forceMultiplier = 10f;
    public int sampleRadius = 5;  // Радиус сэмплирования в пикселях
    
    private Texture2D cpuTexture;
    private bool dataReady = false;
    private Color[] pixelData;
    
    void Start()
    {
        cpuTexture = new Texture2D(textureSize, textureSize, TextureFormat.RGBAFloat, false);
        pixelData = new Color[textureSize * textureSize];
    }
    
    void Update()
    {
        // Запрашиваем асинхронное чтение
        AsyncGPUReadback.Request(gasTexture, 0, TextureFormat.RGBAFloat, OnReadbackComplete);
    }
    
    void OnReadbackComplete(AsyncGPUReadbackRequest request)
    {
        if (request.hasError)
        {
            Debug.LogError("GPU readback error!");
            return;
        }
        
        // Копируем данные
        var data = request.GetData<Color>();
        data.CopyTo(pixelData);
        dataReady = true;
    }
    
    void FixedUpdate()
    {
        if (!dataReady || targetBody == null) return;
        
        // Вычисляем силу от газа
        Vector2 force = CalculateGasForce();
        targetBody.AddForce(force, ForceMode2D.Force);
    }
    
    Vector2 CalculateGasForce()
    {
        Vector2 texPos = WorldToTexturePos(targetBody.position);
        int cx = Mathf.RoundToInt(texPos.x);
        int cy = Mathf.RoundToInt(texPos.y);
        
        Vector2 totalForce = Vector2.zero;
        int samples = 0;
        
        // Сэмплируем область вокруг объекта
        for (int dy = -sampleRadius; dy <= sampleRadius; dy++)
        {
            for (int dx = -sampleRadius; dx <= sampleRadius; dx++)
            {
                int px = cx + dx;
                int py = cy + dy;
                
                if (px < 0 || px >= textureSize || py < 0 || py >= textureSize)
                    continue;
                
                Color pixel = pixelData[py * textureSize + px];
                
                // pixel.r = плотность газа
                // pixel.g, pixel.b = скорость (закодирована 0-1)
                float density = pixel.r;
                Vector2 velocity = new Vector2(pixel.g * 2f - 1f, pixel.b * 2f - 1f);
                
                // Сила пропорциональна плотности и скорости
                totalForce += velocity * density;
                samples++;
            }
        }
        
        if (samples > 0)
            totalForce /= samples;
        
        return totalForce * forceMultiplier;
    }
    
    Vector2 WorldToTexturePos(Vector2 worldPos)
    {
        float x = (worldPos.x - simWorldMin.x) / (simWorldMax.x - simWorldMin.x) * textureSize;
        float y = (worldPos.y - simWorldMin.y) / (simWorldMax.y - simWorldMin.y) * textureSize;
        return new Vector2(x, y);
    }
}
```

### Метод 2: Локальное чтение через RenderTexture.ReadPixels

Более простой, но синхронный (может тормозить):

```csharp
public class LocalGasReader : MonoBehaviour
{
    public Rigidbody2D targetBody;
    public RenderTexture gasTexture;
    public int sampleSize = 16;  // Читаем маленькую область
    
    private Texture2D localSample;
    
    void Start()
    {
        localSample = new Texture2D(sampleSize, sampleSize, TextureFormat.RGBAFloat, false);
    }
    
    void FixedUpdate()
    {
        // Определяем область для чтения
        Vector2 texPos = WorldToTexturePos(targetBody.position);
        int x = Mathf.Clamp(Mathf.RoundToInt(texPos.x) - sampleSize/2, 0, gasTexture.width - sampleSize);
        int y = Mathf.Clamp(Mathf.RoundToInt(texPos.y) - sampleSize/2, 0, gasTexture.height - sampleSize);
        
        // Читаем только нужную область
        RenderTexture.active = gasTexture;
        localSample.ReadPixels(new Rect(x, y, sampleSize, sampleSize), 0, 0);
        localSample.Apply();
        RenderTexture.active = null;
        
        // Вычисляем силу
        Vector2 force = Vector2.zero;
        Color[] pixels = localSample.GetPixels();
        
        foreach (Color p in pixels)
        {
            float density = p.r;
            Vector2 velocity = new Vector2(p.g * 2f - 1f, p.b * 2f - 1f);
            force += velocity * density;
        }
        
        force /= pixels.Length;
        targetBody.AddForce(force * 10f, ForceMode2D.Force);
    }
    
    Vector2 WorldToTexturePos(Vector2 worldPos) { /* ... */ }
}
```

---

## Направление 3: Двухстороннее взаимодействие

### Полный контроллер

```csharp
using UnityEngine;
using UnityEngine.Rendering;
using System.Collections.Generic;

public class BidirectionalPhysics : MonoBehaviour
{
    [Header("Simulation")]
    public ComputeShader simulationCompute;
    public int textureSize = 256;
    
    [Header("World Mapping")]
    public Vector2 worldMin = new Vector2(-5, -5);
    public Vector2 worldMax = new Vector2(5, 5);
    
    [Header("Physics")]
    public float forceMultiplier = 10f;
    public List<Rigidbody2D> physicsBodies = new List<Rigidbody2D>();
    
    // Текстуры
    private RenderTexture[] gasBuffers = new RenderTexture[2];
    private RenderTexture obstacleTexture;
    private int currentBuffer = 0;
    
    // Буферы
    private ComputeBuffer obstacleBuffer;
    private Vector4[] obstacleData;
    
    // Async readback
    private Color[] gasData;
    private bool gasDataReady = false;
    
    void Start()
    {
        InitializeTextures();
        InitializeBuffers();
    }
    
    void InitializeTextures()
    {
        for (int i = 0; i < 2; i++)
        {
            gasBuffers[i] = CreateRT();
        }
        obstacleTexture = CreateRT();
    }
    
    RenderTexture CreateRT()
    {
        RenderTexture rt = new RenderTexture(textureSize, textureSize, 0, RenderTextureFormat.ARGBFloat);
        rt.enableRandomWrite = true;
        rt.Create();
        return rt;
    }
    
    void InitializeBuffers()
    {
        obstacleData = new Vector4[100];
        obstacleBuffer = new ComputeBuffer(100, sizeof(float) * 4);
        gasData = new Color[textureSize * textureSize];
    }
    
    void Update()
    {
        // 1. Rigidbody → Simulation: обновляем препятствия
        UpdateObstacles();
        
        // 2. Симуляция газа
        SimulateGas();
        
        // 3. Запрашиваем данные для физики
        RequestGasData();
    }
    
    void FixedUpdate()
    {
        // 4. Simulation → Rigidbody: применяем силы
        if (gasDataReady)
        {
            ApplyGasForces();
        }
    }
    
    void UpdateObstacles()
    {
        // Очищаем
        RenderTexture.active = obstacleTexture;
        GL.Clear(true, true, Color.clear);
        RenderTexture.active = null;
        
        // Заполняем данные
        for (int i = 0; i < physicsBodies.Count && i < obstacleData.Length; i++)
        {
            var rb = physicsBodies[i];
            if (rb == null) continue;
            
            Vector2 texPos = WorldToTex(rb.position);
            float texRadius = WorldToTexScale(GetColliderRadius(rb));
            
            obstacleData[i] = new Vector4(texPos.x, texPos.y, texRadius, 1);
        }
        
        // Рисуем в текстуру
        obstacleBuffer.SetData(obstacleData);
        
        int kernel = simulationCompute.FindKernel("DrawObstacles");
        simulationCompute.SetTexture(kernel, "_ObstaclesTex", obstacleTexture);
        simulationCompute.SetBuffer(kernel, "_Obstacles", obstacleBuffer);
        simulationCompute.SetInt("_ObstacleCount", physicsBodies.Count);
        
        int groups = Mathf.CeilToInt(textureSize / 8.0f);
        simulationCompute.Dispatch(kernel, groups, groups, 1);
    }
    
    void SimulateGas()
    {
        int read = currentBuffer;
        int write = 1 - currentBuffer;
        
        int kernel = simulationCompute.FindKernel("SimulateGas");
        simulationCompute.SetTexture(kernel, "_GasInput", gasBuffers[read]);
        simulationCompute.SetTexture(kernel, "_GasOutput", gasBuffers[write]);
        simulationCompute.SetTexture(kernel, "_ObstaclesTex", obstacleTexture);
        simulationCompute.SetFloat("_DeltaTime", Time.deltaTime);
        
        int groups = Mathf.CeilToInt(textureSize / 8.0f);
        simulationCompute.Dispatch(kernel, groups, groups, 1);
        
        currentBuffer = write;
    }
    
    void RequestGasData()
    {
        AsyncGPUReadback.Request(gasBuffers[currentBuffer], 0, TextureFormat.RGBAFloat, 
            (AsyncGPUReadbackRequest request) =>
            {
                if (!request.hasError)
                {
                    request.GetData<Color>().CopyTo(gasData);
                    gasDataReady = true;
                }
            });
    }
    
    void ApplyGasForces()
    {
        foreach (var rb in physicsBodies)
        {
            if (rb == null) continue;
            
            Vector2 force = SampleGasForce(rb.position, GetColliderRadius(rb));
            rb.AddForce(force * forceMultiplier, ForceMode2D.Force);
        }
    }
    
    Vector2 SampleGasForce(Vector2 worldPos, float radius)
    {
        Vector2 texPos = WorldToTex(worldPos);
        int texRadius = Mathf.RoundToInt(WorldToTexScale(radius));
        int cx = Mathf.RoundToInt(texPos.x);
        int cy = Mathf.RoundToInt(texPos.y);
        
        Vector2 force = Vector2.zero;
        int samples = 0;
        
        for (int dy = -texRadius; dy <= texRadius; dy++)
        {
            for (int dx = -texRadius; dx <= texRadius; dx++)
            {
                if (dx * dx + dy * dy > texRadius * texRadius) continue;
                
                int px = cx + dx;
                int py = cy + dy;
                
                if (px < 0 || px >= textureSize || py < 0 || py >= textureSize)
                    continue;
                
                Color gas = gasData[py * textureSize + px];
                
                float density = gas.r;
                Vector2 velocity = new Vector2(gas.g * 2f - 1f, gas.b * 2f - 1f);
                
                // Направление от центра объекта
                Vector2 dir = new Vector2(dx, dy).normalized;
                
                // Сила давления + сила потока
                force += dir * density * 0.5f;  // Давление
                force += velocity * density;     // Поток
                
                samples++;
            }
        }
        
        if (samples > 0)
            force /= samples;
        
        return force;
    }
    
    // Вспомогательные функции
    Vector2 WorldToTex(Vector2 worldPos)
    {
        float x = (worldPos.x - worldMin.x) / (worldMax.x - worldMin.x) * textureSize;
        float y = (worldPos.y - worldMin.y) / (worldMax.y - worldMin.y) * textureSize;
        return new Vector2(x, y);
    }
    
    float WorldToTexScale(float worldSize)
    {
        return worldSize / (worldMax.x - worldMin.x) * textureSize;
    }
    
    float GetColliderRadius(Rigidbody2D rb)
    {
        var circle = rb.GetComponent<CircleCollider2D>();
        if (circle != null) return circle.radius * rb.transform.localScale.x;
        
        var box = rb.GetComponent<BoxCollider2D>();
        if (box != null) return Mathf.Max(box.size.x, box.size.y) * 0.5f;
        
        return 0.5f;
    }
    
    void OnDestroy()
    {
        foreach (var rt in gasBuffers) if (rt != null) rt.Release();
        if (obstacleTexture != null) obstacleTexture.Release();
        if (obstacleBuffer != null) obstacleBuffer.Release();
    }
}
```

---

## Визуализация препятствий

Добавь в визуализатор:

```hlsl
// В fragment shader
sampler2D _ObstacleTex;
fixed4 _ObstacleColor;

fixed4 frag(v2f i) : SV_Target
{
    // ... существующий код ...
    
    // Препятствия поверх всего
    float obstacle = tex2D(_ObstacleTex, i.uv).r;
    finalColor = lerp(finalColor, _ObstacleColor, obstacle * 0.8);
    
    return finalColor;
}
```

---

## Оптимизация

### 1. Пропуск кадров
```csharp
private int frameSkip = 2;
private int frameCounter = 0;

void Update()
{
    frameCounter++;
    if (frameCounter % frameSkip != 0) return;
    
    // Обновляем препятствия
}
```

### 2. Spatial Hashing
Для большого количества объектов используй spatial hash вместо полного перебора.

### 3. Уменьшенное разрешение для физики
```csharp
// Основная симуляция: 512x512
// Текстура для физики: 128x128 (Blit с уменьшением)
Graphics.Blit(gasBuffers[currentBuffer], lowResGas);
AsyncGPUReadback.Request(lowResGas, ...);
```

---

## Результат

После этого урока ты сможешь:
- ✅ Делать Rigidbody препятствиями для частиц
- ✅ Применять силы газа/частиц к Rigidbody
- ✅ Создавать двустороннее взаимодействие
- ✅ Оптимизировать GPU→CPU передачу данных

**Реализуй базовый вариант и напиши "Готово" или опиши проблему!**
