using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using LLama;
using LLama.Common;
using LLama.Native;

namespace DiffKeep.Services;

public class LlamaSharpEmbeddingGenerateService : IEmbeddingGenerationService
{
    private const string DefaultModel = "gte-large.Q6_K.gguf";
    private LLamaWeights? _loadedModel;
    private LLamaEmbedder? _embedder;
    private LLamaContext? _context;
    private bool _isEmbeddingModel = true;
    private ModelParams? _modelParams;
    private readonly SemaphoreSlim _modelLock = new SemaphoreSlim(1, 1);
    private readonly SemaphoreSlim _generatingLock = new SemaphoreSlim(1, 1);
    private string _modelName;

    private async Task LoadModelInternalAsync(string modelPath, bool isEmbeddingModel = true)
    {
        var fullModelPath = Path.Join(Program.DataPath, "models", modelPath);
        _isEmbeddingModel = isEmbeddingModel;
        Debug.WriteLine($"Loading model: {fullModelPath}. EmbeddingModel: {_isEmbeddingModel}");

        var parameters = new ModelParams(fullModelPath)
        {
            GpuLayerCount = 999,
        };
        _modelParams = parameters;
        if (isEmbeddingModel)
            parameters.Embeddings = true;
        else
        {
            parameters.PoolingType = LLamaPoolingType.Mean;
            parameters.ContextSize = 1024;
        }

        _loadedModel = await LLamaWeights.LoadFromFileAsync(parameters);
        _embedder = new LLamaEmbedder(_loadedModel, parameters);
        Debug.WriteLine($"Loaded model: {fullModelPath}");
        _modelName = Path.GetFileNameWithoutExtension(fullModelPath);
    }

    public string ModelName()
    {
        return _modelName;
    }

    public async Task LoadModelAsync(string modelPath, bool isEmbeddingModel = true)
    {
        await _modelLock.WaitAsync();
        try
        {
            if (_loadedModel != null)
                return;

            await LoadModelInternalAsync(modelPath, isEmbeddingModel);
        }
        finally
        {
            _modelLock.Release();
        }
    }

    public async Task<IReadOnlyList<float[]>> GenerateEmbeddingAsync(string text)
    {
        if (_loadedModel == null)
        {
            await _modelLock.WaitAsync();
            try
            {
                if (_loadedModel == null)
                {
                    await LoadModelInternalAsync(DefaultModel);
                }
            }
            finally
            {
                _modelLock.Release();
            }
        }

        await _generatingLock.WaitAsync();
        try
        {
            return _isEmbeddingModel && _embedder != null
                ? await _embedder.GetEmbeddings(text)
                : await GenerateEmbeddingsFromNormalModelAsync(text);
        }
        finally
        {
            _generatingLock.Release();
        }
    }

    private async Task<IReadOnlyList<float[]>> GenerateEmbeddingsFromNormalModelAsync(string text)
    {
        if (_loadedModel == null || _modelParams == null || _embedder == null)
            throw new InvalidOperationException("Model must be loaded before generating embeddings");
        
        return await _embedder.GetEmbeddings(text);
    }
}