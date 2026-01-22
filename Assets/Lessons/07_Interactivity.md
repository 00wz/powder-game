# Этап 6: Интерактивность и UI

## Что мы реализуем

1. **Mouse Input** — рисование мышью
2. **Screen to Texture coordinates** — преобразование координат
3. **GPU Spawning** — спавн через Compute Shader (эффективно!)
4. **Tool Selection** — выбор инструмента (песок, газ, стирание)
5. **Simple UI** — кнопки для инструментов

---

## 1. Преобразование координат

### Проблема
Мышь даёт **экранные координаты** (пиксели), а нам нужны **координаты текстуры** (0-255).

### Решение: Raycast на Quad

```csharp
// Преобразование позиции мыши в координаты текстуры
Vector2Int GetTextureCoordinate()
{
    Ray ray = Camera.main.ScreenPointToRay(Input.mousePosition);
    RaycastHit hit;
    
    if (Physics.Raycast(ray, out hit))
    {
        // hit.textureCoord даёт UV координаты (0-1)
        Vector2 uv = hit.textureCoord;
        
        // Преобразуем в координаты текстуры
        int x = Mathf.FloorToInt(uv.x * textureSize);
        int y = Mathf.FloorToInt(uv.y * textureSize);
        
        return new Vector2Int(x, y);
    }
    
    return new Vector2Int(-1, -1);  // Нет попадания
}
```

**Важно:** На Quad должен быть **Mesh Collider**!

---

## 2. GPU Spawning — Спавн через Compute Shader

### Почему GPU?
- ❌ `ReadPixels()` + `SetPixel()` — очень медленно (CPU ↔ GPU transfer)
- ✅ Compute Shader — всё остаётся на GPU, мгновенно

### Новый kernel для спавна

Добавь в `GasSimulation.compute`:

```hlsl
#pragma kernel SpawnParticle
#pragma kernel SpawnGasAtPoint
#pragma kernel EraseAtPoint

// Параметры кисти
int2 _BrushPosition;
float _BrushRadius;
float _BrushStrength;
int _BrushType;  // 0=sand, 1=gas, 2=erase

// Спавн частиц (песок)
[numthreads(8, 8, 1)]
void SpawnParticle(uint3 id : SV_DispatchThreadID)
{
    int2 pos = int2(id.xy);
    if (!InBounds(pos)) return;
    
    float dist = length(float2(pos) - float2(_BrushPosition));
    
    if (dist < _BrushRadius)
    {
        // Плавный спад от центра (опционально)
        float falloff = 1.0 - (dist / _BrushRadius);
        
        // Записываем частицу
        // Используем _ParticleOutput из основной симуляции
        float4 current = _ParticleOutput[pos];
        
        if (_BrushType == 0)  // Sand
        {
            current.r = 1.0;  // Есть частица
        }
        else if (_BrushType == 2)  // Erase
        {
            current.r = 0.0;  // Удаляем
        }
        
        _ParticleOutput[pos] = current;
    }
}

// Спавн газа
[numthreads(8, 8, 1)]
void SpawnGasAtPoint(uint3 id : SV_DispatchThreadID)
{
    int2 pos = int2(id.xy);
    if (!InBounds(pos)) return;
    
    float dist = length(float2(pos) - float2(_BrushPosition));
    
    if (dist < _BrushRadius)
    {
        float falloff = 1.0 - (dist / _BrushRadius);
        falloff *= falloff;  // Квадратичный спад
        
        float4 gas = _GasOutput[pos];
        
        if (_BrushType == 1)  // Gas
        {
            gas.r += _BrushStrength * falloff * _DeltaTime;
            gas.r = saturate(gas.r);
            
            // Добавляем начальную скорость вверх
            float2 vel = gas.gb * 2.0 - 1.0;
            vel.y += 0.5 * falloff * _DeltaTime;
            gas.gb = saturate(vel * 0.5 + 0.5);
        }
        else if (_BrushType == 2)  // Erase
        {
            gas.r = 0;
            gas.gb = float2(0.5, 0.5);  // Нулевая скорость
        }
        
        _GasOutput[pos] = gas;
    }
}

// Стирание всего
[numthreads(8, 8, 1)]
void EraseAtPoint(uint3 id : SV_DispatchThreadID)
{
    int2 pos = int2(id.xy);
    if (!InBounds(pos)) return;
    
    float dist = length(float2(pos) - float2(_BrushPosition));
    
    if (dist < _BrushRadius)
    {
        _ParticleOutput[pos] = float4(0, 0, 0, 0);
        _GasOutput[pos] = float4(0, 0.5, 0.5, 0);
    }
}
```

---

## 3. Обновлённый контроллер

### Создай: `Assets/Scripts/InteractiveSimController.cs`

```csharp
using UnityEngine;

public class InteractiveSimController : MonoBehaviour
{
    [Header("Compute Shaders")]
    public ComputeShader gasCompute;
    public ComputeShader sandCompute;
    
    [Header("Settings")]
    public int textureSize = 256;
    
    [Header("Gas Parameters")]
    [Range(0, 50)] public float advectionSpeed = 20f;
    [Range(0, 0.5f)] public float diffusion = 0.1f;
    [Range(0, 1f)] public float dissipation = 0.02f;
    [Range(-1, 1)] public float gravity = 0.1f;
    [Range(-5, 5)] public float buoyancy = 1f;
    
    [Header("Brush")]
    [Range(1, 30)] public float brushRadius = 8f;
    [Range(0.1f, 10f)] public float brushStrength = 3f;
    public BrushType currentBrush = BrushType.Sand;
    
    [Header("Visualization")]
    public Material displayMaterial;
    public MeshCollider targetCollider;  // Для raycasting
    
    public enum BrushType { Sand, Gas, Erase }
    
    // Текстуры
    private RenderTexture[] gasBuffers = new RenderTexture[2];
    private RenderTexture[] particleBuffers = new RenderTexture[2];
    private int currentGasBuffer = 0;
    private int currentParticleBuffer = 0;
    
    // Kernels
    private int advectKernel, diffuseKernel, forcesKernel, sourceKernel;
    private int sandSimulateKernel, sandInitKernel;
    private int spawnParticleKernel, spawnGasKernel, eraseKernel;
    
    private int threadGroups;
    
    void Start()
    {
        CreateTextures();
        SetupKernels();
        InitializeSimulation();
        threadGroups = Mathf.CeilToInt(textureSize / 8.0f);
    }
    
    void CreateTextures()
    {
        for (int i = 0; i < 2; i++)
        {
            gasBuffers[i] = CreateRT();
            particleBuffers[i] = CreateRT();
        }
    }
    
    RenderTexture CreateRT()
    {
        RenderTexture rt = new RenderTexture(textureSize, textureSize, 0, RenderTextureFormat.ARGBFloat);
        rt.enableRandomWrite = true;
        rt.filterMode = FilterMode.Point;
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
        
        // Brush kernels (добавь их в GasSimulation.compute!)
        spawnParticleKernel = gasCompute.FindKernel("SpawnParticle");
        spawnGasKernel = gasCompute.FindKernel("SpawnGasAtPoint");
        eraseKernel = gasCompute.FindKernel("EraseAtPoint");
        
        // Sand kernels
        sandSimulateKernel = sandCompute.FindKernel("SimulateSand");
        sandInitKernel = sandCompute.FindKernel("InitializeTexture");
        
        // Размеры
        gasCompute.SetInt("_Width", textureSize);
        gasCompute.SetInt("_Height", textureSize);
        sandCompute.SetInt("_Width", textureSize);
        sandCompute.SetInt("_Height", textureSize);
    }
    
    void InitializeSimulation()
    {
        for (int i = 0; i < 2; i++)
        {
            sandCompute.SetTexture(sandInitKernel, "_Output", gasBuffers[i]);
            sandCompute.Dispatch(sandInitKernel, threadGroups, threadGroups, 1);
            
            sandCompute.SetTexture(sandInitKernel, "_Output", particleBuffers[i]);
            sandCompute.Dispatch(sandInitKernel, threadGroups, threadGroups, 1);
        }
    }
    
    void Update()
    {
        HandleInput();
        
        float dt = Mathf.Min(Time.deltaTime, 0.033f);
        
        SimulateSand();
        SimulateGas(dt);
        UpdateDisplay();
    }
    
    // ===== INPUT HANDLING =====
    
    void HandleInput()
    {
        // Выбор инструмента клавишами
        if (Input.GetKeyDown(KeyCode.Alpha1)) currentBrush = BrushType.Sand;
        if (Input.GetKeyDown(KeyCode.Alpha2)) currentBrush = BrushType.Gas;
        if (Input.GetKeyDown(KeyCode.Alpha3)) currentBrush = BrushType.Erase;
        
        // Изменение размера кисти колёсиком
        float scroll = Input.GetAxis("Mouse ScrollWheel");
        brushRadius = Mathf.Clamp(brushRadius + scroll * 5f, 1f, 30f);
        
        // Рисование
        if (Input.GetMouseButton(0))
        {
            Vector2Int texCoord = GetTextureCoordinate();
            if (texCoord.x >= 0)
            {
                DrawAtPosition(texCoord);
            }
        }
        
        // Очистка всего
        if (Input.GetKeyDown(KeyCode.C))
        {
            InitializeSimulation();
        }
    }
    
    Vector2Int GetTextureCoordinate()
    {
        if (targetCollider == null)
        {
            Debug.LogWarning("Assign MeshCollider!");
            return new Vector2Int(-1, -1);
        }
        
        Ray ray = Camera.main.ScreenPointToRay(Input.mousePosition);
        RaycastHit hit;
        
        if (targetCollider.Raycast(ray, out hit, 100f))
        {
            Vector2 uv = hit.textureCoord;
            int x = Mathf.FloorToInt(uv.x * textureSize);
            int y = Mathf.FloorToInt(uv.y * textureSize);
            return new Vector2Int(
                Mathf.Clamp(x, 0, textureSize - 1),
                Mathf.Clamp(y, 0, textureSize - 1)
            );
        }
        
        return new Vector2Int(-1, -1);
    }
    
    void DrawAtPosition(Vector2Int pos)
    {
        // Устанавливаем параметры кисти
        gasCompute.SetInts("_BrushPosition", pos.x, pos.y);
        gasCompute.SetFloat("_BrushRadius", brushRadius);
        gasCompute.SetFloat("_BrushStrength", brushStrength);
        gasCompute.SetInt("_BrushType", (int)currentBrush);
        gasCompute.SetFloat("_DeltaTime", Time.deltaTime);
        
        switch (currentBrush)
        {
            case BrushType.Sand:
                // Спавним частицы напрямую в текущий буфер
                gasCompute.SetTexture(spawnParticleKernel, "_ParticleOutput", particleBuffers[currentParticleBuffer]);
                gasCompute.Dispatch(spawnParticleKernel, threadGroups, threadGroups, 1);
                break;
                
            case BrushType.Gas:
                gasCompute.SetTexture(spawnGasKernel, "_GasOutput", gasBuffers[currentGasBuffer]);
                gasCompute.Dispatch(spawnGasKernel, threadGroups, threadGroups, 1);
                break;
                
            case BrushType.Erase:
                gasCompute.SetTexture(eraseKernel, "_ParticleOutput", particleBuffers[currentParticleBuffer]);
                gasCompute.SetTexture(eraseKernel, "_GasOutput", gasBuffers[currentGasBuffer]);
                gasCompute.Dispatch(eraseKernel, threadGroups, threadGroups, 1);
                break;
        }
    }
    
    // ===== SIMULATION =====
    
    void SimulateSand()
    {
        int read = currentParticleBuffer;
        int write = 1 - currentParticleBuffer;
        
        sandCompute.SetInt("_Frame", Time.frameCount);
        sandCompute.SetTexture(sandSimulateKernel, "_Input", particleBuffers[read]);
        sandCompute.SetTexture(sandSimulateKernel, "_Output", particleBuffers[write]);
        sandCompute.Dispatch(sandSimulateKernel, threadGroups, threadGroups, 1);
        
        currentParticleBuffer = write;
    }
    
    void SimulateGas(float dt)
    {
        gasCompute.SetFloat("_DeltaTime", dt);
        gasCompute.SetFloat("_AdvectionSpeed", advectionSpeed);
        gasCompute.SetFloat("_Diffusion", diffusion);
        gasCompute.SetFloat("_Dissipation", dissipation);
        gasCompute.SetFloat("_Gravity", gravity);
        gasCompute.SetFloat("_Buoyancy", buoyancy);
        
        gasCompute.SetTexture(forcesKernel, "_ParticlesTex", particleBuffers[currentParticleBuffer]);
        
        int read = currentGasBuffer;
        int write = 1 - currentGasBuffer;
        
        // Advection
        gasCompute.SetTexture(advectKernel, "_GasInput", gasBuffers[read]);
        gasCompute.SetTexture(advectKernel, "_GasOutput", gasBuffers[write]);
        gasCompute.Dispatch(advectKernel, threadGroups, threadGroups, 1);
        Swap(ref read, ref write);
        
        // Diffusion
        for (int i = 0; i < 2; i++)
        {
            gasCompute.SetTexture(diffuseKernel, "_GasInput", gasBuffers[read]);
            gasCompute.SetTexture(diffuseKernel, "_GasOutput", gasBuffers[write]);
            gasCompute.Dispatch(diffuseKernel, threadGroups, threadGroups, 1);
            Swap(ref read, ref write);
        }
        
        // Forces
        gasCompute.SetTexture(forcesKernel, "_GasInput", gasBuffers[read]);
        gasCompute.SetTexture(forcesKernel, "_GasOutput", gasBuffers[write]);
        gasCompute.Dispatch(forcesKernel, threadGroups, threadGroups, 1);
        
        currentGasBuffer = write;
    }
    
    void Swap(ref int a, ref int b) { int t = a; a = b; b = t; }
    
    void UpdateDisplay()
    {
        if (displayMaterial != null)
        {
            displayMaterial.SetTexture("_GasTex", gasBuffers[currentGasBuffer]);
            displayMaterial.SetTexture("_ParticleTex", particleBuffers[currentParticleBuffer]);
        }
    }
    
    void OnDestroy()
    {
        foreach (var rt in gasBuffers) if (rt != null) rt.Release();
        foreach (var rt in particleBuffers) if (rt != null) rt.Release();
    }
    
    // ===== GUI =====
    
    void OnGUI()
    {
        GUILayout.BeginArea(new Rect(10, 10, 200, 300));
        GUILayout.BeginVertical("box");
        
        GUILayout.Label("Tools (1-3):");
        
        GUI.color = currentBrush == BrushType.Sand ? Color.yellow : Color.white;
        if (GUILayout.Button("1. Sand")) currentBrush = BrushType.Sand;
        
        GUI.color = currentBrush == BrushType.Gas ? Color.cyan : Color.white;
        if (GUILayout.Button("2. Gas")) currentBrush = BrushType.Gas;
        
        GUI.color = currentBrush == BrushType.Erase ? Color.red : Color.white;
        if (GUILayout.Button("3. Erase")) currentBrush = BrushType.Erase;
        
        GUI.color = Color.white;
        
        GUILayout.Space(10);
        GUILayout.Label($"Brush Size: {brushRadius:F1}");
        GUILayout.Label("(Mouse Wheel)");
        
        GUILayout.Space(10);
        if (GUILayout.Button("Clear All (C)"))
        {
            InitializeSimulation();
        }
        
        GUILayout.EndVertical();
        GUILayout.EndArea();
    }
}
```

---

## 4. Обновление GasSimulation.compute

Нужно добавить новые kernel'ы и переменные. Добавь в начало файла:

```hlsl
#pragma kernel SpawnParticle
#pragma kernel SpawnGasAtPoint  
#pragma kernel EraseAtPoint

// Дополнительные текстуры для спавна
RWTexture2D<float4> _ParticleOutput;

// Параметры кисти
int2 _BrushPosition;
float _BrushRadius;
float _BrushStrength;
int _BrushType;
```

И добавь сами kernel'ы (код выше в разделе "GPU Spawning").

---

## 5. Настройка сцены

1. **На Quad добавь MeshCollider**
   - Select Quad → Add Component → Mesh Collider
   
2. **Замени контроллер:**
   - Удали/отключи GasSimulationController
   - Добавь InteractiveSimController
   - Назначь:
     - Gas Compute, Sand Compute
     - Display Material
     - Target Collider = MeshCollider на Quad

3. **Камера должна смотреть на Quad!**

---

## Управление

| Клавиша | Действие |
|---------|----------|
| **1** | Выбрать песок |
| **2** | Выбрать газ |
| **3** | Выбрать ластик |
| **ЛКМ** | Рисовать |
| **Колёсико** | Размер кисти |
| **C** | Очистить всё |

---

## Дополнительно: Визуализация курсора

Можно добавить отображение кисти на экране:

```csharp
// В OnGUI() добавь:
void DrawBrushPreview()
{
    if (targetCollider == null) return;
    
    Ray ray = Camera.main.ScreenPointToRay(Input.mousePosition);
    RaycastHit hit;
    
    if (targetCollider.Raycast(ray, out hit, 100f))
    {
        Vector3 worldPos = hit.point;
        
        // Размер кисти в мировых координатах
        float worldRadius = (brushRadius / textureSize) * targetCollider.bounds.size.x;
        
        // Рисуем круг (для этого нужен отдельный shader или GL.Lines)
        Handles.color = Color.white;
        Handles.DrawWireDisc(worldPos, Vector3.forward, worldRadius);
    }
}
```

Или проще — используй UI Image с круговым спрайтом, следующим за мышью.

---

## Результат

После этого урока у тебя:
- ✅ Рисование мышью (песок, газ, ластик)
- ✅ Эффективный GPU спавн (без CPU↔GPU transfer)
- ✅ Выбор инструментов (клавиши 1-3)
- ✅ Регулировка размера кисти
- ✅ Простой GUI

**Напиши "Готово" когда сможешь рисовать песок и газ мышью!**
