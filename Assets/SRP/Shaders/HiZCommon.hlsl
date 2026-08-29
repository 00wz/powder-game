#ifndef HIZ_COMMON_INCLUDED
#define HIZ_COMMON_INCLUDED

// Must match SSRPass.HiZMaxMips on the C# side.
#define HIZ_MAX_MIPS 12

TEXTURE2D(_HiZMip0);
TEXTURE2D(_HiZMip1);
TEXTURE2D(_HiZMip2);
TEXTURE2D(_HiZMip3);
TEXTURE2D(_HiZMip4);
TEXTURE2D(_HiZMip5);
TEXTURE2D(_HiZMip6);
TEXTURE2D(_HiZMip7);
TEXTURE2D(_HiZMip8);
TEXTURE2D(_HiZMip9);
TEXTURE2D(_HiZMip10);
TEXTURE2D(_HiZMip11);
// sampler_PointClamp is a URP builtin global sampler (declared in GlobalSamplers.hlsl,
// pulled in via Core.hlsl) - do not redeclare it here.

// Number of levels actually generated this frame (<= HIZ_MAX_MIPS).
float _HiZLevelCount;

// Per level: xy = resolution in texels, zw = 1/resolution (texel size).
float4 _HiZMipInfo[HIZ_MAX_MIPS];

// Real (unpadded) screen resolution the pyramid was built from: xy = size, zw = 1/size.
// The pyramid textures themselves are padded up to a power of two (see
// SSRPass.BuildHiZPyramid / HiZDepthPyramid.shader), so tracing must clamp against this
// real size, not the padded per-level sizes in _HiZMipInfo.
float4 _HiZScreenSize;

// Returns (min, max) raw device depth stored at the given pyramid level.
// `level` must already be clamped to [0, _HiZLevelCount - 1] by the caller.
float2 SampleHiZLevel(float2 uv, int level)
{
    float4 texel;
    if (level == 0)       texel = SAMPLE_TEXTURE2D_LOD(_HiZMip0, sampler_PointClamp, uv, 0);
    else if (level == 1)  texel = SAMPLE_TEXTURE2D_LOD(_HiZMip1, sampler_PointClamp, uv, 0);
    else if (level == 2)  texel = SAMPLE_TEXTURE2D_LOD(_HiZMip2, sampler_PointClamp, uv, 0);
    else if (level == 3)  texel = SAMPLE_TEXTURE2D_LOD(_HiZMip3, sampler_PointClamp, uv, 0);
    else if (level == 4)  texel = SAMPLE_TEXTURE2D_LOD(_HiZMip4, sampler_PointClamp, uv, 0);
    else if (level == 5)  texel = SAMPLE_TEXTURE2D_LOD(_HiZMip5, sampler_PointClamp, uv, 0);
    else if (level == 6)  texel = SAMPLE_TEXTURE2D_LOD(_HiZMip6, sampler_PointClamp, uv, 0);
    else if (level == 7)  texel = SAMPLE_TEXTURE2D_LOD(_HiZMip7, sampler_PointClamp, uv, 0);
    else if (level == 8)  texel = SAMPLE_TEXTURE2D_LOD(_HiZMip8, sampler_PointClamp, uv, 0);
    else if (level == 9)  texel = SAMPLE_TEXTURE2D_LOD(_HiZMip9, sampler_PointClamp, uv, 0);
    else if (level == 10) texel = SAMPLE_TEXTURE2D_LOD(_HiZMip10, sampler_PointClamp, uv, 0);
    else                  texel = SAMPLE_TEXTURE2D_LOD(_HiZMip11, sampler_PointClamp, uv, 0);
    return texel.rg;
}

// Shared depth-space conversions (moved here from SSR.shader so HiZDepthPyramid.shader can
// reuse them too, e.g. for its own normal-aware min/max widening - see InitFrag).

// Linearized [0,1] depth (0 = near, 1 = far), accounting for camera type.
float GetLinearDepth01(float rawDepth)
{
    if (unity_OrthoParams.w > 0.5) // Orthographic
    {
        #if UNITY_REVERSED_Z
            return 1.0 - rawDepth;
        #else
            return rawDepth;
        #endif
    }
    return Linear01Depth(rawDepth, _ZBufferParams);
}

// Linear eye-space depth, accounting for camera type.
float GetLinearEyeDepth(float rawDepth)
{
    if (unity_OrthoParams.w > 0.5) // Orthographic
    {
        float linear01 = GetLinearDepth01(rawDepth);
        return lerp(_ProjectionParams.y, _ProjectionParams.z, linear01);
    }
    return LinearEyeDepth(rawDepth, _ZBufferParams);
}

// Reconstructs the view-space position from a screen UV and raw device depth.
float3 ReconstructViewPosition(float2 uv, float depth)
{
    // undo ComputeScreenPos Y-flip
    if (_ProjectionParams.x < 0)
    {
        uv.y = 1.0 - uv.y;
    }

    float4 clipPos;
    clipPos.xy = uv * 2.0 - 1.0;

    clipPos.z = depth;
    clipPos.w = 1.0;

    float4 viewPos = mul(UNITY_MATRIX_I_P, clipPos);
    return viewPos.xyz / viewPos.w;
}

// Inverse of GetLinearEyeDepth: converts a linear eye-space depth back into raw device
// depth. Used wherever a fixed world-space distance (e.g. _Thickness, or a pixel's local
// depth extent) needs to be applied to a stored raw depth value - eye depth is the only one
// of the two spaces where "add a fixed distance" is meaningful, since raw depth is highly
// non-linear in true distance.
float EyeDepthToRawDepth(float eyeDepth)
{
    if (unity_OrthoParams.w > 0.5) // Orthographic
    {
        float linear01 = (eyeDepth - _ProjectionParams.y) / (_ProjectionParams.z - _ProjectionParams.y);
        #if UNITY_REVERSED_Z
            return 1.0 - linear01;
        #else
            return linear01;
        #endif
    }
    float invEye = 1.0 / max(eyeDepth, 1e-6);
    return (invEye - _ZBufferParams.w) / _ZBufferParams.z;
}

#endif
