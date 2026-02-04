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

        // Матрицы для реконструкции позиции (с префиксом SSR_ чтобы избежать конфликтов)
        float4x4 _SSR_InverseProjectionMatrix;
        float4x4 _SSR_ProjectionMatrix;
        float4x4 _SSR_ViewMatrix;
        float4x4 _SSR_InverseViewMatrix;

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
            // NDC координаты
            float2 ndc = uv * 2.0 - 1.0;
            
            if (unity_OrthoParams.w > 0.5) // Orthographic
            {
                float3 viewPos;
                viewPos.x = ndc.x * unity_OrthoParams.x;
                viewPos.y = ndc.y * unity_OrthoParams.y;
                viewPos.z = -GetLinearEyeDepth(depth);
                return viewPos;
            }
            
            // Perspective
            float4 clipPos = float4(ndc.x, ndc.y, depth, 1.0);
            
            #if UNITY_REVERSED_Z
                clipPos.z = 1.0 - clipPos.z;
            #endif
            
            float4 viewPos = mul(_SSR_InverseProjectionMatrix, clipPos);
            return viewPos.xyz / viewPos.w;
        }

        // Проекция View Space → Screen UV
        float3 ViewToScreen(float3 viewPos)
        {
            float4 clipPos = mul(_SSR_ProjectionMatrix, float4(viewPos, 1.0));
            float3 ndc = clipPos.xyz / clipPos.w;
            
            float2 uv = ndc.xy * 0.5 + 0.5;
            
            #if UNITY_UV_STARTS_AT_TOP
                uv.y = 1.0 - uv.y;
            #endif
            
            return float3(uv, ndc.z);
        }

        // Шум для jittering
        float InterleavedGradientNoise(float2 pixelCoord)
        {
            float3 magic = float3(0.06711056, 0.00583715, 52.9829189);
            return frac(magic.z * frac(dot(pixelCoord, magic.xy)));
        }

        // Ray March в Screen Space
        // Возвращает: xy = hitUV, z = hit (0 или 1), w = fade
        float4 RayMarch(float3 viewOrigin, float3 viewDir, float2 screenUV)
        {
            float3 viewEnd = viewOrigin + viewDir * _MaxDistance;
            
            // Проецируем начало и конец в screen space
            float3 screenStart = ViewToScreen(viewOrigin);
            float3 screenEnd = ViewToScreen(viewEnd);
            
            // Направление в screen space
            float2 screenDir = screenEnd.xy - screenStart.xy;
            float screenDirLen = length(screenDir);
            
            if (screenDirLen < 0.001)
                return float4(0, 0, 0, 0);
            
            screenDir /= screenDirLen;
            
            // Фиксированное количество шагов для компилятора
            const int MAX_STEPS = 64;
            int steps = min(MAX_STEPS, max(1, (int)(screenDirLen / _StepSize)));
            
            float stepSize = screenDirLen / steps;
            
            // Jitter для уменьшения артефактов
            float jitter = InterleavedGradientNoise(screenUV * _ScreenParams.xy) * 0.5;
            
            float3 currentScreen = screenStart;
            float3 prevScreen = screenStart;
            
            // Начинаем с небольшим отступом, чтобы избежать self-intersection
            currentScreen.xy += screenDir * stepSize * (0.5 + jitter);
            
            [loop]
            for (int i = 0; i < MAX_STEPS; i++)
            {
                // Ранний выход если превысили нужное количество шагов
                if (i >= steps)
                    break;
                    
                // Проверяем, что UV в пределах экрана
                if (currentScreen.x < 0 || currentScreen.x > 1 ||
                    currentScreen.y < 0 || currentScreen.y > 1)
                    break;
                
                // Сэмплируем глубину сцены (без градиентов - LOD версия)
                float sceneDepth = SampleSceneDepthLOD(currentScreen.xy);
                float sceneLinearDepth = GetLinearEyeDepth(sceneDepth);
                
                // Интерполируем глубину луча
                float t = (float)(i + 1) / steps;
                float rayLinearDepth = lerp(-viewOrigin.z, -viewEnd.z, t);
                
                // Проверяем пересечение
                float depthDiff = rayLinearDepth - sceneLinearDepth;
                
                if (depthDiff > 0 && depthDiff < _Thickness)
                {
                    // Нашли пересечение!
                    float2 hitUV = currentScreen.xy;
                    
                    // Binary search refinement (3 итерации)
                    float3 midScreen;
                    float3 lo = prevScreen;
                    float3 hi = currentScreen;
                    
                    for (int j = 0; j < 3; j++)
                    {
                        midScreen = (lo + hi) * 0.5;
                        float midSceneDepth = SampleSceneDepthLOD(midScreen.xy);
                        float midSceneLinear = GetLinearEyeDepth(midSceneDepth);
                        
                        float midT = lerp(0, t, length(midScreen.xy - screenStart.xy) / screenDirLen);
                        float midRayLinear = lerp(-viewOrigin.z, -viewEnd.z, midT);
                        
                        if (midRayLinear > midSceneLinear)
                            hi = midScreen;
                        else
                            lo = midScreen;
                    }
                    
                    hitUV = midScreen.xy;
                    
                    // Fade к краям экрана
                    float2 edgeFade = smoothstep(0, _EdgeFade, hitUV) * 
                                      smoothstep(0, _EdgeFade, 1.0 - hitUV);
                    float screenFade = edgeFade.x * edgeFade.y;
                    
                    // Fade по расстоянию
                    float distFade = 1.0 - saturate(t);
                    
                    return float4(hitUV, 1.0, screenFade * distFade);
                }
                
                prevScreen = currentScreen;
                currentScreen.xy += screenDir * stepSize;
            }
            
            return float4(0, 0, 0, 0);
        }

        // Используем Vert из Blit.hlsl
        half4 Frag(Varyings input) : SV_Target
        {
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
            
            // Конвертируем нормаль в view space
            float3 normalVS = mul((float3x3)_SSR_ViewMatrix, normalWS);
            
            // Направление взгляда (в view space камера в начале координат, смотрит в -Z)
            float3 viewDir;
            if (unity_OrthoParams.w > 0.5) // Orthographic
            {
                viewDir = float3(0.0, 0.0, -1.0);
            }
            else
            {
                viewDir = normalize(viewPos);
            }
            
            // Направление отражения
            float3 reflectDir = reflect(viewDir, normalVS);
            
            // Пропускаем, если отражение направлено от камеры (за объект)
            // В view space, если reflectDir.z > 0, луч идёт к камере
            // if (reflectDir.z > 0.1)
            //     return sceneColor;
            
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
                float reflectionStrength = fade * _Intensity;// * fresnel;
                
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
