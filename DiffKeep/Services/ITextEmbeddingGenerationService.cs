using System.Collections.Generic;
using System.Threading.Tasks;

namespace DiffKeep.Services;

public interface ITextEmbeddingGenerationService
{
    Task LoadModelAsync(string modelPath, bool isEmbeddingModel = true);
    Task<IReadOnlyList<float[]>> GenerateEmbeddingAsync(string text);
    string ModelName();
    int EmbeddingSize();
}