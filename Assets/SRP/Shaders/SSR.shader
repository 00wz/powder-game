Shader "Hidden/SSR"
{
    Properties
    {
        _MaxSteps ("Max Steps", Range(8, 128)) = 32
        _JitterStrength ("Jitter Strength", Range(0, 1)) = 0.2
        _Thickness ("Thickness", Range(0.01, 2.0)) = 0.5
        _MaxDistance ("Max Distance", Range(1, 100)) = 50
        _Intensity ("Intensity", Range(0, 1)) = 0.5
        _EdgeFade ("Edge Fade", Range(0.01, 0.5)) = 0.1
    }

    SubShader
    {
        Tags 
        { 
            "RenderType" = "Opaque" 
            "RenderPipeline" = "UniversalPipeline"
        }
        
        ZWrite Off
        Cull Off

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareNormalsTexture.hlsl"
        #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"
        #include "HiZCommon.hlsl"

        // Skybox cubemap (передаётся из C#)
        TEXTURECUBE(_SSR_SkyCube);
        SAMPLER(sampler_SSR_SkyCube);
        float4 _SSR_SkyCube_HDR;
        float _SSR_UseSkyboxFallback;
        
        // Декодирование HDR из RGBM (Unity reflection probe format)
        half3 DecodeHDRCubemap(half4 data, half4 hdr)
        {
            // RGBM decoding: color.rgb * (color.a * hdr.x)
            // hdr.x содержит множитель для декодирования
            return data.rgb * (data.a * hdr.x);
        }

        // Параметры SSR
        float _MaxSteps;
        float _JitterStrength;
        float _Thickness;
        float _MaxDistance;
        float _Intensity;
        float _EdgeFade;

        // Используем встроенные матрицы Unity:
        // UNITY_MATRIX_V - View matrix (world to camera)
        // UNITY_MATRIX_I_V - Inverse View matrix (camera to world)
        // UNITY_MATRIX_P - Projection matrix
        // UNITY_MATRIX_I_P - Inverse Projection matrix

        // Сэмплирование глубины без градиентов (для использования в циклах)
        float SampleSceneDepthLOD(float2 uv)
        {
            return SAMPLE_TEXTURE2D_LOD(_CameraDepthTexture, sampler_CameraDepthTexture, uv, 0).r;
        }

        // Получаем линейную глубину с учётом типа камеры
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

        float GetLinearEyeDepth(float rawDepth)
        {
            if (unity_OrthoParams.w > 0.5) // Orthographic
            {
                float linear01 = GetLinearDepth01(rawDepth);
                return lerp(_ProjectionParams.y, _ProjectionParams.z, linear01);
            }
            return LinearEyeDepth(rawDepth, _ZBufferParams);
        }

        // Реконструкция позиции в View Space из UV и глубины
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

        // Проекция View Space → Screen UV
        float3 ViewToScreen(float3 viewPos)
        {
            float4 clipPos = mul(UNITY_MATRIX_P, float4(viewPos, 1.0));
            float4 screenPos = ComputeScreenPos(clipPos);

            float2 uv = screenPos.xy / screenPos.w;
            float depth = screenPos.z / screenPos.w;
            
            return float3(uv, depth);
        }

        // Шум для jittering
        float InterleavedGradientNoise(float2 pixelCoord)
        {
            float3 magic = float3(0.06711056, 0.00583715, 52.9829189);
            return frac(magic.z * frac(dot(pixelCoord, magic.xy)));
        }

        // Ray March в View Space (корректно для перспективной проекции)
        // Возвращает: xy = hitUV, z = hit (0 или 1), w = fade
        float4 RayMarch(float3 viewOrigin, float3 viewDir, float2 screenUV)
        {
            // Шаг в view space
            float viewStepSize = _MaxDistance / _MaxSteps;
            
            // Jitter для уменьшения артефактов
            float jitter = InterleavedGradientNoise(screenUV * _ScreenParams.xy);
            
            // Начинаем с небольшим отступом чтобы избежать self-intersection
            float3 currentViewPos = viewOrigin + viewDir * viewStepSize * (1.0 + (jitter - 0.5) * _JitterStrength);
            float3 prevViewPos = viewOrigin;
            float prevDepthDiff = -1;
            
            const int MAX_STEPS_LIMIT = 128;
            int steps = min(MAX_STEPS_LIMIT, (int)_MaxSteps);
            
            [loop]
            for (int i = 0; i < MAX_STEPS_LIMIT; i++)
            {
                if (i >= steps)
                    break;
                
                // Проецируем текущую точку луча в screen space
                float3 screenPos = ViewToScreen(currentViewPos);
                float2 currentUV = screenPos.xy;
                
                // Проверяем, что UV в пределах экрана
                if (currentUV.x < 0 || currentUV.x > 1 ||
                    currentUV.y < 0 || currentUV.y > 1)
                    break;
                
                // Сэмплируем глубину сцены
                float sceneDepth = SampleSceneDepthLOD(currentUV);
                float sceneLinearDepth = GetLinearEyeDepth(sceneDepth);
                
                // Глубина луча (в view space Z отрицательный, поэтому берём минус)
                float rayLinearDepth = -currentViewPos.z;
                
                // Проверяем пересечение: луч прошёл за поверхность
                float depthDiff = rayLinearDepth - sceneLinearDepth;
                
                if (prevDepthDiff <= 0 && depthDiff > 0 && depthDiff < _Thickness) // TODO: можно добавить динамическую толщину в зависимости от угла
                {
                    // Нашли пересечение! Binary search refinement в view space
                    float3 lo = prevViewPos;
                    float3 hi = currentViewPos;
                    float2 hitUV = currentUV;
                    
                    [unroll]
                    for (int j = 0; j < 4; j++)
                    {
                        float3 midView = (lo + hi) * 0.5;
                        float3 midScreen = ViewToScreen(midView);
                        float2 midUV = midScreen.xy;
                        
                        // Проверяем границы
                        if (midUV.x < 0 || midUV.x > 1 || midUV.y < 0 || midUV.y > 1)
                        {
                            hi = midView;
                            continue;
                        }
                        
                        float midSceneDepth = SampleSceneDepthLOD(midUV);
                        float midSceneLinear = GetLinearEyeDepth(midSceneDepth);
                        float midRayLinear = -midView.z;
                        
                        if (midRayLinear > midSceneLinear)
                        {
                            hi = midView;
                            hitUV = midUV;
                        }
                        else
                        {
                            lo = midView;
                        }
                    }
                    
                    // Fade к краям экрана
                    float2 edgeFade = smoothstep(0, _EdgeFade, hitUV) *
                                      smoothstep(0, _EdgeFade, 1.0 - hitUV);
                    float screenFade = edgeFade.x * edgeFade.y;
                    
                    // Fade по расстоянию (нормализуем по MaxDistance)
                    float travelDist = length(currentViewPos - viewOrigin);
                    float distFade = 1.0 - saturate(travelDist / _MaxDistance);
                    
                    return float4(hitUV, 1.0, screenFade * distFade);
                }
                
                // Шагаем дальше по лучу в view space
                prevViewPos = currentViewPos;
                prevDepthDiff = depthDiff;
                currentViewPos += viewDir * viewStepSize;
            }
            
            return float4(0, 0, 0, 0);
        }

        // === Hi-Z Min-Max Tracing ===========================================
        // Cell-based hierarchical traversal (GPU Pro 5 / Stingray / AMD FidelityFX
        // SSSR style): the ray is advanced through screen-space texel cells using a
        // fully parametric ray/cell-boundary and ray/depth-plane intersection test,
        // not point-sampling. Within a cell the ray's depth changes continuously as
        // it moves in X/Y, so comparing one interpolated depth sample against the
        // cell's stored max is not sufficient - what matters is which happens FIRST
        // as the ray advances: leaving the cell's XY footprint, or reaching the
        // cell's nearest-possible-occluder depth plane. Both are solved in closed
        // form (as ray parameter t, in mip0-pixel units) and compared directly.
        //
        // NDC device depth is affine in screen-space distance along a straight 2D
        // screen-space line (the same property that lets GPU rasterizer hardware
        // z-interpolate linearly across a triangle without perspective correction),
        // so the depth-plane crossing has an exact closed-form solution - no
        // iterative refinement needed. Because mip 0's stored max IS the exact
        // per-pixel scene depth (see HiZDepthPyramid.shader's Init pass), and a hit
        // is only ever accepted once the traversal has descended all the way to mip
        // 0, the returned hit position is already exact to the depth buffer's own
        // texel resolution - unlike RayMarch's fixed-size steps, there is no
        // precision gap between samples for a binary search to recover.

        bool HiZIsBehindOrAt(float rayDepth, float surfaceDepth)
        {
#if UNITY_REVERSED_Z
            return rayDepth <= surfaceDepth;
#else
            return rayDepth >= surfaceDepth;
#endif
        }

        float4 HiZTrace(float3 viewOrigin, float3 viewDir, float2 screenUV)
        {
            float3 startSS = ViewToScreen(viewOrigin);
            float3 endSS = ViewToScreen(viewOrigin + viewDir * _MaxDistance);

            float2 realSize = _HiZScreenSize.xy;
            float2 startPx = startSS.xy * realSize;
            float2 endPx = endSS.xy * realSize;

            float2 deltaPx = endPx - startPx;
            float distPx = length(deltaPx);
            if (distPx < 1.0)
                return float4(0, 0, 0, 0);

            float2 dir = deltaPx / distPx;
            // Cell-boundary math divides by direction components - keep them safely non-zero.
            float2 safeDir = float2(
                abs(dir.x) < 1e-5 ? (dir.x < 0.0 ? -1e-5 : 1e-5) : dir.x,
                abs(dir.y) < 1e-5 ? (dir.y < 0.0 ? -1e-5 : 1e-5) : dir.y);

            float deltaDepth = endSS.z - startSS.z;
            bool depthVaries = abs(deltaDepth) > 1e-8;
            float invDeltaDepth = depthVaries ? (1.0 / deltaDepth) : 0.0;

            // Small jittered start offset (in pixels) to reduce banding/self-intersection,
            // mirroring the jitter RayMarch applies to its own starting position.
            float jitter = InterleavedGradientNoise(screenUV * _ScreenParams.xy);
            float t = 1.0 + (jitter - 0.5) * _JitterStrength;

            int maxLevel = max((int)_HiZLevelCount - 1, 0);
            int level = 0;

            const int HIZ_MAX_ITER = 128;
            int iterCount = min((int)_MaxSteps, HIZ_MAX_ITER);

            [loop]
            for (int i = 0; i < HIZ_MAX_ITER; i++)
            {
                if (i >= iterCount || t >= distPx)
                    break;

                float2 pos = startPx + dir * t;
                if (pos.x < 0.0 || pos.x >= realSize.x || pos.y < 0.0 || pos.y >= realSize.y)
                    return float4(0, 0, 0, 0);

                // UV is resolution-independent, so it must always be normalized against the
                // BASE (level 0) padded canvas size, never the current level's own (smaller)
                // size - _HiZMipInfo[level] only describes that level's texel count, not a
                // valid UV denominator for a `pos` given in base-resolution pixel units.
                float2 uvPyramid = pos / _HiZMipInfo[0].xy;
                float2 minMax = SampleHiZLevel(uvPyramid, level);

                // t at which the ray's depth reaches this cell's nearest possible occluder.
                // Whether "not yet reached" (dt > 0, still ahead) or "already behind" is
                // checked explicitly via HiZIsBehindOrAt rather than inferred from the sign of
                // the closed-form solve, so this is correct regardless of whether the ray's
                // depth is increasing or decreasing along its length (a reflection can curve
                // back toward the camera, not just away from it).
                float currentDepth = lerp(startSS.z, endSS.z, saturate(t / distPx));
                float tDepth;
                if (HiZIsBehindOrAt(currentDepth, minMax.y))
                    tDepth = t;
                else if (depthVaries)
                    tDepth = max((minMax.y - startSS.z) * invDeltaDepth * distPx, t);
                else
                    tDepth = 1e8;

                // t at which the ray leaves the current cell's XY footprint.
                float cellSize = (float)(1u << level);
                float2 cellIndex = floor(pos / cellSize);
                float2 boundary = (cellIndex + step(0.0, safeDir)) * cellSize;
                float2 tAxis = (boundary - startPx) / safeDir;
                float tCell = max(min(tAxis.x, tAxis.y), t);

                float tNext = min(tCell, tDepth);

                if (tDepth <= tCell)
                {
                    // The ray reaches the depth plane before leaving the cell - candidate hit.
                    if (level == 0)
                    {
                        float hitT = tNext;
                        float2 hitUV = (startPx + dir * hitT) / realSize;

                        float2 edgeFade = smoothstep(0, _EdgeFade, hitUV) *
                                          smoothstep(0, _EdgeFade, 1.0 - hitUV);
                        float screenFade = edgeFade.x * edgeFade.y;
                        float distFade = 1.0 - saturate(hitT / distPx);

                        return float4(hitUV, 1.0, screenFade * distFade);
                    }

                    level--;
                }
                else
                {
                    level = min(level + 1, maxLevel);
                }

                t = tNext + 0.05;
            }

            return float4(0, 0, 0, 0);
        }

        half3 GetSkyBoxColor(float3 dirVS)
        {
            // Конвертируем направление отражения из view space в world space
            float3 dirWS = mul((float3x3)UNITY_MATRIX_I_V, dirVS);
            
            // Сэмплируем skybox cubemap
            half4 encodedIrradiance = SAMPLE_TEXTURECUBE_LOD(_SSR_SkyCube, sampler_SSR_SkyCube, dirWS, 0);
            
            // Декодируем HDR
            return DecodeHDRCubemap(encodedIrradiance, _SSR_SkyCube_HDR);
        }

        // Используем Vert из Blit.hlsl
        half4 Frag(Varyings input) : SV_Target
        {
            //float2 uv = GetNormalizedScreenSpaceUV(input.positionCS);
            float2 uv = input.texcoord;
            
            // Исходный цвет сцены
            half4 sceneColor = SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, uv);
            
            // Глубина и нормаль
            float depth = SampleSceneDepth(uv);
            float3 normalWS = SampleSceneNormals(uv);
            
            // Пропускаем sky (глубина = 0 или 1 в зависимости от reversed-z)
            #if UNITY_REVERSED_Z
                if (depth < 0.0001)
                    return sceneColor;
            #else
                if (depth > 0.9999)
                    return sceneColor;
            #endif
            
            // Реконструируем позицию в view space
            float3 viewPos = ReconstructViewPosition(uv, depth);
            // Конвертируем нормаль из World Space в View Space
            // Для нормалей используем транспонированную инверсную матрицу,
            // но для ортонормированных матриц (без масштабирования) это то же самое что (float3x3)ViewMatrix
            float3 normalVS = normalize(mul((float3x3)UNITY_MATRIX_V, normalWS));
            
            // Направление взгляда (от камеры к точке)
            // В view space камера в (0,0,0) и смотрит в направлении -Z
            float3 viewDir;
            if (unity_OrthoParams.w > 0.5) // Orthographic
            {
                // Для ортографической камеры направление всегда (0,0,-1) в view space
                viewDir = float3(0.0, 0.0, -1.0);
            }
            else
            {
                // Для перспективной камеры - вектор от камеры к точке
                viewDir = normalize(viewPos);
            }
            
            // Направление отражения в view space
            // reflect(I, N) возвращает I - 2*dot(I,N)*N
            float3 reflectDir = reflect(viewDir, normalVS);
            
            // Fresnel эффект - отражения сильнее на пологих углах
            float fresnel = pow(1.0 - saturate(dot(-viewDir, normalVS)), 3.0);
            
            // Ray march / Hi-Z trace
#if defined(_SSR_TRACING_HIZ)
            float4 hitResult = HiZTrace(viewPos, reflectDir, uv);
#else
            float4 hitResult = RayMarch(viewPos, reflectDir, uv);
#endif
            
            half3 reflectionColor;
            float reflectionStrength;
            
            if (hitResult.z > 0.5) // Есть пересечение с геометрией
            {
                float2 hitUV = hitResult.xy;
                float fade = hitResult.w;
                
                // Сэмплируем цвет отражения из screen
                reflectionColor = SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, hitUV).rgb;
                if(_SSR_UseSkyboxFallback > 0.5)
                {
                    reflectionColor = lerp(GetSkyBoxColor(reflectDir), reflectionColor, fade);
                    reflectionStrength = _Intensity * fresnel;
                }
                else
                {
                    reflectionStrength = fade * _Intensity * fresnel;
                }
            }
            else
            {
                // Fallback: сэмплируем skybox
                if (_SSR_UseSkyboxFallback > 0.5)
                {
                    reflectionColor = GetSkyBoxColor(reflectDir);
                    
                    // Для skybox fallback используем fresnel и полную интенсивность
                    reflectionStrength = _Intensity * fresnel;
                }
                else
                {
                    // Skybox fallback отключен - возвращаем исходный цвет
                    return sceneColor;
                }
            }
            
            return half4(lerp(sceneColor.rgb, reflectionColor, reflectionStrength), sceneColor.a);
        }

        // Визуализация Hi-Z пирамиды для отладки/подбора настроек: левая половина экрана -
        // min глубина выбранного уровня, правая половина - max глубина того же уровня.
        float _HiZDebugMipIndex;

        half4 HiZDebugFrag(Varyings input) : SV_Target
        {
            float2 uv = input.texcoord;

            int levelCount = max((int)_HiZLevelCount, 1);
            int level = clamp((int)_HiZDebugMipIndex, 0, levelCount - 1);

            bool showMax = uv.x > 0.5;
            float2 sampleUV = float2(showMax ? (uv.x - 0.5) * 2.0 : uv.x * 2.0, uv.y);

            float2 minMax = SampleHiZLevel(sampleUV, level);
            float rawDepth = showMax ? minMax.y : minMax.x;
            float linear01 = GetLinearDepth01(rawDepth);

            // GetLinearDepth01 normalizes by the camera's far plane, so with a typical far
            // distance nearby geometry compresses into a near-zero range that reads as flat
            // black. This curve is purely a contrast boost for readability of this debug view -
            // it does not affect the stored pyramid values or any future tracing.
            float debugContrast = pow(saturate(linear01), 0.25);

            half3 color = half3(debugContrast, debugContrast, debugContrast);

            // Разделительная линия по центру между min (слева) и max (справа).
            if (abs(uv.x - 0.5) < 0.0015)
                color = half3(1.0h, 0.0h, 0.0h);

            return half4(color, 1.0h);
        }
        ENDHLSL

        Pass
        {
            Name "SSR"

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag
            #pragma multi_compile _ _SSR_TRACING_HIZ
            ENDHLSL
        }

        Pass
        {
            Name "HiZDebug"

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment HiZDebugFrag
            ENDHLSL
        }
    }
}
