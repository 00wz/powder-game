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

### Этап 1: Архитектура SRP (Теория + Практика)
**Цель:** Понять, как устроен рендер-пайплайн изнутри

- [ ] **1.1** Архитектура Render Pipeline
  - Что такое SRP и зачем он нужен
  - RenderPipelineAsset vs ScriptableRenderer
  - Сравнение Built-in, URP, HDRP
  - **Практика:** Изучить структуру URP Asset в проекте

- [ ] **1.2** ScriptableRenderPass — основной строительный блок
  - Жизненный цикл: Create → Configure → Execute → Cleanup
  - RenderPassEvent (injection points)
  - **Практика:** Создать "пустой" pass, который только логирует этапы

- [ ] **1.3** ScriptableRendererFeature — интеграция в пайплайн
  - Добавление кастомных фич в Renderer
  - AddRenderPasses и SetupRenderPasses
  - **Практика:** Renderer Feature, который меняет цвет экрана

### Этап 2: Blit-операции и Full-Screen эффекты
**Цель:** Освоить базовые операции пост-обработки

- [ ] **2.1** RTHandle и управление текстурами
  - Разница между RenderTexture и RTHandle
  - Правила работы с камерными буферами
  - **Практика:** Копирование camera color в temporary texture

- [ ] **2.2** Простой Full-Screen эффект: Инверсия цветов
  - Blit с кастомным материалом
  - ConfigureInput для запроса ресурсов
  - **Кейс:** Эффект "негатива" для UI паузы

- [ ] **2.3** Grayscale с управляемым параметром
  - Shader с _Intensity property
  - VolumeComponent для управления эффектом
  - **Кейс:** Плавное обесцвечивание при смерти персонажа

- [ ] **2.4** Vignette эффект с нуля
  - Математика виньетки (distance from center)
  - Smooth falloff
  - **Кейс:** Эффект повреждения персонажа

### Этап 3: Render Graph System (Современный подход)
**Цель:** Освоить новый API рендер-графа Unity

- [ ] **3.1** Концепция Render Graph
  - Почему Render Graph вместо immediate mode
  - Декларативный vs императивный подход
  - Автоматическое управление ресурсами

- [ ] **3.2** Структура Render Graph Pass
  - PassData классы
  - RecordRenderGraph метод
  - builder.UseTexture и AccessFlags
  - **Практика:** Переписать Grayscale на Render Graph

- [ ] **3.3** Чтение и запись ресурсов
  - SetRenderAttachment, SetInputAttachment
  - Framebuffer Fetch для оптимизации
  - **Практика:** Multi-pass эффект (blur)

- [ ] **3.4** Создание временных текстур
  - renderGraph.CreateTexture
  - TextureDesc настройка
  - **Кейс:** Two-pass Gaussian Blur

### Этап 4: Продвинутые Renderer Features
**Цель:** Создавать сложные визуальные эффекты

- [ ] **4.1** Outline эффект через Depth + Normals
  - Sobel edge detection
  - Доступ к _CameraDepthTexture и _CameraNormalsTexture
  - **Кейс:** Выделение объектов при наведении мыши

- [ ] **4.2** Outline через Stencil Buffer
  - Stencil operations в шейдерах
  - Render Objects с Layer Mask
  - **Кейс:** Контур для выделенных объектов сквозь стены

- [ ] **4.3** Kawase Blur — оптимизированный blur
  - Downsampling + upsampling pyramid
  - Kernel optimization
  - **Кейс:** Эффект глубины резкости (DoF) для меню

- [ ] **4.4** Screen Space Reflections (SSR) — упрощённая версия
  - Ray marching в screen space
  - Fallback на Cubemap
  - **Кейс:** Отражения на полу для стилизованной графики

### Этап 5: Интеграция с Powder Game
**Цель:** Применить знания SRP к текущему проекту

- [ ] **5.1** Custom Particle Renderer Feature
  - Отдельный pass для рендеринга симуляции
  - Контроль порядка отрисовки
  - **Кейс:** Частицы всегда поверх фона

- [ ] **5.2** Glow для газа через SRP
  - Bloom только для определённого слоя
  - Threshold по яркости
  - **Кейс:** Светящийся газ без влияния на UI

- [ ] **5.3** Heat Distortion эффект
  - UV displacement на основе temperature field
  - Normal map generation from field
  - **Кейс:** Искажение воздуха над горячими частицами

- [ ] **5.4** Ambient Occlusion для частиц
  - Screen Space AO адаптированный для 2D
  - Sampling из particle density texture
  - **Кейс:** Глубина и объём для песка

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
**Статус:** 🚀 Курс начат
**Текущий этап:** 1.1 — Архитектура Render Pipeline

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
