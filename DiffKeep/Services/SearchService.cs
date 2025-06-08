using System;
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
    private readonly IImageRepository _imageRepository;

    public SearchService(
        IEmbeddingGenerationService embeddingService,
        IEmbeddingsRepository embeddingsRepository,
        IImageRepository imageRepository)
    {
        _embeddingService = embeddingService;
        _embeddingsRepository = embeddingsRepository;
        _imageRepository = imageRepository;
    }
    
    public async Task<IEnumerable<Image>> TextSearchImagesAsync(string searchText, long? libraryId = null, string? path = null)
    {
        if (!Program.Settings.UseEmbeddings)
        {
            // search using FTS
            return await _imageRepository.SearchByPromptAsync(searchText, libraryId, path);
        }
        
        var searchResults = await SearchByTextAsync(searchText, libraryId, path);
        return searchResults.Select(result => new Image
        {
            Id = result.ImageId,
            Path = result.Path,
            Hash = "",
            Score = 1 - result.Score, // invert the "lower is better" similarity score, for better UX
        });
    }

    private async Task<IEnumerable<(long ImageId, string Path, float Score)>> SearchByTextAsync(string searchText, long? libraryId = null, string? path = null)
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
        return await _embeddingsRepository.SearchSimilarByVectorAsync(embeddings[0], 1000, libraryId, path);
    }
}