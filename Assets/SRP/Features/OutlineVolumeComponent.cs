using System;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

[Serializable, VolumeComponentMenu("Custom Post-processing/Outline")]
public class OutlineVolumeComponent : VolumeComponent, IPostProcessComponent
{
    [Tooltip("Толщина линий")]
    public ClampedFloatParameter thickness = new ClampedFloatParameter(1f, 0.5f, 5f);
    
    [Tooltip("Порог обнаружения границ (меньше = больше линий)")]
    public ClampedFloatParameter threshold = new ClampedFloatParameter(0.1f, 0.01f, 1f);
    
    [Tooltip("Цвет контура")]
    public ColorParameter outlineColor = new ColorParameter(Color.black, true, false, true);
    
    [Tooltip("Цвет фона (при colorMix = 0)")]
    public ColorParameter backgroundColor = new ColorParameter(Color.white, true, false, true);
    
    [Tooltip("0 = только контур на фоне, 1 = контур поверх изображения")]
    public ClampedFloatParameter colorMix = new ClampedFloatParameter(1f, 0f, 1f);
    
    [Tooltip("Включить эффект")]
    public BoolParameter enabled = new BoolParameter(false);
    
    public bool IsActive() => enabled.value;
    public bool IsTileCompatible() => true;
}
