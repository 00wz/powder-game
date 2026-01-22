using UnityEngine;

public class SandSimulationController : MonoBehaviour
{
    [Header("Compute Shader")]
    public ComputeShader sandCompute;
    
    [Header("Settings")]
    public int textureSize = 256;
    
    [Header("Visualization")]
    public Material displayMaterial;
    
    [Header("Spawning")]
    public bool spawnSand = true;
    public int spawnRadius = 3;
    public float spawnRate = 0.5f;  // Шанс спавна каждый кадр
    
    // Double buffering
    private RenderTexture[] buffers = new RenderTexture[2];
    private int currentBuffer = 0;
    
    // Kernel handles
    private int simulateKernel;
    private int initKernel;
    
    // Для спавна
    private Vector2Int spawnPosition;
    
    void Start()
    {
        CreateTextures();
        SetupComputeShader();
        InitializeSimulation();
        
        spawnPosition = new Vector2Int(textureSize / 2, textureSize - 10);
    }
    
    void CreateTextures()
    {
        for (int i = 0; i < 2; i++)
        {
            buffers[i] = new RenderTexture(textureSize, textureSize, 0, RenderTextureFormat.ARGBFloat);
            buffers[i].enableRandomWrite = true;
            buffers[i].filterMode = FilterMode.Point;
            buffers[i].wrapMode = TextureWrapMode.Clamp;
            buffers[i].Create();
        }
    }
    
    void SetupComputeShader()
    {
        simulateKernel = sandCompute.FindKernel("SimulateSand");
        initKernel = sandCompute.FindKernel("InitializeTexture");
        
        sandCompute.SetInt("_Width", textureSize);
        sandCompute.SetInt("_Height", textureSize);
    }
    
    void InitializeSimulation()
    {
        // Очищаем обе текстуры
        int groups = Mathf.CeilToInt(textureSize / 8.0f);
        
        sandCompute.SetTexture(initKernel, "_Output", buffers[0]);
        sandCompute.Dispatch(initKernel, groups, groups, 1);
        
        sandCompute.SetTexture(initKernel, "_Output", buffers[1]);
        sandCompute.Dispatch(initKernel, groups, groups, 1);
    }
    
    void Update()
    {
        // Спавн песка
        if (spawnSand && Random.value < spawnRate)
        {
            SpawnSand(spawnPosition.x, spawnPosition.y, spawnRadius);
        }
        
        // Симуляция
        SimulateStep();
        
        // Обновляем материал для отображения
        if (displayMaterial != null)
        {
            displayMaterial.mainTexture = buffers[currentBuffer];
        }
    }
    
    void SimulateStep()
    {
        int readBuffer = currentBuffer;
        int writeBuffer = 1 - currentBuffer;
        
        sandCompute.SetInt("_Frame", Time.frameCount);
        sandCompute.SetTexture(simulateKernel, "_Input", buffers[readBuffer]);
        sandCompute.SetTexture(simulateKernel, "_Output", buffers[writeBuffer]);
        
        int groups = Mathf.CeilToInt(textureSize / 8.0f);
        sandCompute.Dispatch(simulateKernel, groups, groups, 1);
        
        currentBuffer = writeBuffer;
    }
    
    // Спавн песка в позиции
    public void SpawnSand(int x, int y, int radius)
    {
        // Создаём временную текстуру для модификации
        Texture2D tempTex = new Texture2D(textureSize, textureSize, TextureFormat.RGBAFloat, false);
        
        // Копируем текущий буфер
        RenderTexture.active = buffers[currentBuffer];
        tempTex.ReadPixels(new Rect(0, 0, textureSize, textureSize), 0, 0);
        tempTex.Apply();
        RenderTexture.active = null;
        
        // Добавляем песок
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
                        tempTex.SetPixel(px, py, new Color(1, 0, 0, 1)); // 1 = SAND
                    }
                }
            }
        }
        tempTex.Apply();
        
        // Копируем обратно в RenderTexture
        Graphics.Blit(tempTex, buffers[currentBuffer]);
        
        Destroy(tempTex);
    }
    
    void OnDestroy()
    {
        for (int i = 0; i < 2; i++)
        {
            if (buffers[i] != null)
            {
                buffers[i].Release();
            }
        }
    }
}