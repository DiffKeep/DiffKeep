using System.Collections.Generic;
using System.Threading.Tasks;

namespace DiffKeep.Services;

public interface IEmbeddingGenerationService
{
    Task LoadModelAsync(string modelPath);
    Task<IReadOnlyList<float[]>> GenerateEmbeddingAsync(string text);
}