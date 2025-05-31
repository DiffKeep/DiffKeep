using System.Collections.Generic;
using System.Threading.Tasks;
using DiffKeep.Models;

namespace DiffKeep.Repositories;

public interface IEmbeddingsRepository
{
    Task DeleteEmbeddingsForImageAsync(long imageId);
    Task DeleteEmbeddingsForLibraryAsync(long libraryId);
    Task StoreEmbeddingAsync(long imageId, EmbeddingType embeddingType, float[] embedding);
    Task StoreBatchEmbeddingsAsync(IEnumerable<(long ImageId, EmbeddingType Type, float[] Embedding)> embeddings);
    Task<IEnumerable<(long ImageId, string Path, float Score)>> SearchSimilarByVectorAsync(float[] embedding, int limit = 100);
}
