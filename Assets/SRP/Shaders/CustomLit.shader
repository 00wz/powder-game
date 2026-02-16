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
        // Основной проход рендеринга с освещением и тенями
        Pass
        {
            Name "CustomLit"
            Tags { "LightMode" = "CustomLit" }
            
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            
            // Shader variants
            #pragma multi_compile _ _ADDITIONAL_LIGHTS
            #pragma multi_compile_fog
            
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Packing.hlsl"
            
            // =====================================================
            // ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ (устанавливаются из C#)
            // =====================================================
            
            // --- Освещение ---
            float4 _MainLightDirection;   // xyz = направление к свету, w = unused
            float4 _MainLightColor;       // rgb = color * intensity
            
            int _AdditionalLightCount;
            float4 _AdditionalLightPositions[16];  // xyz = position, w = range
            float4 _AdditionalLightColors[16];     // rgb = color * intensity
            
            float4 _AmbientLight;
            float3 _WorldSpaceCameraPos;
            
            // --- Тени ---
            // Shadow map texture с аппаратным сравнением глубины
            TEXTURE2D_SHADOW(_ShadowMap);
            SAMPLER_CMP(sampler_ShadowMap);
            
            float4x4 _WorldToShadowMatrix;  // World → Shadow UV [0,1] + depth
            float _ShadowStrength;           // 0 = нет тени, 1 = полная тень
            float4 _ShadowMapSize;           // xy = size, zw = 1/size (для PCF)
            
            // --- Материал ---
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
            
            // --- Матрицы трансформации ---
            float4x4 unity_ObjectToWorld;
            float4x4 unity_WorldToObject;
            float4x4 unity_MatrixVP;
            
            // =====================================================
            // СТРУКТУРЫ ДАННЫХ
            // =====================================================
            
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
            
            // =====================================================
            // ФУНКЦИИ ОСВЕЩЕНИЯ
            // =====================================================
            
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
                float shininess = exp2(10.0 * smoothness + 1.0);
                return pow(NdotH, shininess);
            }
            
            // Затухание по расстоянию
            float DistanceAttenuation(float distance, float range)
            {
                float rangeSqr = max(range * range, 0.0001);
                float distanceSqr = distance * distance;
                float factor = distanceSqr / rangeSqr;
                float smoothFactor = saturate(1.0 - factor * factor);
                return smoothFactor * smoothFactor;
            }
            
            // =====================================================
            // ФУНКЦИИ ТЕНЕЙ
            // =====================================================
            
            /// <summary>
            /// Сэмплирует shadow map с PCF (Percentage Closer Filtering).
            /// 
            /// Bias применяется на GPU через SetGlobalDepthBias при рендеринге
            /// shadow casters, поэтому здесь только сэмплирование.
            /// 
            /// PCF усредняет 9 сэмплов (3x3 kernel) для мягких краёв теней.
            /// </summary>
            float SampleShadowMapPCF(float3 positionWS)
            {
                // 1. World position → Shadow UV + depth
                float4 shadowCoord = mul(_WorldToShadowMatrix, float4(positionWS, 1.0));
                shadowCoord.xyz /= shadowCoord.w;
                
                // 2. Проверка границ shadow map
                if (shadowCoord.x < 0.0 || shadowCoord.x > 1.0 ||
                    shadowCoord.y < 0.0 || shadowCoord.y > 1.0)
                {
                    return 1.0;  // Вне shadow map — нет тени
                }
                
                // 3. PCF 3x3 kernel
                float2 texelSize = _ShadowMapSize.zw;
                float shadow = 0.0;
                
                [unroll]
                for (int x = -1; x <= 1; x++)
                {
                    [unroll]
                    for (int y = -1; y <= 1; y++)
                    {
                        float2 offset = float2(x, y) * texelSize;
                        float2 sampleUV = saturate(shadowCoord.xy + offset);
                        float3 sampleCoord = float3(sampleUV, shadowCoord.z);
                        
                        // SAMPLE_TEXTURE2D_SHADOW делает аппаратное сравнение
                        shadow += SAMPLE_TEXTURE2D_SHADOW(_ShadowMap, sampler_ShadowMap, sampleCoord);
                    }
                }
                
                shadow /= 9.0;
                
                // 4. Применяем силу тени
                return lerp(1.0, shadow, _ShadowStrength);
            }
            
            // =====================================================
            // VERTEX SHADER
            // =====================================================
            
            Varyings vert(Attributes input)
            {
                Varyings output;
                
                // Object → World
                float3 positionWS = mul(unity_ObjectToWorld, float4(input.positionOS.xyz, 1.0)).xyz;
                output.positionWS = positionWS;
                
                // World → Clip
                output.positionCS = mul(unity_MatrixVP, float4(positionWS, 1.0));
                
                // Normal → World (используем inverse transpose)
                float3 normalWS = normalize(mul((float3x3)unity_ObjectToWorld, input.normalOS));
                output.normalWS = normalWS;
                
                // Tangent → World
                float3 tangentWS = normalize(mul((float3x3)unity_ObjectToWorld, input.tangentOS.xyz));
                output.tangentWS = tangentWS;
                
                // Bitangent
                output.bitangentWS = cross(normalWS, tangentWS) * input.tangentOS.w;
                
                // UV
                output.uv = input.uv * _BaseMap_ST.xy + _BaseMap_ST.zw;
                
                return output;
            }
            
            // =====================================================
            // FRAGMENT SHADER
            // =====================================================
            
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
                float3x3 TBN = float3x3(tangentWS, bitangentWS, normalWS);
                normalWS = normalize(mul(normalTS, TBN));
                
                // View direction
                float3 viewDir = normalize(_WorldSpaceCameraPos - input.positionWS);
                
                // Base color
                float4 baseMap = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, input.uv);
                float3 albedo = baseMap.rgb * _BaseColor.rgb;
                float alpha = baseMap.a * _BaseColor.a;
                
                // === ОСВЕЩЕНИЕ ===
                
                float3 diffuseLight = float3(0, 0, 0);
                float3 specularLight = float3(0, 0, 0);
                
                // --- 1. Main Directional Light ---
                {
                    float3 lightDir = normalize(_MainLightDirection.xyz);
                    float3 lightColor = _MainLightColor.rgb;
                    
                    // Тень
                    float shadowAttenuation = SampleShadowMapPCF(input.positionWS);
                    
                    // Diffuse
                    float NdotL = LambertDiffuse(normalWS, lightDir);
                    diffuseLight += lightColor * NdotL * shadowAttenuation;
                    
                    // Specular
                    float spec = BlinnPhongSpecular(normalWS, lightDir, viewDir, _Smoothness);
                    specularLight += lightColor * spec * NdotL * shadowAttenuation;
                }
                
                // --- 2. Additional Lights ---
                #ifdef _ADDITIONAL_LIGHTS
                for (int i = 0; i < _AdditionalLightCount; i++)
                {
                    float4 lightPos = _AdditionalLightPositions[i];
                    float3 lightColor = _AdditionalLightColors[i].rgb;
                    
                    float3 lightVec = lightPos.xyz - input.positionWS;
                    float distance = length(lightVec);
                    float3 lightDir = lightVec / max(distance, 0.0001);
                    
                    float range = lightPos.w;
                    float attenuation = DistanceAttenuation(distance, range);
                    
                    if (attenuation < 0.001)
                        continue;
                    
                    float NdotL = LambertDiffuse(normalWS, lightDir);
                    diffuseLight += lightColor * NdotL * attenuation;
                    
                    float spec = BlinnPhongSpecular(normalWS, lightDir, viewDir, _Smoothness);
                    specularLight += lightColor * spec * NdotL * attenuation;
                }
                #endif
                
                // --- 3. Ambient ---
                float3 ambient = _AmbientLight.rgb;
                
                // === Итоговый цвет ===
                float3 finalColor = albedo * (diffuseLight + ambient) + 
                                    _SpecularColor.rgb * specularLight;
                
                return float4(finalColor, alpha);
            }
            ENDHLSL
        }
        
        // ===== SHADOW CASTER PASS =====
        // Рендерит объект в shadow map (только глубина, без цвета)
        // Bias применяется через SetGlobalDepthBias в C#
        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode" = "ShadowCaster" }
            
            ZWrite On
            ZTest LEqual
            ColorMask 0  // Не пишем цвет
            Cull Back
            
            HLSLPROGRAM
            #pragma vertex ShadowVert
            #pragma fragment ShadowFrag
            
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
            
            float4x4 unity_ObjectToWorld;
            float4x4 unity_MatrixVP;
            
            struct ShadowAttributes
            {
                float4 positionOS : POSITION;
            };
            
            struct ShadowVaryings
            {
                float4 positionCS : SV_POSITION;
            };
            
            ShadowVaryings ShadowVert(ShadowAttributes input)
            {
                ShadowVaryings output;
                float3 positionWS = mul(unity_ObjectToWorld, float4(input.positionOS.xyz, 1.0)).xyz;
                output.positionCS = mul(unity_MatrixVP, float4(positionWS, 1.0));
                return output;
            }
            
            float4 ShadowFrag(ShadowVaryings input) : SV_Target
            {
                return 0;  // GPU записывает только глубину
            }
            ENDHLSL
        }
        
    }
    
    FallBack "Hidden/InternalErrorShader"
}
