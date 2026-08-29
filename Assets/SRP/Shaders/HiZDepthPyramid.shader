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

        // At grazing angles (surface normal near-perpendicular to the view direction), depth
        // changes very fast from one screen pixel to the next, so a mip-0 texel that just
        // stores a single depth sample is a poor stand-in for the small patch of surface it
        // actually covers - a ray that should legitimately land on this texel can miss it by
        // more than _Thickness, which shows up as a periodic banding/striping pattern on
        // grazing surfaces. To fix this we widen the stored (min, max) using the fragment's
        // own normal to estimate how much the surface's depth plausibly varies across its own
        // pixel footprint.
        //
        // This deliberately does NOT sample neighboring texels (e.g. via ddx/ddy of depth):
        // screen-space derivatives are computed from the actual rasterized 2x2 quad, so at a
        // genuine silhouette edge (this pixel's object against unrelated background/another
        // object) they report a huge, real jump that has nothing to do with surface slope -
        // widening by that amount would corrupt the pyramid at every object edge in the scene,
        // not just at grazing angles. Instead we ask a purely local, single-pixel question:
        // "if this fragment's surface were an infinite plane (this position, this normal), how
        // far would its depth extend across one pixel's angular footprint?" - which depends
        // only on this fragment's own normal and depth, so a silhouette next door cannot
        // contaminate it.
        //
        // IMPORTANT: under perspective projection, the neighboring screen pixel corresponds to
        // a DIVERGING ray from the camera origin, not a parallel shift of this ray. An earlier
        // version of this function approximated the depth delta using only the plane's local
        // slope (dz/dx = -N.x/N.z, from the plane equation N.(P-P0)=0 alone) - that equation
        // answers "how does Z change moving ALONG the plane", which is only the same question
        // as "where does the neighboring pixel's ray cross the plane" when the pixel sits on
        // the view axis (P0.xy == 0). Off-axis - which is most of the screen, and exactly
        // where a grazing surface spans much of the frame - the two diverge substantially, so
        // that version under/over-estimated the extent and left visible banding. The fix below
        // solves the actual ray/plane intersection for the neighboring rays instead of just
        // the local slope.
        float2 EstimateDepthExtent(float2 uv, float rawDepth)
        {
            float3 normalWS = SampleSceneNormals(uv);
            float3 N = normalize(mul((float3x3)UNITY_MATRIX_V, normalWS));
            float3 P0 = ReconstructViewPosition(uv, rawDepth);
            float eyeDepth0 = -P0.z;

            float2 realSize = _SrcMipInfo.xy;
            float2 halfExtentEyeXY;

            if (unity_OrthoParams.w > 0.5)
            {
                // Orthographic: all rays are parallel, so "the neighboring pixel's ray" is
                // exactly "this ray shifted by one pixel's world size at constant depth" -
                // the local-slope shortcut is exact here, no off-axis correction needed.
                float2 orthoSize = float2(2.0 / UNITY_MATRIX_P._m00, 2.0 / UNITY_MATRIX_P._m11);
                float2 pixelWorldSize = orthoSize / realSize;
                float safeNz = abs(N.z) > 1e-4 ? N.z : (N.z >= 0.0 ? 1e-4 : -1e-4);
                halfExtentEyeXY = abs(N.xy / safeNz) * pixelWorldSize;
            }
            else
            {
                // Perspective: solve the exact ray/plane intersection for the X and Y
                // neighbor rays. Both are derived algebraically from P0 - no extra
                // ReconstructViewPosition (matrix multiply) calls needed.
                float2 tanHalfFov = float2(1.0 / UNITY_MATRIX_P._m00, 1.0 / UNITY_MATRIX_P._m11);
                float2 pixelWorldSize = 2.0 * tanHalfFov * eyeDepth0 / realSize;

                float3 dir0 = P0 / eyeDepth0; // ray direction, Z-component normalized to -1
                float nDotP0 = dot(N, P0);

                float3 dirX = dir0 + float3(pixelWorldSize.x / eyeDepth0, 0.0, 0.0);
                float3 dirY = dir0 + float3(0.0, pixelWorldSize.y / eyeDepth0, 0.0);

                float denomX = dot(N, dirX);
                float denomY = dot(N, dirY);
                // Guarded explicitly (not left to saturate() at the end) - a near-zero
                // denominator means the neighboring ray is nearly parallel to the plane
                // (grazing), which is exactly the case being estimated for, not one to ignore.
                float safeDenomX = abs(denomX) > 1e-6 ? denomX : (denomX >= 0.0 ? 1e-6 : -1e-6);
                float safeDenomY = abs(denomY) > 1e-6 ? denomY : (denomY >= 0.0 ? 1e-6 : -1e-6);

                float2 tXY = nDotP0 / float2(safeDenomX, safeDenomY);
                halfExtentEyeXY = abs(tXY - eyeDepth0);
            }

            float halfExtentEye = 0.5 * (halfExtentEyeXY.x + halfExtentEyeXY.y);

            float rawA = EyeDepthToRawDepth(eyeDepth0 - halfExtentEye);
            float rawB = EyeDepthToRawDepth(eyeDepth0 + halfExtentEye);
            return float2(min(rawA, rawB), max(rawA, rawB));
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

            float2 extent = isSky ? float2(d, d) : EstimateDepthExtent(uv, d);
            float minD = min(extent.x, d);
            float maxD = max(extent.y, d);
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
