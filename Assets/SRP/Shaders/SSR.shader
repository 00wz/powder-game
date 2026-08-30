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

        // GetLinearDepth01 / GetLinearEyeDepth / EyeDepthToRawDepth / ReconstructViewPosition
        // перенесены в HiZCommon.hlsl (уже подключён выше) - переиспользуются также в
        // HiZDepthPyramid.shader.

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

                if (depthDiff > 0 && depthDiff < _Thickness) // TODO: можно добавить динамическую толщину в зависимости от угла
                {
                    if (prevDepthDiff > 0)
                    {
                        // На предыдущем шаге луч уже был "за" сценой (либо тоже в пределах
                        // thickness-окна без подтверждённого пересечения, либо ушёл глубже
                        // thickness и теперь вынырнул обратно в окно) - это не свежий подход
                        // "спереди", а продолжение уже "испорченного" состояния (см.
                        // approachedFromClear в HiZTrace - тот же принцип). Глубина буфера
                        // хранит только лицевую поверхность, так что мы не знаем, что там на
                        // самом деле происходит - прерываем трассировку вместо того, чтобы
                        // принять сомнительное пересечение или молча продолжать шагать.
                        return float4(0, 0, 2.0, 0);
                    }

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

            // Чистый промах: бюджет шагов исчерпан либо луч вышел за экран, ни разу не
            // столкнувшись с "испорченным" (не-спереди) пересечением - симметрично тому, что
            // HiZTrace не проверяет tunnelled-состояние в своих собственных точках выхода по
            // границе экрана/бюджету, а прерывается только в момент обнаружения самого
            // некорректного пересечения (см. выше).
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

        // Solves for the ray parameter t (>= currentT) at which the ray's depth first
        // becomes "behind or at" `targetDepth` (see HiZIsBehindOrAt), or returns a very
        // large sentinel if that never happens for the remainder of the ray.
        //
        // A reflection ray's depth does not necessarily move away from the camera for its
        // whole length - it can curve back toward it (e.g. near-grazing reflections off a
        // steeply angled surface). Once the ray is confirmed NOT behind `targetDepth` yet,
        // whether it can EVER become behind it later depends on which way its depth is
        // moving relative to the active depth convention:
        //  - moving in the "away" direction (reversed-Z: depth decreasing; otherwise
        //    increasing): the ray is closing in on `targetDepth` and WILL cross it at the
        //    algebraic solution, which is guaranteed to lie ahead of currentT.
        //  - moving in the "toward camera" direction: the ray is moving further from ever
        //    satisfying HiZIsBehindOrAt against this specific target - it can only have
        //    been behind it in the past (already handled by the "currently behind" check
        //    above), never in the future, so this cell can never register a hit going
        //    forward and must be reported as unreachable (the sentinel), not solved for.
        // Treating both directions with the same closed-form formula (as an earlier version
        // of this function did) silently assumes the first case always holds; for the
        // second case the algebraic solution lands in the past, and naively clamping it
        // forward to currentT turns every step of a toward-camera ray into a false
        // immediate hit - which is exactly the "reflections cut off at grazing angles" bug
        // this function exists to avoid.
        float HiZSolveDepthCrossing(float currentT, float currentDepth, float targetDepth,
                                     float startDepth, float deltaDepth, float invDeltaDepth, float distPx)
        {
            if (HiZIsBehindOrAt(currentDepth, targetDepth))
                return currentT;

            if (abs(deltaDepth) <= 1e-8)
                return 1e8; // Depth does not change along the ray - it will never reach a different value.

#if UNITY_REVERSED_Z
            bool approachingTarget = deltaDepth < 0.0;
#else
            bool approachingTarget = deltaDepth > 0.0;
#endif
            if (!approachingTarget)
                return 1e8;

            return max((targetDepth - startDepth) * invDeltaDepth * distPx, currentT);
        }

        // Complementary to HiZSolveDepthCrossing: given the ray is CURRENTLY behind
        // `targetDepth`, solves for the t (>= currentT) at which it will surface back out of
        // that state, or returns a large sentinel if it stays behind for the rest of the ray.
        // A ray moving away from the camera that is already behind a given depth stays behind
        // it forever (monotonically decreasing depth never comes back) - only a ray curving
        // back toward the camera can surface out again, which is exactly the direction
        // HiZSolveDepthCrossing treats as "never enters". Without this, a coarse cell's
        // "tunnelled through" state (see HiZClassifyOcclusion) would be assumed to persist
        // until the ray leaves the cell in XY, silently skipping over the point where a
        // toward-camera ray re-emerges mid-cell.
        float HiZSolveDepthExit(float currentT, float startDepth, float targetDepth,
                                 float deltaDepth, float invDeltaDepth, float distPx)
        {
            if (abs(deltaDepth) <= 1e-8)
                return 1e8; // Depth never changes - if already behind, stays behind forever.

#if UNITY_REVERSED_Z
            bool recedingFromTarget = deltaDepth > 0.0;
#else
            bool recedingFromTarget = deltaDepth < 0.0;
#endif
            if (!recedingFromTarget)
                return 1e8;

            return max((targetDepth - startDepth) * invDeltaDepth * distPx, currentT);
        }

        // Thickness-aware occlusion classification for a Hi-Z cell. A depth buffer only ever
        // stores the front-facing surface at each texel, with no information about how far
        // back solid geometry actually extends - treating that single value as an infinitely
        // thick wall means a ray that should legitimately continue behind a thin foreground
        // object (a lamppost, a railing, ...) instead stops dead at its front face._Thickness
        // bounds how far behind a stored depth value the ray is still considered "on the
        // surface"; further than that, the ray is assumed to have exited the back of the
        // (assumed-thin) object into open space and should keep marching.
        //
        // minMax.y (nearest possible surface in the cell) still gates whether the ray could
        // have hit anything at all, exactly as before. minMax.x (farthest possible surface)
        // does the complementary job: once the ray is behind minMax.x by more than
        // _Thickness, it has tunnelled past even the most distant geometry the cell could
        // contain, with margin, so nothing in this cell can produce a valid hit any more -
        // this is what lets the traversal skip past a run of thin-occluder cells via the
        // hierarchy instead of being forced down to mip 0 for every single one of them.
        //
        // Returns:
        //   0 = not reached yet   - ray is still in front of the near plane (definitely clear
        //                           so far); `outEventT` receives the future t (>= currentT) at
        //                           which it would enter the window, for skipping ahead to (or
        //                           a large sentinel if it never will - see
        //                           HiZSolveDepthCrossing).
        //   1 = inside the window - within _Thickness of some surface in the cell; `outEventT`
        //                           equals currentT (the window is entered right now).
        //   2 = tunnelled through - behind even minMax.x by more than _Thickness; nothing here
        //                           can register a hit. `outEventT` receives the future t at
        //                           which the ray would surface back out of this state (only
        //                           possible for a ray curving toward the camera), or a large
        //                           sentinel if it stays tunnelled through for the rest of the
        //                           ray - see HiZSolveDepthExit. Callers MUST treat this
        //                           symmetrically with case 0 (compare against the cell's XY
        //                           exit t) rather than assuming it always persists to the
        //                           cell boundary.
        int HiZClassifyOcclusion(float currentT, float currentDepth, float2 minMax,
                                  float startDepth, float deltaDepth, float invDeltaDepth, float distPx,
                                  out float outEventT)
        {
            if (!HiZIsBehindOrAt(currentDepth, minMax.y))
            {
                outEventT = HiZSolveDepthCrossing(currentT, currentDepth, minMax.y, startDepth, deltaDepth, invDeltaDepth, distPx);
                return 0;
            }

            float farThreshold = EyeDepthToRawDepth(GetLinearEyeDepth(minMax.x) + _Thickness);
            if (!HiZIsBehindOrAt(currentDepth, farThreshold))
            {
                outEventT = currentT;
                return 1;
            }

            outEventT = HiZSolveDepthExit(currentT, startDepth, farThreshold, deltaDepth, invDeltaDepth, distPx);
            return 2;
        }

        // Clamps the view-space marching distance so viewOrigin + viewDir * distance never
        // crosses (or gets numerically close to) the camera's near plane. ViewToScreen()'s
        // perspective divide (clip.w = -viewZ) is only well-behaved in front of the camera:
        // as a point approaches the near plane, w -> 0 and its projected screen position/depth
        // blow up toward infinity, then flip sign once actually behind it. Reflections
        // routinely curve back toward the camera at grazing angles (viewDir.z > 0), so this is
        // a real, reachable case - the ray must be clipped the same way a rasterizer clips
        // triangles against the near plane before the perspective divide, rather than trusting
        // the raw _MaxDistance endpoint to always be safely projectable.
        float HiZClipDistanceToNearPlane(float3 viewOrigin, float3 viewDir, float maxDistance)
        {
            if (unity_OrthoParams.w > 0.5 || viewDir.z <= 0.0)
                return maxDistance; // Orthographic has no perspective singularity; moving away
                                     // from the camera never approaches the near plane.

            // Small safety margin so w stays comfortably away from zero, not just non-negative.
            float nearZ = -_ProjectionParams.y * 1.05;
            float distToNearPlane = (nearZ - viewOrigin.z) / viewDir.z;
            return clamp(distToNearPlane, 0.0, maxDistance);
        }

        float4 HiZTrace(float3 viewOrigin, float3 viewDir)
        {
            float3 startSS = ViewToScreen(viewOrigin);
            float clippedDistance = HiZClipDistanceToNearPlane(viewOrigin, viewDir, _MaxDistance);
            float3 endSS = ViewToScreen(viewOrigin + viewDir * clippedDistance);

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

            // A fixed small starting offset (in pixels) is enough to avoid self-intersection
            // with the reflecting surface itself. Unlike RayMarch, HiZTrace does not sample at
            // discrete fixed-size steps - every hit is an exact closed-form crossing point, so
            // there is no fixed step grid for per-pixel jitter to dither/de-band; _JitterStrength
            // intentionally has no effect here.
            float t = 1.0;

            int maxLevel = max((int)_HiZLevelCount - 1, 0);
            int level = 0;

            // Tracks whether the ray's approach to whatever occlusion state it's currently in
            // was "clean" (confirmed clear beforehand) or "tainted" (it just surfaced out of a
            // tunnelled-through state - see the occlusion == 2 branch below). A depth buffer
            // only stores front-facing surfaces, so a hit found immediately after surfacing
            // from tunnelling means the ray approached it from behind/inside, not from the
            // front - there is no reliable way to know what that means physically (the ray
            // could still be inside solid geometry, or could legitimately be in open space),
            // so such hits are rejected and the trace aborts rather than guessing.
            //
            // Only updated when t actually advances (jumping to tEvent or climbing to tCell) -
            // NOT during a pure level-- descent at the same t, so a multi-level descent chain
            // while investigating the same approach event never resets it.
            bool approachedFromClear = true;

            const int HIZ_MAX_ITER = 128;
            int iterCount = min((int)_MaxSteps, HIZ_MAX_ITER);

            [loop]
            for (int i = 0; i < HIZ_MAX_ITER; i++)
            {
                if (i >= iterCount || t >= distPx)
                    break;

                float2 pos = startPx + dir * t;
                if (pos.x < 0.0 || pos.x >= realSize.x || pos.y < 0.0 || pos.y >= realSize.y)
                    return float4(0, 0, 0, 0); // Clean miss: ray left the visible screen.

                // UV is resolution-independent, so it must always be normalized against the
                // BASE (level 0) padded canvas size, never the current level's own (smaller)
                // size - _HiZMipInfo[level] only describes that level's texel count, not a
                // valid UV denominator for a `pos` given in base-resolution pixel units.
                float2 uvPyramid = pos / _HiZMipInfo[0].xy;
                float2 minMax = SampleHiZLevel(uvPyramid, level);

                float currentDepth = lerp(startSS.z, endSS.z, saturate(t / distPx));
                float tEvent;
                int occlusion = HiZClassifyOcclusion(t, currentDepth, minMax, startSS.z,
                                                      deltaDepth, invDeltaDepth, distPx, tEvent);

                // t at which the ray leaves the current cell's XY footprint.
                float cellSize = (float)(1u << level);
                float2 cellIndex = floor(pos / cellSize);
                float2 boundary = (cellIndex + step(0.0, safeDir)) * cellSize;
                float2 tAxis = (boundary - startPx) / safeDir;
                float tCell = max(min(tAxis.x, tAxis.y), t);

                if (occlusion == 1)
                {
                    // Within _Thickness of some surface in the cell - candidate hit.
                    if (level == 0)
                    {
                        if (!approachedFromClear)
                            return float4(0, 0, 2.0, 0); // Aborted: approached from behind/inside.

                        float2 hitUV = pos / realSize;

                        float2 edgeFade = smoothstep(0, _EdgeFade, hitUV) *
                                          smoothstep(0, _EdgeFade, 1.0 - hitUV);
                        float screenFade = edgeFade.x * edgeFade.y;
                        float distFade = 1.0 - saturate(t / distPx);

                        return float4(hitUV, 1.0, screenFade * distFade);
                    }

                    level--;
                }
                else if (occlusion == 2)
                {
                    // Tunnelled past even the farthest possible surface in this cell (with
                    // _Thickness margin) - e.g. the ray has passed behind a thin occluder.
                    // Symmetric to the occlusion == 0 handling below: a ray curving toward the
                    // camera can surface back out of this state before leaving the cell (see
                    // HiZSolveDepthExit), so that must be checked for explicitly rather than
                    // assuming the tunnelled state always persists to the cell boundary.
                    approachedFromClear = false;

                    if (tEvent < tCell)
                    {
                        // Surfaces back out mid-cell - re-examine there, same level (we have
                        // not left the cell "clear").
                        t = tEvent + 0.05;
                    }
                    else
                    {
                        // Stays tunnelled through for the rest of this cell - skip past it and
                        // climb back up the hierarchy to resume skipping efficiently.
                        t = tCell + 0.05;
                        level = min(level + 1, maxLevel);
                    }
                }
                else // occlusion == 0
                {
                    approachedFromClear = true;

                    if (tEvent < tCell)
                    {
                        // Will enter the occlusion window before leaving this cell - jump
                        // straight to it and re-classify there next iteration.
                        t = tEvent + 0.05;
                    }
                    else
                    {
                        // Clear for the remainder of this cell - climb the hierarchy.
                        t = tCell + 0.05;
                        level = min(level + 1, maxLevel);
                    }
                }
            }

            return float4(0, 0, 0, 0); // Clean miss: search budget exhausted.
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
            // The Hi-Z pyramid's mip 0 stores a WIDENED (min,max) window for this exact
            // texel (see HiZDepthPyramid.shader's EstimateDepthExtent), to correctly handle
            // grazing-angle surfaces. If the ray still launched from the exact per-pixel
            // depth, its starting position would sit BEHIND the pyramid's own claimed nearest
            // bound for this same texel, and HiZTrace's 1-pixel self-intersection margin is
            // no longer enough to escape it - a false self-intersection with the ray's own
            // origin (blind spots / missing reflections), worst for rays travelling away from
            // the camera on grazing surfaces, exactly where the widening is largest. Launch
            // the ray from this same texel's own near bound instead, restoring the invariant
            // "ray start depth == this texel's own max" that the self-intersection margin was
            // designed around.
            float2 uvPyramid0 = uv * (_HiZScreenSize.xy / _HiZMipInfo[0].xy);
            float2 originMinMax = SampleHiZLevel(uvPyramid0, 0);
            float3 hizViewOrigin = ReconstructViewPosition(uv, originMinMax.y);
            float4 hitResult = HiZTrace(hizViewOrigin, reflectDir);
#else
            float4 hitResult = RayMarch(viewPos, reflectDir, uv);
#endif
            
            // Aborted (статус 2): трассировка обнаружила, что подошла к пересечению "с
            // изнанки"/изнутри геометрии (см. HiZTrace/RayMarch) и не смогла его достоверно
            // разрешить. Реальность за точкой обрыва неизвестна - в частности, нельзя
            // показывать skybox fallback, иначе объект будет выглядеть "просвечивающим".
            if (hitResult.z > 1.5)
                return sceneColor;

            half3 reflectionColor;
            float reflectionStrength;

            if (hitResult.z > 0.5) // Есть пересечение с геометрией (статус 1)
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
