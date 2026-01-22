using UnityEngine;

public class WawesController : MonoBehaviour
{
    public ComputeShader wawesCompute;
    
    public float oscillationSpeed = 1f;
    
    [Header("Settings")]
    public int textureSize = 256;
    
    [Header("Absorbing Boundary")]
    [Range(0, 100)] public float absorbingZoneWidth = 20f;  // Ширина поглощающей зоны в пикселях
    [Range(0.1f, 20f)] public float absorbingStrength = 5f; // Сила затухания
    
    [Header("Triangle Initialization")]
    [Range(10, 200)] public float triangleSize = 50f;       // Размер (высота) треугольника
    [Range(1, 50)] public float triangleWaveSpeed = 10f;    // Скорость волны внутри треугольника
    [Range(1, 50)] public float defaultWaveSpeed = 20f;     // Скорость волны снаружи треугольника
    
    [Header("Directional Wave Source")]
    [Range(0, 360)] public float directionalAngle = 0f;     // Угол направления волны (в градусах)
    [Range(5, 100)] public float directionalSize = 20f;     // Размер источника
    [Range(0.1f, 10f)] public float directionalAmplitude = 1f; // Амплитуда волны
    
    [Header("Directional Wave Frequencies (RGB)")]
    [Range(0.01f, 1f)] public float directionalFrequencyR = 0.25f; // Частота для красного канала
    [Range(0.01f, 1f)] public float directionalFrequencyG = 0.35f; // Частота для зелёного канала
    [Range(0.01f, 1f)] public float directionalFrequencyB = 0.45f; // Частота для синего канала

    [Header("Brush")]
    [Range(1, 30)] public float brushRadius = 1f;
    public BrushType currentBrush = BrushType.Point;
    public float wawesSpeed = 1f;

    public float wawesSpeedDelta = 5f;
    
    [Header("Visualization")]
    public Material displayMaterial;
    public MeshCollider targetCollider;  // Для raycasting
    
    public enum BrushType { Point, Row, Column, Wall, Directional }

    // Текстуры - двойная буферизация для Amplitude и Velocity
    // Amplitude: RGB = амплитуды для R,G,B каналов; A = скорость распространения
    // Velocity: RGB = скорости для R,G,B каналов; A = не используется
    private RenderTexture[] ampBuffers = new RenderTexture[2];
    private RenderTexture[] velBuffers = new RenderTexture[2];
    private int currentBuffer = 0;
    
    // Kernels
    private int wawesSimulateKernel, spawnWawesKernel, wawesInitKernel, initWithTriangleKernel;
    private int spawnWawesRowKernel, spawnWawesColumnKernel, spawnWallKernel, spawnDirectionalKernel;
    
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
            ampBuffers[i] = CreateRT();
            velBuffers[i] = CreateRT();
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
        // Wawes kernels
        wawesSimulateKernel = wawesCompute.FindKernel("SimulateWawes");
        spawnWawesKernel = wawesCompute.FindKernel("SpawnWawes");
        wawesInitKernel = wawesCompute.FindKernel("InitializeTexture");
        initWithTriangleKernel = wawesCompute.FindKernel("InitializeWithTriangle");
        spawnWawesRowKernel = wawesCompute.FindKernel("SpawnWawesRow");
        spawnWawesColumnKernel = wawesCompute.FindKernel("SpawnWawesColumn");     
        spawnWallKernel = wawesCompute.FindKernel("SpawnWalls");
        spawnDirectionalKernel = wawesCompute.FindKernel("SpawnDirectionalWave");
        
        // Размеры
        wawesCompute.SetInt("_Width", textureSize);
        wawesCompute.SetInt("_Height", textureSize);
    }
    
    void InitializeSimulation()
    {
        for (int i = 0; i < 2; i++)
        {
            // Устанавливаем обе текстуры для инициализации
            wawesCompute.SetTexture(wawesInitKernel, "_AmpOutput", ampBuffers[i]);
            wawesCompute.SetTexture(wawesInitKernel, "_VelOutput", velBuffers[i]);
            wawesCompute.Dispatch(wawesInitKernel, threadGroups, threadGroups, 1);
        }
    }
    
    void InitializeWithTriangle()
    {
        // Устанавливаем параметры треугольника
        wawesCompute.SetFloat("_TriangleSize", triangleSize);
        wawesCompute.SetFloat("_TriangleWaveSpeed", triangleWaveSpeed);
        wawesCompute.SetFloat("_DefaultWaveSpeed", defaultWaveSpeed);
        
        for (int i = 0; i < 2; i++)
        {
            wawesCompute.SetTexture(initWithTriangleKernel, "_AmpOutput", ampBuffers[i]);
            wawesCompute.SetTexture(initWithTriangleKernel, "_VelOutput", velBuffers[i]);
            wawesCompute.Dispatch(initWithTriangleKernel, threadGroups, threadGroups, 1);
        }
    }

    void Update()
    {
        HandleInput();        
        SimulateWawes();
        UpdateDisplay();
    }
    
    // ===== INPUT HANDLING =====

    void HandleInput()
    {        
        // Выбор инструмента клавишами
        if (Input.GetKeyDown(KeyCode.Alpha1)) currentBrush = BrushType.Point;
        if (Input.GetKeyDown(KeyCode.Alpha2)) currentBrush = BrushType.Row;
        if (Input.GetKeyDown(KeyCode.Alpha3)) currentBrush = BrushType.Column;
        if (Input.GetKeyDown(KeyCode.Alpha4)) currentBrush = BrushType.Wall;
        if (Input.GetKeyDown(KeyCode.Alpha5)) currentBrush = BrushType.Directional;

        // Изменение скорости осцилляции колёсиком
        float scroll = Input.GetAxis("Mouse ScrollWheel");
        oscillationSpeed = Mathf.Clamp(oscillationSpeed + scroll * 10f, 1f, 100f);
        
        // Поворот направления волны клавишами Q/E
        if (currentBrush == BrushType.Directional)
        {
            if (Input.GetKey(KeyCode.Q))
                directionalAngle = (directionalAngle - 90f * Time.deltaTime + 360f) % 360f;
            if (Input.GetKey(KeyCode.E))
                directionalAngle = (directionalAngle + 90f * Time.deltaTime) % 360f;
        }
        
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
        
        // Инициализация с треугольником
        if (Input.GetKeyDown(KeyCode.T))
        {
            InitializeWithTriangle();
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
        float value = Mathf.Sin(Time.time * oscillationSpeed);
        // Устанавливаем параметры кисти
        wawesCompute.SetInts("_BrushPosition", pos.x, pos.y);
        wawesCompute.SetFloat("_BrushRadius", brushRadius);
        wawesCompute.SetFloat("_BrushValue", value);
        
        // Для рисования используем текущий буфер (и Amp и Vel)
        int curr = currentBuffer;
        
        switch (currentBrush)
        {
            case BrushType.Point:
                wawesCompute.SetTexture(spawnWawesKernel, "_AmpOutput", ampBuffers[curr]);
                wawesCompute.SetTexture(spawnWawesKernel, "_VelOutput", velBuffers[curr]);
                wawesCompute.Dispatch(spawnWawesKernel, threadGroups, threadGroups, 1);
                break;
                
            case BrushType.Row:
                wawesCompute.SetTexture(spawnWawesRowKernel, "_AmpOutput", ampBuffers[curr]);
                wawesCompute.SetTexture(spawnWawesRowKernel, "_VelOutput", velBuffers[curr]);
                wawesCompute.Dispatch(spawnWawesRowKernel, threadGroups, threadGroups, 1);
                break;
                
            case BrushType.Column:
                wawesCompute.SetTexture(spawnWawesColumnKernel, "_AmpOutput", ampBuffers[curr]);
                wawesCompute.SetTexture(spawnWawesColumnKernel, "_VelOutput", velBuffers[curr]);
                wawesCompute.Dispatch(spawnWawesColumnKernel, threadGroups, threadGroups, 1);
                break;
                
            case BrushType.Wall:
                wawesCompute.SetTexture(spawnWallKernel, "_AmpOutput", ampBuffers[curr]);
                wawesCompute.SetTexture(spawnWallKernel, "_VelOutput", velBuffers[curr]);
                wawesCompute.SetFloat("_WawesSpeed", wawesSpeed);
                wawesCompute.Dispatch(spawnWallKernel, threadGroups, threadGroups, 1);
                break;
                
            case BrushType.Directional:
                wawesCompute.SetFloat("_DirectionalAngle", directionalAngle * Mathf.Deg2Rad);
                wawesCompute.SetFloat("_DirectionalFrequencyR", directionalFrequencyR);
                wawesCompute.SetFloat("_DirectionalFrequencyG", directionalFrequencyG);
                wawesCompute.SetFloat("_DirectionalFrequencyB", directionalFrequencyB);
                wawesCompute.SetFloat("_DirectionalSize", directionalSize);
                wawesCompute.SetFloat("_DirectionalAmplitude", directionalAmplitude);
                wawesCompute.SetFloat("_Time", Time.time);
                wawesCompute.SetTexture(spawnDirectionalKernel, "_AmpOutput", ampBuffers[curr]);
                wawesCompute.SetTexture(spawnDirectionalKernel, "_VelOutput", velBuffers[curr]);
                wawesCompute.Dispatch(spawnDirectionalKernel, threadGroups, threadGroups, 1);
                break;
        }
    }
    
    // ===== SIMULATION =====
    
    void SimulateWawes()
    {
        int read = currentBuffer;
        int write = 1 - currentBuffer;
        
        wawesCompute.SetFloat("_DeltaTime", Time.deltaTime);
        // Обновляем параметры поглощающей зоны каждый кадр (для изменения в реальном времени)
        wawesCompute.SetFloat("_AbsorbingZoneWidth", absorbingZoneWidth);
        wawesCompute.SetFloat("_AbsorbingStrength", absorbingStrength);
        wawesCompute.SetFloat("_WawesSpeedDelta", wawesSpeedDelta);
        
        // Устанавливаем текстуры для чтения и записи
        wawesCompute.SetTexture(wawesSimulateKernel, "_AmpInput", ampBuffers[read]);
        wawesCompute.SetTexture(wawesSimulateKernel, "_VelInput", velBuffers[read]);
        wawesCompute.SetTexture(wawesSimulateKernel, "_AmpOutput", ampBuffers[write]);
        wawesCompute.SetTexture(wawesSimulateKernel, "_VelOutput", velBuffers[write]);
        
        wawesCompute.Dispatch(wawesSimulateKernel, threadGroups, threadGroups, 1);
        
        currentBuffer = write;
    }
    
    void UpdateDisplay()
    {
        if (displayMaterial != null)
        {
            // Устанавливаем текстуру амплитуды для визуализации
            displayMaterial.SetTexture("_AmpTex", ampBuffers[currentBuffer]);
        }
    }
    
    void OnDestroy()
    {
        foreach (var rt in ampBuffers) if (rt != null) rt.Release();
        foreach (var rt in velBuffers) if (rt != null) rt.Release();
    }
    
    // ===== GUI =====
    
    void OnGUI()
    {
        GUILayout.BeginArea(new Rect(10, 10, 200, 350));
        GUILayout.BeginVertical("box");
        
        GUILayout.Label("Tools (1-5):");
        
        GUI.color = currentBrush == BrushType.Point ? Color.yellow : Color.white;
        if (GUILayout.Button("1. Point")) currentBrush = BrushType.Point;
        
        GUI.color = currentBrush == BrushType.Row ? Color.cyan : Color.white;
        if (GUILayout.Button("2. Row")) currentBrush = BrushType.Row;
        
        GUI.color = currentBrush == BrushType.Column ? Color.red : Color.white;
        if (GUILayout.Button("3. Column")) currentBrush = BrushType.Column;
        
        GUI.color = currentBrush == BrushType.Wall ? Color.green : Color.white;
        if (GUILayout.Button("4. Wall")) currentBrush = BrushType.Wall;
        
        GUI.color = currentBrush == BrushType.Directional ? Color.magenta : Color.white;
        if (GUILayout.Button("5. Directional (RGB)")) currentBrush = BrushType.Directional;
        
        GUI.color = Color.white;
        
        GUILayout.Space(10);
        GUILayout.Label($"OscillationSpeed: {oscillationSpeed:F1}");
        
        if (currentBrush == BrushType.Directional)
        {
            GUILayout.Label($"Direction: {directionalAngle:F0}°");
            GUILayout.Label("Use Q/E to rotate");
            GUILayout.Space(5);
            GUILayout.Label($"Freq R: {directionalFrequencyR:F2}");
            GUILayout.Label($"Freq G: {directionalFrequencyG:F2}");
            GUILayout.Label($"Freq B: {directionalFrequencyB:F2}");
        }
        
        GUILayout.Space(10);
        if (GUILayout.Button("Clear All (C)"))
        {
            InitializeSimulation();
        }
        
        if (GUILayout.Button("Triangle Init (T)"))
        {
            InitializeWithTriangle();
        }
        
        GUILayout.EndVertical();
        GUILayout.EndArea();
    }
}
