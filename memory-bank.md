# Memory Bank: PowderGame Unity Project

## Описание проекта
Разработка игры в жанре PowderGame/ThePowderToy на Unity с упором на изучение шейдеров и реализацию field-based gas simulation.

## Цели обучения
- Понимание основ шейдеров в Unity (Surface, Vertex/Fragment, Compute)
- Работа с текстурами как с данными (texture-based simulation)
- Реализация GPU-симуляции частиц
- Field-based подход к симуляции газов
- Оптимизация и производительность

---

## ПЛАН ПРОЕКТА

### Этап 1: Основы шейдеров в Unity ✅
- [x] **1.1** Введение в шейдеры: типы шейдеров в Unity, HLSL основы
- [x] **1.2** Разбор Unlit Shader и практика
- [x] **1.3** Работа с текстурами в шейдерах (подготовка к симуляции)

### Этап 2: Compute Shaders ✅
- [x] **2.1** Введение в Compute Shaders: концепция GPGPU
- [x] **2.2** Первый Compute Shader: анимированный градиент
- [x] **2.3** RenderTexture и работа с двумерными данными
- [x] **2.4** Double buffering (ping-pong technique)

### Этап 3: Базовая симуляция частиц ✅
- [x] **3.1** Архитектура данных: представление частиц в текстуре
- [x] **3.2** Симуляция гравитации (падающий песок)
- [x] **3.3** Pull-based логика и InBounds проверки

### Этап 4: Field-Based Gas Simulation ✅
- [x] **4.1** Теория: Эйлерова vs Лагранжева симуляция
- [x] **4.2** Advection (Semi-Lagrangian метод)
- [x] **4.3** Diffusion и диссипация
- [x] **4.4** Взаимодействие газа с твёрдыми частицами

### Этап 5: Визуализация и рендеринг ✅
- [x] **5.1** Цветовые градиенты по плотности
- [x] **5.2** Ambient Occlusion для частиц
- [x] **5.3** Glow эффект для газа (blur)
- [x] **5.4** HSV визуализация скорости

### Этап 6: Интерактивность и UI ✅
- [x] **6.1** Raycast → UV координаты
- [x] **6.2** GPU Spawning через Compute Shader
- [x] **6.3** Инструменты (песок, газ, ластик)
- [x] **6.4** Простой GUI (OnGUI)

### Этап 7: Оптимизация и расширение ✅
- [x] **7.1** Профилирование (Frame Debugger, Profiler)
- [x] **7.2** Shared Memory оптимизация
- [x] **7.3** Архитектура для новых элементов (вода, огонь)
- [x] **7.4** Chunk system концепция

---

## Текущий прогресс
**Статус:** ✅ КУРС ЗАВЕРШЁН
**Все 7 этапов пройдены успешно!**

---

## Созданные файлы

### Уроки (Assets/Lessons/)
- `01_ShaderBasics.md` — Введение в шейдеры
- `01_ShaderBasics_Part2.md` — Текстуры как данные
- `02_TexturesAsData.md` — Работа с текстурами
- `03_ComputeShaders.md` — Compute Shaders основы
- `04_FallingSand.md` — Симуляция падающего песка
- `05_GasSimulation.md` — Field-based газовая симуляция
- `06_Visualization.md` — Продвинутая визуализация
- `07_Interactivity.md` — Интерактивность и UI
- `08_Optimization.md` — Оптимизация и расширение

### Шейдеры (Assets/Shaders/)
- `TestShader.shader` — Первый Unlit шейдер
- `DataVisualizer.shader` — Визуализация данных
- `SimpleCompute.compute` — Первый Compute Shader
- `SandSimulation.compute` — Симуляция частиц
- `SandVisualizer.shader` — Визуализация песка
- `GasSimulation.compute` — Газовая симуляция
- `GasParticleVisualizer.shader` — Визуализация газа
- `AdvancedVisualizer.shader` — Продвинутые эффекты
- `WavesSimulation.compute` — Эксперименты пользователя

### Скрипты (Assets/Scripts/)
- `SimpleComputeController.cs`
- `SandSimulationController.cs`
- `GasSimulationController.cs`
- `InteractiveSimController.cs`

---

## Ключевые изученные концепции

### HLSL/Шейдеры
- Vertex/Fragment pipeline
- Properties, SubShader, Pass
- Семантики (POSITION, TEXCOORD, SV_Target)
- Встроенные функции (lerp, saturate, frac, sin)

### Compute Shaders
- `[numthreads(8,8,1)]` и `Dispatch()`
- `RWTexture2D<float4>` для записи
- `SV_DispatchThreadID` для координат
- Thread Groups и синхронизация

### Симуляция
- Double Buffering (ping-pong)
- Pull-based логика ("кто падает в меня?")
- InBounds проверки
- Field-based (Eulerian) vs Particle-based (Lagrangian)
- Semi-Lagrangian advection
- Bilinear interpolation

### Оптимизация
- Shared Memory (`groupshared`)
- Memory coalescing
- Early exit
- Chunk system

---

## Технические детали проекта
- **Render Pipeline**: Universal Render Pipeline (URP) 2D
- **Texture Format**: ARGBFloat для высокой точности
- **Filter Mode**: Point для частиц, Bilinear для газа
- **Double Buffering**: Обязательно для корректной симуляции

---

## Следующие шаги (самостоятельно)
- [ ] Добавить воду (текучая жидкость)
- [ ] Добавить огонь и горение
- [ ] Реализовать реакции между элементами
- [ ] Chunk system для большого мира
- [ ] Красивый UI с Unity UI Toolkit
- [ ] Сохранение/загрузка миров

---

## История изменений
- **2026-01-14**: Создан Memory Bank, составлен план проекта
- **2026-01-14**: Этап 1 — Основы шейдеров
- **2026-01-15**: Этап 2-3 — Compute Shaders и падающий песок
- **2026-01-16**: Этап 4-6 — Газ, визуализация, интерактивность
- **2026-01-20**: Этап 7 — Оптимизация. **КУРС ЗАВЕРШЁН!** 🎉
- **2026-01-22**: Начат новый курс — Scriptable Render Pipeline (SRP)

---

# 🎨 КУРС: Scriptable Render Pipeline (SRP)

## Описание курса
Глубокое практическое изучение Scriptable Render Pipeline в Unity. Курс построен на реальных кейсах и задачах из игровой разработки. Фокус на URP (Universal Render Pipeline), так как проект уже использует эту систему.

## Предварительные требования
- ✅ Понимание шейдеров (Vertex/Fragment)
- ✅ Опыт работы с Compute Shaders
- ✅ Базовое понимание рендер-пайплайна

---

## ПЛАН ОБУЧЕНИЯ SRP

### Этап 1: Архитектура SRP (Теория + Практика) ✅
**Цель:** Понять, как устроен рендер-пайплайн изнутри

- [x] **1.1** Архитектура Render Pipeline
  - Что такое SRP и зачем он нужен
  - RenderPipelineAsset vs ScriptableRenderer
  - Сравнение Built-in, URP, HDRP
  - **Практика:** Изучили структуру URP Asset и Renderer 2D

- [x] **1.2** ScriptableRenderPass — основной строительный блок
  - Жизненный цикл: RecordRenderGraph (современный API)
  - RenderPassEvent (injection points)
  - **Реализовано:** DebugRenderPass.cs

- [x] **1.3** ScriptableRendererFeature — интеграция в пайплайн
  - Добавление кастомных фич в Renderer
  - AddRenderPasses и Create методы
  - **Реализовано:** DebugRendererFeature.cs, InvertColorsFeature.cs

### Этап 2: Blit-операции и Full-Screen эффекты ✅
**Цель:** Освоить базовые операции пост-обработки

- [x] **2.1** RTHandle и управление текстурами
  - TextureHandle в Render Graph
  - renderGraph.CreateTexture для временных текстур
  - **Реализовано:** PixelatePass.cs, PixelateFeature.cs

- [x] **2.2** Простой Full-Screen эффект: Инверсия цветов
  - Blit с кастомным материалом через Blitter.BlitTexture
  - **Реализовано:** InvertColors.shader, InvertColorsPass.cs

- [x] **2.3** Grayscale с управляемым параметром
  - Shader с _Intensity property
  - VolumeComponent для управления эффектом
  - **Реализовано:** Grayscale.shader, GrayscalePass.cs, GrayscaleVolumeComponent.cs

- [x] **2.4** Vignette эффект с нуля
  - Математика виньетки (distance from center)
  - Smooth falloff, настраиваемые параметры
  - **Реализовано:** Vignette.shader, VignettePass.cs, VignetteFeature.cs

### Этап 3: Render Graph System (Современный подход) ✅
**Цель:** Освоить новый API рендер-графа Unity

- [x] **3.1** Концепция Render Graph
  - Декларативный vs императивный подход
  - Автоматическое управление ресурсами
  - AllowGlobalStateModification для изменения шейдер-параметров

- [x] **3.2** Структура Render Graph Pass
  - PassData классы
  - RecordRenderGraph метод
  - builder.UseTexture и AccessFlags
  - **Изучено на практике во всех эффектах**

- [x] **3.3** Чтение и запись ресурсов
  - SetRenderAttachment для записи
  - UseTexture с AccessFlags.Read
  - **Реализовано:** Multi-pass Gaussian Blur

- [x] **3.4** Создание временных текстур
  - renderGraph.CreateTexture
  - Уникальные текстуры для каждого прохода
  - **Реализовано:** GaussianBlur.shader, BlurPass.cs (с iterations)

### Этап 4: Продвинутые Renderer Features ✅ (частично)
**Цель:** Создавать сложные визуальные эффекты

- [x] **4.1** Outline эффект через Sobel Edge Detection
  - Sobel edge detection по luminance
  - Настраиваемые параметры (thickness, threshold, colors)
  - **Реализовано:** SobelOutline.shader, OutlinePass.cs, OutlineFeature.cs

- [ ] **4.2** Stencil Buffer и Render Objects
  - Stencil operations в шейдерах
  - URP Render Objects feature
  - **Кейс:** Контур для объектов сквозь стены

- [ ] **4.3** Kawase Blur — оптимизированный blur
  - Downsampling + upsampling pyramid
  - Сравнение с Gaussian blur
  - **Кейс:** Bloom эффект

- [ ] **4.4** Доступ к Depth и Normals буферам
  - _CameraDepthTexture, _CameraNormalsTexture
  - DepthNormals prepass
  - **Кейс:** Depth-based outline, SSAO preparation

- [ ] **4.5** Screen Space Reflections (SSR) — упрощённая версия
  - Ray marching в screen space
  - Отражения только для горизонтальных поверхностей
  - Fallback на Cubemap/Reflection Probe
  - **Кейс:** Отражения на полу для стилизованной графики

### Этап 5: Custom Render Pipeline с нуля 🆕
**Цель:** Научиться создавать полноценный рендер-пайплайн

- [ ] **5.1** Архитектура Custom SRP
  - RenderPipelineAsset — точка входа
  - RenderPipeline — логика рендеринга
  - Жизненный цикл: Render() для каждой камеры
  - **Практика:** Минимальный пайплайн с очисткой экрана

- [ ] **5.2** Рендеринг объектов (DrawRenderers)
  - ScriptableRenderContext.DrawRenderers()
  - FilteringSettings — что рендерить
  - DrawingSettings — как рендерить (shader passes)
  - SortingSettings — порядок отрисовки
  - **Практика:** Рендерим Unlit объекты

- [ ] **5.3** Управление камерами и render targets
  - Настройка viewport и projection matrix
  - CullingResults для отсечения невидимых объектов
  - Несколько камер и render targets
  - **Практика:** Multi-camera setup

- [ ] **5.4** Освещение в Custom SRP
  - Передача light data в шейдеры
  - Per-object lighting vs per-pixel lighting
  - Directional, Point, Spot lights
  - **Практика:** Простой Lambert diffuse lighting

- [ ] **5.5** Тени в Custom SRP
  - Shadow maps — концепция
  - Shadow caster pass
  - Shadow receiver pass
  - Cascaded Shadow Maps для directional light
  - **Практика:** Базовые тени от directional light

- [ ] **5.6** Пост-обработка в Custom SRP
  - Рендер в off-screen buffer
  - Full-screen pass
  - Интеграция эффектов в кастомный пайплайн
  - **Практика:** Bloom в нашем Custom SRP

### Этап 6: Оптимизация и Production
**Цель:** Подготовить знания для реальных проектов

- [ ] **6.1** Profiling SRP
  - Frame Debugger для анализа passes
  - RenderDoc интеграция
  - **Практика:** Оптимизация своих Renderer Features

- [ ] **6.2** Conditional Rendering
  - Отключение passes по условию
  - LOD для эффектов
  - **Практика:** Quality settings для своих эффектов

- [ ] **6.3** Батчинг и инстансинг через SRP
  - SRP Batcher совместимость
  - GPU Instancing в custom passes
  - **Практика:** Оптимизация рендеринга частиц

- [ ] **6.4** Mobile оптимизация
  - Tile-based rendering considerations
  - Reduced precision (half vs float)
  - **Кейс:** Адаптация эффектов для мобильных

---

## Реальные кейсы из игровой индустрии

### 🎮 Кейс 1: "Режим сканирования" (Metroid Prime стиль)
- Переключение в монохромный режим
- Outline для интерактивных объектов
- UI overlay поверх эффекта

### 🎮 Кейс 2: "Время замедления" (Max Payne стиль)
- Radial blur от центра экрана
- Desaturation + color tint
- Motion blur усиление

### 🎮 Кейс 3: "Взгляд хищника" (Predator Vision)
- Thermal imaging эффект
- Объекты подсвечиваются по температуре
- Edge glow для живых существ

### 🎮 Кейс 4: "Подводный мир"
- Caustics projection
- Depth fog с изменением цвета
- Искажение UV (underwater distortion)

### 🎮 Кейс 5: "Пиксельный ретро-фильтр"
- Downsampling до низкого разрешения
- Color quantization (палитра)
- Dithering паттерн

---

## Текущий прогресс SRP
**Статус:** 🚀 Этапы 1-3 завершены, 4.1 выполнен
**Текущий этап:** 4.2 — Stencil Buffer и Render Objects

### Созданные файлы SRP (Assets/SRP/)

**Шейдеры (Shaders/):**
- `InvertColors.shader` — Инверсия цветов
- `Pixelate.shader` — Пикселизация
- `Grayscale.shader` — Обесцвечивание
- `Vignette.shader` — Виньетка
- `GaussianBlur.shader` — Gaussian blur
- `SobelOutline.shader` — Outline через Sobel

**Passes (Features/):**
- `DebugRenderPass.cs` — Отладочный pass
- `InvertColorsPass.cs` — Инверсия
- `PixelatePass.cs` — Пикселизация
- `GrayscalePass.cs` — Grayscale
- `VignettePass.cs` — Виньетка
- `BlurPass.cs` — Multi-pass blur
- `OutlinePass.cs` — Sobel outline

**Features (Features/):**
- `DebugRendererFeature.cs`
- `InvertColorsFeature.cs`
- `PixelateFeature.cs`
- `GrayscaleFeature.cs`
- `VignetteFeature.cs`
- `BlurFeature.cs`
- `OutlineFeature.cs`

**Volume Components (Features/):**
- `GrayscaleVolumeComponent.cs`
- `BlurVolumeComponent.cs`
- `OutlineVolumeComponent.cs`

---

## Ресурсы для изучения
- Unity Graphics GitHub: `/unity-technologies/graphics`
- URP Documentation
- Render Graph System Guide
- Frame Debugger Tutorial

---

## Глоссарий SRP

| Термин | Описание |
|--------|----------|
| **RenderPipelineAsset** | ScriptableObject с настройками пайплайна |
| **ScriptableRenderer** | Определяет какие passes выполняются |
| **ScriptableRenderPass** | Один шаг рендеринга (draw calls, blit) |
| **ScriptableRendererFeature** | Модуль для добавления кастомных passes |
| **RenderPassEvent** | Момент инъекции pass в пайплайн |
| **RTHandle** | Умный handle для render textures |
| **Render Graph** | Декларативная система описания рендеринга |
| **Blit** | Копирование текстуры с опциональным шейдером |
