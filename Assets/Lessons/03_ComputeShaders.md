# Этап 2: Compute Shaders — Сердце симуляции

## Что такое Compute Shader?

**Compute Shader** — программа для GPU, которая выполняет **произвольные вычисления**, не связанные с рендерингом графики.

```
Vertex/Fragment Shaders:          Compute Shaders:
┌─────────────────────┐           ┌─────────────────────┐
│ Вершины → Пиксели   │           │ Данные → Вычисления │
│ Жёсткий конвейер    │           │ Свободная структура │
│ Для отрисовки       │           │ Для симуляции       │
└─────────────────────┘           └─────────────────────┘
```

## Почему Compute Shader идеален для PowderGame?

1. **Параллелизм**: Миллионы частиц обрабатываются одновременно
2. **Прямая запись**: Можно писать в RenderTexture напрямую
3. **Гибкость**: Любая логика, не ограниченная конвейером
4. **Скорость**: GPU в 100-1000 раз быстрее CPU для таких задач

## Модель выполнения

### Thread Groups (Группы потоков)

```
┌───────────────────────────────────────┐
│           Dispatch(4, 4, 1)           │  ← 4×4 = 16 групп
│  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐      │
│  │Group│ │Group│ │Group│ │Group│      │
│  │(0,0)│ │(1,0)│ │(2,0)│ │(3,0)│      │
│  └─────┘ └─────┘ └─────┘ └─────┘      │
│  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐      │
│  │Group│ │Group│ │Group│ │Group│      │
│  │(0,1)│ │(1,1)│ │(2,1)│ │(3,1)│      │
│  └─────┘ └─────┘ └─────┘ └─────┘      │
│           ...                         │
└───────────────────────────────────────┘

Каждая группа содержит потоки:
┌─────────────────────────────┐
│  [numthreads(8, 8, 1)]      │  ← 8×8 = 64 потока в группе
│  ┌───┬───┬───┬───┬───┬───┐  │
│  │0,0│1,0│2,0│3,0│...│7,0│  │
│  ├───┼───┼───┼───┼───┼───┤  │
│  │0,1│1,1│2,1│...│...│...│  │
│  ├───┼───┼───┼───┼───┼───┤  │
│  │...│...│...│...│...│7,7│  │
│  └───┴───┴───┴───┴───┴───┘  │
└─────────────────────────────┘
```

### Вычисление ID потока

```hlsl
[numthreads(8, 8, 1)]
void CSMain (uint3 id : SV_DispatchThreadID)
{
    // id.xy — глобальные координаты потока
    // Для текстуры 256×256:
    // - Dispatch(32, 32, 1) — 32×32 групп
    // - Каждая группа 8×8 потоков
    // - 32×8 = 256, покрываем всю текстуру
}
```

## Структура Compute Shader

```hlsl
// Объявление ресурсов
RWTexture2D<float4> Result;  // RW = Read/Write
Texture2D<float4> Input;     // Только чтение
float _Time;                 // Параметр из C#

// Объявление kernel (точка входа)
#pragma kernel CSMain

[numthreads(8, 8, 1)]
void CSMain (uint3 id : SV_DispatchThreadID)
{
    // Код выполняется для каждого потока
    // id.xy — координаты текущего пикселя
    
    float4 color = float4(id.x / 256.0, id.y / 256.0, 0, 1);
    Result[id.xy] = color;
}
```

## Ключевые типы данных

### RWTexture2D (Read/Write)
```hlsl
RWTexture2D<float4> _OutputTex;  // Запись результата
_OutputTex[id.xy] = float4(1,0,0,1);  // Записываем красный
```

### Texture2D (только чтение)
```hlsl
Texture2D<float4> _InputTex;
float4 data = _InputTex[id.xy];  // Читаем по координатам
```

### SamplerState (для интерполяции)
```hlsl
SamplerState sampler_InputTex;
float4 data = _InputTex.SampleLevel(sampler_InputTex, uv, 0);
```

## Связь с C# кодом

```csharp
public class ComputeController : MonoBehaviour
{
    public ComputeShader computeShader;
    public RenderTexture outputTexture;
    
    private int kernelHandle;
    
    void Start()
    {
        // Создаём RenderTexture
        outputTexture = new RenderTexture(256, 256, 0);
        outputTexture.enableRandomWrite = true;  // ВАЖНО!
        outputTexture.filterMode = FilterMode.Point;
        outputTexture.Create();
        
        // Находим kernel
        kernelHandle = computeShader.FindKernel("CSMain");
        
        // Привязываем текстуру
        computeShader.SetTexture(kernelHandle, "Result", outputTexture);
    }
    
    void Update()
    {
        // Передаём параметры
        computeShader.SetFloat("_Time", Time.time);
        
        // Запускаем вычисления
        // 256 / 8 = 32 группы в каждом измерении
        computeShader.Dispatch(kernelHandle, 256 / 8, 256 / 8, 1);
    }
}
```

## Double Buffering (Ping-Pong)

Для симуляции нужно читать текущее состояние и записывать новое **одновременно**. Решение — две текстуры:

```
Frame N:
┌──────────┐  Compute   ┌──────────┐
│ Texture A│ ────────→  │ Texture B│
│ (читаем) │  Shader    │ (пишем)  │
└──────────┘            └──────────┘

Frame N+1:
┌──────────┐  Compute   ┌──────────┐
│ Texture B│ ────────→  │ Texture A│
│ (читаем) │  Shader    │ (пишем)  │
└──────────┘            └──────────┘
```

```csharp
// В C#
RenderTexture[] buffers = new RenderTexture[2];
int currentBuffer = 0;

void Update()
{
    int readBuffer = currentBuffer;
    int writeBuffer = 1 - currentBuffer;
    
    computeShader.SetTexture(kernel, "_Input", buffers[readBuffer]);
    computeShader.SetTexture(kernel, "_Output", buffers[writeBuffer]);
    computeShader.Dispatch(kernel, ...);
    
    currentBuffer = writeBuffer;  // Меняем местами
}
```

---

## Практическое задание: Первый Compute Shader

### Шаг 1: Создай Compute Shader

Создай файл `Assets/Shaders/SimpleCompute.compute`:

```hlsl
#pragma kernel CSMain

// Выходная текстура (записываем результат)
RWTexture2D<float4> Result;

// Параметры из C#
float _Time;
int _Width;
int _Height;

[numthreads(8, 8, 1)]
void CSMain (uint3 id : SV_DispatchThreadID)
{
    // Проверка границ (важно!)
    if (id.x >= (uint)_Width || id.y >= (uint)_Height)
        return;
    
    // Нормализованные координаты (0-1)
    float2 uv = float2(id.x, id.y) / float2(_Width, _Height);
    
    // Анимированный градиент
    float r = sin(uv.x * 10.0 + _Time) * 0.5 + 0.5;
    float g = sin(uv.y * 10.0 + _Time * 1.3) * 0.5 + 0.5;
    float b = sin((uv.x + uv.y) * 5.0 + _Time * 0.7) * 0.5 + 0.5;
    
    Result[id.xy] = float4(r, g, b, 1.0);
}
```

### Шаг 2: Создай C# контроллер

Создай файл `Assets/Scripts/SimpleComputeController.cs`:

```csharp
using UnityEngine;

public class SimpleComputeController : MonoBehaviour
{
    [Header("Compute Shader")]
    public ComputeShader computeShader;
    
    [Header("Settings")]
    public int textureWidth = 256;
    public int textureHeight = 256;
    
    [Header("Output")]
    public Material displayMaterial;  // Материал для отображения
    
    private RenderTexture outputTexture;
    private int kernelHandle;
    
    void Start()
    {
        // Создаём RenderTexture
        outputTexture = new RenderTexture(textureWidth, textureHeight, 0);
        outputTexture.enableRandomWrite = true;  // Обязательно для Compute Shader!
        outputTexture.filterMode = FilterMode.Point;
        outputTexture.wrapMode = TextureWrapMode.Clamp;
        outputTexture.Create();
        
        // Находим kernel по имени
        kernelHandle = computeShader.FindKernel("CSMain");
        
        // Устанавливаем постоянные параметры
        computeShader.SetInt("_Width", textureWidth);
        computeShader.SetInt("_Height", textureHeight);
        computeShader.SetTexture(kernelHandle, "Result", outputTexture);
        
        // Назначаем текстуру на материал для отображения
        if (displayMaterial != null)
        {
            displayMaterial.mainTexture = outputTexture;
        }
    }
    
    void Update()
    {
        // Передаём время
        computeShader.SetFloat("_Time", Time.time);
        
        // Вычисляем количество групп
        // textureWidth / 8 = количество групп по X
        int groupsX = Mathf.CeilToInt(textureWidth / 8.0f);
        int groupsY = Mathf.CeilToInt(textureHeight / 8.0f);
        
        // Запускаем Compute Shader
        computeShader.Dispatch(kernelHandle, groupsX, groupsY, 1);
    }
    
    void OnDestroy()
    {
        // Освобождаем ресурсы
        if (outputTexture != null)
        {
            outputTexture.Release();
        }
    }
}
```

### Шаг 3: Настройка в Unity

1. **Создай папку** `Assets/Scripts` (если нет)
2. **Создай Compute Shader:**
   - ПКМ в Assets/Shaders → Create → Shader → Compute Shader
   - Назови `SimpleCompute`
   - Замени содержимое на код выше
3. **Создай C# скрипт:**
   - ПКМ в Assets/Scripts → Create → C# Script
   - Назови `SimpleComputeController`
   - Замени содержимое на код выше
4. **Создай объект для отображения:**
   - Hierarchy → 3D Object → Quad (или используй Sprite)
   - Назови его "ComputeDisplay"
5. **Создай материал:**
   - ПКМ в Assets/Material → Create → Material
   - Назови "ComputeMaterial"
   - Shader: Unlit/Texture (или PowderGame/TestShader)
6. **Настрой контроллер:**
   - Создай пустой GameObject, назови "ComputeController"
   - Добавь компонент SimpleComputeController
   - Назначь:
     - Compute Shader: SimpleCompute
     - Display Material: ComputeMaterial
7. **Назначь материал на Quad:**
   - Выбери Quad
   - Mesh Renderer → Materials → ComputeMaterial
8. **Запусти игру** (Play) и наблюдай анимированный градиент!

---

## Возможные ошибки и решения

| Ошибка | Причина | Решение |
|--------|---------|---------|
| Чёрный экран | enableRandomWrite = false | Установи `outputTexture.enableRandomWrite = true` |
| Ничего не видно | Материал не назначен | Проверь назначение материала и текстуры |
| Ошибка компиляции | Синтаксис | Проверь код Compute Shader |
| Неверные размеры | Dispatch неправильный | `Dispatch(width/8, height/8, 1)` |

---

## Ключевые концепции

| Концепция | Описание |
|-----------|----------|
| **Kernel** | Функция-точка входа в Compute Shader |
| **numthreads** | Размер группы потоков (обычно 8×8×1) |
| **Dispatch** | Запуск с указанием количества групп |
| **RWTexture2D** | Текстура для записи результата |
| **enableRandomWrite** | Флаг RenderTexture для записи |
| **SV_DispatchThreadID** | Глобальный ID потока |

---

**Когда увидишь анимированный градиент — напиши "Готово".**

Это база для всей симуляции! В следующем уроке добавим частицы.
