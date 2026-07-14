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

#endif
