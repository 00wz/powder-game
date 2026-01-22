Shader "PowderGame/SandVisualizer"
{
    Properties
    {
        _MainTex ("Simulation Texture", 2D) = "black" {}
        _SandColor ("Sand Color", Color) = (0.76, 0.70, 0.50, 1)
        _EmptyColor ("Empty Color", Color) = (0.1, 0.1, 0.15, 1)
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

            sampler2D _MainTex;
            float4 _MainTex_ST;
            float4 _SandColor;
            float4 _EmptyColor;

            v2f vert (appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.uv = TRANSFORM_TEX(v.uv, _MainTex);
                return o;
            }

            fixed4 frag (v2f i) : SV_Target
            {
                float4 data = tex2D(_MainTex, i.uv);
                float particleType = data.r;
                
                // Интерполяция между пустым и песком
                fixed4 col = lerp(_EmptyColor, _SandColor, particleType);
                
                return col;
            }
            ENDCG
        }
    }
}