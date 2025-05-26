using System.Collections.Generic;
using System.Threading.Tasks;

namespace DiffKeep.Repositories;

public interface IEmbeddingsRepository
{
    Task StorePromptEmbeddingAsync(long imageId, float[] embedding);
    Task StoreDescriptionEmbeddingAsync(long imageId, float[] embedding);
    Task<IEnumerable<(long ImageId, float Score)>> SearchSimilarPromptsByVectorAsync(float[] embedding, int limit = 10);
    Task<IEnumerable<(long ImageId, float Score)>> SearchSimilarDescriptionsByVectorAsync(float[] embedding, int limit = 10);
    Task DeleteEmbeddingsForImageAsync(long imageId);
}
