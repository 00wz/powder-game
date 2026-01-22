#if UNITY_EDITOR
using UnityEditor;
#endif
using UnityEngine;

public class InteractiveSimController : MonoBehaviour
{
    [Header("Compute Shaders")]
    public ComputeShader gasCompute;
    public ComputeShader sandCompute;
    
    [Header("Settings")]
    public int textureSize = 256;
    
    [Header("Gas Parameters")]
    [Range(0, 50)] public float advectionSpeed = 20f;
    [Range(0, 0.5f)] public float diffusion = 0.1f;
    [Range(0, 1f)] public float dissipation = 0.02f;
    [Range(-1, 1)] public float gravity = 0.1f;
    [Range(-5, 5)] public float buoyancy = 1f;
    
    [Header("Brush")]
    [Range(1, 30)] public float brushRadius = 8f;
    [Range(0.1f, 10f)] public float brushStrength = 3f;
    public BrushType currentBrush = BrushType.Sand;
    
    [Header("Visualization")]
    public Material displayMaterial;
    public MeshCollider targetCollider;  // Для raycasting
    
    public enum BrushType { Sand, Gas, Erase }
    
    // Текстуры
    private RenderTexture[] gasBuffers = new RenderTexture[2];
    private RenderTexture[] particleBuffers = new RenderTexture[2];
    private int currentGasBuffer = 0;
    private int currentParticleBuffer = 0;
    
    // Kernels
    private int advectKernel, diffuseKernel, forcesKernel, sourceKernel;
    private int sandSimulateKernel, sandInitKernel;
    private int spawnParticleKernel, spawnGasKernel, eraseKernel, gasInitKernel;
    
    private int threadGroups;
    
    void Start()
    {
        threadGroups = Mathf.CeilToInt(textureSize / 8.0f); 
        CreateTextures();
        SetupKernels();
        InitializeSimulation();
    }
    
    void CreateTextures()
    {
        for (int i = 0; i < 2; i++)
        {
            gasBuffers[i] = CreateRT();
            particleBuffers[i] = CreateRT();
        }
    }
    
    RenderTexture CreateRT()
    {
        RenderTexture rt = new RenderTexture(textureSize, textureSize, 0, RenderTextureFormat.ARGBFloat);
        rt.enableRandomWrite = true;
        rt.filterMode = FilterMode.Point;
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
        
        // Brush kernels (добавь их в GasSimulation.compute!)
        spawnParticleKernel = gasCompute.FindKernel("SpawnParticle");
        spawnGasKernel = gasCompute.FindKernel("SpawnGasAtPoint");
        eraseKernel = gasCompute.FindKernel("EraseAtPoint");
        
        // Sand kernels
        sandSimulateKernel = sandCompute.FindKernel("SimulateSand");
        sandInitKernel = sandCompute.FindKernel("InitializeTexture");
        
        // Размеры
        gasCompute.SetInt("_Width", textureSize);
        gasCompute.SetInt("_Height", textureSize);
        sandCompute.SetInt("_Width", textureSize);
        sandCompute.SetInt("_Height", textureSize);
    }
    
    void InitializeSimulation()
    {
        for (int i = 0; i < 2; i++)
        {
            gasCompute.SetTexture(gasInitKernel, "_GasOutput", gasBuffers[i]);
            gasCompute.Dispatch(gasInitKernel, threadGroups, threadGroups, 1);
            
            sandCompute.SetTexture(sandInitKernel, "_Output", particleBuffers[i]);
            sandCompute.Dispatch(sandInitKernel, threadGroups, threadGroups, 1);
        }
    }
    
    void Update()
    {
        HandleInput();
        
        float dt = Mathf.Min(Time.deltaTime, 0.033f);
        
        SimulateSand();
        SimulateGas(dt);
        UpdateDisplay();
    }
    
    // ===== INPUT HANDLING =====
    
    void HandleInput()
    {
        // Выбор инструмента клавишами
        if (Input.GetKeyDown(KeyCode.Alpha1)) currentBrush = BrushType.Sand;
        if (Input.GetKeyDown(KeyCode.Alpha2)) currentBrush = BrushType.Gas;
        if (Input.GetKeyDown(KeyCode.Alpha3)) currentBrush = BrushType.Erase;
        
        // Изменение размера кисти колёсиком
        float scroll = Input.GetAxis("Mouse ScrollWheel");
        brushRadius = Mathf.Clamp(brushRadius + scroll * 5f, 1f, 30f);
        
        // Рисование
        if (Input.GetMouseButton(0))
        {
            Vector2Int texCoord = GetTextureCoordinate();
            if (texCoord.x >= 0)
            {
                DrawAtPosition(texCoord);
            }
        }
        
        // Очистка всего
        if (Input.GetKeyDown(KeyCode.C))
        {
            InitializeSimulation();
        }
    }
    
    Vector2Int GetTextureCoordinate()
    {
        if (targetCollider == null)
        {
            Debug.LogWarning("Assign MeshCollider!");
            return new Vector2Int(-1, -1);
        }
        
        Ray ray = Camera.main.ScreenPointToRay(Input.mousePosition);
        RaycastHit hit;
        
        if (targetCollider.Raycast(ray, out hit, 100f))
        {
            Vector2 uv = hit.textureCoord;
            int x = Mathf.FloorToInt(uv.x * textureSize);
            int y = Mathf.FloorToInt(uv.y * textureSize);
            return new Vector2Int(
                Mathf.Clamp(x, 0, textureSize - 1),
                Mathf.Clamp(y, 0, textureSize - 1)
            );
        }
        
        return new Vector2Int(-1, -1);
    }
    
    void DrawAtPosition(Vector2Int pos)
    {
        // Устанавливаем параметры кисти
        gasCompute.SetInts("_BrushPosition", pos.x, pos.y);
        gasCompute.SetFloat("_BrushRadius", brushRadius);
        gasCompute.SetFloat("_BrushStrength", brushStrength);
        gasCompute.SetInt("_BrushType", (int)currentBrush);
        gasCompute.SetFloat("_DeltaTime", Time.deltaTime);
        
        switch (currentBrush)
        {
            case BrushType.Sand:
                // Спавним частицы напрямую в текущий буфер
                gasCompute.SetTexture(spawnParticleKernel, "_ParticleOutput", particleBuffers[currentParticleBuffer]);
                gasCompute.Dispatch(spawnParticleKernel, threadGroups, threadGroups, 1);
                break;
                
            case BrushType.Gas:
                gasCompute.SetTexture(spawnGasKernel, "_GasOutput", gasBuffers[currentGasBuffer]);
                gasCompute.Dispatch(spawnGasKernel, threadGroups, threadGroups, 1);
                break;
                
            case BrushType.Erase:
                gasCompute.SetTexture(eraseKernel, "_ParticleOutput", particleBuffers[currentParticleBuffer]);
                gasCompute.SetTexture(eraseKernel, "_GasOutput", gasBuffers[currentGasBuffer]);
                gasCompute.Dispatch(eraseKernel, threadGroups, threadGroups, 1);
                break;
        }
    }
    
    // ===== SIMULATION =====
    
    void SimulateSand()
    {
        int read = currentParticleBuffer;
        int write = 1 - currentParticleBuffer;
        
        sandCompute.SetInt("_Frame", Time.frameCount);
        sandCompute.SetTexture(sandSimulateKernel, "_Input", particleBuffers[read]);
        sandCompute.SetTexture(sandSimulateKernel, "_Output", particleBuffers[write]);
        sandCompute.Dispatch(sandSimulateKernel, threadGroups, threadGroups, 1);
        
        currentParticleBuffer = write;
    }
    
    void SimulateGas(float dt)
    {
        gasCompute.SetFloat("_DeltaTime", dt);
        gasCompute.SetFloat("_AdvectionSpeed", advectionSpeed);
        gasCompute.SetFloat("_Diffusion", diffusion);
        gasCompute.SetFloat("_Dissipation", dissipation);
        gasCompute.SetFloat("_Gravity", gravity);
        gasCompute.SetFloat("_Buoyancy", buoyancy);
        
        gasCompute.SetTexture(forcesKernel, "_ParticlesTex", particleBuffers[currentParticleBuffer]);
        
        int read = currentGasBuffer;
        int write = 1 - currentGasBuffer;
        
        // Advection
        gasCompute.SetTexture(advectKernel, "_GasInput", gasBuffers[read]);
        gasCompute.SetTexture(advectKernel, "_GasOutput", gasBuffers[write]);
        gasCompute.Dispatch(advectKernel, threadGroups, threadGroups, 1);
        Swap(ref read, ref write);
        
        // Diffusion
        for (int i = 0; i < 2; i++)
        {
            gasCompute.SetTexture(diffuseKernel, "_GasInput", gasBuffers[read]);
            gasCompute.SetTexture(diffuseKernel, "_GasOutput", gasBuffers[write]);
            gasCompute.Dispatch(diffuseKernel, threadGroups, threadGroups, 1);
            Swap(ref read, ref write);
        }
        
        // Forces
        gasCompute.SetTexture(forcesKernel, "_GasInput", gasBuffers[read]);
        gasCompute.SetTexture(forcesKernel, "_GasOutput", gasBuffers[write]);
        gasCompute.Dispatch(forcesKernel, threadGroups, threadGroups, 1);
        
        currentGasBuffer = write;
    }
    
    void Swap(ref int a, ref int b) { int t = a; a = b; b = t; }
    
    void UpdateDisplay()
    {
        if (displayMaterial != null)
        {
            displayMaterial.SetTexture("_GasTex", gasBuffers[currentGasBuffer]);
            displayMaterial.SetTexture("_ParticleTex", particleBuffers[currentParticleBuffer]);
        }
    }
    
    void OnDestroy()
    {
        foreach (var rt in gasBuffers) if (rt != null) rt.Release();
        foreach (var rt in particleBuffers) if (rt != null) rt.Release();
    }
    
    // ===== GUI =====
    
    void OnGUI()
    {
        GUILayout.BeginArea(new Rect(10, 10, 200, 300));
        GUILayout.BeginVertical("box");
        
        GUILayout.Label("Tools (1-3):");
        
        GUI.color = currentBrush == BrushType.Sand ? Color.yellow : Color.white;
        if (GUILayout.Button("1. Sand")) currentBrush = BrushType.Sand;
        
        GUI.color = currentBrush == BrushType.Gas ? Color.cyan : Color.white;
        if (GUILayout.Button("2. Gas")) currentBrush = BrushType.Gas;
        
        GUI.color = currentBrush == BrushType.Erase ? Color.red : Color.white;
        if (GUILayout.Button("3. Erase")) currentBrush = BrushType.Erase;
        
        GUI.color = Color.white;
        
        GUILayout.Space(10);
        GUILayout.Label($"Brush Size: {brushRadius:F1}");
        GUILayout.Label("(Mouse Wheel)");
        
        GUILayout.Space(10);
        if (GUILayout.Button("Clear All (C)"))
        {
            InitializeSimulation();
        }
        
        GUILayout.EndVertical();
        GUILayout.EndArea();
    }

#if UNITY_EDITOR
    void DrawBrushPreview()
    {
        if (targetCollider == null) return;
        
        Ray ray = Camera.main.ScreenPointToRay(Input.mousePosition);
        RaycastHit hit;
        
        if (targetCollider.Raycast(ray, out hit, 100f))
        {
            Vector3 worldPos = hit.point;
            
            // Размер кисти в мировых координатах
            float worldRadius = (brushRadius / textureSize) * targetCollider.bounds.size.x;
            
            // Рисуем круг (для этого нужен отдельный shader или GL.Lines)
            Handles.color = Color.white;
            Handles.DrawWireDisc(worldPos, Vector3.forward, worldRadius);
        }
    }
#endif
}