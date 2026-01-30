Shader "Custom/XRaySilhouette"
{
    Properties
    {
        _SilhouetteColor ("Silhouette Color", Color) = (1, 0.5, 0, 1)
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
            Name "XRay Silhouette"
            
            // // Stencil: записываем значение 1 туда, где рисуем
            // Stencil
            // {
            //     Ref 1
            //     Comp Always
            //     Pass Replace
            // }
            
            // ZTest Greater — рисуем только там, где объект ЗА другими объектами
            ZTest Greater
            ZWrite Off
            
            // Рисуем поверх с прозрачностью
            Blend SrcAlpha OneMinusSrcAlpha
            
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
            
            float4 frag(Varyings IN) : SV_Target
            {
                return _SilhouetteColor;
            }
            ENDHLSL
        }
    }
}
