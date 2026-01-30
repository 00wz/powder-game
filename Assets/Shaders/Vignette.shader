Shader "Hidden/SRP/Vignette"
{
    SubShader
    {
        Tags { "RenderType"="Opaque" "RenderPipeline"="UniversalPipeline" }
        
        Pass
        {
            Name "Vignette"
            
            ZWrite Off
            ZTest Always
            Cull Off
            
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"
            
            float _Intensity;    // Сила эффекта (0-1)
            float _Smoothness;   // Плавность перехода
            float _Roundness;    // Округлость (для коррекции aspect ratio)
            half4 _VignetteColor; // Цвет виньетки (обычно чёрный)
            
            half4 Frag(Varyings input) : SV_Target
            {
                half4 color = SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, input.texcoord);
                
                // Нормализуем UV к центру (-0.5 to 0.5)
                float2 uv = input.texcoord - 0.5;
                
                // Коррекция aspect ratio (опционально)
                // uv.x *= _ScreenParams.x / _ScreenParams.y;
                
                // Расстояние от центра
                float dist = length(uv) * 1.41421356237;

                float lowerEdge = 1.0 - _Intensity;
                
                // Вычисляем vignette с плавным переходом
                // _Intensity контролирует где начинается затемнение
                // _Smoothness контролирует ширину перехода
                float vignette = smoothstep(lowerEdge, lowerEdge - _Smoothness, dist);
                
                // Применяем цвет виньетки
                color.rgb = lerp(_VignetteColor.rgb, color.rgb, vignette);
                
                return color;
            }
            ENDHLSL
        }
    }
}
