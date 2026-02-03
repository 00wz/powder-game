Shader "Custom/SRP/XRayOutline"
{
    // Эффект X-Ray с контуром:
    // - Объект за стеной отображается силуэтом
    // - Вокруг силуэта рисуется контур
    // 
    // ПОДХОД: Используем один проход который рисует ОБА эффекта
    // через разный vertex offset для front/back faces
    
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
        // PASS 1: Рисуем КОНТУР (увеличенный объект, back faces)
        // ============================================
        Pass
        {
            Name "XRay Outline"
            Tags { "LightMode" = "UniversalForward" }
            
            ZTest Greater
            ZWrite Off
            Blend SrcAlpha OneMinusSrcAlpha
            Cull Front  // Рисуем back faces
            
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
        
        // ============================================
        // PASS 2: Рисуем СИЛУЭТ (обычный размер, front faces)
        // ============================================
        Pass
        {
            Name "XRay Silhouette"
            Tags { "LightMode" = "UniversalForwardOnly" }
            
            ZTest Greater
            ZWrite Off
            Blend SrcAlpha OneMinusSrcAlpha
            Cull Back  // Рисуем front faces
            
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
    }
}
