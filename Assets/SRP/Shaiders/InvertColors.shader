Shader "Hidden/SRP/InvertColors"
{
    SubShader
    {
        Tags { "RenderType"="Opaque" "RenderPipeline"="UniversalPipeline" }
        
        Pass
        {
            Name "InvertColors"
            
            ZWrite Off
            ZTest Always
            Cull Off
            
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"
            
            // _BlitTexture и _BlitScaleBias определены в Blit.hlsl
            
            half4 Frag(Varyings input) : SV_Target
            {
                // Семплируем исходное изображение
                half4 color = SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, input.texcoord);
                
                // Инвертируем цвет (сохраняем альфу)
                color.rgb = 1.0 - color.rgb;
                
                return color;
            }
            ENDHLSL
        }
    }
}

