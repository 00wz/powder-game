Shader "Hidden/SRP/SobelOutline"
{
    SubShader
    {
        Tags { "RenderType"="Opaque" "RenderPipeline"="UniversalPipeline" }
        
        Pass
        {
            Name "Sobel Outline"
            
            ZWrite Off
            ZTest Always
            Cull Off
            
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"
            
            float _Thickness;
            float _Threshold;
            half4 _OutlineColor;
            half4 _BackgroundColor;
            float _ColorMix; // 0 = только outline, 1 = outline поверх изображения
            
            // Получаем яркость пикселя
            float GetLuminance(float2 uv)
            {
                half4 color = SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, uv);
                return dot(color.rgb, float3(0.299, 0.587, 0.114));
            }
            
            half4 Frag(Varyings input) : SV_Target
            {
                float2 texelSize = _BlitTexture_TexelSize.xy * _Thickness;
                float2 uv = input.texcoord;
                
                // Семплируем 3x3 окрестность
                // [0][1][2]
                // [3][4][5]
                // [6][7][8]
                float s[9];
                s[0] = GetLuminance(uv + texelSize * float2(-1, -1));
                s[1] = GetLuminance(uv + texelSize * float2( 0, -1));
                s[2] = GetLuminance(uv + texelSize * float2( 1, -1));
                s[3] = GetLuminance(uv + texelSize * float2(-1,  0));
                s[4] = GetLuminance(uv + texelSize * float2( 0,  0)); // центр
                s[5] = GetLuminance(uv + texelSize * float2( 1,  0));
                s[6] = GetLuminance(uv + texelSize * float2(-1,  1));
                s[7] = GetLuminance(uv + texelSize * float2( 0,  1));
                s[8] = GetLuminance(uv + texelSize * float2( 1,  1));
                
                // Sobel kernels
                // Gx = [-1,0,+1; -2,0,+2; -1,0,+1]
                float gx = s[2] + 2*s[5] + s[8] - s[0] - 2*s[3] - s[6];
                
                // Gy = [+1,+2,+1; 0,0,0; -1,-2,-1]
                float gy = s[0] + 2*s[1] + s[2] - s[6] - 2*s[7] - s[8];
                
                // Magnitude (сила границы)
                float edge = sqrt(gx*gx + gy*gy);
                
                // Применяем threshold
                edge = step(_Threshold, edge);
                
                // Оригинальный цвет
                half4 originalColor = SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, uv);
                
                // Смешиваем: edge=1 -> outline color, edge=0 -> original/background
                half4 baseColor = lerp(_BackgroundColor, originalColor, _ColorMix);
                half4 finalColor = lerp(baseColor, _OutlineColor, edge);
                
                return finalColor;
            }
            ENDHLSL
        }
    }
}
