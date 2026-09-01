// Builds a Hi-Z min/max depth pyramid from the camera depth texture using plain
// fragment-shader raster passes only (no compute shaders), so it works identically
// on every platform URP supports, including WebGL.
//
// Pass 0 "Init"       copies raw device depth into mip 0, padded up to the next
//                      power-of-two canvas (padding filled with the "no occluder"
//                      sentinel depth).
// Pass 1 "Downsample" reduces the previous level's (min, max) 2x2 neighborhood into
//                      the next level.
//
// The base resolution is padded to a power of two (see SSRPass.BuildHiZPyramid) so
// that every level is EXACTLY half the previous one in both dimensions, with no
// rounding ambiguity. This is deliberate: an earlier version used a tight
// ceil(size/2) chain to avoid the padding waste, but whenever an odd size appeared
// along the chain the level-to-level ratio stopped being exactly 2x, which made a
// coarse cell's on-screen footprint not line up with exactly 4 finer cells -
// looking like corrupted data (in the debug view, and potentially in tracing) even
// though the reduction itself was gap-free. Power-of-two padding removes that whole
// class of bug at the cost of some wasted texels at the padded edge.
//
// Each level is a separate render target (see SSRPass.BuildHiZPyramid) rather than
// a single texture with a real mip chain, so a pass never reads and writes the same
// GPU resource at different mip levels - this avoids relying on RenderGraph tracking
// read/write hazards at sub-resource (mip) granularity, which is not guaranteed.
Shader "Hidden/HiZDepthPyramid"
{
    SubShader
    {
        Tags
        {
            "RenderType" = "Opaque"
            "RenderPipeline" = "UniversalPipeline"
        }

        ZWrite Off
        ZTest Always
        Cull Off

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareNormalsTexture.hlsl"
        #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"
        #include "HiZCommon.hlsl"

        // sampler_PointClamp is a URP builtin global sampler (declared in GlobalSamplers.hlsl,
        // pulled in via Core.hlsl) - do not redeclare it here.

        // MUST be supplied through an explicit per-draw MaterialPropertyBlock (see
        // SSRPass.BuildHiZPyramid), never via Material.SetVector: this pyramid is built by
        // several sequential RenderGraph passes that all reuse the same shared Material
        // instance, and plain material-property mutation is not reliably captured per-draw once
        // RenderGraph batches/merges raster passes (every level after mip 0 was observed to
        // silently read back whichever values were set last, i.e. the smallest level's).
        //
        // Init pass:       xy/zw = real (unpadded) camera pixel size / its reciprocal.
        // Downsample pass:  xy/zw = size/reciprocal of the level being READ (the previous one).
        float4 _SrcMipInfo;
        // Init pass:       xy/zw = padded mip 0 canvas size / its reciprocal.
        // Downsample pass:  xy/zw = size/reciprocal of the level being WRITTEN.
        float4 _DstMipInfo;

        // Depth value that represents "no occluder here" for the active depth convention -
        // matches how the rest of SSR.shader already treats sky (see Frag()'s reversed-Z check).
        float NoOccluderDepth()
        {
#if UNITY_REVERSED_Z
            return 0.0;
#else
            return 1.0;
#endif
        }

        float2 InitFrag(Varyings input) : SV_Target
        {
            // input.texcoord spans the padded (power-of-two) mip 0 canvas. Only the
            // [0, realSize) sub-rectangle has real depth data; the rest is padding.
            uint2 pixel = (uint2)(input.texcoord * _DstMipInfo.xy);
            uint2 realSize = (uint2)_SrcMipInfo.xy;

            if (pixel.x >= realSize.x || pixel.y >= realSize.y)
            {
                float sentinel = NoOccluderDepth();
                return float2(sentinel, sentinel);
            }

            float2 uv = (pixel + 0.5) * _SrcMipInfo.zw;
            float d = SAMPLE_TEXTURE2D_LOD(_CameraDepthTexture, sampler_CameraDepthTexture, uv, 0).r;

            // Sky pixels have no real surface, so _CameraNormalsTexture holds whatever
            // default/cleared value the normals prepass uses there (often zero) -
            // normalize()-ing that would produce NaN. Skip the widening entirely for sky,
            // matching the same reversed-Z sky check SSR.shader's Frag() already uses.
            bool isSky;
#if UNITY_REVERSED_Z
            isSky = d < 0.0001;
#else
            isSky = d > 0.9999;
#endif

            float minD = d;
            float maxD = d;
            if (!isSky)
            {
                float rawMin, rawMax;
                EstimateFragmentDepthRange(uv, d, _SrcMipInfo.xy, rawMin, rawMax);
                minD = min(rawMin, d);
                maxD = max(rawMax, d);
            }
            return float2(saturate(minD), saturate(maxD));
        }

        float2 SampleSrcTexel(uint2 texel)
        {
            float2 uv = (texel + 0.5) * _SrcMipInfo.zw;
            return SAMPLE_TEXTURE2D_LOD(_BlitTexture, sampler_PointClamp, uv, 0).rg;
        }

        float2 DownsampleFrag(Varyings input) : SV_Target
        {
            uint2 dstSize = (uint2)_DstMipInfo.xy;
            uint2 dstTexel = min((uint2)(input.texcoord * dstSize), dstSize - 1);
            uint2 baseTexel = dstTexel * 2;

            // The base canvas is power-of-two and every level exactly halves the previous one,
            // so this plain 2x2 tap is always fully in-bounds - no clamping or guard taps needed.
            float2 r00 = SampleSrcTexel(baseTexel + uint2(0, 0));
            float2 r10 = SampleSrcTexel(baseTexel + uint2(1, 0));
            float2 r01 = SampleSrcTexel(baseTexel + uint2(0, 1));
            float2 r11 = SampleSrcTexel(baseTexel + uint2(1, 1));

            float minD = min(min(r00.x, r10.x), min(r01.x, r11.x));
            float maxD = max(max(r00.y, r10.y), max(r01.y, r11.y));

            return float2(minD, maxD);
        }
        ENDHLSL

        Pass
        {
            Name "Init"

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment InitFrag
            ENDHLSL
        }

        Pass
        {
            Name "Downsample"

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment DownsampleFrag
            ENDHLSL
        }
    }
}
