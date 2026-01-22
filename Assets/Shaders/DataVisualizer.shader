Shader "PowderGame/DataVisualizer"
{
    Properties
    {
        _DataTex ("Data Texture", 2D) = "black" {}
        _VisMode ("Visualization Mode", Range(0, 3)) = 0
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

            sampler2D _DataTex;
            float4 _DataTex_ST;
            float4 _DataTex_TexelSize; // Unity автоматически: (1/width, 1/height, width, height)
            float _VisMode;

            v2f vert (appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.uv = TRANSFORM_TEX(v.uv, _DataTex);
                return o;
            }

            fixed4 frag (v2f i) : SV_Target
            {
                float4 data = tex2D(_DataTex, i.uv);
                fixed4 col = fixed4(0, 0, 0, 1);
                
                int mode = (int)_VisMode;
                
                if (mode == 0)
                {
                    // Режим 0: Показать как обычную картинку
                    col = data;
                }
                else if (mode == 1)
                {
                    // Режим 1: Только R канал (тип частицы)
                    col.rgb = data.r;
                }
                else if (mode == 2)
                {
                    // Режим 2: Показать UV как цвет (отладка координат)
                    col.r = i.uv.x;
                    col.g = i.uv.y;
                    col.b = 0;
                }
                else if (mode == 3)
                {
                    // Режим 3: Показать разницу с соседями (edge detection)
                    float2 texel = _DataTex_TexelSize.xy;
                    
                    float4 right = tex2D(_DataTex, i.uv + float2(texel.x, 0));
                    float4 up    = tex2D(_DataTex, i.uv + float2(0, texel.y));
                    
                    float edge = length(data.rgb - right.rgb) + length(data.rgb - up.rgb);
                    col.rgb = edge;
                }
                
                return col;
            }
            ENDCG
        }
    }
}