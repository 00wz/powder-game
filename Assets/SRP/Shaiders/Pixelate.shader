Shader "Hidden/SRP/Pixelate"
{
    SubShader
    {
        Tags { "RenderType"="Opaque" "RenderPipeline"="UniversalPipeline" }
        
        Pass
        {
            Name "Pixelate"
            
            ZWrite Off
            ZTest Always
            Cull Off
            
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"
            
            float _PixelSize;
            float2 _PixelateScreenSize; // Переименовано чтобы избежать конфликта с _ScreenSize из Core.hlsl
            
            half4 Frag(Varyings input) : SV_Target
            {
                float2 uv = input.texcoord;
                
                // Вычисляем размер "большого пикселя" в UV пространстве
                float2 pixelUV = _PixelSize / _PixelateScreenSize;
                
                // Округляем UV до ближайшего "большого пикселя"
                uv = floor(uv / pixelUV) * pixelUV + pixelUV * 0.5;
                
                // Семплируем цвет в центре "большого пикселя"
                half4 color = SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_PointClamp, uv);
                
                return color;
            }
            ENDHLSL
        }
    }
}
