using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using LLama;
using LLama.Common;
using LLama.Native;

namespace DiffKeep.Services;

public class LlamaSharpEmbeddingGenerateService: IEmbeddingGenerationService
{
    private const string DefaultModel = "gte-large.Q6_K.gguf";
    private LLamaWeights? loadedModel;
    private LLamaEmbedder? embedder;

    public LlamaSharpEmbeddingGenerateService()
    {
        NativeLibraryConfig.All.WithLogCallback(delegate(LLamaLogLevel level, string message)
        {
            Debug.WriteLine($"{level}: {message}");
        });
    }
    
    public async Task LoadModelAsync(string modelPath)
    {
        var fullModelPath = Path.Join(Program.DataPath, "models", modelPath);
        
        var parameters = new ModelParams(fullModelPath)
        {
            Embeddings = true,
            GpuLayerCount = 999,
            Threads = 16,
            BatchThreads = 16,
            // add model params as needed
        };
        loadedModel = await LLamaWeights.LoadFromFileAsync(parameters);
        embedder = new LLamaEmbedder(loadedModel, parameters);
    }

    public async Task<IReadOnlyList<float[]>> GenerateEmbeddingAsync(string text)
    {
        if (loadedModel == null)
        {
            await LoadModelAsync(DefaultModel);
        }

        return await embedder.GetEmbeddings(text);
    }
}