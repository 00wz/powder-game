// =============================================================================
//  SCREEN SPACE PATH TRACING  (SSPT)
//  Hidden/SSPT — 4 passes: Trace → Temporal → Denoise → Composite
//
//  Теория:
//  Path tracing решает интеграл уравнения рендеринга (Kajiya, 1986):
//
//    Lo(x,ωo) = Le(x,ωo) + ∫ Li(x,ωi) · fr(x,ωi,ωo) · |cos θi| dωi
//
//  Для diffuse GI: fr = albedo/π, importance-sampling по cosine hemisphere
//  даёт PDF = cosθ/π → веса сокращаются → weight = albedo ≈ 1 (нет GBuffer).
//
//  Screen Space ограничение: видны только пиксели на экране.
//  Temporal accumulation компенсирует noise, а-trous denoise убирает остатки.
// =============================================================================
Shader "Hidden/SSPT"
{
    SubShader
    {
        Tags { "RenderType"="Opaque" "RenderPipeline"="UniversalPipeline" }
        ZWrite Off
        Cull Off

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareNormalsTexture.hlsl"
        #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"

        // ─────────────────────────────────────────────────────────────────────
        //  ПАРАМЕТРЫ (устанавливаются из C#)
        // ─────────────────────────────────────────────────────────────────────
        int   _SampleCount;       // лучей на пиксель за кадр (1–8)
        int   _MaxSteps;          // шагов ray march на луч
        float _MaxDistance;       // макс. расстояние в world units
        float _Thickness;         // толщина для определения хита
        float _EdgeFade;          // fade к краям экрана
        float _IndirectIntensity; // интенсивность GI при композитинге
        float _TemporalAlpha;     // blend с историей: 1=только текущий кадр
        float _FrameIndex;        // счётчик кадров для анимации шума
        float _DenoiseStepWidth;  // ширина шага для a-trous (1,2,4,8...)

        TEXTURE2D(_HistoryTexture);  SAMPLER(sampler_HistoryTexture);
        TEXTURE2D(_IndirectTexture); SAMPLER(sampler_IndirectTexture);

        TEXTURECUBE(_SSPT_SkyCube);  SAMPLER(sampler_SSPT_SkyCube);
        float4 _SSPT_SkyCube_HDR;
        float  _SSPT_UseSkybox;

        // ─────────────────────────────────────────────────────────────────────
        //  СЛУЧАЙНЫЕ ЧИСЛА И LOW-DISCREPANCY SEQUENCES
        //
        //  Проблема обычного pseudo-random: плохое покрытие пространства,
        //  видимые паттерны. Решение: low-discrepancy sequences.
        //
        //  Hammersley sequence: детерминированный набор точек, равномерно
        //  распределённых в [0,1)^2 с использованием Van der Corput sequence.
        //  Преимущество: быстрая сходимость O(1/N) vs O(1/√N) у MC.
        // ─────────────────────────────────────────────────────────────────────

        // Van der Corput: зеркалит биты числа вокруг десятичной точки.
        // Пример: 6 = 0b110 → 0b011 · 2^-3 = 0.375
        float VdC(uint bits)
        {
            bits = (bits << 16u) | (bits >> 16u);
            bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
            bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
            bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
            bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
            return float(bits) * 2.3283064365386963e-10; // / 0x100000000
        }

        // Hammersley: xi.x = равномерная сетка, xi.y = VdC (quasi-random)
        float2 Hammersley(uint i, uint N)
        {
            return float2(float(i) / float(N), VdC(i));
        }

        // Быстрый hash: uint → float в [0,1) для per-pixel scramble
        float HashF(uint n)
        {
            n = (n ^ 61u) ^ (n >> 16u);
            n *= 9u; n ^= n >> 4u;
            n *= 0x27d4eb2du; n ^= n >> 15u;
            return float(n) * (1.0 / 4294967296.0);
        }

        // Interleaved Gradient Noise (Jimenez 2014, XDev talk)
        // Анимированный: разный результат на каждом кадре (frame offset),
        // но одинаковый паттерн по пространству → temporal accumulation
        // видит новые сэмплы на каждом кадре.
        float IGN(float2 p, float frame)
        {
            p += frame * float2(47.53f, 83.21f); // golden-ratio-based shift
            return frac(52.9829189f * frac(dot(p, float2(0.06711056f, 0.00583715f))));
        }

        // ─────────────────────────────────────────────────────────────────────
        //  IMPORTANCE SAMPLING: COSINE-WEIGHTED HEMISPHERE
        //
        //  Для Lambertian BRDF: fr = albedo/π
        //  Уравнение рендеринга упрощается при importance sampling по cosθ:
        //
        //    E[f/pdf] = E[(albedo/π · Li · cosθ) / (cosθ/π)]
        //             = E[albedo · Li]
        //             ≈ albedo · mean(Li)   (при albedo=1: просто mean(Li))
        //
        //  → Нет веса cosθ при суммировании, просто среднее Li.
        // ─────────────────────────────────────────────────────────────────────

        // Cosine-weighted hemisphere sample (Malley's method)
        // xi ∈ [0,1)^2 → направление с z>0 (локальное, z=вверх=normal)
        float3 CosineSampleHemisphere(float2 xi)
        {
            float phi = TWO_PI * xi.x;          // азимутальный угол
            float r   = sqrt(xi.y);              // радиус на диске (проекция)
            float z   = sqrt(max(0.0, 1.0 - xi.y)); // cosθ = z
            return float3(r * cos(phi), r * sin(phi), z);
        }

        // Pixar/Frisvad ортонормальный базис из нормали (numerically stable)
        // Позволяет преобразовать локальный hemisphere sample в world-space.
        void BuildTBN(float3 n, out float3 t, out float3 b)
        {
            float s = (n.z >= 0.0) ? 1.0 : -1.0;
            float a = -1.0 / (s + n.z);
            float c = n.x * n.y * a;
            t = float3(1.0 + s * n.x * n.x * a, s * c, -s * n.x);
            b = float3(c, s + n.y * n.y * a, -n.y);
        }

        // Преобразуем локальный hemisphere sample в space нормали
        float3 LocalToWorld(float3 d, float3 n)
        {
            float3 t, b;
            BuildTBN(n, t, b);
            return normalize(t * d.x + b * d.y + n * d.z);
        }

        // ─────────────────────────────────────────────────────────────────────
        //  ГЕОМЕТРИЧЕСКИЕ УТИЛИТЫ
        // ─────────────────────────────────────────────────────────────────────

        // LOD=0 → без gradient sampling, безопасно внутри циклов
        float SampleDepthLOD(float2 uv)
        {
            return SAMPLE_TEXTURE2D_LOD(_CameraDepthTexture,
                                        sampler_CameraDepthTexture, uv, 0).r;
        }

        // Raw depth → линейная глубина в world units (camera eye depth)
        float EyeDepth(float raw)
        {
            if (unity_OrthoParams.w > 0.5)
            {
                #if UNITY_REVERSED_Z
                float lin = 1.0 - raw;
                #else
                float lin = raw;
                #endif
                return lerp(_ProjectionParams.y, _ProjectionParams.z, lin);
            }
            return LinearEyeDepth(raw, _ZBufferParams);
        }

        // Screen UV + raw depth → позиция в View Space
        // Используем UNITY_MATRIX_I_P (обратная проекционная матрица)
        float3 ReconstructViewPos(float2 uv, float raw)
        {
            if (_ProjectionParams.x < 0) uv.y = 1.0 - uv.y; // Y-flip
            float4 clip = float4(uv * 2.0 - 1.0, raw, 1.0);
            float4 view = mul(UNITY_MATRIX_I_P, clip);
            return view.xyz / view.w; // perspective divide
        }

        // View Space → Screen UV (и z/w для глубины)
        float3 ViewToScreen(float3 vp)
        {
            float4 clip   = mul(UNITY_MATRIX_P, float4(vp, 1.0));
            float4 screen = ComputeScreenPos(clip);
            return float3(screen.xy / screen.w, screen.z / screen.w);
        }

        // ─────────────────────────────────────────────────────────────────────
        //  SCREEN SPACE RAY MARCHING
        //
        //  Луч марширует в View Space (равномерные шаги по мировым единицам),
        //  но каждый шаг проецируется в Screen Space для сэмплирования depth.
        //
        //  Преимущество View Space марчинга: нет искажений перспективы,
        //  шаги одинакового размера в мировых единицах.
        //
        //  Binary Search уточняет точку пересечения после грубого хита.
        // ─────────────────────────────────────────────────────────────────────

        // Возвращает: xy = hitUV, z = 1 если хит, w = fade
        float4 RayMarch(float3 origin, float3 dir, float jitter)
        {
            float stepSize = _MaxDistance / _MaxSteps;

            // Начальный offset: избегает self-intersection.
            // Jitter делает первый шаг случайным → temporal accumulation
            // превращает это в правильное сэмплирование.
            float3 pos  = origin + dir * stepSize * (0.5 + jitter);
            float3 prev = origin;
            float  prevDiff = -1.0;

            [loop]
            for (int i = 0; i < 128; i++)
            {
                if (i >= _MaxSteps) break;

                float3 ss = ViewToScreen(pos);
                float2 uv = ss.xy;

                // Луч вышел за экран
                if (any(uv < 0.0) || any(uv > 1.0)) break;

                // Сравниваем глубину луча и геометрии
                float sceneDepth = EyeDepth(SampleDepthLOD(uv));
                float rayDepth   = -pos.z; // view-space Z отрицателен в Unity
                float diff       = rayDepth - sceneDepth;

                // Хит: луч прошёл чуть за поверхность (в пределах Thickness)
                if (prevDiff <= 0.0 && diff > 0.0 && diff < _Thickness)
                {
                    // Binary Search: 5 итераций бисекции для точного UV хита
                    float3 lo = prev, hi = pos;
                    float2 hitUV = uv;

                    [unroll]
                    for (int j = 0; j < 5; j++)
                    {
                        float3 mid = (lo + hi) * 0.5;
                        float3 mss = ViewToScreen(mid);
                        float2 muv = mss.xy;
                        if (any(muv < 0.0) || any(muv > 1.0)) { hi = mid; continue; }
                        float mScene = EyeDepth(SampleDepthLOD(muv));
                        if (-mid.z > mScene) { hi = mid; hitUV = muv; }
                        else                 { lo = mid; }
                    }

                    // Edge fade: плавное исчезновение у краёв экрана
                    float2 ef   = smoothstep(0.0, _EdgeFade, hitUV) *
                                  smoothstep(0.0, _EdgeFade, 1.0 - hitUV);
                    // Distance fade: затухание с расстоянием
                    float  dist = length(pos - origin);
                    float  fade = ef.x * ef.y * (1.0 - saturate(dist / _MaxDistance));

                    return float4(hitUV, 1.0, fade);
                }

                prev     = pos;
                prevDiff = diff;
                pos     += dir * stepSize;
            }

            return float4(0, 0, 0, 0); // miss
        }

        // Сэмплируем skybox cubemap: View Space dir → World Space → cubemap
        half3 SampleSky(float3 dirVS)
        {
            float3 dirWS = mul((float3x3)UNITY_MATRIX_I_V, dirVS);
            half4  enc   = SAMPLE_TEXTURECUBE_LOD(_SSPT_SkyCube, sampler_SSPT_SkyCube, dirWS, 0);
            return DecodeHDREnvironment(enc, _SSPT_SkyCube_HDR);
        }

        half MaxComponent(half3 v)
        {
            return max(v.x, max(v.y, v.z));
        }

        ENDHLSL

        // ═════════════════════════════════════════════════════════════════════
        //  PASS 0 — TRACE
        //
        //  Для каждого пикселя стреляем N стохастических лучей из hemisphere
        //  над surface normal. Собираем incoming radiance Li из:
        //   a) screen-space хит → цвет пикселя сцены (уже содержит direct light)
        //   b) miss → skybox
        //
        //  Результат: сырой (зашумлённый) буфер indirect radiance.
        //
        //  КЛЮЧЕВАЯ ИДЕЯ: scene color buffer на момент трейса уже содержит
        //  direct lighting + indirect от предыдущих кадров (через temporal acc.).
        //  → Каждый кадр добавляет один bounce, temporal строит multi-bounce GI.
        // ═════════════════════════════════════════════════════════════════════
        Pass
        {
            Name "SSPT_Trace"
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag_Trace

            half4 Frag_Trace(Varyings input) : SV_Target
            {
                float2 uv  = input.texcoord;
                float  raw = SampleDepthLOD(uv);

                // Пропускаем небо
                #if UNITY_REVERSED_Z
                if (raw < 0.0001) return half4(0, 0, 0, 0);
                #else
                if (raw > 0.9999) return half4(0, 0, 0, 0);
                #endif

                float3 viewPos  = ReconstructViewPos(uv, raw);
                float3 normalWS = SampleSceneNormals(uv);
                // Нормаль в View Space (для ray marching в VS)
                float3 normalVS = normalize(mul((float3x3)UNITY_MATRIX_V, normalWS));

                float2 px = uv * _ScreenParams.xy; // пиксельные координаты
                uint   fi = (uint)_FrameIndex;

                half3 totalRadiance = 0;

                [loop]
                for (int s = 0; s < 8; s++) // [loop] с compile-time cap = 8
                {
                    if (s >= _SampleCount) break;

                    // ── Генерируем квази-случайный 2D сэмпл ─────────────────
                    // Hammersley с per-pixel scramble + per-frame offset:
                    // - Per-frame: Hammersley индекс смещается на N каждый кадр
                    //   → temporal accumulation видит разные сэмплы по кадрам
                    // - Per-pixel scramble: IGN + hash разбивает корреляцию
                    //   между соседними пикселями (иначе видны полосы)
                    uint N    = (uint)max(1, _SampleCount) * 64u; // 64-кадровый цикл
                    uint idx  = ((uint)s + fi * (uint)max(1, _SampleCount)) % N;
                    float2 xi = Hammersley(idx, N);

                    // Per-pixel + per-sample scramble
                    uint seed = (uint)px.x * 1619u + (uint)px.y * 31337u;
                    xi.x = frac(xi.x + IGN(px, _FrameIndex));
                    xi.y = frac(xi.y + HashF(seed ^ (uint)s * 7919u));

                    // ── Направление луча ─────────────────────────────────────
                    // Cosine-weighted hemisphere → importance sampling для diffuse
                    float3 localDir = CosineSampleHemisphere(xi);
                    float3 rayDir   = LocalToWorld(localDir, normalVS);

                    // Защита от лучей сквозь поверхность
                    if (dot(rayDir, normalVS) < 0.001) continue;

                    // Jitter для starting offset: hash вместо IGN — пространственно
                    // декоррелированный (нет когерентных полос → нет волн)
                    float jitter = HashF(seed ^ (fi * 6271u) ^ ((uint)s * 1117u));

                    // ── Ray march ────────────────────────────────────────────
                    float4 hit = RayMarch(viewPos, rayDir, jitter);

                    half3 L;
                    if (hit.z > 0.5)
                    {
                        L = SAMPLE_TEXTURE2D_LOD(_BlitTexture, sampler_LinearClamp, hit.xy, 0).rgb
                            * hit.w;
                    }
                    else if (_SSPT_UseSkybox > 0.5)
                    {
                        L = SampleSky(rayDir);
                    }
                    else
                    {
                        L = 0;
                    }

                    // Firefly rejection: ограничиваем яркость сэмпла по luminance.
                    // Без этого один очень яркий пиксель (окно, эмиссив) накапливается
                    // в истории и даёт стойкое засветление.
                    half lum = dot(L, half3(0.2126h, 0.7152h, 0.0722h));
                    if (lum > 2.0h) L *= 2.0h / lum;

                    totalRadiance += L;
                }

                totalRadiance /= (float)max(1, _SampleCount);
                return half4(totalRadiance, 1.0);
            }
            ENDHLSL
        }

        // ═════════════════════════════════════════════════════════════════════
        //  PASS 1 — TEMPORAL ACCUMULATION
        //
        //  Смешиваем текущий зашумлённый кадр с историей предыдущих кадров:
        //    acc(t) = lerp(history(t-1), current(t), alpha)
        //           = (1-alpha)·history + alpha·current
        //
        //  При alpha=0.1 и статичной сцене: effective sample count ≈ 1/alpha = 10
        //  После 10 кадров: SNR улучшается в √10 ≈ 3.16x
        //
        //  GHOSTING: при движении объектов/камеры history некорректна.
        //  Решение — variance clamping: ограничиваем историю в пределах
        //  распределения текущих соседних пикселей. Это разрушает устаревшие
        //  хвосты истории без полного сброса накопления.
        // ═════════════════════════════════════════════════════════════════════
        Pass
        {
            Name "SSPT_Temporal"
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag_Temporal

            half4 Frag_Temporal(Varyings input) : SV_Target
            {
                float2 uv = input.texcoord;

                // Текущий кадр (raw trace output)
                half3 cur = SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, uv).rgb;
                // Предыдущий накопленный (history)
                half3 his = SAMPLE_TEXTURE2D(_HistoryTexture, sampler_HistoryTexture, uv).rgb;

                // ── Variance Clamping (anti-ghosting) ────────────────────────
                // Собираем статистику (mean, variance) из 3x3 окрестности текущего кадра.
                // История за пределами [mean ± k·σ] считается устаревшей и клампится.
                half3  mean = 0, sq = 0;
                float2 tx   = 1.0 / _ScreenParams.xy;

                [unroll]
                for (int dy = -1; dy <= 1; dy++)
                [unroll]
                for (int dx = -1; dx <= 1; dx++)
                {
                    half3 s = SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp,
                                               uv + float2(dx, dy) * tx).rgb;
                    mean += s;
                    sq   += s * s;
                }
                mean /= 9.0;
                sq   /= 9.0;

                // Дисперсия: E[X²] - E[X]²
                half3 sigma = sqrt(max(0, sq - mean * mean));

                // k=2.5: с 1spp variance в 3x3 окрестности высокая, k=1.5 отвергал
                // историю слишком агрессивно → мерцание и полосы.
                his = clamp(his, mean - 2.5 * sigma, mean + 2.5 * sigma);

                // Exponential Moving Average
                half3 acc = lerp(his, cur, _TemporalAlpha);
                return half4(acc, 1.0);
            }
            ENDHLSL
        }

        // ═════════════════════════════════════════════════════════════════════
        //  PASS 2 — À-TROUS WAVELET SPATIAL DENOISING (одна итерация)
        //
        //  Edge-aware (bilateral) фильтр, вызывается C# несколько раз
        //  с удваивающимся step width: 1 → 2 → 4 → 8 пикселей.
        //
        //  "À-trous" = "с дырками" (фр.): разреженный 5×5 kernel,
        //  эффективный радиус растёт без увеличения числа сэмплов (25 сэмплов).
        //
        //  Итерация i: step=2^i  → effective radius = 2·(2^i - 1) + 2
        //   i=0: 2px, i=1: 6px, i=2: 14px, i=3: 30px
        //
        //  Bilateral weights сохраняют края:
        //   - Depth weight: exp(-|Δdepth| / σd)
        //   - Normal weight: pow(dot(n1,n2), power)
        // ═════════════════════════════════════════════════════════════════════
        Pass
        {
            Name "SSPT_Denoise"
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag_Denoise

            half4 Frag_Denoise(Varyings input) : SV_Target
            {
                float2 uv  = input.texcoord;
                float  raw = SampleDepthLOD(uv);

                // Пропускаем небо (нет геометрии — нет GI)
                #if UNITY_REVERSED_Z
                if (raw < 0.0001) return SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, uv);
                #else
                if (raw > 0.9999) return SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, uv);
                #endif

                float  cDepth  = EyeDepth(raw);
                float3 cNormal = SampleSceneNormals(uv);
                float2 tx      = 1.0 / _ScreenParams.xy;

                // À-trous Gaussian weights (1D: h = [1/16, 1/4, 3/8, 1/4, 1/16])
                // 2D kernel = outer product h[dy] · h[dx]
                const float h[5] = { 0.0625, 0.25, 0.375, 0.25, 0.0625 };

                half3 weightedSum = 0;
                float totalWeight = 0;

                [unroll]
                for (int dy = 0; dy < 5; dy++)
                [unroll]
                for (int dx = 0; dx < 5; dx++)
                {
                    float2 offset = float2(dx - 2, dy - 2) * tx * _DenoiseStepWidth;
                    float2 suv    = saturate(uv + offset);

                    float  sRaw   = SampleDepthLOD(suv);
                    float  sDepth = EyeDepth(sRaw);
                    float3 sNorm  = SampleSceneNormals(suv);

                    // Bilateral weight: глубина
                    float wDepth  = exp(-abs(cDepth - sDepth));

                    // Bilateral weight: нормаль (sharp: pow=8)
                    float wNormal = pow(saturate(dot(cNormal, sNorm)), 8.0);

                    // Gaussian kernel weight
                    float w = h[dx] * h[dy] * wDepth * wNormal;

                    half3 s = SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, suv).rgb;
                    weightedSum += s * w;
                    totalWeight += w;
                }

                half3 result = (totalWeight > 0.001)
                    ? weightedSum / totalWeight
                    : SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, uv).rgb;

                return half4(result, 1.0);
            }
            ENDHLSL
        }

        // ═════════════════════════════════════════════════════════════════════
        //  PASS 3 — COMPOSITE
        //
        //  Добавляем denoised indirect GI к direct lighting сцены:
        //    L_final = L_direct + L_indirect · intensity
        //
        //  L_direct = результат всех предыдущих рендер пассов (direct + SSR + etc.)
        //  L_indirect = аккумулированный и отфильтрованный SSPT GI
        //
        //  Физическое обоснование: это single-bounce approximation уравнения
        //  рендеринга. Multi-bounce строится temporal accumulation
        //  (луч "видит" GI предыдущих кадров через scene color).
        // ═════════════════════════════════════════════════════════════════════
        Pass
        {
            Name "SSPT_Composite"
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag_Composite

            half4 Frag_Composite(Varyings input) : SV_Target
            {
                float2 uv = input.texcoord;
                half4  sc = SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, uv);

                float raw = SampleDepthLOD(uv);
                #if UNITY_REVERSED_Z
                if (raw < 0.0001) return sc;
                #else
                if (raw > 0.9999) return sc;
                #endif

                half3 indirect = SAMPLE_TEXTURE2D(_IndirectTexture, sampler_IndirectTexture, uv).rgb;
                return half4(sc.rgb + (indirect - MaxComponent(indirect))  * _IndirectIntensity, sc.a);
            }
            ENDHLSL
        }
    }
}
