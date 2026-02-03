Shader "Custom/SRP/XRayOutlineStencil"
{
    // Эффект X-Ray с контуром через STENCIL BUFFER
    // 
    // ЛОГИКА:
    // Pass 1: Записываем маску увеличенного объекта (stencil = 1), не рисуем цвет
    // Pass 2: Рисуем силуэт, записываем stencil = 2 (перезаписывает 1 внутри)
    // Pass 3: Рисуем контур только где stencil == 1 (увеличенная зона минус силуэт)
    //
    // Stencil Buffer после Pass 1:        После Pass 2:
    // ┌───────────────┐                   ┌───────────────┐
    // │   1 1 1 1 1   │                   │   1 1 1 1 1   │  ← остаётся 1
    // │ 1 1 1 1 1 1 1 │      =>           │ 1 2 2 2 2 2 1 │  ← становится 2
    // │ 1 1 1 1 1 1 1 │                   │ 1 2 2 2 2 2 1 │
    // │   1 1 1 1 1   │                   │   1 1 1 1 1   │
    // └───────────────┘                   └───────────────┘
    //
    // Pass 3 рисует только где stencil == 1 = КОНТУР!
    
    Properties
    {
        _SilhouetteColor ("Silhouette Color", Color) = (0.2, 0.5, 1.0, 0.5)
        _OutlineColor ("Outline Color", Color) = (0.0, 0.8, 1.0, 1.0)
        _OutlineWidth ("Outline Width", Range(0.001, 0.2)) = 0.03
    }
    
    SubShader
    {
        Tags 
        { 
            "RenderType" = "Transparent" 
            "RenderPipeline" = "UniversalPipeline"
            "Queue" = "Transparent"
        }
        
        // ============================================
        // PASS 1: Записываем маску УВЕЛИЧЕННОГО объекта
        // Stencil = 1, ColorMask 0 (не рисуем цвет)
        // ============================================
        Pass
        {
            Name "Stencil Mask"
            Tags { "LightMode" = "UniversalForward" }
            
            Stencil
            {
                Ref 1
                Comp Always
                Pass Replace      // Записываем 1
            }
            
            ZTest Greater         // X-Ray: только за стеной
            ZWrite Off
            ColorMask 0           // НЕ рисуем цвет
            Cull Front            // Back faces для увеличения наружу
            
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            
            CBUFFER_START(UnityPerMaterial)
                float4 _SilhouetteColor;
                float4 _OutlineColor;
                float _OutlineWidth;
            CBUFFER_END
            
            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
            };
            
            struct Varyings
            {
                float4 positionCS : SV_POSITION;
            };
            
            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                // Увеличиваем объект вдоль нормалей
                float3 expandedPos = IN.positionOS.xyz + IN.normalOS * _OutlineWidth;
                OUT.positionCS = TransformObjectToHClip(expandedPos);
                return OUT;
            }
            
            half4 frag(Varyings IN) : SV_Target
            {
                return 0; // ColorMask 0 всё равно блокирует
            }
            ENDHLSL
        }
        
        // ============================================
        // PASS 2: Рисуем СИЛУЭТ, записываем Stencil = 2
        // Это перезапишет 1 внутри силуэта
        // ============================================
        Pass
        {
            Name "Silhouette"
            Tags { "LightMode" = "UniversalForwardOnly" }
            
            Stencil
            {
                Ref 2
                Comp Always
                Pass Replace      // Записываем 2 (перезаписываем 1)
            }
            
            ZTest Greater         // X-Ray
            ZWrite Off
            Blend SrcAlpha OneMinusSrcAlpha
            Cull Back
            
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            
            CBUFFER_START(UnityPerMaterial)
                float4 _SilhouetteColor;
                float4 _OutlineColor;
                float _OutlineWidth;
            CBUFFER_END
            
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
                return _SilhouetteColor;
            }
            ENDHLSL
        }
        
        // ============================================
        // PASS 3: Рисуем КОНТУР
        // Только где Stencil == 1 (увеличенная зона БЕЗ силуэта)
        // Требует XRayOutlineFeature в Renderer!
        // ============================================
        Pass
        {
            Name "Outline"
            Tags { "LightMode" = "XRayOutline" }
            
            Stencil
            {
                Ref 1
                Comp Equal        // Рисуем ТОЛЬКО где stencil == 1
                Pass Keep
            }
            
            ZTest Greater         // X-Ray
            ZWrite Off
            Blend SrcAlpha OneMinusSrcAlpha
            Cull Front            // Back faces для покрытия увеличенной области
            
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            
            CBUFFER_START(UnityPerMaterial)
                float4 _SilhouetteColor;
                float4 _OutlineColor;
                float _OutlineWidth;
            CBUFFER_END
            
            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
            };
            
            struct Varyings
            {
                float4 positionCS : SV_POSITION;
            };
            
            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                // Увеличенная геометрия для покрытия области контура
                float3 expandedPos = IN.positionOS.xyz + IN.normalOS * _OutlineWidth;
                OUT.positionCS = TransformObjectToHClip(expandedPos);
                return OUT;
            }
            
            half4 frag(Varyings IN) : SV_Target
            {
                return _OutlineColor;
            }
            ENDHLSL
        }
    }
}
