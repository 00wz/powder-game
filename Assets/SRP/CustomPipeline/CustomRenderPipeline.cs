using UnityEngine;
using UnityEngine.Rendering;

/// <summary>
/// Основной класс рендер-пайплайна.
/// Выполняет рендеринг всех камер каждый кадр.
///
/// Использует современный RendererList API (Unity 2023+/Unity 6+)
///
/// Урок 13-15: Custom SRP - Архитектура, освещение и тени
/// </summary>
public class CustomRenderPipeline : RenderPipeline
{
    private CustomRenderPipelineAsset settings;
    
    // Класс для управления освещением
    private Lighting lighting = new Lighting();
    
    // Класс для управления тенями
    private Shadows shadows = new Shadows();
    
    // ShaderTagId определяет какой Pass шейдера использовать
    // "SRPDefaultUnlit" — стандартный тег для Unlit шейдеров
    // ВАЖНО: Шейдеры БЕЗ тега LightMode автоматически получают "SRPDefaultUnlit"!
    private static readonly ShaderTagId[] supportedShaderTagIds =
    {
        new ShaderTagId("SRPDefaultUnlit"),       // Шейдеры без LightMode тега попадают сюда!
        new ShaderTagId("CustomLit"),             // Наш Custom Lit шейдер с освещением
        new ShaderTagId("UniversalForward"),      // Поддержка URP шейдеров
        new ShaderTagId("UniversalForwardOnly"),
        new ShaderTagId("LightweightForward"),    // Устаревший LWRP
    };
    
    // Шейдеры для отображения неподдерживаемых материалов (debug)
    private static readonly ShaderTagId[] legacyShaderTagIds = 
    {
        new ShaderTagId("Always"),
        new ShaderTagId("ForwardBase"),
        new ShaderTagId("PrepassBase"),
        new ShaderTagId("Vertex"),
        new ShaderTagId("VertexLMRGBM"),
        new ShaderTagId("VertexLM"),
    };
    
    private Material errorMaterial;
    
    public CustomRenderPipeline(CustomRenderPipelineAsset asset)
    {
        settings = asset;
        
        // Включаем SRP Batcher для оптимизации батчинга
        GraphicsSettings.useScriptableRenderPipelineBatching = asset.UseSRPBatcher;
        
        // Используем линейное цветовое пространство (если проект настроен на Linear)
        GraphicsSettings.lightsUseLinearIntensity = true;
        
        // Настраиваем параметры теней из asset
        shadows.Setup(
            asset.ShadowMapSize,
            asset.ShadowDistance,
            asset.ShadowBias,
            asset.ShadowStrength
        );
    }
    
    /// <summary>
    /// Главный метод рендеринга — вызывается каждый кадр.
    /// Рендерит все активные камеры.
    /// </summary>
    protected override void Render(ScriptableRenderContext context, Camera[] cameras)
    {
        // Рендерим каждую камеру по отдельности
        foreach (Camera camera in cameras)
        {
            RenderCamera(context, camera);
        }
    }
    
    /// <summary>
    /// Рендерит одну камеру.
    /// Использует современный RendererList API.
    /// </summary>
    private void RenderCamera(ScriptableRenderContext context, Camera camera)
    {
        // =====================================
        // 1. SETUP CAMERA
        // =====================================
        
        // Устанавливаем VP матрицы и другие параметры камеры
        context.SetupCameraProperties(camera);
        
        // =====================================
        // 2. CULLING
        // =====================================
        
        // Получаем параметры для culling
        if (!camera.TryGetCullingParameters(out ScriptableCullingParameters cullingParams))
        {
            // Камера не может делать culling (например, viewport = 0)
            return;
        }
        
        // Выполняем culling — получаем список видимых объектов
        CullingResults cullingResults = context.Cull(ref cullingParams);
        
        // =====================================
        // 3. SETUP COMMAND BUFFER
        // =====================================
        
        // CommandBuffer — буфер команд для GPU
        CommandBuffer cmd = new CommandBuffer { name = camera.name };
        
        // Добавляем профилирование для Frame Debugger
        cmd.BeginSample(camera.name);
        context.ExecuteCommandBuffer(cmd);
        cmd.Clear();
        
        // =====================================
        // 4. CLEAR RENDER TARGET
        // =====================================
        
        CameraClearFlags clearFlags = camera.clearFlags;
        
        // Определяем что очищать
        bool clearDepth = clearFlags <= CameraClearFlags.Depth;
        bool clearColor = clearFlags == CameraClearFlags.Color || 
                          clearFlags == CameraClearFlags.SolidColor;
        
        // Используем цвет камеры или цвет по умолчанию
        Color backgroundColor = clearColor ? camera.backgroundColor : settings.DefaultClearColor;
        
        cmd.ClearRenderTarget(clearDepth, clearColor, backgroundColor);
        context.ExecuteCommandBuffer(cmd);
        cmd.Clear();
        
        // =====================================
        // 5. SHADOW PASS
        // =====================================
        
        // Рендерим shadow map ПЕРЕД основным рендерингом
        // Shadow pass использует свой render target и VP матрицы
        shadows.Render(context, ref cullingResults, cmd);
        
        // Восстанавливаем camera render target после shadow pass
        cmd.SetRenderTarget(BuiltinRenderTextureType.CameraTarget);
        context.ExecuteCommandBuffer(cmd);
        cmd.Clear();
        
        // Восстанавливаем VP матрицы камеры
        context.SetupCameraProperties(camera);
        
        // =====================================
        // 6. SETUP LIGHTING
        // =====================================
        
        // Настраиваем освещение ПЕРЕД рендерингом объектов!
        // Это передаёт данные о видимых источниках света в шейдеры
        lighting.Setup(cmd, ref cullingResults);
        context.ExecuteCommandBuffer(cmd);
        cmd.Clear();
        
        // =====================================
        // 7. DRAW OPAQUE OBJECTS (RendererList API)
        // =====================================
        
        // Сортировка: ближние объекты сначала (для early-z optimization)
        SortingSettings sortingSettings = new SortingSettings(camera)
        {
            criteria = SortingCriteria.CommonOpaque
        };
        
        // Настройки рисования: какой shader pass использовать
        DrawingSettings drawingSettings = CreateDrawingSettings(sortingSettings);
        
        // Фильтрация: только opaque объекты (RenderQueue 0-2500)
        FilteringSettings filteringSettings = new FilteringSettings(RenderQueueRange.opaque);
        
        // Создаём RendererList — современный способ рендеринга
        RendererListParams opaqueParams = new RendererListParams(cullingResults, drawingSettings, filteringSettings);
        RendererList opaqueList = context.CreateRendererList(ref opaqueParams);
        
        // Рисуем opaque объекты через CommandBuffer
        cmd.DrawRendererList(opaqueList);
        context.ExecuteCommandBuffer(cmd);
        cmd.Clear();
        
        // =====================================
        // 8. DRAW SKYBOX (RendererList API)
        // =====================================
        
        if (settings.RenderSkybox &&
            camera.clearFlags == CameraClearFlags.Skybox &&
            RenderSettings.skybox != null)
        {
            // Создаём RendererList для skybox
            RendererList skyboxList = context.CreateSkyboxRendererList(camera);
            cmd.DrawRendererList(skyboxList);
            context.ExecuteCommandBuffer(cmd);
            cmd.Clear();
        }
        
        // =====================================
        // 9. DRAW TRANSPARENT OBJECTS
        // =====================================
        
        if (settings.RenderTransparent)
        {
            // Сортировка: дальние объекты сначала (для корректного смешивания)
            sortingSettings.criteria = SortingCriteria.CommonTransparent;
            drawingSettings.sortingSettings = sortingSettings;
            
            // Фильтрация: только transparent объекты (RenderQueue 2501-5000)
            filteringSettings.renderQueueRange = RenderQueueRange.transparent;
            
            // Создаём RendererList для прозрачных объектов
            RendererListParams transparentParams = new RendererListParams(cullingResults, drawingSettings, filteringSettings);
            RendererList transparentList = context.CreateRendererList(ref transparentParams);
            
            cmd.DrawRendererList(transparentList);
            context.ExecuteCommandBuffer(cmd);
            cmd.Clear();
        }
        
        // =====================================
        // 10. DRAW UNSUPPORTED SHADERS (DEBUG)
        // =====================================
        
#if UNITY_EDITOR
        if (settings.ShowUnsupportedShaders)
        {
            DrawUnsupportedShaders(context, cullingResults, camera, cmd);
        }
        
        // Рисуем Gizmos в редакторе
        if (UnityEditor.Handles.ShouldRenderGizmos())
        {
            context.DrawGizmos(camera, GizmoSubset.PreImageEffects);
            context.DrawGizmos(camera, GizmoSubset.PostImageEffects);
        }
#endif
        
        // =====================================
        // 11. END PROFILING & SUBMIT
        // =====================================
        
        cmd.EndSample(camera.name);
        context.ExecuteCommandBuffer(cmd);
        cmd.Release();
        
        // ВАЖНО: Submit отправляет все команды на GPU!
        // Без этого ничего не отрендерится.
        context.Submit();
    }
    
    /// <summary>
    /// Создаёт DrawingSettings с поддержкой нескольких shader tags.
    /// </summary>
    private DrawingSettings CreateDrawingSettings(SortingSettings sortingSettings)
    {
        // Создаём настройки с первым тегом
        DrawingSettings drawingSettings = new DrawingSettings(
            supportedShaderTagIds[0], 
            sortingSettings
        );
        
        // Добавляем остальные теги
        for (int i = 1; i < supportedShaderTagIds.Length; i++)
        {
            drawingSettings.SetShaderPassName(i, supportedShaderTagIds[i]);
        }
        
        return drawingSettings;
    }
    
#if UNITY_EDITOR
    /// <summary>
    /// Рисует объекты с неподдерживаемыми шейдерами розовым цветом.
    /// Помогает найти проблемные материалы в сцене.
    /// Использует RendererList API.
    /// </summary>
    private void DrawUnsupportedShaders(
        ScriptableRenderContext context, 
        CullingResults cullingResults, 
        Camera camera,
        CommandBuffer cmd)
    {
        // Создаём error material (розовый цвет)
        if (errorMaterial == null)
        {
            errorMaterial = new Material(Shader.Find("Hidden/InternalErrorShader"));
        }
        
        SortingSettings sortingSettings = new SortingSettings(camera);
        DrawingSettings drawingSettings = new DrawingSettings(
            legacyShaderTagIds[0], 
            sortingSettings
        )
        {
            overrideMaterial = errorMaterial,
            overrideMaterialPassIndex = 0
        };
        
        // Добавляем все legacy теги
        for (int i = 1; i < legacyShaderTagIds.Length; i++)
        {
            drawingSettings.SetShaderPassName(i, legacyShaderTagIds[i]);
        }
        
        FilteringSettings filteringSettings = FilteringSettings.defaultValue;
        
        // Создаём и рисуем RendererList
        RendererListParams errorParams = new RendererListParams(cullingResults, drawingSettings, filteringSettings);
        RendererList errorList = context.CreateRendererList(ref errorParams);
        
        cmd.DrawRendererList(errorList);
        context.ExecuteCommandBuffer(cmd);
        cmd.Clear();
    }
#endif
    
    /// <summary>
    /// Вызывается при уничтожении пайплайна.
    /// Освобождаем ресурсы.
    /// </summary>
    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        
        // Освобождаем ресурсы теней
        shadows.Cleanup();
        
        if (errorMaterial != null)
        {
#if UNITY_EDITOR
            Object.DestroyImmediate(errorMaterial);
#else
            Object.Destroy(errorMaterial);
#endif
            errorMaterial = null;
        }
    }
}
