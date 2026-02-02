Shader "Custom/XRaySilhouette"
{
    Properties
    {
        _SilhouetteColor ("Silhouette Color", Color) = (1, 0.5, 0, 1)
        _RimWidth ("Contur width", float) = 0.2
    }
    
    SubShader
    {
        Tags 
        { 
            "RenderType" = "Opaque" 
            "RenderPipeline" = "UniversalPipeline"
            "Queue" = "Geometry+2"
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
                float _RimWidth;
            CBUFFER_END
            
            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
            };
            
            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 normalWS   : TEXCOORD0;
                float3 positionWS : TEXCOORD1;
            };
            
            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                OUT.positionCS = TransformObjectToHClip(IN.positionOS.xyz);
                OUT.positionWS = TransformObjectToWorld(IN.positionOS.xyz);
                OUT.normalWS = TransformObjectToWorldNormal(IN.normalOS);
                return OUT;
            }
            
            float4 frag(Varyings IN) : SV_Target
            {
                float3 normalWS = normalize(IN.normalWS);

                // направление от пикселя к камере
                //float3 viewDirWS = normalize(_WorldSpaceCameraPos - IN.positionWS);
                float3 viewDirWS = normalize(-UNITY_MATRIX_V[2].xyz);

                // скалярное произведение
                float ndotv = abs(dot(normalWS, viewDirWS));

                // чем ближе к 0 — тем сильнее силуэт
                float silhouette = 1.0 - smoothstep(0.0, _RimWidth, ndotv);

                return float4(_SilhouetteColor.rgb, _SilhouetteColor.a * silhouette);
            }
            ENDHLSL
        }
    }
}
