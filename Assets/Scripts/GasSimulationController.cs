using System;
using UnityEngine;

public class GasSimulationController : MonoBehaviour
{
    [Header("Compute Shaders")]
    public ComputeShader gasCompute;
    public ComputeShader sandCompute;  // Для частиц
    
    [Header("Settings")]
    public int textureSize = 256;
    
    [Header("Gas Parameters")]
    [Range(0, 50)] public float advectionSpeed = 20f;
    [Range(0, 0.5f)] public float diffusion = 0.1f;
    [Range(0, 1f)] public float dissipation = 0.02f;
    [Range(-1, 1)] public float gravity = 0.1f;
    [Range(-5, 5)] public float buoyancy = 1f;
    
    [Header("Source")]
    public bool emitGas = true;
    public Vector2Int sourcePosition = new Vector2Int(128, 20);
    public float sourceRadius = 10f;
    public float sourceStrength = 5f;
    public Vector2 sourceVelocity = new Vector2(0, 1);
    
    [Header("Visualization")]
    public Material displayMaterial;
    
    // Текстуры
    private RenderTexture[] gasBuffers = new RenderTexture[2];
    private RenderTexture[] particleBuffers = new RenderTexture[2];
    private int currentGasBuffer = 0;
    private int currentParticleBuffer = 0;
    
    // Kernels
    private int advectKernel, diffuseKernel, forcesKernel, sourceKernel, gasInitKernel;
    private int sandSimulateKernel, sandInitKernel;
    
    void Start()
    {
        CreateTextures();
        SetupKernels();
        InitializeSimulation();
    }
    
    void CreateTextures()
    {
        // Газовые буферы
        for (int i = 0; i < 2; i++)
        {
            gasBuffers[i] = CreateRenderTexture();
            particleBuffers[i] = CreateRenderTexture();
        }
    }
    
    RenderTexture CreateRenderTexture()
    {
        RenderTexture rt = new RenderTexture(textureSize, textureSize, 0, RenderTextureFormat.ARGBFloat);
        rt.enableRandomWrite = true;
        rt.filterMode = FilterMode.Bilinear;  // Для газа можно Bilinear
        rt.wrapMode = TextureWrapMode.Clamp;
        rt.Create();
        return rt;
    }
    
    void SetupKernels()
    {
        // Gas kernels
        advectKernel = gasCompute.FindKernel("AdvectGas");
        diffuseKernel = gasCompute.FindKernel("DiffuseGas");
        forcesKernel = gasCompute.FindKernel("ApplyForces");
        sourceKernel = gasCompute.FindKernel("AddGasSource");
        gasInitKernel = gasCompute.FindKernel("InitializeTexture");
        
        // Sand kernels
        sandSimulateKernel = sandCompute.FindKernel("SimulateSand");
        sandInitKernel = sandCompute.FindKernel("InitializeTexture");
        
        // Установка размеров
        gasCompute.SetInt("_Width", textureSize);
        gasCompute.SetInt("_Height", textureSize);
        sandCompute.SetInt("_Width", textureSize);
        sandCompute.SetInt("_Height", textureSize);
    }
    
    void InitializeSimulation()
    {
        int groups = Mathf.CeilToInt(textureSize / 8.0f);
        
        // Инициализируем газ (пусто)
        for (int i = 0; i < 2; i++)
        {
            gasCompute.SetTexture(gasInitKernel, "_GasOutput", gasBuffers[i]);
            gasCompute.Dispatch(gasInitKernel, groups, groups, 1);
            
            sandCompute.SetTexture(sandInitKernel, "_Output", particleBuffers[i]);
            sandCompute.Dispatch(sandInitKernel, groups, groups, 1);
        }
    }
    
    void Update()
    {
        float dt = Mathf.Min(Time.deltaTime, 0.033f);  // Максимум ~30 FPS для стабильности
        int groups = Mathf.CeilToInt(textureSize / 8.0f);
        
        // 1. Симуляция частиц (песок)
        SimulateSand(groups);
        
        // 2. Симуляция газа
        SimulateGas(dt, groups);
        
        // 3. Обновляем материал
        UpdateDisplay();

        SpawnPaeticles();
    }

    private void SpawnPaeticles()
    {
        emitGas = false;
        if (Input.GetMouseButton(0))
        {
            Ray ray = Camera.main.ScreenPointToRay(Input.mousePosition);
            RaycastHit hit;

            if (Physics.Raycast(ray, out hit)) 
            {
                Vector2 uv = hit.textureCoord;
                emitGas = true;
                sourcePosition = new Vector2Int((int)(uv.x * textureSize), (int)(uv.y * textureSize));
                //Debug.Log("UV: " + uv);
            }
        }

        if (Input.GetMouseButton(1))
        {
            Ray ray = Camera.main.ScreenPointToRay(Input.mousePosition);
            RaycastHit hit;

            if (Physics.Raycast(ray, out hit))
            {
                Vector2 uv = hit.textureCoord;
                sourcePosition = new Vector2Int((int)(uv.x * textureSize), (int)(uv.y * textureSize));
                SpawnSandAt(sourcePosition.x, sourcePosition.y, Mathf.RoundToInt(sourceRadius));  
            }
        }
    }

    void SimulateSand(int groups)
    {
        int read = currentParticleBuffer;
        int write = 1 - currentParticleBuffer;
        
        sandCompute.SetInt("_Frame", Time.frameCount);
        sandCompute.SetTexture(sandSimulateKernel, "_Input", particleBuffers[read]);
        sandCompute.SetTexture(sandSimulateKernel, "_Output", particleBuffers[write]);
        sandCompute.Dispatch(sandSimulateKernel, groups, groups, 1);
        
        currentParticleBuffer = write;
    }
    
    void SimulateGas(float dt, int groups)
    {
        // Общие параметры
        gasCompute.SetFloat("_DeltaTime", dt);
        gasCompute.SetFloat("_AdvectionSpeed", advectionSpeed);
        gasCompute.SetFloat("_Diffusion", diffusion);
        gasCompute.SetFloat("_Dissipation", dissipation);
        gasCompute.SetFloat("_Gravity", gravity);
        gasCompute.SetFloat("_Buoyancy", buoyancy);
        
        // Текстура частиц для взаимодействия
        gasCompute.SetTexture(forcesKernel, "_ParticlesTex", particleBuffers[currentParticleBuffer]);
        
        int read = currentGasBuffer;
        int write = 1 - currentGasBuffer;
        
        // Шаг 1: Advection
        gasCompute.SetTexture(advectKernel, "_GasInput", gasBuffers[read]);
        gasCompute.SetTexture(advectKernel, "_GasOutput", gasBuffers[write]);
        gasCompute.Dispatch(advectKernel, groups, groups, 1);
        SwapGasBuffers(ref read, ref write);
        
        // Шаг 2: Diffusion (несколько итераций для лучшего качества)
        for (int i = 0; i < 2; i++)
        {
            gasCompute.SetTexture(diffuseKernel, "_GasInput", gasBuffers[read]);
            gasCompute.SetTexture(diffuseKernel, "_GasOutput", gasBuffers[write]);
            gasCompute.Dispatch(diffuseKernel, groups, groups, 1);
            SwapGasBuffers(ref read, ref write);
        }
        
        // Шаг 3: Forces
        gasCompute.SetTexture(forcesKernel, "_GasInput", gasBuffers[read]);
        gasCompute.SetTexture(forcesKernel, "_GasOutput", gasBuffers[write]);
        gasCompute.Dispatch(forcesKernel, groups, groups, 1);
        
        // Шаг 4: Add source (работает с Output)
        if (emitGas)
        {
            gasCompute.SetInts("_SourcePosition", sourcePosition.x, sourcePosition.y);
            gasCompute.SetFloat("_SourceRadius", sourceRadius);
            gasCompute.SetFloat("_SourceStrength", sourceStrength);
            gasCompute.SetFloats("_SourceVelocity", sourceVelocity.x, sourceVelocity.y);
            
            gasCompute.SetTexture(sourceKernel, "_GasOutput", gasBuffers[write]);
            gasCompute.Dispatch(sourceKernel, groups, groups, 1);
        }
        
        currentGasBuffer = write;
    }
    
    void SwapGasBuffers(ref int read, ref int write)
    {
        int temp = read;
        read = write;
        write = temp;
    }
    
    void UpdateDisplay()
    {
        if (displayMaterial != null)
        {
            displayMaterial.SetTexture("_GasTex", gasBuffers[currentGasBuffer]);
            displayMaterial.SetTexture("_ParticleTex", particleBuffers[currentParticleBuffer]);
        }
    }
    
    // Публичные методы для спавна
    public void SpawnSandAt(int x, int y, int radius)
    {
        // Используем тот же метод что в SandSimulationController
        Texture2D temp = new Texture2D(textureSize, textureSize, TextureFormat.RGBAFloat, false);
        RenderTexture.active = particleBuffers[currentParticleBuffer];
        temp.ReadPixels(new Rect(0, 0, textureSize, textureSize), 0, 0);
        temp.Apply();
        RenderTexture.active = null;
        
        for (int dx = -radius; dx <= radius; dx++)
        {
            for (int dy = -radius; dy <= radius; dy++)
            {
                if (dx * dx + dy * dy <= radius * radius)
                {
                    int px = x + dx;
                    int py = y + dy;
                    if (px >= 0 && px < textureSize && py >= 0 && py < textureSize)
                    {
                        temp.SetPixel(px, py, new Color(1, 0, 0, 1));
                    }
                }
            }
        }
        temp.Apply();
        Graphics.Blit(temp, particleBuffers[currentParticleBuffer]);
        Destroy(temp);
    }
    
    void OnDestroy()
    {
        foreach (var rt in gasBuffers) if (rt != null) rt.Release();
        foreach (var rt in particleBuffers) if (rt != null) rt.Release();
    }
}
