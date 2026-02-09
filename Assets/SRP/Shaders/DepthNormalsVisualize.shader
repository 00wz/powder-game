Shader "Hidden/SRP/DepthNormalsVisualize"
{
    // Визуализация Depth и Normals буферов
    // Режимы: Raw Depth, Linear01 Depth, Eye Depth, Normals, Depth Edge, Normal Edge
    
    Properties
    {
        _DepthThreshold ("Depth Edge Threshold", Range(0.001, 0.1)) = 0.01
        _NormalThreshold ("Normal Edge Threshold", Range(0.1, 2.0)) = 0.5
    }
    
    HLSLINCLUDE
    #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
    #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"
    #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
    #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareNormalsTexture.hlsl"
    
    float _DepthThreshold;
    float _NormalThreshold;
    float _MaxDepthDistance;
    int _VisualizeMode;
    
    // ============================================
    // Функции для работы с глубиной (учитывают тип проекции)
    // unity_OrthoParams.w = 1 для ортографической, 0 для перспективной
    // ============================================
    
    // Получить линейную глубину 0-1 (near-far)
    float GetLinearDepth01(float rawDepth)
    {
        // Для ортографической камеры глубина уже линейная
        // Только нужно учесть Reversed-Z
        if (unity_OrthoParams.w > 0.5)
        {
            #if UNITY_REVERSED_Z
                return 1.0 - rawDepth;
            #else
                return rawDepth;
            #endif
        }
        
        // Для перспективной используем стандартную функцию
        return Linear01Depth(rawDepth, _ZBufferParams);
    }
    
    // Получить глубину в мировых единицах
    float GetLinearEyeDepth(float rawDepth)
    {
        // Для ортографической камеры
        if (unity_OrthoParams.w > 0.5)
        {
            float near = _ProjectionParams.y;
            float far = _ProjectionParams.z;
            
            #if UNITY_REVERSED_Z
                rawDepth = 1.0 - rawDepth;
            #endif
            
            // Интерполируем между near и far plane
            return lerp(near, far, rawDepth);
        }
        
        // Для перспективной
        return LinearEyeDepth(rawDepth, _ZBufferParams);
    }
    
    // ============================================
    // MODE 0: Raw Depth (прямое значение из буфера)
    // ============================================
    half4 FragRawDepth(Varyings input) : SV_Target
    {
        float2 uv = input.texcoord;
        float depth = SampleSceneDepth(uv);
        return half4(depth, depth, depth, 1);
    }
    
    // ============================================
    // MODE 1: Linear 01 Depth (0 = near, 1 = far)
    // Корректно работает и для ортографической, и для перспективной камеры
    // ============================================
    half4 FragLinear01Depth(Varyings input) : SV_Target
    {
        float2 uv = input.texcoord;
        float depth = SampleSceneDepth(uv);
        float linear01 = GetLinearDepth01(depth);
        return half4(linear01, linear01, linear01, 1);
    }
    
    // Сэмплирование глубины без градиентов (для использования в циклах)
    float SampleSceneDepthLOD(float2 uv)
    {
        return SAMPLE_TEXTURE2D_LOD(_CameraDepthTexture, sampler_CameraDepthTexture, uv, 0).r;
    }

    // ============================================
    // MODE 2: Eye Depth (глубина в мировых единицах, нормализованная)
    // ============================================
    half4 FragEyeDepth(Varyings input) : SV_Target
    {
        float2 uv = input.texcoord;
        float depth = SampleSceneDepthLOD(uv);//SampleSceneDepth(uv);
        float eyeDepth = GetLinearEyeDepth(depth);
        
        // Нормализуем для визуализации
        float maxDist = _MaxDepthDistance > 0.0 ? _MaxDepthDistance : 1000.0;
        float normalized = saturate(eyeDepth / maxDist);
        return half4(normalized, normalized, normalized, 1);
    }
    
    // ============================================
    // MODE 3: Normals (как RGB цвет)
    // ============================================
    half4 FragNormals(Varyings input) : SV_Target
    {
        float2 uv = input.texcoord;
        float3 normalWS = SampleSceneNormals(uv);
        
        // Преобразуем из [-1,1] в [0,1] для визуализации
        float3 normalVis = normalWS * 0.5 + 0.5;
        return half4(normalVis, 1);
    }
    
    // ============================================
    // MODE 4: Depth Edge Detection
    // ============================================
    half4 FragDepthEdge(Varyings input) : SV_Target
    {
        float2 uv = input.texcoord;
        float2 texelSize = _BlitTexture_TexelSize.xy;
        
        // Сэмплируем глубину в 5 точках (используем нашу функцию для ортографической камеры)
        float depthC = GetLinearDepth01(SampleSceneDepth(uv));
        float depthL = GetLinearDepth01(SampleSceneDepth(uv + float2(-texelSize.x, 0)));
        float depthR = GetLinearDepth01(SampleSceneDepth(uv + float2( texelSize.x, 0)));
        float depthU = GetLinearDepth01(SampleSceneDepth(uv + float2(0,  texelSize.y)));
        float depthD = GetLinearDepth01(SampleSceneDepth(uv + float2(0, -texelSize.y)));
        
        // Разница глубины (Roberts cross)
        float edgeH = abs(depthL - depthR);
        float edgeV = abs(depthU - depthD);
        float edge = sqrt(edgeH * edgeH + edgeV * edgeV);
        
        // Применяем порог
        float isEdge = step(_DepthThreshold, edge);
        
        return half4(isEdge, isEdge, isEdge, 1);
    }
    
    // ============================================
    // MODE 5: Normal Edge Detection
    // ============================================
    half4 FragNormalEdge(Varyings input) : SV_Target
    {
        float2 uv = input.texcoord;
        float2 texelSize = _BlitTexture_TexelSize.xy;
        
        // Сэмплируем нормали в 5 точках
        float3 normalC = SampleSceneNormals(uv);
        float3 normalL = SampleSceneNormals(uv + float2(-texelSize.x, 0));
        float3 normalR = SampleSceneNormals(uv + float2( texelSize.x, 0));
        float3 normalU = SampleSceneNormals(uv + float2(0,  texelSize.y));
        float3 normalD = SampleSceneNormals(uv + float2(0, -texelSize.y));
        
        // Разница нормалей через dot product
        float edge = 0;
        edge += 1.0 - saturate(dot(normalC, normalL));
        edge += 1.0 - saturate(dot(normalC, normalR));
        edge += 1.0 - saturate(dot(normalC, normalU));
        edge += 1.0 - saturate(dot(normalC, normalD));
        
        // Применяем порог
        float isEdge = step(_NormalThreshold, edge);
        
        return half4(isEdge, isEdge, isEdge, 1);
    }
    
    // ============================================
    // MODE 6: Combined Edge (Depth + Normal)
    // ============================================
    half4 FragCombinedEdge(Varyings input) : SV_Target
    {
        float2 uv = input.texcoord;
        float2 texelSize = _BlitTexture_TexelSize.xy;
        
        // Depth edge (используем нашу функцию для ортографической камеры)
        float depthC = GetLinearDepth01(SampleSceneDepth(uv));
        float depthL = GetLinearDepth01(SampleSceneDepth(uv + float2(-texelSize.x, 0)));
        float depthR = GetLinearDepth01(SampleSceneDepth(uv + float2( texelSize.x, 0)));
        float depthU = GetLinearDepth01(SampleSceneDepth(uv + float2(0,  texelSize.y)));
        float depthD = GetLinearDepth01(SampleSceneDepth(uv + float2(0, -texelSize.y)));
        
        float depthEdge = abs(depthL - depthR) + abs(depthU - depthD);
        
        // Normal edge
        float3 normalC = SampleSceneNormals(uv);
        float3 normalL = SampleSceneNormals(uv + float2(-texelSize.x, 0));
        float3 normalR = SampleSceneNormals(uv + float2( texelSize.x, 0));
        float3 normalU = SampleSceneNormals(uv + float2(0,  texelSize.y));
        float3 normalD = SampleSceneNormals(uv + float2(0, -texelSize.y));
        
        float normalEdge = 0;
        normalEdge += 1.0 - saturate(dot(normalC, normalL));
        normalEdge += 1.0 - saturate(dot(normalC, normalR));
        normalEdge += 1.0 - saturate(dot(normalC, normalU));
        normalEdge += 1.0 - saturate(dot(normalC, normalD));
        
        // Комбинируем
        float depthFactor = step(_DepthThreshold, depthEdge);
        float normalFactor = step(_NormalThreshold, normalEdge);
        float combined = max(depthFactor, normalFactor);
        
        // Цветовое кодирование: красный = depth edge, зелёный = normal edge
        return half4(depthFactor, normalFactor, 0, 1);
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
        
        // Pass 0: Raw Depth
        Pass
        {
            Name "Raw Depth"
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment FragRawDepth
            ENDHLSL
        }
        
        // Pass 1: Linear 01 Depth
        Pass
        {
            Name "Linear01 Depth"
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment FragLinear01Depth
            ENDHLSL
        }
        
        // Pass 2: Eye Depth
        Pass
        {
            Name "Eye Depth"
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment FragEyeDepth
            ENDHLSL
        }
        
        // Pass 3: Normals
        Pass
        {
            Name "Normals"
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment FragNormals
            ENDHLSL
        }
        
        // Pass 4: Depth Edge
        Pass
        {
            Name "Depth Edge"
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment FragDepthEdge
            ENDHLSL
        }
        
        // Pass 5: Normal Edge
        Pass
        {
            Name "Normal Edge"
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment FragNormalEdge
            ENDHLSL
        }
        
        // Pass 6: Combined Edge
        Pass
        {
            Name "Combined Edge"
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment FragCombinedEdge
            ENDHLSL
        }
    }
}
