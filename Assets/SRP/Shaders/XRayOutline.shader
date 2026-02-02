Shader "Custom/SRP/XRayOutline"
{
    // Эффект X-Ray с контуром:
    // - Объект за стеной отображается силуэтом
    // - Вокруг силуэта рисуется контур
    // 
    // Используем 2 бита Stencil:
    // Бит 1 (значение 1): маска увеличенного объекта (для outline)
    // Бит 2 (значение 2): маска реального объекта (силуэт)
    
    Properties
    {
        _SilhouetteColor ("Silhouette Color", Color) = (0.2, 0.5, 1.0, 0.5)
        _OutlineColor ("Outline Color", Color) = (0.0, 0.8, 1.0, 1.0)
        _OutlineWidth ("Outline Width", Range(0.001, 0.1)) = 0.02
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
        // Это будет область для outline
        // ============================================
        Pass
        {
            Name "Outline Mask"
            Tags { "LightMode" = "SRPDefaultUnlit" }
            
            // Записываем 1 в stencil для увеличенного объекта
            Stencil
            {
                Ref 1
                Comp Always
                Pass Replace
            }
            
            // Только за другими объектами (X-Ray)
            ZTest Greater
            ZWrite Off
            
            // Не рисуем цвет - только маска
            ColorMask 0
            
            // Увеличиваем объект через vertex offset
            Cull Front  // Рисуем заднюю сторону (для корректного увеличения)
            
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            
            CBUFFER_START(UnityPerMaterial)
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
                return 0;
            }
            ENDHLSL
        }
        
        // ============================================
        // PASS 2: Рисуем силуэт объекта
        // Записываем 2 в stencil там где рисуем
        // ============================================
        Pass
        {
            Name "Silhouette"
            Tags { "LightMode" = "UniversalForward" }
            
            // Записываем 2 в stencil (перезаписываем 1 где пересекается)
            Stencil
            {
                Ref 2
                Comp Always
                Pass Replace
            }
            
            // Только за другими объектами (X-Ray)
            ZTest Greater
            ZWrite Off
            
            // Прозрачный силуэт
            Blend SrcAlpha OneMinusSrcAlpha
            
            Cull Back
            
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            
            CBUFFER_START(UnityPerMaterial)
                float4 _SilhouetteColor;
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
        // PASS 3: Рисуем контур
        // Только там где Stencil == 1 (маска есть, но силуэта нет)
        // ============================================
        Pass
        {
            Name "Outline"
            Tags { "LightMode" = "SRPDefaultUnlit" }
            
            // Рисуем только где stencil == 1 (увеличенная область БЕЗ силуэта)
            Stencil
            {
                Ref 1
                Comp Equal
                Pass Keep
            }
            
            // Только за другими объектами (X-Ray)
            ZTest Greater
            ZWrite Off
            
            // Непрозрачный контур
            Blend SrcAlpha OneMinusSrcAlpha
            
            Cull Back
            
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            
            CBUFFER_START(UnityPerMaterial)
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
                
                // Используем увеличенную геометрию для покрытия области outline
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
