Shader "Hidden/SRP/GaussianBlur"
{
    SubShader
    {
        Tags { "RenderType"="Opaque" "RenderPipeline"="UniversalPipeline" }
        
        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"
        
        float2 _BlurDirection; // (1,0) для horizontal, (0,1) для vertical
        float _BlurSize;
        
        // Gaussian weights для 9-tap blur
        static const float weights[5] = { 0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216 };
        
        half4 BlurFragment(Varyings input) : SV_Target
        {
            float2 texelSize = _BlitTexture_TexelSize.xy;
            float2 uv = input.texcoord;
            
            // Центральный семпл
            half4 color = SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, uv) * weights[0];
            
            // Семплы в обе стороны от центра
            for (int i = 1; i < 5; i++)
            {
                float2 offset = _BlurDirection * texelSize * i * _BlurSize;
                color += SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, uv + offset) * weights[i];
                color += SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, uv - offset) * weights[i];
            }
            
            return color;
        }
        ENDHLSL
        
        // Pass 0: Horizontal blur
        Pass
        {
            Name "Horizontal Blur"
            
            ZWrite Off
            ZTest Always
            Cull Off
            
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment BlurFragment
            ENDHLSL
        }
        
        // Pass 1: Vertical blur (тот же код, direction задаётся из C#)
        Pass
        {
            Name "Vertical Blur"
            
            ZWrite Off
            ZTest Always
            Cull Off
            
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment BlurFragment
            ENDHLSL
        }
    }
}
