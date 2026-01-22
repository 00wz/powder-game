using UnityEngine;

public class SimpleComputeController : MonoBehaviour
{
    [Header("Compute Shader")]
    public ComputeShader computeShader;
    
    [Header("Settings")]
    public int textureWidth = 256;
    public int textureHeight = 256;
    
    [Header("Output")]
    public Material displayMaterial;  // Материал для отображения
    
    private RenderTexture outputTexture;
    private int kernelHandle;
    
    void Start()
    {
        // Создаём RenderTexture
        outputTexture = new RenderTexture(textureWidth, textureHeight, 0);
        outputTexture.enableRandomWrite = true;  // Обязательно для Compute Shader!
        outputTexture.filterMode = FilterMode.Point;
        outputTexture.wrapMode = TextureWrapMode.Clamp;
        outputTexture.Create();
        
        // Находим kernel по имени
        kernelHandle = computeShader.FindKernel("CSMain");
        
        // Устанавливаем постоянные параметры
        computeShader.SetInt("_Width", textureWidth);
        computeShader.SetInt("_Height", textureHeight);
        computeShader.SetTexture(kernelHandle, "Result", outputTexture);
        
        // Назначаем текстуру на материал для отображения
        if (displayMaterial != null)
        {
            displayMaterial.mainTexture = outputTexture;
        }
    }
    
    void Update()
    {
        // Передаём время
        computeShader.SetFloat("_Time", Time.time);
        
        // Вычисляем количество групп
        // textureWidth / 8 = количество групп по X
        int groupsX = Mathf.CeilToInt(textureWidth / 8.0f);
        int groupsY = Mathf.CeilToInt(textureHeight / 8.0f);
        
        // Запускаем Compute Shader
        computeShader.Dispatch(kernelHandle, groupsX, groupsY, 1);
    }
    
    void OnDestroy()
    {
        // Освобождаем ресурсы
        if (outputTexture != null)
        {
            outputTexture.Release();
        }
    }
}