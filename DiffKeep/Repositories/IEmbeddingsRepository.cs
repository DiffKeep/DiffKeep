using System.Collections.Generic;
using System.Threading.Tasks;
using DiffKeep.Models;

namespace DiffKeep.Repositories;

public interface IEmbeddingsRepository
{
    Task DeleteEmbeddingsForImageAsync(long imageId);
    Task DeleteEmbeddingsForLibraryAsync(long libraryId);
    Task StoreEmbeddingAsync(long imageId, EmbeddingSource source, string model, float[] embedding);
    Task StoreBatchEmbeddingsAsync(IEnumerable<(long ImageId, EmbeddingSource Source, string Model, float[] Embedding)> embeddings);
    Task<IEnumerable<(long ImageId, string Path, float Score)>> SearchSimilarByVectorAsync(float[] embedding, string modelName,
        int limit = 100, long? libraryId = null, string path = null);

    Task<IEnumerable<(long ImageId, string Path, float Score)>> SearchCombinedAsync(
        string textQuery,
        float[] embedding,
        string modelName,
        int embeddingSize,
        float vectorWeight = 0.7f, // Adjustable weight for vector search
        float textWeight = 0.3f, // Adjustable weight for FTS5 search
        int limit = 100,
        long? libraryId = null,
        string path = null);

    public Task<IEnumerable<Embedding>> GetAllAsync();
}
