using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using DiffKeep.Models;
using DiffKeep.Repositories;

namespace DiffKeep.Services;

public class SearchService
{
    private readonly IEmbeddingGenerationService _embeddingService;
    private readonly IEmbeddingsRepository _embeddingsRepository;

    public SearchService(
        IEmbeddingGenerationService embeddingService,
        IEmbeddingsRepository embeddingsRepository)
    {
        _embeddingService = embeddingService;
        _embeddingsRepository = embeddingsRepository;
    }
    
    public async Task<IEnumerable<Image>> SearchByTextAndGetImagesAsync(string searchText)
    {
        var searchResults = await SearchByTextAsync(searchText);
        return searchResults.Select(result => new Image
        {
            Id = result.ImageId,
            Path = result.Path,
            Hash = "",
        });
    }

    public async Task<IEnumerable<(long ImageId, string Path, float Score)>> SearchByTextAsync(string searchText)
    {
        // Generate embedding for the search text
        var embeddings = await _embeddingService.GenerateEmbeddingAsync(searchText);
        
        // Since GenerateEmbeddingAsync returns IReadOnlyList<float[]>, we'll use the first embedding
        // Typically for text embeddings, we expect a single embedding vector
        if (embeddings.Count == 0)
        {
            return new List<(long ImageId, string Path, float Score)>();
        }

        // Search for similar vectors in the repository
        return await _embeddingsRepository.SearchSimilarByVectorAsync(embeddings[0]);
    }
}