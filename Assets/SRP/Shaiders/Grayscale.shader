Shader "Hidden/SRP/Grayscale"
{
    SubShader
    {
        Tags { "RenderType"="Opaque" "RenderPipeline"="UniversalPipeline" }
        
        Pass
        {
            Name "Grayscale"
            
            ZWrite Off
            ZTest Always
            Cull Off
            
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"
            
            float _Intensity;
            
            half4 Frag(Varyings input) : SV_Target
            {
                // Семплируем исходный цвет
                half4 color = SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, input.texcoord);
                
                // Вычисляем яркость (luminance) с учётом восприятия глаза
                half luminance = dot(color.rgb, half3(0.299, 0.587, 0.114));
                
                // Плавно переходим от цветного к серому
                color.rgb = lerp(color.rgb, luminance.xxx, _Intensity);
                
                return color;
            }
            ENDHLSL
        }
    }
}
