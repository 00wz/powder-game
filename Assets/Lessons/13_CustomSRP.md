# Урок 13: Custom Render Pipeline — Архитектура с нуля

## Введение

До этого момента мы работали с **URP (Universal Render Pipeline)** — готовым рендер-пайплайном Unity. Мы добавляли свои `ScriptableRendererFeature` и `ScriptableRenderPass`, но сам пайплайн управлялся Unity.

Теперь мы создадим **полностью собственный рендер-пайплайн** с нуля. Это даст нам полное понимание того, как работает рендеринг в Unity.

---

## Зачем создавать Custom SRP?

### Когда это нужно:
1. **Полный контроль** — точно знаете, что и когда рендерится
2. **Оптимизация** — убираете всё лишнее для конкретного проекта
3. **Специфичные требования** — нестандартный рендеринг (voxels, ray tracing)
4. **Обучение** — глубокое понимание графического пайплайна

### Когда НЕ нужно:
- Для большинства проектов URP/HDRP достаточно
- Больше работы по поддержке
- Нет готовых шейдеров (Lit, Unlit придётся писать самим)

---

## Архитектура SRP

```
┌─────────────────────────────────────────────────────────────┐
│                    Graphics Settings                         │
│                 (Project Settings → Graphics)                │
│                           │                                  │
│                           ▼                                  │
│              ┌─────────────────────────┐                    │
│              │  RenderPipelineAsset    │                    │
│              │  (ScriptableObject)     │                    │
│              │                         │                    │
│              │  - Хранит настройки     │                    │
│              │  - Создаёт Pipeline     │                    │
│              └───────────┬─────────────┘                    │
│                          │                                  │
│                          ▼ CreatePipeline()                 │
│              ┌─────────────────────────┐                    │
│              │   RenderPipeline        │                    │
│              │   (C# класс)            │                    │
│              │                         │                    │
│              │  - Логика рендеринга    │                    │
│              │  - Render() для камер   │                    │
│              └───────────┬─────────────┘                    │
│                          │                                  │
│                          ▼ Render(context, cameras)         │
│              ┌─────────────────────────┐                    │
│              │ ScriptableRenderContext │                    │
│              │                         │                    │
│              │  - Очередь команд GPU   │                    │
│              │  - DrawRenderers()      │                    │
│              │  - ExecuteCommandBuffer │                    │
│              └─────────────────────────┘                    │
└─────────────────────────────────────────────────────────────┘
```

---

## Ключевые классы

### 1. RenderPipelineAsset

`RenderPipelineAsset` — это **ScriptableObject**, который:
- Хранится как asset в проекте
- Назначается в Project Settings → Graphics
- Создаёт экземпляр `RenderPipeline`

```csharp
using UnityEngine;
using UnityEngine.Rendering;

// CreateAssetMenu позволяет создавать asset через контекстное меню
[CreateAssetMenu(menuName = "Rendering/Custom Render Pipeline Asset")]
public class CustomRenderPipelineAsset : RenderPipelineAsset
{
    // Настройки пайплайна
    [SerializeField] private Color clearColor = Color.black;
    [SerializeField] private bool useSRPBatcher = true;
    
    public Color ClearColor => clearColor;
    public bool UseSRPBatcher => useSRPBatcher;
    
    // Unity вызывает этот метод для создания пайплайна
    protected override RenderPipeline CreatePipeline()
    {
        return new CustomRenderPipeline(this);
    }
}
```

### 2. RenderPipeline

`RenderPipeline` — это **основной класс**, который выполняет рендеринг:

```csharp
using UnityEngine;
using UnityEngine.Rendering;

public class CustomRenderPipeline : RenderPipeline
{
    private CustomRenderPipelineAsset settings;
    
    public CustomRenderPipeline(CustomRenderPipelineAsset asset)
    {
        settings = asset;
        
        // Включаем SRP Batcher для оптимизации
        GraphicsSettings.useScriptableRenderPipelineBatching = asset.UseSRPBatcher;
    }
    
    // Главный метод — вызывается каждый кадр
    protected override void Render(ScriptableRenderContext context, Camera[] cameras)
    {
        // Рендерим каждую камеру
        foreach (Camera camera in cameras)
        {
            RenderCamera(context, camera);
        }
    }
    
    private void RenderCamera(ScriptableRenderContext context, Camera camera)
    {
        // Здесь будет логика рендеринга для одной камеры
    }
}
```

### 3. ScriptableRenderContext

`ScriptableRenderContext` — это **интерфейс к GPU**:

| Метод | Описание |
|-------|----------|
| `SetupCameraProperties(camera)` | Устанавливает VP матрицы |
| `DrawRenderers(cullingResults, ...)` | Рендерит объекты |
| `ExecuteCommandBuffer(cmd)` | Выполняет CommandBuffer |
| `Submit()` | Отправляет команды на GPU |
| `Cull(ref cullingParameters)` | Отсекает невидимые объекты |

---

## Минимальный рендер-пайплайн

Создадим пайплайн, который:
1. Очищает экран заданным цветом
2. Рендерит все Unlit объекты

### Шаг 1: CustomRenderPipelineAsset.cs

```csharp
using UnityEngine;
using UnityEngine.Rendering;

[CreateAssetMenu(menuName = "Rendering/Custom Render Pipeline Asset")]
public class CustomRenderPipelineAsset : RenderPipelineAsset
{
    [Header("General")]
    [SerializeField] private bool useSRPBatcher = true;
    
    [Header("Camera")]
    [SerializeField] private Color defaultClearColor = new Color(0.1f, 0.1f, 0.1f, 1f);
    
    public bool UseSRPBatcher => useSRPBatcher;
    public Color DefaultClearColor => defaultClearColor;
    
    protected override RenderPipeline CreatePipeline()
    {
        return new CustomRenderPipeline(this);
    }
}
```

### Шаг 2: CustomRenderPipeline.cs

```csharp
using UnityEngine;
using UnityEngine.Rendering;

public class CustomRenderPipeline : RenderPipeline
{
    private CustomRenderPipelineAsset settings;
    
    // ShaderTagId определяет какой Pass шейдера использовать
    private static readonly ShaderTagId unlitShaderTagId = new ShaderTagId("SRPDefaultUnlit");
    
    public CustomRenderPipeline(CustomRenderPipelineAsset asset)
    {
        settings = asset;
        GraphicsSettings.useScriptableRenderPipelineBatching = asset.UseSRPBatcher;
    }
    
    protected override void Render(ScriptableRenderContext context, Camera[] cameras)
    {
        foreach (Camera camera in cameras)
        {
            RenderCamera(context, camera);
        }
    }
    
    private void RenderCamera(ScriptableRenderContext context, Camera camera)
    {
        // 1. Настраиваем свойства камеры (матрицы View/Projection)
        context.SetupCameraProperties(camera);
        
        // 2. Получаем параметры culling
        if (!camera.TryGetCullingParameters(out ScriptableCullingParameters cullingParams))
        {
            return; // Камера не может делать culling (например, размер 0)
        }
        
        // 3. Выполняем culling — отсекаем невидимые объекты
        CullingResults cullingResults = context.Cull(ref cullingParams);
        
        // 4. Создаём CommandBuffer для команд
        CommandBuffer cmd = new CommandBuffer { name = "Render Camera" };
        
        // 5. Очищаем экран
        CameraClearFlags clearFlags = camera.clearFlags;
        cmd.ClearRenderTarget(
            clearDepth: clearFlags <= CameraClearFlags.Depth,
            clearColor: clearFlags == CameraClearFlags.Color || clearFlags == CameraClearFlags.SolidColor,
            backgroundColor: camera.backgroundColor
        );
        context.ExecuteCommandBuffer(cmd);
        cmd.Clear();
        
        // 6. Настраиваем сортировку (ближние объекты сначала)
        SortingSettings sortingSettings = new SortingSettings(camera)
        {
            criteria = SortingCriteria.CommonOpaque
        };
        
        // 7. Настраиваем рисование — какой shader pass использовать
        DrawingSettings drawingSettings = new DrawingSettings(unlitShaderTagId, sortingSettings);
        
        // 8. Настраиваем фильтрацию — какие объекты рендерить
        FilteringSettings filteringSettings = new FilteringSettings(RenderQueueRange.opaque);
        
        // 9. Рисуем объекты!
        context.DrawRenderers(cullingResults, ref drawingSettings, ref filteringSettings);
        
        // 10. Рисуем Skybox (если нужен)
        if (camera.clearFlags == CameraClearFlags.Skybox && RenderSettings.skybox != null)
        {
            context.DrawSkybox(camera);
        }
        
        // 11. Рисуем прозрачные объекты
        sortingSettings.criteria = SortingCriteria.CommonTransparent;
        drawingSettings.sortingSettings = sortingSettings;
        filteringSettings.renderQueueRange = RenderQueueRange.transparent;
        context.DrawRenderers(cullingResults, ref drawingSettings, ref filteringSettings);
        
        // 12. Освобождаем CommandBuffer
        cmd.Release();
        
        // 13. Отправляем все команды на GPU
        context.Submit();
    }
}
```

---

## Процесс рендеринга — пошаговый разбор

### 1. Setup Camera Properties
```csharp
context.SetupCameraProperties(camera);
```
Устанавливает:
- `UNITY_MATRIX_V` — View matrix
- `UNITY_MATRIX_P` — Projection matrix
- `UNITY_MATRIX_VP` — View-Projection matrix
- `_WorldSpaceCameraPos` — Позиция камеры
- Viewport

### 2. Culling
```csharp
CullingResults cullingResults = context.Cull(ref cullingParams);
```
**Culling** — отсечение объектов, которые не видны камере:
- **Frustum culling** — объекты вне пирамиды видимости
- **Occlusion culling** — объекты за другими объектами
- **Layer culling** — по настройкам камеры (Culling Mask)

`CullingResults` содержит список видимых:
- `visibleRenderers` — объекты для рендеринга
- `visibleLights` — источники света
- `visibleReflectionProbes` — reflection probes

### 3. Clear Render Target
```csharp
cmd.ClearRenderTarget(clearDepth, clearColor, backgroundColor);
```
Очищает буферы перед рендерингом:
- **Color buffer** — цвет пикселей
- **Depth buffer** — глубина (Z-buffer)
- **Stencil buffer** — часть depth buffer

### 4. Drawing Settings
```csharp
DrawingSettings drawingSettings = new DrawingSettings(shaderTagId, sortingSettings);
```
**ShaderTagId** определяет какой `Pass` использовать:

```hlsl
// В шейдере:
Pass
{
    Tags { "LightMode" = "SRPDefaultUnlit" }  // ← ShaderTagId ищет это
    // ...
}
```

Стандартные теги:
| Tag | Описание |
|-----|----------|
| `SRPDefaultUnlit` | Стандартный Unlit pass |
| `UniversalForward` | Forward rendering в URP |
| `ShadowCaster` | Pass для теней |
| `DepthOnly` | Только глубина |
| `Meta` | Для lightmapping |

### ⚠️ Важно: Поведение по умолчанию

**Если Pass НЕ имеет тега `LightMode`, Unity автоматически присваивает ему `"SRPDefaultUnlit"`!**

```hlsl
// Этот шейдер:
Pass
{
    // Нет Tags { "LightMode" = "..." }
    CGPROGRAM
    ...
    ENDCG
}

// Интерпретируется Unity как:
Pass
{
    Tags { "LightMode" = "SRPDefaultUnlit" }  // Автоматически!
    CGPROGRAM
    ...
    ENDCG
}
```

Поэтому простые Unlit шейдеры работают в Custom SRP без модификаций — они попадают под `SRPDefaultUnlit`.

### 5. Filtering Settings
```csharp
FilteringSettings filteringSettings = new FilteringSettings(RenderQueueRange.opaque);
```
Фильтрует объекты по:
- **RenderQueue** — opaque (0-2500), transparent (2501-5000)
- **Layer mask** — какие слои рендерить
- **Rendering layer mask** — дополнительная маска

### 6. Sorting Settings
```csharp
SortingSettings sortingSettings = new SortingSettings(camera)
{
    criteria = SortingCriteria.CommonOpaque
};
```
Порядок рендеринга:
- **CommonOpaque** — front-to-back (для early-z rejection)
- **CommonTransparent** — back-to-front (для корректного смешивания)
- **SortingCriteria.None** — без сортировки

### 7. Draw Renderers
```csharp
context.DrawRenderers(cullingResults, ref drawingSettings, ref filteringSettings);
```
Отправляет draw calls для всех объектов, прошедших фильтрацию.

### 8. Submit
```csharp
context.Submit();
```
**Критически важно!** Без этого ничего не отрендерится. Отправляет накопленные команды на GPU.

---

## Порядок рендеринга

```
┌─────────────────────────────────────────┐
│  1. Setup Camera Properties             │
├─────────────────────────────────────────┤
│  2. Culling                             │
├─────────────────────────────────────────┤
│  3. Clear (Color, Depth, Stencil)       │
├─────────────────────────────────────────┤
│  4. Draw Opaque Objects (front-to-back) │
├─────────────────────────────────────────┤
│  5. Draw Skybox                         │
├─────────────────────────────────────────┤
│  6. Draw Transparent (back-to-front)    │
├─────────────────────────────────────────┤
│  7. Post-Processing                     │
├─────────────────────────────────────────┤
│  8. Submit                              │
└─────────────────────────────────────────┘
```

### Почему такой порядок?

**Opaque front-to-back:**
- GPU использует **Early-Z test** — если пиксель уже закрыт, фрагментный шейдер не выполняется
- Ближние объекты закрывают дальние → экономия

**Transparent back-to-front:**
- Прозрачные объекты не записывают глубину (ZWrite Off)
- Для корректного смешивания нужен правильный порядок
- Дальние рисуются первыми, ближние поверх

---

## CommandBuffer — команды рендеринга

`CommandBuffer` — буфер команд для GPU:

```csharp
CommandBuffer cmd = new CommandBuffer { name = "My Commands" };

// Очистка
cmd.ClearRenderTarget(true, true, Color.black);

// Установка render target
cmd.SetRenderTarget(renderTexture);

// Установка shader параметров
cmd.SetGlobalVector("_CustomParam", new Vector4(1, 2, 3, 4));
cmd.SetGlobalTexture("_CustomTex", texture);

// Blit
cmd.Blit(source, destination, material, pass);

// Отправка команд
context.ExecuteCommandBuffer(cmd);
cmd.Clear();  // Очищаем буфер для повторного использования

// В конце — освобождаем
cmd.Release();
```

### Важно: порядок ExecuteCommandBuffer

```csharp
// Неправильно — команды потеряются!
cmd.ClearRenderTarget(...);
cmd.Clear();
context.ExecuteCommandBuffer(cmd);  // Пустой буфер!

// Правильно
cmd.ClearRenderTarget(...);
context.ExecuteCommandBuffer(cmd);
cmd.Clear();  // Очищаем после выполнения
```

---

## Profiling и отладка

### Frame Debugger

`Window → Analysis → Frame Debugger` показывает:
- Все draw calls
- Состояние GPU (render target, shader)
- Порядок выполнения

### Profiler Markers

```csharp
using (new ProfilingScope(cmd, new ProfilingSampler("My Pass")))
{
    // Код будет видно в Profiler
    cmd.ClearRenderTarget(...);
}
context.ExecuteCommandBuffer(cmd);
```

### BeginSample / EndSample

```csharp
cmd.BeginSample("Clear");
cmd.ClearRenderTarget(true, true, Color.black);
cmd.EndSample("Clear");
```

---

## Практическое задание

### Задание 1: Создайте минимальный пайплайн

1. Создайте `CustomRenderPipelineAsset.cs` и `CustomRenderPipeline.cs`
2. Создайте asset: `Create → Rendering → Custom Render Pipeline Asset`
3. Назначьте в `Project Settings → Graphics → Scriptable Render Pipeline Settings`
4. Добавьте на сцену объекты с Unlit материалами
5. Проверьте, что они рендерятся

### Задание 2: Добавьте настраиваемый clear color

1. Добавьте `[SerializeField] Color clearColor` в Asset
2. Используйте его вместо `camera.backgroundColor`
3. Проверьте изменение цвета в инспекторе

### Задание 3: Добавьте поддержку нескольких shader passes

Поддержите несколько LightMode тегов:

```csharp
private static readonly ShaderTagId[] shaderTagIds = 
{
    new ShaderTagId("SRPDefaultUnlit"),
    new ShaderTagId("CustomUnlit"),  // Свой тег
};

// В DrawingSettings:
DrawingSettings drawingSettings = new DrawingSettings(shaderTagIds[0], sortingSettings);
for (int i = 1; i < shaderTagIds.Length; i++)
{
    drawingSettings.SetShaderPassName(i, shaderTagIds[i]);
}
```

---

## Типичные ошибки

### 1. Забыли Submit
```csharp
// ❌ Ничего не отрендерится!
context.DrawRenderers(...);
// Забыли context.Submit();

// ✅ Правильно
context.DrawRenderers(...);
context.Submit();
```

### 2. Неправильный порядок камер
```csharp
// ❌ Все камеры рендерятся в Main Camera
protected override void Render(ScriptableRenderContext context, Camera[] cameras)
{
    context.SetupCameraProperties(cameras[0]);  // Только первая!
    foreach (Camera camera in cameras)
    {
        RenderCamera(context, camera);  // Но VP матрицы от первой камеры
    }
}

// ✅ Правильно — SetupCameraProperties для каждой камеры
private void RenderCamera(ScriptableRenderContext context, Camera camera)
{
    context.SetupCameraProperties(camera);  // Для текущей камеры
    // ...
}
```

### 3. Release CommandBuffer без его создания
```csharp
// ❌ NullReferenceException
CommandBuffer cmd = null;
cmd.Release();

// ✅ Проверка
if (cmd != null)
    cmd.Release();
```

---

## Итоги

В этом уроке мы изучили:

1. **Архитектуру SRP** — RenderPipelineAsset создаёт RenderPipeline
2. **RenderPipeline.Render()** — главный метод, вызываемый каждый кадр
3. **ScriptableRenderContext** — интерфейс к GPU
4. **Culling** — отсечение невидимых объектов
5. **DrawRenderers** — рендеринг объектов с фильтрацией
6. **CommandBuffer** — буфер команд для GPU
7. **Порядок рендеринга** — opaque, skybox, transparent, post-processing

В следующем уроке мы добавим:
- Рендеринг Lit объектов
- Передачу информации об освещении
- Несколько render targets
