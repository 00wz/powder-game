Shader "Hidden/SRP/KawaseBlur"
{
    // Kawase Blur - оптимизированное размытие с 4 сэмплами
    // Два прохода: Downsample и Upsample для пирамиды разрешений
    
    Properties
    {
        _Offset ("Blur Offset", Float) = 1.0
    }
    
    HLSLINCLUDE
    #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
    #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"
    
    float _Offset;
    
    // ============================================
    // DOWNSAMPLE PASS
    // Уменьшает разрешение и применяет blur
    // Сэмплирует 4 точки по диагонали
    // ============================================
    half4 FragDownsample(Varyings input) : SV_Target
    {
        float2 uv = input.texcoord;
        
        // _BlitTexture_TexelSize устанавливается автоматически Blitter'ом
        float2 texelSize = _BlitTexture_TexelSize.xy;
        
        // Kawase downsample pattern:
        // Смещение половина пикселя + offset для blur
        float2 offset = texelSize * (_Offset + 0.5);
        
        // 4 диагональных сэмпла
        half4 color = half4(0, 0, 0, 0);
        color += SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, uv + float2(-offset.x, -offset.y));
        color += SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, uv + float2( offset.x, -offset.y));
        color += SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, uv + float2(-offset.x,  offset.y));
        color += SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, uv + float2( offset.x,  offset.y));
        
        return color * 0.25; // Среднее 4 сэмплов
    }
    
    // ============================================
    // UPSAMPLE PASS
    // Увеличивает разрешение и применяет blur
    // Более широкий pattern для лучшего смешивания
    // ============================================
    half4 FragUpsample(Varyings input) : SV_Target
    {
        float2 uv = input.texcoord;
        float2 texelSize = _BlitTexture_TexelSize.xy;
        
        float2 offset = texelSize * (_Offset + 0.5);
        
        // 8 сэмплов для upsample (крестообразный + диагональный pattern)
        half4 color = half4(0, 0, 0, 0);
        
        // Диагонали (вес 1)
        color += SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, uv + float2(-offset.x, -offset.y));
        color += SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, uv + float2( offset.x, -offset.y));
        color += SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, uv + float2(-offset.x,  offset.y));
        color += SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, uv + float2( offset.x,  offset.y));
        
        // Крест (вес 2 для лучшего качества)
        color += SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, uv + float2(-offset.x, 0)) * 2;
        color += SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, uv + float2( offset.x, 0)) * 2;
        color += SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, uv + float2(0, -offset.y)) * 2;
        color += SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, uv + float2(0,  offset.y)) * 2;
        
        return color / 12.0; // Нормализация: 4*1 + 4*2 = 12
    }
    
    // ============================================
    // SIMPLE KAWASE PASS
    // Для использования без пирамиды (просто несколько итераций)
    // ============================================
    half4 FragSimple(Varyings input) : SV_Target
    {
        float2 uv = input.texcoord;
        float2 texelSize = _BlitTexture_TexelSize.xy;
        
        // Offset зависит от номера итерации
        float2 offset = texelSize * (_Offset + 0.5);
        
        half4 color = half4(0, 0, 0, 0);
        
        // 4 диагональных сэмпла — классический Kawase
        color += SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, uv + float2(-offset.x, -offset.y));
        color += SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, uv + float2( offset.x, -offset.y));
        color += SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, uv + float2(-offset.x,  offset.y));
        color += SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, uv + float2( offset.x,  offset.y));
        
        return color * 0.25;
    }
    ENDHLSL
    
    SubShader
    {
        Tags 
        { 
            "RenderType" = "Opaque" 
            "RenderPipeline" = "UniversalPipeline"
        }
        
        ZTest Always
        ZWrite Off
        Cull Off
        
        // Pass 0: Downsample
        Pass
        {
            Name "Kawase Downsample"
            
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment FragDownsample
            ENDHLSL
        }
        
        // Pass 1: Upsample
        Pass
        {
            Name "Kawase Upsample"
            
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment FragUpsample
            ENDHLSL
        }
        
        // Pass 2: Simple (без пирамиды)
        Pass
        {
            Name "Kawase Simple"
            
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment FragSimple
            ENDHLSL
        }
    }
}
