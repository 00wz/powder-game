using System;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

[Serializable, VolumeComponentMenu("Custom Post-processing/Blur")]
public class BlurVolumeComponent : VolumeComponent, IPostProcessComponent
{
    [Tooltip("Сила размытия")]
    public ClampedFloatParameter intensity = new ClampedFloatParameter(0f, 0f, 5f);
    
    [Tooltip("Количество итераций (больше = сильнее размытие, но дороже)")]
    public ClampedIntParameter iterations = new ClampedIntParameter(1, 1, 4);
    
    public bool IsActive() => intensity.value > 0.001f;
    public bool IsTileCompatible() => true;
}
