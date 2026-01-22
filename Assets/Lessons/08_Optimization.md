# Этап 7: Оптимизация и расширение

## Что мы рассмотрим

1. **Профилирование** — как найти узкие места
2. **Оптимизация Compute Shaders** — группы потоков, memory coalescing
3. **LOD для симуляции** — разное разрешение для разных зон
4. **Новые типы частиц** — вода, огонь, дерево
5. **Реакции между элементами**
6. **Архитектура для масштабирования**

---

## 1. Профилирование в Unity

### Frame Debugger
`Window → Analysis → Frame Debugger`
- Показывает каждый draw call и compute dispatch
- Можно увидеть, какие шейдеры сколько времени занимают

### Profiler
`Window → Analysis → Profiler`
- GPU Usage — время на GPU операции
- Rendering — детали рендеринга

### RenderDoc (для глубокого анализа)
- Внешний инструмент, но мощнее
- Показывает время каждого kernel'а

---

## 2. Оптимизация Compute Shaders

### 2.1 Размер Thread Group

```hlsl
// Текущий: 8x8x1 = 64 потока
[numthreads(8, 8, 1)]

// Для современных GPU оптимально: 64-256 потоков
// Варианты:
[numthreads(16, 16, 1)]  // 256 потоков - хорошо для NVIDIA
[numthreads(8, 8, 1)]    // 64 потока - безопасный вариант
[numthreads(32, 8, 1)]   // 256 потоков - альтернатива
```

**Правило:** Кратно размеру warp/wavefront (32 для NVIDIA, 64 для AMD).

### 2.2 Memory Coalescing

GPU читает память блоками. Соседние потоки должны читать соседнюю память.

```hlsl
// ✅ Хорошо: соседние потоки читают соседние пиксели
uint3 id : SV_DispatchThreadID
int2 pos = int2(id.xy);
float4 data = _Texture[pos];

// ❌ Плохо: случайный доступ
int2 pos = int2(id.x * 7 % 256, id.y * 13 % 256);
```

### 2.3 Shared Memory (Group Shared)

Для операций с соседями (blur, diffusion) — кэшируем в shared memory:

```hlsl
// Объявляем shared memory для группы
groupshared float4 sharedData[10][10];  // 8x8 + границы

[numthreads(8, 8, 1)]
void DiffuseOptimized(uint3 id : SV_DispatchThreadID, uint3 groupId : SV_GroupID, uint3 localId : SV_GroupThreadID)
{
    int2 pos = int2(id.xy);
    int2 local = int2(localId.xy);
    
    // 1. Загружаем в shared memory (включая границы)
    sharedData[local.x + 1][local.y + 1] = _Input[pos];
    
    // Границы загружают крайние потоки
    if (local.x == 0) sharedData[0][local.y + 1] = _Input[pos + int2(-1, 0)];
    if (local.x == 7) sharedData[9][local.y + 1] = _Input[pos + int2(1, 0)];
    if (local.y == 0) sharedData[local.x + 1][0] = _Input[pos + int2(0, -1)];
    if (local.y == 7) sharedData[local.x + 1][9] = _Input[pos + int2(0, 1)];
    
    // 2. Барьер синхронизации — ждём, пока все загрузят
    GroupMemoryBarrierWithGroupSync();
    
    // 3. Теперь читаем из shared memory (быстро!)
    float4 center = sharedData[local.x + 1][local.y + 1];
    float4 left = sharedData[local.x][local.y + 1];
    float4 right = sharedData[local.x + 2][local.y + 1];
    float4 down = sharedData[local.x + 1][local.y];
    float4 up = sharedData[local.x + 1][local.y + 2];
    
    float4 avg = (left + right + down + up) / 4.0;
    _Output[pos] = lerp(center, avg, _Diffusion);
}
```

### 2.4 Early Exit

Пропускаем пустые области:

```hlsl
[numthreads(8, 8, 1)]
void SimulateSand(uint3 id : SV_DispatchThreadID)
{
    int2 pos = int2(id.xy);
    float4 current = _Input[pos];
    
    // Early exit для пустых ячеек без соседей
    if (current.r < 0.01)
    {
        float4 above = GetParticle(pos + int2(0, 1));
        if (above.r < 0.01)
        {
            _Output[pos] = current;
            return;  // Ничего не происходит
        }
    }
    
    // ... остальная логика
}
```

---

## 3. Новые типы частиц

### Система типов

```hlsl
// Типы частиц
#define EMPTY 0
#define SAND 1
#define WATER 2
#define STONE 3
#define FIRE 4
#define WOOD 5
#define STEAM 6

// Храним в красном канале (или используем int текстуру)
// R = тип (0-255)
// G = данные1 (температура, lifetime)
// B = данные2 (скорость, давление)
// A = данные3 (флаги)
```

### Вода (текучая жидкость)

```hlsl
void SimulateWater(int2 pos, inout float4 result)
{
    float4 current = GetParticle(pos);
    if (GetType(current) != WATER) return;
    
    int2 below = pos + int2(0, -1);
    int2 belowLeft = pos + int2(-1, -1);
    int2 belowRight = pos + int2(1, -1);
    int2 left = pos + int2(-1, 0);
    int2 right = pos + int2(1, 0);
    
    // Приоритет: вниз → вниз-в-сторону → в-сторону
    if (IsEmpty(below))
    {
        result = MakeWater();
    }
    else if (IsEmpty(belowLeft) && Random(pos) > 0.5)
    {
        result = MakeWater();
    }
    else if (IsEmpty(belowRight))
    {
        result = MakeWater();
    }
    else if (IsEmpty(left) && Random(pos) > 0.5)
    {
        result = MakeWater();  // Растекается
    }
    else if (IsEmpty(right))
    {
        result = MakeWater();
    }
}
```

### Огонь и горение

```hlsl
void SimulateFire(int2 pos, inout float4 result)
{
    float4 current = GetParticle(pos);
    if (GetType(current) != FIRE) return;
    
    float lifetime = current.g;  // Время жизни
    lifetime -= _DeltaTime;
    
    if (lifetime <= 0)
    {
        // Огонь погас → дым/пусто
        result = MakeEmpty();  // или MakeSmoke()
        return;
    }
    
    // Огонь поднимается
    int2 above = pos + int2(0, 1);
    if (IsEmpty(above) && Random(pos) > 0.3)
    {
        result = MakeFire(lifetime);
    }
    
    // Поджигаем соседнее дерево
    for (int dx = -1; dx <= 1; dx++)
    {
        for (int dy = -1; dy <= 1; dy++)
        {
            int2 neighbor = pos + int2(dx, dy);
            if (GetType(GetParticle(neighbor)) == WOOD)
            {
                if (Random(neighbor) > 0.95)
                {
                    // Дерево загорается
                    _Output[neighbor] = MakeFire(2.0);
                }
            }
        }
    }
    
    current.g = lifetime;
    result = current;
}
```

---

## 4. Реакции между элементами

### Таблица реакций

```hlsl
// Реакции: ElementA + ElementB → ResultA + ResultB
// Вода + Огонь → Пар + Пусто
// Вода + Песок (при движении) → Мокрый песок

void CheckReactions(int2 pos, int2 neighborPos, inout float4 result)
{
    int typeA = GetType(GetParticle(pos));
    int typeB = GetType(GetParticle(neighborPos));
    
    // Вода + Огонь = Пар
    if ((typeA == WATER && typeB == FIRE) || (typeA == FIRE && typeB == WATER))
    {
        result = MakeSteam();
        _Output[neighborPos] = MakeEmpty();
    }
    
    // Вода + Лава = Камень + Пар
    if (typeA == WATER && typeB == LAVA)
    {
        result = MakeSteam();
        _Output[neighborPos] = MakeStite();
    }
}
```

---

## 5. Архитектура для масштабирования

### Chunk System

Для больших миров разбиваем на чанки:

```csharp
public class ChunkManager : MonoBehaviour
{
    public int chunkSize = 128;
    public int worldWidth = 8;   // 8 чанков = 1024 пикселей
    public int worldHeight = 4;
    
    private SimulationChunk[,] chunks;
    
    void Start()
    {
        chunks = new SimulationChunk[worldWidth, worldHeight];
        for (int x = 0; x < worldWidth; x++)
        {
            for (int y = 0; y < worldHeight; y++)
            {
                chunks[x, y] = new SimulationChunk(chunkSize, x, y);
            }
        }
    }
    
    void Update()
    {
        // Обновляем только активные чанки (где есть движение)
        foreach (var chunk in chunks)
        {
            if (chunk.IsActive)
            {
                chunk.Simulate();
            }
        }
        
        // Обмен частицами на границах
        ExchangeBoundaries();
    }
}
```

### Active/Sleep система

Чанки без изменений "засыпают":

```csharp
class SimulationChunk
{
    public bool IsActive { get; private set; }
    private int sleepCounter = 0;
    
    public void Simulate()
    {
        // ... симуляция ...
        
        if (NoChangesThisFrame())
        {
            sleepCounter++;
            if (sleepCounter > 30)  // 30 кадров без изменений
            {
                IsActive = false;
            }
        }
        else
        {
            sleepCounter = 0;
        }
    }
    
    public void Wake()
    {
        IsActive = true;
        sleepCounter = 0;
    }
}
```

---

## 6. Визуальные улучшения

### Marching Squares для воды

Сглаживание границ жидкости:

```hlsl
float GetWaterSDF(float2 uv)
{
    // Signed Distance Field для воды
    float water = 0;
    for (int y = -1; y <= 1; y++)
    {
        for (int x = -1; x <= 1; x++)
        {
            float2 offset = float2(x, y) * _TexelSize;
            float w = tex2D(_ParticleTex, uv + offset).r == WATER ? 1 : 0;
            float dist = length(float2(x, y));
            water += w / (1.0 + dist);
        }
    }
    return water / 4.0 - 0.5;  // SDF: <0 внутри, >0 снаружи
}
```

### Parallax для глубины

```hlsl
// В fragment shader:
float depth = CalculateDepth(i.uv);  // На основе соседних частиц
float2 parallaxOffset = _ViewDir.xy * depth * _ParallaxStrength;
float2 finalUV = i.uv + parallaxOffset;
```

---

## 7. Производительность: Сводка

| Техника | Ускорение | Сложность |
|---------|-----------|-----------|
| Thread group size | 10-30% | Низкая |
| Shared memory | 2-3x | Средняя |
| Early exit | 20-50% | Низкая |
| Chunk system | 5-10x | Высокая |
| Sleep system | 2-5x | Средняя |
| LOD | 2-4x | Средняя |

---

## 8. Идеи для дальнейшего развития

1. **Физика давления** — жидкости давят друг на друга
2. **Температура** — плавление, замерзание
3. **Электричество** — проводники, молнии
4. **Биология** — рост растений, бактерии
5. **Гравитация** — изменяемое направление
6. **Порталы** — телепортация частиц
7. **Сохранение/загрузка** — сериализация текстур

---

## Финальный чеклист проекта

- [x] Базовые шейдеры (Unlit, работа с текстурами)
- [x] Compute Shaders (параллельные вычисления на GPU)
- [x] Падающий песок (частицы, double buffering)
- [x] Gas Simulation (Eulerian field-based)
- [x] Продвинутая визуализация (AO, glow, gradients)
- [x] Интерактивность (mouse input, GPU spawning)
- [x] Оптимизация (профилирование, shared memory)
- [ ] Новые элементы (вода, огонь) — самостоятельно!
- [ ] Chunk system — для больших миров
- [ ] Polish (UI, звуки, эффекты)

---

## Поздравляю! 🎉

Ты прошёл полный курс по шейдерам и GPU-симуляции в Unity!

**Что ты изучил:**
- HLSL/CG синтаксис
- Graphics pipeline
- Compute Shaders
- Double buffering
- Field-based simulation
- GPU оптимизация

**Следующие шаги:**
1. Добавь воду и огонь
2. Реализуй реакции
3. Сделай chunk system для большого мира
4. Создай красивый UI
5. Добавь звуки и эффекты частиц

Удачи в разработке! 🚀
