Shader "Custom/PortalContent"
{
    // Этот шейдер рисует объекты ТОЛЬКО там, где Stencil равен заданному значению
    // И только если объект находится ЗА порталом (глубина больше чем у портала)
    // Т.е. объекты видны только "через портал"
    
    Properties
    {
        _BaseColor ("Base Color", Color) = (1, 1, 1, 1)
        _StencilRef ("Stencil Reference", Int) = 1
        [Toggle] _UsePortalDepth ("Use Portal Depth Clipping", Float) = 1
    }
    
    SubShader
    {
        Tags
        {
            "RenderType" = "Opaque"
            "RenderPipeline" = "UniversalPipeline"
            "Queue" = "Geometry+1"
        }
        
        Pass
        {
            Name "Portal Content"
            
            // Stencil: ЧИТАЕМ и СРАВНИВАЕМ
            Stencil
            {
                Ref [_StencilRef]
                Comp Equal          // Рисуем ТОЛЬКО если Stencil == Ref
                Pass Keep           // Не меняем Stencil
            }
            
            // Обычный depth test
            ZTest LEqual
            ZWrite On
            
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma shader_feature_local _USEPORTALDEPTH_ON
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            
            // Текстура глубины порталов (заполняется PortalDepthFeature)
            TEXTURE2D(_PortalDepthTexture);
            SAMPLER(sampler_PortalDepthTexture);
            
            CBUFFER_START(UnityPerMaterial)
                float4 _BaseColor;
                float _UsePortalDepth;
            CBUFFER_END
            
            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
            };
            
            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 normalWS : TEXCOORD0;
                float4 screenPos : TEXCOORD1;
                float depth : TEXCOORD2;
            };
            
            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                OUT.positionCS = TransformObjectToHClip(IN.positionOS.xyz);
                OUT.normalWS = TransformObjectToWorldNormal(IN.normalOS);
                
                // Вычисляем screen position для сэмплирования текстуры глубины
                OUT.screenPos = ComputeScreenPos(OUT.positionCS);
                
                // Сохраняем линейную глубину для сравнения
                OUT.depth = OUT.positionCS.z / OUT.positionCS.w;
                
                return OUT;
            }
            
            half4 frag(Varyings IN) : SV_Target
            {
                #ifdef _USEPORTALDEPTH_ON
                // Получаем UV для сэмплирования текстуры глубины
                float2 screenUV = IN.screenPos.xy / IN.screenPos.w;
                
                // Сэмплируем глубину портала
                float portalDepth = SAMPLE_TEXTURE2D(_PortalDepthTexture, sampler_PortalDepthTexture, screenUV).r;
                
                // Текущая глубина пикселя (normalized device coordinates)
                float currentDepth = IN.depth;
                
                // Unity использует reversed-Z на большинстве платформ:
                // - Большая глубина (близко к 1) = БЛИЖЕ к камере
                // - Меньшая глубина (близко к 0) = ДАЛЬШЕ от камеры
                // 
                // Нам нужно рисовать объекты ЗА порталом (дальше от камеры)
                // Если текущая глубина БОЛЬШЕ чем глубина портала - объект ПЕРЕД порталом - отсекаем
                
                // portalDepth будет 0 если портала нет в этом пикселе (очищается в 0)
                // Проверяем: если portalDepth валидна и текущий пиксель ближе к камере чем портал
                if (portalDepth > 0.0001 && currentDepth > portalDepth)
                {
                    // Объект находится ПЕРЕД порталом - не рисуем
                    clip(-1);
                }
                #endif
                
                // Простое освещение (Lambert)
                Light mainLight = GetMainLight();
                float NdotL = saturate(dot(normalize(IN.normalWS), mainLight.direction));
                float3 lighting = mainLight.color * NdotL + 0.2; // ambient
                
                return half4(_BaseColor.rgb * lighting, 1);
            }
            ENDHLSL
        }
    }
}
