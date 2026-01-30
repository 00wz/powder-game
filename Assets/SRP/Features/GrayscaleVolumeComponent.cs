using System;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

// SupportedOnRenderPipeline указывает что этот компонент для URP
// VolumeComponentMenu определяет где в меню появится компонент
[Serializable]
[VolumeComponentMenu("Custom Post-processing/Grayscale")]
[SupportedOnRenderPipeline(typeof(UniversalRenderPipelineAsset))]
public class GrayscaleVolumeComponent : VolumeComponent, IPostProcessComponent
{
    // ClampedFloatParameter автоматически ограничивает значение
    // Первый параметр - значение по умолчанию
    [Tooltip("Интенсивность эффекта обесцвечивания")]
    public ClampedFloatParameter intensity = new ClampedFloatParameter(0f, 0f, 1f);
    
    // IPostProcessComponent требует этот метод
    // Возвращает true если эффект активен
    public bool IsActive() => intensity.value > 0.001f;
    
    // Deprecated в новых версиях, но нужен для совместимости
    public bool IsTileCompatible() => true;
}
