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

// Estimates the raw device depth range a single fragment's pixel footprint actually spans,
// by treating the fragment as an infinite plane (its own view-space position + normal) and
// solving where the two screen-space corners diagonally aligned with the plane's slope
// (the ones where depth deviates the most) intersect that plane. A depth buffer only ever
// stores one point-sample per pixel, which is a poor stand-in for a fragment's true extent
// at grazing angles (surface normal near-perpendicular to the view direction): depth then
// changes very fast from one screen pixel to the next, so a single stored value undersells
// how far a legitimate ray hit can land from it - producing periodic banding/striping in SSR
// (a ray that should land on this fragment misses by more than _Thickness).
//
// This deliberately does NOT sample neighboring texels (e.g. via ddx/ddy of depth): screen-
// space derivatives are computed from the actual rasterized 2x2 quad, so at a genuine
// silhouette edge (this pixel's object against unrelated background/another object) they
// report a huge, real jump that has nothing to do with surface slope - widening by that
// amount would corrupt the estimate at every object edge in the scene, not just at grazing
// angles. This function only ever depends on THIS fragment's own normal and depth, so a
// silhouette next door cannot contaminate it.
//
// Math: the ray/plane intersection for a view-space ray of direction `dir` against the plane
// (P0, N) is t = dot(N,P0) / dot(N,dir). The numerator is fixed; the denominator is LINEAR in
// the ray direction offset (dot product), so offsetting by half a pixel in X changes it by
// deltaX = 0.5*N.x*pixelWorldSize.x/eyeDepth0 (deltaY analogously), and offsetting by both
// X and Y at once (a footprint corner) changes it by exactly +-deltaX +-deltaY - no need to
// build the diagonal ray explicitly. Since t is monotonic in the denominator (for a
// same-signed denominator), the extrema over all 4 corners occur at just the 2 corners where
// the denominator is most different from its unperturbed value, i.e. where both deltas share
// the sign of N.x/N.y (and the opposite) - so only two candidate depths need to be solved.
//
// Requires DeclareNormalsTexture.hlsl (for SampleSceneNormals) to be included before this
// file by the caller - true today for both SSR.shader and HiZDepthPyramid.shader.
void EstimateFragmentDepthRange(float2 uv, float rawDepth, float2 screenSizePixels, out float rawMin, out float rawMax)
{
    float3 normalWS = SampleSceneNormals(uv);
    float3 N = normalize(mul((float3x3)UNITY_MATRIX_V, normalWS));
    float3 P0 = ReconstructViewPosition(uv, rawDepth);
    float eyeDepth0 = -P0.z;

    float eyeMin, eyeMax;

    if (unity_OrthoParams.w > 0.5)
    {
        // Orthographic: rays are parallel, so "the neighboring pixel's ray" is exactly "this
        // ray shifted by one pixel's world size at constant depth" - the corner deviation is
        // then EXACTLY the sum of the two half-pixel axis-aligned slope contributions (no
        // approximation, unlike the perspective case below).
        float2 orthoSize = float2(2.0 / UNITY_MATRIX_P._m00, 2.0 / UNITY_MATRIX_P._m11);
        float2 pixelWorldSize = orthoSize / screenSizePixels;
        float safeNz = abs(N.z) > 1e-4 ? N.z : (N.z >= 0.0 ? 1e-4 : -1e-4);
        float2 slope = N.xy / safeNz; // dz/dx, dz/dy along the plane
        float halfExtentEye = abs(slope.x) * 0.5 * pixelWorldSize.x + abs(slope.y) * 0.5 * pixelWorldSize.y;
        eyeMin = eyeDepth0 - halfExtentEye;
        eyeMax = eyeDepth0 + halfExtentEye;
    }
    else
    {
        float2 tanHalfFov = float2(1.0 / UNITY_MATRIX_P._m00, 1.0 / UNITY_MATRIX_P._m11);
        float2 pixelWorldSize = 2.0 * tanHalfFov * eyeDepth0 / screenSizePixels;

        float3 dir0 = P0 / eyeDepth0; // ray direction, Z-component normalized to -1
        float denom0 = dot(N, dir0);
        float nDotP0 = dot(N, P0);

        float halfDenomSpread = 0.5 * (abs(N.x) * pixelWorldSize.x + abs(N.y) * pixelWorldSize.y) / eyeDepth0;
        float denomHigh = denom0 + halfDenomSpread;
        float denomLow = denom0 - halfDenomSpread;
        // Guarded explicitly (not left to a saturate() at the end) - a near-zero denominator
        // means that corner's ray is nearly parallel to the plane (grazing), which is exactly
        // the case being estimated for, not one to silently ignore.
        float safeDenomHigh = abs(denomHigh) > 1e-6 ? denomHigh : (denomHigh >= 0.0 ? 1e-6 : -1e-6);
        float safeDenomLow = abs(denomLow) > 1e-6 ? denomLow : (denomLow >= 0.0 ? 1e-6 : -1e-6);

        float tHigh = nDotP0 / safeDenomHigh;
        float tLow = nDotP0 / safeDenomLow;

        eyeMin = min(min(tHigh, tLow), eyeDepth0);
        eyeMax = max(max(tHigh, tLow), eyeDepth0);
    }

    // EyeDepthToRawDepth's monotonic direction flips with UNITY_REVERSED_Z, so sort the
    // converted pair explicitly rather than assuming eyeMin maps to rawMin.
    float rA = EyeDepthToRawDepth(eyeMin);
    float rB = EyeDepthToRawDepth(eyeMax);
    rawMin = min(rA, rB);
    rawMax = max(rA, rB);
}

#endif
