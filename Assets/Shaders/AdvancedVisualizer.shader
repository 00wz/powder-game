Shader "PowderGame/AdvancedVisualizer"
{
    Properties
    {
        _ParticleTex ("Particles", 2D) = "black" {}
        _GasTex ("Gas", 2D) = "black" {}
        
        [Header(Sand Colors)]
        _SandColorLight ("Sand Light", Color) = (0.85, 0.78, 0.55, 1)
        _SandColorDark ("Sand Dark", Color) = (0.65, 0.55, 0.35, 1)
        
        [Header(Gas Colors)]
        _GasColorLow ("Gas Low Density", Color) = (0.1, 0.3, 0.6, 1)
        _GasColorMid ("Gas Mid Density", Color) = (0.4, 0.2, 0.7, 1)
        _GasColorHigh ("Gas High Density", Color) = (0.8, 0.3, 0.2, 1)
        
        [Header(Background)]
        _BgColorTop ("Background Top", Color) = (0.02, 0.02, 0.05, 1)
        _BgColorBottom ("Background Bottom", Color) = (0.08, 0.06, 0.12, 1)
        
        [Header(Effects)]
        _AOStrength ("AO Strength", Range(0, 1)) = 0.3
        _GlowStrength ("Glow Strength", Range(0, 2)) = 0.5
        _GasOpacity ("Gas Opacity", Range(0, 1)) = 0.7
        
        [Header(Debug)]
        [Toggle] _ShowVelocity ("Show Velocity", Float) = 0
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

            sampler2D _ParticleTex;
            sampler2D _GasTex;
            float4 _ParticleTex_TexelSize;  // (1/width, 1/height, width, height)
            
            fixed4 _SandColorLight;
            fixed4 _SandColorDark;
            fixed4 _GasColorLow;
            fixed4 _GasColorMid;
            fixed4 _GasColorHigh;
            fixed4 _BgColorTop;
            fixed4 _BgColorBottom;
            
            float _AOStrength;
            float _GlowStrength;
            float _GasOpacity;
            float _ShowVelocity;

            v2f vert (appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.uv = v.uv;
                return o;
            }

            // ===== ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ =====
            
            // Градиент из 3 цветов
            fixed4 SampleGradient3(float t, fixed4 a, fixed4 b, fixed4 c)
            {
                t = saturate(t);
                if (t < 0.5)
                    return lerp(a, b, t * 2.0);
                else
                    return lerp(b, c, (t - 0.5) * 2.0);
            }
            
            // HSV to RGB
            fixed3 HSVtoRGB(float h, float s, float v)
            {
                float c = v * s;
                float x = c * (1.0 - abs(fmod(h * 6.0, 2.0) - 1.0));
                float m = v - c;
                
                float3 rgb;
                if (h < 1.0/6.0)      rgb = float3(c, x, 0);
                else if (h < 2.0/6.0) rgb = float3(x, c, 0);
                else if (h < 3.0/6.0) rgb = float3(0, c, x);
                else if (h < 4.0/6.0) rgb = float3(0, x, c);
                else if (h < 5.0/6.0) rgb = float3(x, 0, c);
                else                  rgb = float3(c, 0, x);
                
                return rgb + m;
            }
            
            // Подсчёт соседних частиц для AO
            float CalculateAO(float2 uv)
            {
                float2 texel = _ParticleTex_TexelSize.xy;
                float current = tex2D(_ParticleTex, uv).r;
                
                if (current < 0.5) return 1.0;  // Нет частицы - нет AO
                
                float neighbors = 0;
                // 8 направлений
                neighbors += tex2D(_ParticleTex, uv + float2(-texel.x, -texel.y)).r > 0.5 ? 1 : 0;
                neighbors += tex2D(_ParticleTex, uv + float2(0, -texel.y)).r > 0.5 ? 1 : 0;
                neighbors += tex2D(_ParticleTex, uv + float2(texel.x, -texel.y)).r > 0.5 ? 1 : 0;
                neighbors += tex2D(_ParticleTex, uv + float2(-texel.x, 0)).r > 0.5 ? 1 : 0;
                neighbors += tex2D(_ParticleTex, uv + float2(texel.x, 0)).r > 0.5 ? 1 : 0;
                neighbors += tex2D(_ParticleTex, uv + float2(-texel.x, texel.y)).r > 0.5 ? 1 : 0;
                neighbors += tex2D(_ParticleTex, uv + float2(0, texel.y)).r > 0.5 ? 1 : 0;
                neighbors += tex2D(_ParticleTex, uv + float2(texel.x, texel.y)).r > 0.5 ? 1 : 0;
                
                // Больше соседей = темнее, но только если "зажат"
                float ao = 1.0 - (neighbors / 8.0) * _AOStrength;
                return ao;
            }
            
            // Простой blur для газа (5 samples)
            float4 BlurGas(float2 uv)
            {
                float2 texel = _ParticleTex_TexelSize.xy * 2.0;  // Больше радиус
                float4 sum = float4(0,0,0,0);
                
                sum += tex2D(_GasTex, uv) * 0.4;
                sum += tex2D(_GasTex, uv + float2(texel.x, 0)) * 0.15;
                sum += tex2D(_GasTex, uv - float2(texel.x, 0)) * 0.15;
                sum += tex2D(_GasTex, uv + float2(0, texel.y)) * 0.15;
                sum += tex2D(_GasTex, uv - float2(0, texel.y)) * 0.15;
                
                return sum;
            }

            fixed4 frag (v2f i) : SV_Target
            {
                // Читаем данные
                float4 particle = tex2D(_ParticleTex, i.uv);
                float4 gas = tex2D(_GasTex, i.uv);
                float4 gasBlurred = BlurGas(i.uv);
                
                float particleType = particle.r;
                float gasDensity = gas.r;
                float gasBlurredDensity = gasBlurred.r;
                float2 velocity = gas.gb * 2.0 - 1.0;
                
                // ===== ФОНОВЫЙ ГРАДИЕНТ =====
                fixed4 bgColor = lerp(_BgColorBottom, _BgColorTop, i.uv.y);
                
                // ===== ГАЗОВОЕ СВЕЧЕНИЕ (glow) =====
                fixed4 gasGlow = SampleGradient3(gasBlurredDensity * 2.0, 
                    fixed4(0,0,0,0), _GasColorLow, _GasColorMid);
                gasGlow *= gasBlurredDensity * _GlowStrength;
                
                // ===== ОСНОВНОЙ ЦВЕТ ГАЗА =====
                fixed4 gasColor = SampleGradient3(gasDensity, 
                    _GasColorLow, _GasColorMid, _GasColorHigh);
                gasColor.a = gasDensity * _GasOpacity;
                
                // ===== VELOCITY VISUALIZATION (debug) =====
                if (_ShowVelocity > 0.5 && gasDensity > 0.01)
                {
                    float speed = length(velocity);
                    float angle = atan2(velocity.y, velocity.x);
                    float hue = (angle + 3.14159) / (2.0 * 3.14159);
                    gasColor.rgb = HSVtoRGB(hue, 1.0, speed * 2.0);
                }
                
                // ===== ЦВЕТ ЧАСТИЦЫ С AO =====
                float ao = CalculateAO(i.uv);
                fixed4 sandColor = lerp(_SandColorDark, _SandColorLight, ao);
                
                // Добавляем небольшой шум для текстуры песка
                float noise = frac(sin(dot(i.uv * 100.0, float2(12.9898, 78.233))) * 43758.5453);
                sandColor.rgb += (noise - 0.5) * 0.05;
                
                // ===== КОМПОЗИТИНГ =====
                // Начинаем с фона
                fixed4 finalColor = bgColor;
                
                // Добавляем glow газа
                finalColor.rgb += gasGlow.rgb;
                
                // Смешиваем основной газ
                finalColor.rgb = lerp(finalColor.rgb, gasColor.rgb, gasColor.a);
                
                // Частица поверх всего
                finalColor = lerp(finalColor, sandColor, particleType);
                
                finalColor.a = 1.0;
                return finalColor;
            }
            ENDCG
        }
    }
}