using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Rendering.RenderGraphModule;
using UnityEngine.Experimental.Rendering;

/// <summary>
/// SSPT RenderGraph Pass — управляет пайплайном из 4 шагов:
///
///   [0] Trace        : N стохастических лучей → raw indirect buffer
///   [1] Temporal     : blend с историей (exponential moving avg + variance clamp)
///   [2] Denoise ×N   : A-Trous wavelet bilateral filter (step=1,2,4,8)
///   [3] Composite    : direct + indirect → финальный цвет
///
/// Две persistent RTHandle (переживают между кадрами):
///   m_HistoryRT       — temporal accumulation buffer
///   m_DenoiseResultRT — denoised indirect для composite pass
///
/// Все промежуточные текстуры — RenderGraph-allocated (живут один кадр).
/// </summary>
public class SSPTPass : ScriptableRenderPass
{
    private Material             m_Material;
    private SSPTFeature.Settings m_Settings;

    // Persistent buffers (не пересоздаются каждый кадр)
    private RTHandle   m_HistoryRT;
    private RTHandle   m_DenoiseResultRT;
    private Vector2Int m_LastSize   = Vector2Int.zero;
    private int        m_FrameIndex = 0;

    // ── Shader property IDs ──────────────────────────────────────────────────
    static readonly int k_SampleCount       = Shader.PropertyToID("_SampleCount");
    static readonly int k_MaxSteps          = Shader.PropertyToID("_MaxSteps");
    static readonly int k_MaxDistance       = Shader.PropertyToID("_MaxDistance");
    static readonly int k_Thickness         = Shader.PropertyToID("_Thickness");
    static readonly int k_EdgeFade          = Shader.PropertyToID("_EdgeFade");
    static readonly int k_IndirectIntensity = Shader.PropertyToID("_IndirectIntensity");
    static readonly int k_TemporalAlpha     = Shader.PropertyToID("_TemporalAlpha");
    static readonly int k_FrameIndex        = Shader.PropertyToID("_FrameIndex");
    static readonly int k_DenoiseStepWidth  = Shader.PropertyToID("_DenoiseStepWidth");
    static readonly int k_HistoryTex        = Shader.PropertyToID("_HistoryTexture");
    static readonly int k_IndirectTex       = Shader.PropertyToID("_IndirectTexture");
    static readonly int k_SkyCube           = Shader.PropertyToID("_SSPT_SkyCube");
    static readonly int k_SkyCubeHDR        = Shader.PropertyToID("_SSPT_SkyCube_HDR");
    static readonly int k_UseSkybox         = Shader.PropertyToID("_SSPT_UseSkybox");

    // PassData: всё что нужно render func во время execute (после записи графа)
    // RenderGraph копирует это значение — НЕ используем ссылки на стек!
    private class PassData
    {
        public Material              mat;
        public TextureHandle         src;         // _BlitTexture source
        public RTHandle              historyRT;   // persistent: m_HistoryRT
        public RTHandle              denoiseRT;   // persistent: m_DenoiseResultRT
        public SSPTFeature.Settings  settings;
        public int                   frameIndex;
        public float                 denoiseStep;
        public Texture               skyTex;
        public Vector4               skyHDR;
        public bool                  hasSkybox;
    }

    public SSPTPass(Material material, SSPTFeature.Settings settings)
    {
        m_Material      = material;
        m_Settings      = settings;
        renderPassEvent = settings.renderPassEvent;
        // Объявляем зависимость от depth и normals texture URP
        ConfigureInput(ScriptableRenderPassInput.Depth | ScriptableRenderPassInput.Normal);
    }

    public void UpdateSettings(SSPTFeature.Settings s)
    {
        m_Settings      = s;
        renderPassEvent = s.renderPassEvent;
    }

    // Создаём/пересоздаём persistent RT при смене разрешения
    private void EnsureRTs(int w, int h)
    {
        if (m_LastSize.x == w && m_LastSize.y == h) return;

        m_HistoryRT?.Release();
        m_DenoiseResultRT?.Release();

        const GraphicsFormat fmt = GraphicsFormat.R16G16B16A16_SFloat;

        m_HistoryRT = RTHandles.Alloc(
            w, h,
            colorFormat: fmt,
            filterMode:  FilterMode.Bilinear,
            wrapMode:    TextureWrapMode.Clamp,
            name:        "_SSPT_History"
        );

        m_DenoiseResultRT = RTHandles.Alloc(
            w, h,
            colorFormat: fmt,
            filterMode:  FilterMode.Bilinear,
            wrapMode:    TextureWrapMode.Clamp,
            name:        "_SSPT_DenoiseResult"
        );

        m_LastSize   = new Vector2Int(w, h);
        m_FrameIndex = 0; // сброс при изменении разрешения
    }

    public override void RecordRenderGraph(RenderGraph rg, ContextContainer frame)
    {
        if (m_Material == null) return;

        var res = frame.Get<UniversalResourceData>();
        var cam = frame.Get<UniversalCameraData>();

        int w = cam.cameraTargetDescriptor.width;
        int h = cam.cameraTargetDescriptor.height;

        EnsureRTs(w, h);

        // ── Дескриптор для HDR float буферов indirect ────────────────────────
        var hdrDesc = new TextureDesc(w, h)
        {
            colorFormat = GraphicsFormat.R16G16B16A16_SFloat,
            filterMode  = FilterMode.Bilinear,
            wrapMode    = TextureWrapMode.Clamp,
            clearBuffer = false,
        };

        // Промежуточные RenderGraph текстуры (живут один кадр)
        hdrDesc.name = "_SSPT_Raw";
        TextureHandle rawIndirect = rg.CreateTexture(hdrDesc);

        hdrDesc.name = "_SSPT_Temporal";
        TextureHandle temporal = rg.CreateTexture(hdrDesc);

        // Ping-pong буферы для A-Trous итераций
        hdrDesc.name = "_SSPT_DenoiseA";
        TextureHandle denoiseA = rg.CreateTexture(hdrDesc);
        hdrDesc.name = "_SSPT_DenoiseB";
        TextureHandle denoiseB = rg.CreateTexture(hdrDesc);

        // Импортируем persistent RTHandle в RenderGraph
        // ImportTexture: RG знает о текстуре, но не владеет памятью
        TextureHandle historyH      = rg.ImportTexture(m_HistoryRT);
        TextureHandle denoiseResultH = rg.ImportTexture(m_DenoiseResultRT);

        // Skybox один раз на кадр
        ResolveSky(out Texture skyTex, out Vector4 skyHDR);
        bool    hasSky  = skyTex != null && m_Settings.useSkyboxFallback;
        int     fi      = m_FrameIndex;

        // ── PASS 0: TRACE ─────────────────────────────────────────────────────
        // src = activeColorTexture (scene color с direct lighting)
        // dst = rawIndirect (HDR буфер indirect radiance, один кадр)
        using (var builder = rg.AddRasterRenderPass<PassData>("SSPT Trace", out var d))
        {
            d.mat        = m_Material;
            d.src        = res.activeColorTexture;
            d.settings   = m_Settings;
            d.frameIndex = fi;
            d.skyTex     = skyTex;
            d.skyHDR     = skyHDR;
            d.hasSkybox  = hasSky;

            builder.UseTexture(res.activeColorTexture, AccessFlags.Read);
            builder.SetRenderAttachment(rawIndirect, 0, AccessFlags.Write);
            builder.AllowGlobalStateModification(true);

            builder.SetRenderFunc((PassData data, RasterGraphContext ctx) =>
            {
                SetCommonProps(data.mat, data.settings, data.frameIndex,
                               data.skyTex, data.skyHDR, data.hasSkybox);
                // Blitter ставит data.src как _BlitTexture → Frag_Trace читает scene color
                Blitter.BlitTexture(ctx.cmd, data.src, new Vector4(1, 1, 0, 0), data.mat, 0);
            });
        }

        // ── PASS 1: TEMPORAL ACCUMULATE ──────────────────────────────────────
        // src = rawIndirect (текущий кадр)
        // _HistoryTexture = m_HistoryRT.rt (предыдущий накопленный)
        // dst = temporal (смешанный результат)
        using (var builder = rg.AddRasterRenderPass<PassData>("SSPT Temporal", out var d))
        {
            d.mat        = m_Material;
            d.src        = rawIndirect;
            d.historyRT  = m_HistoryRT; // persistent RTHandle → render func читает .rt
            d.settings   = m_Settings;

            builder.UseTexture(rawIndirect, AccessFlags.Read);
            builder.UseTexture(historyH,    AccessFlags.Read); // dependency для ordering
            builder.SetRenderAttachment(temporal, 0, AccessFlags.Write);
            builder.AllowGlobalStateModification(true);

            builder.SetRenderFunc((PassData data, RasterGraphContext ctx) =>
            {
                // m_HistoryRT.rt — реальная RenderTexture (не RG handle)
                // Доступна т.к. это imported (persistent) RT
                data.mat.SetTexture(k_HistoryTex, data.historyRT.rt);
                data.mat.SetFloat(k_TemporalAlpha, data.settings.temporalAlpha);
                Blitter.BlitTexture(ctx.cmd, data.src, new Vector4(1, 1, 0, 0), data.mat, 1);
            });
        }

        // ── PASS 1b: COPY temporal → history (для следующего кадра) ──────────
        using (var builder = rg.AddRasterRenderPass<PassData>("SSPT WriteHistory", out var d))
        {
            d.src = temporal;
            builder.UseTexture(temporal, AccessFlags.Read);
            // Пишем в persistent historyH — RG отслеживает write dependency
            builder.SetRenderAttachment(historyH, 0, AccessFlags.Write);
            builder.SetRenderFunc((PassData data, RasterGraphContext ctx) =>
                Blitter.BlitTexture(ctx.cmd, data.src, new Vector4(1, 1, 0, 0), 0, false));
        }

        // ── PASS 2: A-TROUS DENOISE (0–4 итерации) ───────────────────────────
        // Ping-pong между denoiseA/denoiseB.
        // Последняя итерация пишет в denoiseResultH (persistent).
        // При нулевых итерациях: temporal → denoiseResultH напрямую.
        int           iters     = Mathf.Clamp(m_Settings.denoiseIterations, 0, 4);
        TextureHandle curDenoise = temporal;

        if (iters == 0)
        {
            // Нет denoise: просто копируем temporal → persistent denoiseResultRT
            using (var builder = rg.AddRasterRenderPass<PassData>("SSPT CopyResult", out var d))
            {
                d.src = temporal;
                builder.UseTexture(temporal, AccessFlags.Read);
                builder.SetRenderAttachment(denoiseResultH, 0, AccessFlags.Write);
                builder.SetRenderFunc((PassData data, RasterGraphContext ctx) =>
                    Blitter.BlitTexture(ctx.cmd, data.src, new Vector4(1, 1, 0, 0), 0, false));
            }
        }
        else
        {
            for (int i = 0; i < iters; i++)
            {
                bool          isLast = (i == iters - 1);
                float         sw     = Mathf.Pow(2, i); // step: 1, 2, 4, 8
                TextureHandle inp    = curDenoise;
                // Последняя итерация → persistent rt (для composite)
                // Промежуточные → ping-pong между denoiseA/denoiseB
                TextureHandle nxt = isLast
                    ? denoiseResultH
                    : (i % 2 == 0 ? denoiseA : denoiseB);

                float stepWidth = sw; // capture для closure

                using (var builder = rg.AddRasterRenderPass<PassData>($"SSPT Denoise {i}", out var d))
                {
                    d.mat         = m_Material;
                    d.src         = inp;
                    d.denoiseStep = stepWidth;

                    builder.UseTexture(inp, AccessFlags.Read);
                    builder.SetRenderAttachment(nxt, 0, AccessFlags.Write);
                    builder.AllowGlobalStateModification(true);

                    builder.SetRenderFunc((PassData data, RasterGraphContext ctx) =>
                    {
                        data.mat.SetFloat(k_DenoiseStepWidth, data.denoiseStep);
                        Blitter.BlitTexture(ctx.cmd, data.src, new Vector4(1, 1, 0, 0), data.mat, 2);
                    });
                }

                curDenoise = nxt;
            }
        }

        // ── PASS 3: COMPOSITE ─────────────────────────────────────────────────
        // Читаем scene color + denoised indirect → складываем → пишем в temp
        var ldrDesc = new TextureDesc(cam.cameraTargetDescriptor)
        {
            depthBufferBits = 0,
            msaaSamples     = MSAASamples.None,
            filterMode      = FilterMode.Bilinear,
            name            = "_SSPT_Composited"
        };
        TextureHandle composited = rg.CreateTexture(ldrDesc);

        using (var builder = rg.AddRasterRenderPass<PassData>("SSPT Composite", out var d))
        {
            d.mat      = m_Material;
            d.src      = res.activeColorTexture;
            d.denoiseRT = m_DenoiseResultRT; // persistent → читаем .rt в render func
            d.settings = m_Settings;

            builder.UseTexture(res.activeColorTexture, AccessFlags.Read);
            builder.UseTexture(denoiseResultH,         AccessFlags.Read); // ordering dependency
            builder.SetRenderAttachment(composited, 0, AccessFlags.Write);
            builder.AllowGlobalStateModification(true);

            builder.SetRenderFunc((PassData data, RasterGraphContext ctx) =>
            {
                // denoiseRT.rt — реальная RenderTexture из persistent RTHandle
                data.mat.SetTexture(k_IndirectTex, data.denoiseRT.rt);
                data.mat.SetFloat(k_IndirectIntensity, data.settings.indirectIntensity);
                Blitter.BlitTexture(ctx.cmd, data.src, new Vector4(1, 1, 0, 0), data.mat, 3);
            });
        }

        // ── Copy Back: composited → activeColorTexture ────────────────────────
        using (var builder = rg.AddRasterRenderPass<PassData>("SSPT CopyBack", out var d))
        {
            d.src = composited;
            builder.UseTexture(composited, AccessFlags.Read);
            builder.SetRenderAttachment(res.activeColorTexture, 0, AccessFlags.Write);
            builder.SetRenderFunc((PassData data, RasterGraphContext ctx) =>
                Blitter.BlitTexture(ctx.cmd, data.src, new Vector4(1, 1, 0, 0), 0, false));
        }

        m_FrameIndex++;
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private void SetCommonProps(Material m, SSPTFeature.Settings s, int fi,
                                 Texture sky, Vector4 skyHDR, bool hasSky)
    {
        m.SetInt(k_SampleCount,    s.samplesPerPixel);
        m.SetInt(k_MaxSteps,       s.maxSteps);
        m.SetFloat(k_MaxDistance,  s.maxDistance);
        m.SetFloat(k_Thickness,    s.thickness);
        m.SetFloat(k_EdgeFade,     s.edgeFade);
        m.SetFloat(k_FrameIndex,   fi);
        m.SetFloat(k_UseSkybox,    hasSky ? 1f : 0f);

        if (hasSky)
        {
            m.SetTexture(k_SkyCube, sky);
            m.SetVector(k_SkyCubeHDR, skyHDR);
        }
    }

    private void ResolveSky(out Texture tex, out Vector4 hdrDecode)
    {
        hdrDecode = new Vector4(1f, 1f, 0f, 0f);
        tex = null;

        if (!m_Settings.useSkyboxFallback) return;

        if (m_Settings.fallbackCubemap != null)
        {
            tex = m_Settings.fallbackCubemap;
            return;
        }

        if (ReflectionProbe.defaultTexture != null)
        {
            tex       = ReflectionProbe.defaultTexture;
            hdrDecode = ReflectionProbe.defaultTextureHDRDecodeValues;
            return;
        }

        var sky = RenderSettings.skybox;
        if (sky == null) return;
        if (sky.HasProperty("_Tex"))     { tex = sky.GetTexture("_Tex");     return; }
        if (sky.HasProperty("_MainTex")) { tex = sky.GetTexture("_MainTex"); return; }
        if (sky.HasProperty("_Cubemap")) { tex = sky.GetTexture("_Cubemap"); return; }
    }

    public void Dispose()
    {
        m_HistoryRT?.Release();
        m_DenoiseResultRT?.Release();
        m_HistoryRT = m_DenoiseResultRT = null;
    }
}
