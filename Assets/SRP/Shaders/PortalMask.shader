Shader "Custom/PortalMask"
{
    // Этот шейдер ЗАПИСЫВАЕТ в Stencil Buffer, но НЕ рисует цвет
    // Используется для создания "окна" портала
    
    Properties
    {
        _StencilRef ("Stencil Reference", Int) = 1
    }
    
    SubShader
    {
        Tags 
        { 
            "RenderType" = "Transparent" 
            "RenderPipeline" = "UniversalPipeline"
            "Queue" = "Geometry-1" // Рисуем ДО обычных объектов
        }
        
        Pass
        {
            Name "Portal Mask"
            
            //Stencil: ЗАПИСЫВАЕМ значение
            Stencil
            {
                Ref [_StencilRef]
                Comp Always         // Всегда проходим тест
                Pass Replace        // Записываем Ref в буфер
            }
            
            // НЕ пишем цвет - только Stencil
            ColorMask 0
            
            // НЕ пишем в Depth - объекты за порталом должны быть видны
            ZWrite Off
            ZTest LEqual
            
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            
            struct Attributes
            {
                float4 positionOS : POSITION;
            };
            
            struct Varyings
            {
                float4 positionCS : SV_POSITION;
            };
            
            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                OUT.positionCS = TransformObjectToHClip(IN.positionOS.xyz);
                return OUT;
            }
            
            half4 frag(Varyings IN) : SV_Target
            {
                // Ничего не возвращаем - ColorMask 0
                return 0;
            }
            ENDHLSL
        }
        
        // Второй проход: записываем глубину портала в отдельную текстуру
        // Этот проход вызывается через PortalDepthFeature
        Pass
        {
            Name "Portal Depth"
            Tags { "LightMode" = "PortalMask" }
            
            // Пишем ТОЛЬКО глубину
            ColorMask 0
            ZWrite On
            ZTest LEqual
            
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            
            struct Attributes
            {
                float4 positionOS : POSITION;
            };
            
            struct Varyings
            {
                float4 positionCS : SV_POSITION;
            };
            
            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                OUT.positionCS = TransformObjectToHClip(IN.positionOS.xyz);
                return OUT;
            }
            
            half4 frag(Varyings IN) : SV_Target
            {
                // Просто записываем глубину (автоматически через depth buffer)
                return 0;
            }
            ENDHLSL
        }
    }
}
