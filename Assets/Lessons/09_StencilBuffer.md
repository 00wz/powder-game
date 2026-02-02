# Урок 9: Stencil Buffer — глубокое погружение

## Что такое Stencil Buffer?

**Stencil Buffer** — это дополнительный буфер памяти, который хранится вместе с Depth Buffer. Каждый пиксель имеет 8-битное значение (0-255), которое можно читать, записывать и сравнивать.

### Архитектура буферов экрана:

```
┌─────────────────────────────────────────┐
│           Frame Buffer                   │
├─────────────────────────────────────────┤
│  Color Buffer (RGBA)    - 32 bit        │
│  Depth Buffer           - 24 bit        │
│  Stencil Buffer         - 8 bit         │
└─────────────────────────────────────────┘
```

В Unity Depth и Stencil часто объединены в один 32-битный буфер:
- 24 бита — глубина
- 8 бит — стencil

---

## Синтаксис Stencil в шейдерах

```hlsl
Stencil
{
    Ref [значение]           // Эталонное значение (0-255)
    ReadMask [маска]         // Маска при чтении (по умолчанию 255)
    WriteMask [маска]        // Маска при записи (по умолчанию 255)
    Comp [функция]           // Функция сравнения
    Pass [операция]          // Что делать если ОБА теста пройдены (stencil + depth)
    Fail [операция]          // Что делать если stencil тест НЕ пройден
    ZFail [операция]         // Что делать если stencil пройден, но depth НЕ пройден
}
```

### Функции сравнения (Comp):

| Функция | Описание |
|---------|----------|
| `Never` | Никогда не проходит |
| `Less` | Проходит если Ref < буфер |
| `Equal` | Проходит если Ref == буфер |
| `LEqual` | Проходит если Ref <= буфер |
| `Greater` | Проходит если Ref > буфер |
| `NotEqual` | Проходит если Ref != буфер |
| `GEqual` | Проходит если Ref >= буфер |
| `Always` | Всегда проходит (по умолчанию) |

### Операции (Pass/Fail/ZFail):

| Операция | Описание |
|----------|----------|
| `Keep` | Не менять значение в буфере |
| `Zero` | Записать 0 |
| `Replace` | Записать Ref |
| `IncrSat` | Увеличить на 1 (с насыщением до 255) |
| `DecrSat` | Уменьшить на 1 (с насыщением до 0) |
| `Invert` | Побитовая инверсия |
| `IncrWrap` | Увеличить на 1 (с переполнением 255→0) |
| `DecrWrap` | Уменьшить на 1 (с переполнением 0→255) |

---

## Паттерн "Маска + Содержимое"

Это самый базовый паттерн использования Stencil:

### Шаг 1: Объект-маска записывает значение

```hlsl
// PortalMask.shader
Stencil
{
    Ref 1
    Comp Always      // Всегда проходим тест
    Pass Replace     // Записываем 1 в stencil
}
ColorMask 0          // Не рисуем цвет
ZWrite Off           // Не пишем глубину
```

### Шаг 2: Содержимое рисуется только в маске

```hlsl
// PortalContent.shader
Stencil
{
    Ref 1
    Comp Equal       // Рисуем только где stencil == 1
    Pass Keep        // Не меняем stencil
}
```

### Визуализация:

```
Stencil Buffer после маски:
┌───────────────────────┐
│ 0 0 0 0 0 0 0 0 0 0 0 │
│ 0 0 1 1 1 1 1 0 0 0 0 │
│ 0 0 1 1 1 1 1 0 0 0 0 │  ← Портал записал 1
│ 0 0 1 1 1 1 1 0 0 0 0 │
│ 0 0 0 0 0 0 0 0 0 0 0 │
└───────────────────────┘

Рендер содержимого:
- Пиксели где stencil == 1 → рисуются
- Пиксели где stencil == 0 → отбрасываются
```

---

## Паттерн "X-Ray" (видеть сквозь стены)

Использует **ZTest Greater** вместо или вместе со Stencil:

```hlsl
// XRaySilhouette.shader
ZTest Greater        // Рисуем только где объект ЗА другими
ZWrite Off           // Не пишем в depth
Blend SrcAlpha OneMinusSrcAlpha  // Прозрачность
```

### Как это работает:

1. Сначала рендерятся обычные объекты (стены) → заполняют depth buffer
2. Затем рендерится X-Ray объект с ZTest Greater
3. Пиксели объекта, которые ДАЛЬШЕ от камеры чем стена → рисуются (силуэт)
4. Пиксели объекта, которые БЛИЖЕ → не рисуются (видны нормально)

```
Depth Buffer:      X-Ray объект:       Результат:
┌──────────┐       ┌──────────┐        ┌──────────┐
│░░░░░░░░░░│       │          │        │          │
│░░▓▓▓▓░░░░│ стена │   ●●●    │ куб    │   ◐◐◐    │ силуэт
│░░▓▓▓▓░░░░│       │   ●●●    │        │   ◐◐◐    │ за стеной
│░░░░░░░░░░│       │          │        │          │
└──────────┘       └──────────┘        └──────────┘
```

---

## Продвинутый паттерн: Множественные маски

Можно использовать разные значения Ref для разных порталов:

```hlsl
// Portal A
Stencil { Ref 1; Comp Always; Pass Replace; }

// Portal B  
Stencil { Ref 2; Comp Always; Pass Replace; }

// Content для Portal A
Stencil { Ref 1; Comp Equal; Pass Keep; }

// Content для Portal B
Stencil { Ref 2; Comp Equal; Pass Keep; }
```

---

## Паттерн "Отверстие" (NotEqual)

Рисовать везде КРОМЕ маски:

```hlsl
// Маска: записываем 1
Stencil { Ref 1; Comp Always; Pass Replace; }
ColorMask 0

// Объект с "отверстием"
Stencil { Ref 1; Comp NotEqual; Pass Keep; }
// Рисуется везде где stencil != 1
```

---

## Паттерн "Подсчёт перекрытий"

Используется для определения чётности (inside/outside):

```hlsl
// Первый проход: рисуем front faces
Cull Back
Stencil { Comp Always; Pass IncrWrap; }

// Второй проход: рисуем back faces
Cull Front
Stencil { Comp Always; Pass DecrWrap; }

// Результат: stencil != 0 означает "внутри" объекта
```

Это основа для **CSG (Constructive Solid Geometry)**.

---

## ReadMask и WriteMask

Позволяют работать с отдельными битами stencil буфера:

```hlsl
// Записываем только в младшие 4 бита
Stencil
{
    Ref 15          // 0000 1111
    WriteMask 15    // Маска: 0000 1111
    Comp Always
    Pass Replace
}

// Читаем только старшие 4 бита
Stencil
{
    Ref 240         // 1111 0000
    ReadMask 240    // Маска: 1111 0000
    Comp Equal
    Pass Keep
}
```

Это позволяет использовать 8 бит stencil для разных эффектов одновременно!

---

## URP Render Objects Feature

В URP есть встроенная feature для рендеринга объектов с кастомными настройками:

### Настройка в Inspector:

1. Выбери **Universal Renderer** asset
2. Add Renderer Feature → **Render Objects**
3. Настрой:
   - **Name**: XRay Pass
   - **Event**: After Rendering Opaques
   - **Queue**: Opaque
   - **Layer Mask**: XRayTargets
   - **Override Stencil**: ✓
     - Value: 1
     - Compare Function: Always
     - Pass: Replace

### Преимущества:
- Не нужно писать код
- Можно менять настройки в runtime
- Работает со стандартными URP шейдерами

---

## Практическое задание: Silhouette с outline

Создадим эффект где объект за стеной показывается с контуром:

### Идея:
1. **Pass 1**: Записываем маску объекта (чуть увеличенного)
2. **Pass 2**: Рисуем силуэт (где ZTest Greater)
3. **Pass 3**: Рисуем контур (где маска есть, но силуэт нет)

```hlsl
// В этом примере используем 2 бита:
// Бит 0: маска увеличенного объекта
// Бит 1: маска реального объекта
```

---

## Сравнение: Stencil vs Depth vs Clip

| Метод | Когда использовать |
|-------|-------------------|
| **Stencil** | Произвольные маски, порталы, множественные слои |
| **Depth (ZTest)** | Простой X-Ray, отсечение по расстоянию |
| **clip()** | Отсечение по текстуре/паттерну, dissolve эффекты |

---

## Отладка Stencil Buffer

### Frame Debugger:
1. Window → Analysis → Frame Debugger
2. Выбери draw call
3. Смотри в "Stencil" секцию

### RenderDoc:
1. Capture frame
2. Выбери draw call
3. Texture Viewer → Output → Stencil

### Визуализация через шейдер:
Можно создать debug шейдер который визуализирует stencil:

```hlsl
// Требует специальный setup через Render Objects
// или custom Renderer Feature
```

---

## Ограничения и подводные камни

1. **Очистка буфера**: Stencil очищается вместе с depth. `ClearFlag.Depth` очистит оба.

2. **Порядок рендеринга**: Маска ДОЛЖНА рендериться ДО содержимого. Используй `Queue`:
   - `"Queue" = "Geometry-1"` для маски
   - `"Queue" = "Geometry+1"` для содержимого

3. **Прозрачные объекты**: Stencil работает с transparent объектами, но порядок важен!

4. **Mobile**: Некоторые mobile GPU имеют ограниченную поддержку stencil operations.

5. **MSAA**: При MSAA stencil может работать per-sample или per-pixel в зависимости от GPU.

---

## Твои реализованные файлы

### PortalMask.shader
- Записывает значение в Stencil Buffer
- `ColorMask 0` — не рисует цвет
- `ZWrite Off` — не влияет на depth
- Второй pass "Portal Depth" для кастомной глубины

### PortalContent.shader
- Читает Stencil через `Comp Equal`
- Опциональная проверка глубины портала
- Простое Lambert освещение

### PortalDepthFeature + PortalDepthPass
- Рендерит глубину порталов в отдельную текстуру
- Использует `ShaderTagId` для фильтрации
- Устанавливает `_PortalDepthTexture` глобально

### XRaySilhouette.shader
- Использует `ZTest Greater` для X-Ray эффекта
- Прозрачный силуэт с настраиваемым цветом

---

## Следующие шаги

1. **Попробуй**: Создай несколько порталов с разными `_StencilRef`
2. **Эксперимент**: Комбинируй X-Ray + Stencil маску
3. **Challenge**: Сделай "рентгеновское" зрение где:
   - Стены становятся полупрозрачными
   - Враги видны цветным силуэтом
   - Предметы мерцают
