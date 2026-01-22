Shader "Unlit/WawesVisualizer"
{
    Properties
    {
        _AmpTex ("Amplitude Texture", 2D) = "white" {}
        
        [Header(Display Settings)]
        _Brightness ("Brightness", Range(0.1, 5)) = 1.0
        _Contrast ("Contrast", Range(0.5, 3)) = 1.0
        
        [Header(Color Intensity)]
        _RedIntensity ("Red Intensity", Range(0, 2)) = 1.0
        _GreenIntensity ("Green Intensity", Range(0, 2)) = 1.0
        _BlueIntensity ("Blue Intensity", Range(0, 2)) = 1.0
        
        [Header(Background)]
        _BackgroundColor ("Background Color", Color) = (0.05, 0.05, 0.05, 1)
    }
    SubShader
    {
        Tags { "RenderType"="Opaque" }
        LOD 100

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_fog

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

            sampler2D _AmpTex;
            float4 _AmpTex_ST;

            float _Brightness;
            float _Contrast;
            float _RedIntensity;
            float _GreenIntensity;
            float _BlueIntensity;
            float4 _BackgroundColor;

            v2f vert (appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.uv = TRANSFORM_TEX(v.uv, _AmpTex);
                return o;
            }

            fixed4 frag (v2f i) : SV_Target
            {
                // Считываем амплитуды из текстуры
                // RGB = амплитуды для R, G, B каналов; A = скорость распространения
                float4 ampData = tex2D(_AmpTex, i.uv);
                
                // Получаем амплитуды (могут быть положительными и отрицательными)
                float3 amplitudes = ampData.rgb;
                
                // Применяем контраст
                amplitudes = amplitudes * _Contrast;
                
                // Преобразуем в цвет: положительная амплитуда -> яркий цвет, отрицательная -> темный
                // Используем сдвиг 0.5, чтобы отрицательные значения тоже отображались
                float3 color;
                
                // Отдельно обрабатываем положительные и отрицательные амплитуды
                // Положительная амплитуда даёт яркий цвет, отрицательная - приглушенный
                color.r = (amplitudes.r * 0.5 + 0.5) * _RedIntensity;
                color.g = (amplitudes.g * 0.5 + 0.5) * _GreenIntensity;
                color.b = (amplitudes.b * 0.5 + 0.5) * _BlueIntensity;
                
                // Применяем яркость
                color *= _Brightness;
                
                // Смешиваем с фоном в зависимости от общей амплитуды
                float totalAmp = abs(amplitudes.r) + abs(amplitudes.g) + abs(amplitudes.b);
                float mixFactor = saturate(totalAmp * 2.0);
                
                float3 backGround = _BackgroundColor + float3(1,1,1) * ampData.a * 0.02;  

                // Финальный цвет
                fixed4 finalColor;
                finalColor.rgb = lerp(backGround, color, mixFactor + 0.3);
                finalColor.a = 1.0;
                
                return finalColor;
            }
            ENDCG
        }
    }
}
