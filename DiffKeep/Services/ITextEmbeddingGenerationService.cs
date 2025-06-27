using System.Collections.Generic;
using System.Threading.Tasks;

namespace DiffKeep.Services;

public interface ITextEmbeddingGenerationService
{
    Task LoadModelAsync(string modelPath, bool isEmbeddingModel = true);
    Task<IReadOnlyList<float[]>> GenerateEmbeddingAsync(string text, bool isQuery = false);
    string ModelName();
    int EmbeddingSize();
    bool ModelExists(string? modelFile = null);
}