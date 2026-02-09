Shader "Hidden/SSR"
{
    Properties
    {
        _MaxSteps ("Max Steps", Range(8, 128)) = 32
        _StepSize ("Step Size", Range(0.001, 0.1)) = 0.02
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

        // Параметры SSR
        float _MaxSteps;
        float _StepSize;
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
            float3 currentViewPos = viewOrigin + viewDir * viewStepSize * (0.5 + jitter);
            float3 prevViewPos = viewOrigin;
            
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
                
                if (depthDiff > 0 && depthDiff < _Thickness)
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
                currentViewPos += viewDir * viewStepSize;
            }
            
            return float4(0, 0, 0, 0);
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
            
            // Ray march
            float4 hitResult = RayMarch(viewPos, reflectDir, uv);
            
            if (hitResult.z > 0.5) // Есть пересечение
            {
                float2 hitUV = hitResult.xy;
                float fade = hitResult.w;
                
                // Сэмплируем цвет отражения
                half4 reflectionColor = SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, hitUV);
                
                // Финальное смешивание
                float reflectionStrength = fade * _Intensity * fresnel;
                
                return half4(lerp(sceneColor.rgb, reflectionColor.rgb, reflectionStrength), sceneColor.a);
            }
            
            return sceneColor;
        }
        ENDHLSL

        Pass
        {
            Name "SSR"
            
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag
            ENDHLSL
        }
    }
}
