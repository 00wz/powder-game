Shader "PowderGame/GasParticleVisualizer"
{
    Properties
    {
        _ParticleTex ("Particles", 2D) = "black" {}
        _GasTex ("Gas", 2D) = "black" {}
        _SandColor ("Sand Color", Color) = (0.76, 0.70, 0.50, 1)
        _EmptyColor ("Background", Color) = (0.05, 0.05, 0.08, 1)
        _GasColor ("Gas Color", Color) = (0.3, 0.5, 0.8, 1)
        _GasOpacity ("Gas Opacity", Range(0, 1)) = 0.5
    }
    SubShader
    {
        Tags { "RenderType"="Opaque" }

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #include "UnityCG.cginc"

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct v2f
            {
                float2 uv : TEXCOORD0;
                float4 vertex : SV_POSITION;
            };

            sampler2D _ParticleTex;
            sampler2D _GasTex;
            float4 _SandColor;
            float4 _EmptyColor;
            float4 _GasColor;
            float _GasOpacity;

            v2f vert (appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.uv = v.uv;
                return o;
            }

            fixed4 frag (v2f i) : SV_Target
            {
                // Читаем данные
                float4 particle = tex2D(_ParticleTex, i.uv);
                float4 gas = tex2D(_GasTex, i.uv);
                
                float particleType = particle.r;
                float gasDensity = gas.r;
                
                // Базовый цвет (фон или частица)
                fixed4 baseColor = lerp(_EmptyColor, _SandColor, particleType);
                
                // Накладываем газ поверх
                fixed4 gasOverlay = _GasColor * gasDensity * _GasOpacity;
                
                // Финальный цвет
                fixed4 finalColor = baseColor + gasOverlay;
                finalColor.a = 1;
                
                return finalColor;
            }
            ENDCG
        }
    }
}