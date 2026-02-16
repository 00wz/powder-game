Shader "Custom/Lit"
{
    Properties
    {
        [MainColor] _BaseColor ("Base Color", Color) = (1, 1, 1, 1)
        [MainTexture] _BaseMap ("Base Map", 2D) = "white" {}
        
        [Header(Specular)]
        _Smoothness ("Smoothness", Range(0, 1)) = 0.5
        _SpecularColor ("Specular Color", Color) = (1, 1, 1, 1)
        
        [Header(Normal)]
        [Normal] _BumpMap ("Normal Map", 2D) = "bump" {}
        _BumpScale ("Normal Scale", Float) = 1.0
    }
    
    SubShader
    {
        Tags 
        { 
            "RenderType" = "Opaque" 
            "RenderPipeline" = "CustomPipeline"
            "Queue" = "Geometry"
        }
        
        // ===== MAIN PASS - CustomLit =====
        Pass
        {
            Name "CustomLit"
            Tags { "LightMode" = "CustomLit" }
            
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            
            // Variants
            #pragma multi_compile _ _ADDITIONAL_LIGHTS
            #pragma multi_compile_fog
            
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Packing.hlsl"
            
            // === Глобальные переменные освещения (устанавливаются из C#) ===
            
            // Main Directional Light
            float4 _MainLightDirection;   // xyz = direction, w = unused
            float4 _MainLightColor;       // rgb = color * intensity, a = unused
            
            // Additional Lights
            int _AdditionalLightCount;
            float4 _AdditionalLightPositions[16];  // xyz = position, w = range
            float4 _AdditionalLightColors[16];     // rgb = color * intensity
            
            // Ambient
            float4 _AmbientLight;
            
            // Camera
            float3 _WorldSpaceCameraPos;
            
            // === Shadows ===
            TEXTURE2D_SHADOW(_ShadowMap);
            SAMPLER_CMP(sampler_ShadowMap);
            
            float4x4 _LightViewProjection;
            float _ShadowBias;
            float _ShadowStrength;
            float4 _ShadowMapSize;  // xy = size, zw = 1/size
            
            // === Свойства материала ===
            TEXTURE2D(_BaseMap);
            SAMPLER(sampler_BaseMap);
            
            TEXTURE2D(_BumpMap);
            SAMPLER(sampler_BumpMap);
            
            CBUFFER_START(UnityPerMaterial)
                float4 _BaseColor;
                float4 _BaseMap_ST;
                float4 _SpecularColor;
                float _Smoothness;
                float _BumpScale;
            CBUFFER_END
            
            // === Матрицы трансформации ===
            float4x4 unity_ObjectToWorld;
            float4x4 unity_WorldToObject;
            float4x4 unity_MatrixVP;
            
            // === Структуры ===
            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
                float4 tangentOS : TANGENT;
                float2 uv : TEXCOORD0;
            };
            
            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 normalWS : TEXCOORD0;
                float3 positionWS : TEXCOORD1;
                float2 uv : TEXCOORD2;
                float3 tangentWS : TEXCOORD3;
                float3 bitangentWS : TEXCOORD4;
            };
            
            // === Функции освещения ===
            
            // Lambert diffuse
            float LambertDiffuse(float3 normal, float3 lightDir)
            {
                return max(0.0, dot(normal, lightDir));
            }
            
            // Blinn-Phong specular
            float BlinnPhongSpecular(float3 normal, float3 lightDir, float3 viewDir, float smoothness)
            {
                float3 halfDir = normalize(lightDir + viewDir);
                float NdotH = max(0.0, dot(normal, halfDir));
                
                // Преобразуем smoothness (0-1) в shininess (1-256)
                float shininess = exp2(10.0 * smoothness + 1.0);
                
                return pow(NdotH, shininess);
            }
            
            // Затухание по расстоянию (smooth falloff)
            float DistanceAttenuation(float distance, float range)
            {
                // Избегаем деления на ноль
                float rangeSqr = max(range * range, 0.0001);
                float distanceSqr = distance * distance;
                
                // Smooth falloff
                float factor = distanceSqr / rangeSqr;
                float smoothFactor = saturate(1.0 - factor * factor);
                
                // Квадратичное затухание для мягкого перехода
                return smoothFactor * smoothFactor;
            }
            
            // === Функции теней ===
            
            /// <summary>
            /// Сэмплирует shadow map и возвращает коэффициент освещённости (0 = в тени, 1 = освещено).
            /// </summary>
            float SampleShadowMap(float3 positionWS)
            {
                // 1. Трансформируем в пространство света
                // Матрица _LightViewProjection уже включает преобразование NDC -> UV [0,1]
                float4 shadowCoord = mul(_LightViewProjection, float4(positionWS, 1.0));
                
                // 2. Perspective divide (для directional light w=1, но для spot/point нужен)
                shadowCoord.xyz /= shadowCoord.w;
                
                // 3. Проверяем, находится ли точка в пределах shadow map
                if (shadowCoord.x < 0 || shadowCoord.x > 1 ||
                    shadowCoord.y < 0 || shadowCoord.y > 1 ||
                    shadowCoord.z < 0 || shadowCoord.z > 1)
                {
                    return 1.0;  // Вне shadow map — нет тени
                }
                
                // 4. Сэмплируем shadow map с аппаратным сравнением (PCF 1 sample)
                float shadow = SAMPLE_TEXTURE2D_SHADOW(_ShadowMap, sampler_ShadowMap, shadowCoord.xyz);
                
                // 5. Применяем силу тени
                return lerp(1.0, shadow, _ShadowStrength);
            }
            
            /// <summary>
            /// PCF (Percentage Closer Filtering) — мягкие тени.
            /// Сэмплирует несколько точек вокруг и усредняет результат.
            /// </summary>
            float SampleShadowMapPCF(float3 positionWS)
            {
                // Трансформируем в пространство света
                // Матрица _LightViewProjection уже включает преобразование NDC -> UV [0,1]
                float4 shadowCoord = mul(_LightViewProjection, float4(positionWS, 1.0));
                shadowCoord.xyz /= shadowCoord.w;
                
                // Проверяем границы
                if (shadowCoord.x < 0 || shadowCoord.x > 1 ||
                    shadowCoord.y < 0 || shadowCoord.y > 1 ||
                    shadowCoord.z < 0 || shadowCoord.z > 1)
                {
                    return 1.0;
                }
                
                // Размер текселя shadow map
                float2 texelSize = _ShadowMapSize.zw;
                
                float shadow = 0.0;
                
                // 3x3 kernel PCF
                [unroll]
                for (int x = -1; x <= 1; x++)
                {
                    [unroll]
                    for (int y = -1; y <= 1; y++)
                    {
                        float2 offset = float2(x, y) * texelSize;
                        float3 sampleCoord = float3(shadowCoord.xy + offset, shadowCoord.z);
                        shadow += SAMPLE_TEXTURE2D_SHADOW(_ShadowMap, sampler_ShadowMap, sampleCoord);
                    }
                }
                
                shadow /= 9.0;  // Усредняем 9 сэмплов
                
                return lerp(1.0, shadow, _ShadowStrength);
            }
            
            // === Vertex Shader ===
            Varyings vert(Attributes input)
            {
                Varyings output;
                
                // Object to World position
                float3 positionWS = mul(unity_ObjectToWorld, float4(input.positionOS.xyz, 1.0)).xyz;
                output.positionWS = positionWS;
                
                // World to Clip position
                output.positionCS = mul(unity_MatrixVP, float4(positionWS, 1.0));
                
                // Transform normal to world space
                // Используем inverse transpose для корректной трансформации нормалей
                float3 normalWS = normalize(mul((float3x3)unity_ObjectToWorld, input.normalOS));
                output.normalWS = normalWS;
                
                // Transform tangent to world space
                float3 tangentWS = normalize(mul((float3x3)unity_ObjectToWorld, input.tangentOS.xyz));
                output.tangentWS = tangentWS;
                
                // Compute bitangent
                float3 bitangentWS = cross(normalWS, tangentWS) * input.tangentOS.w;
                output.bitangentWS = bitangentWS;
                
                // UV
                output.uv = input.uv * _BaseMap_ST.xy + _BaseMap_ST.zw;
                
                return output;
            }
            
            // === Fragment Shader ===
            float4 frag(Varyings input) : SV_Target
            {
                // === Подготовка данных ===
                
                // Нормализуем после интерполяции
                float3 normalWS = normalize(input.normalWS);
                float3 tangentWS = normalize(input.tangentWS);
                float3 bitangentWS = normalize(input.bitangentWS);
                
                // Normal mapping
                float3 normalTS = UnpackNormalScale(
                    SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, input.uv),
                    _BumpScale
                );
                
                // TBN matrix для преобразования normal map в world space
                float3x3 TBN = float3x3(tangentWS, bitangentWS, normalWS);
                normalWS = normalize(mul(normalTS, TBN));
                
                // View direction
                float3 viewDir = normalize(_WorldSpaceCameraPos - input.positionWS);
                
                // Базовый цвет
                float4 baseMap = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, input.uv);
                float3 albedo = baseMap.rgb * _BaseColor.rgb;
                float alpha = baseMap.a * _BaseColor.a;
                
                // === ОСВЕЩЕНИЕ ===
                
                float3 diffuseLight = float3(0, 0, 0);
                float3 specularLight = float3(0, 0, 0);
                
                // === 1. Main Directional Light ===
                {
                    float3 lightDir = normalize(_MainLightDirection.xyz);
                    float3 lightColor = _MainLightColor.rgb;
                    
                    // Получаем коэффициент тени (PCF soft shadows)
                    float shadowAttenuation = SampleShadowMapPCF(input.positionWS);
                    
                    // Diffuse (с учётом тени)
                    float NdotL = LambertDiffuse(normalWS, lightDir);
                    diffuseLight += lightColor * NdotL * shadowAttenuation;
                    
                    // Specular (с учётом тени)
                    float spec = BlinnPhongSpecular(normalWS, lightDir, viewDir, _Smoothness);
                    specularLight += lightColor * spec * NdotL * shadowAttenuation;
                }
                
                // === 2. Additional Point/Spot Lights ===
                #ifdef _ADDITIONAL_LIGHTS
                for (int i = 0; i < _AdditionalLightCount; i++)
                {
                    float4 lightPos = _AdditionalLightPositions[i];
                    float3 lightColor = _AdditionalLightColors[i].rgb;
                    
                    // Направление к источнику
                    float3 lightVec = lightPos.xyz - input.positionWS;
                    float distance = length(lightVec);
                    float3 lightDir = lightVec / max(distance, 0.0001);
                    
                    // Затухание
                    float range = lightPos.w;
                    float attenuation = DistanceAttenuation(distance, range);
                    
                    // Пропускаем если затухание слишком мало
                    if (attenuation < 0.001)
                        continue;
                    
                    // Diffuse
                    float NdotL = LambertDiffuse(normalWS, lightDir);
                    diffuseLight += lightColor * NdotL * attenuation;
                    
                    // Specular
                    float spec = BlinnPhongSpecular(normalWS, lightDir, viewDir, _Smoothness);
                    specularLight += lightColor * spec * NdotL * attenuation;
                }
                #endif
                
                // === 3. Ambient ===
                float3 ambient = _AmbientLight.rgb;
                
                // === Итоговый цвет ===
                float3 finalColor = albedo * (diffuseLight + ambient) + 
                                    _SpecularColor.rgb * specularLight;
                
                return float4(finalColor, alpha);
            }
            ENDHLSL
        }
        
        // ===== SHADOW CASTER PASS =====
        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode" = "ShadowCaster" }
            
            ZWrite On
            ZTest LEqual
            ColorMask 0  // Не пишем цвет, только глубину
            Cull Back
            
            HLSLPROGRAM
            #pragma vertex ShadowVert
            #pragma fragment ShadowFrag
            
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
            
            float4x4 unity_ObjectToWorld;
            float4x4 unity_MatrixVP;
            float _ShadowBias;
            
            struct ShadowAttributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
            };
            
            struct ShadowVaryings
            {
                float4 positionCS : SV_POSITION;
            };
            
            ShadowVaryings ShadowVert(ShadowAttributes input)
            {
                ShadowVaryings output;
                
                // Object to World
                float3 positionWS = mul(unity_ObjectToWorld, float4(input.positionOS.xyz, 1.0)).xyz;
                float3 normalWS = normalize(mul((float3x3)unity_ObjectToWorld, input.normalOS));
                
                // Применяем bias вдоль нормали для уменьшения shadow acne
                positionWS += normalWS * _ShadowBias;
                
                // World to Clip (используем VP матрицу света)
                output.positionCS = mul(unity_MatrixVP, float4(positionWS, 1.0));
                
                return output;
            }
            
            float4 ShadowFrag(ShadowVaryings input) : SV_Target
            {
                return 0;  // Не важно, пишем только глубину
            }
            ENDHLSL
        }
        
        // ===== DEPTH ONLY PASS =====
        Pass
        {
            Name "DepthOnly"
            Tags { "LightMode" = "DepthOnly" }
            
            ZWrite On
            ColorMask 0
            
            HLSLPROGRAM
            #pragma vertex VertDepth
            #pragma fragment FragDepth
            
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
            
            float4x4 unity_ObjectToWorld;
            float4x4 unity_MatrixVP;
            
            struct AttributesDepth
            {
                float4 positionOS : POSITION;
            };
            
            struct VaryingsDepth
            {
                float4 positionCS : SV_POSITION;
            };
            
            VaryingsDepth VertDepth(AttributesDepth input)
            {
                VaryingsDepth output;
                float3 positionWS = mul(unity_ObjectToWorld, float4(input.positionOS.xyz, 1.0)).xyz;
                output.positionCS = mul(unity_MatrixVP, float4(positionWS, 1.0));
                return output;
            }
            
            float4 FragDepth(VaryingsDepth input) : SV_Target
            {
                return 0;
            }
            ENDHLSL
        }
    }
    
    // Fallback для shadows и других встроенных функций
    FallBack "Hidden/InternalErrorShader"
}
