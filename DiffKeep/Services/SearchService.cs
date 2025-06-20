using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using DiffKeep.Models;
using DiffKeep.Repositories;

namespace DiffKeep.Services;

public enum SearchTypeEnum
{
    FullText,
    Semantic,
    Hybrid
}

public class SearchService
{
    private readonly ITextEmbeddingGenerationService _textEmbeddingService;
    private readonly IEmbeddingsRepository _embeddingsRepository;
    private readonly IImageRepository _imageRepository;

    public SearchService(
        ITextEmbeddingGenerationService textEmbeddingService,
        IEmbeddingsRepository embeddingsRepository,
        IImageRepository imageRepository)
    {
        _textEmbeddingService = textEmbeddingService;
        _embeddingsRepository = embeddingsRepository;
        _imageRepository = imageRepository;
    }
    
    public async Task<IEnumerable<Image>> TextSearchImagesAsync(string searchText, long? libraryId = null,
        string? path = null, SearchTypeEnum searchType = SearchTypeEnum.FullText)
    {
        if (searchType ==  SearchTypeEnum.FullText)
        {
            // search using FTS
            return await _imageRepository.SearchByPromptAsync(searchText, libraryId, path);
        }
        
        var searchResults = await SearchByTextAsync(searchText, libraryId, path, searchType);
        return searchResults.Select(result => new Image
        {
            Id = result.ImageId,
            Path = result.Path,
            Hash = "",
            Score = 1 - result.Score, // invert the "lower is better" similarity score, for better UX
        });
    }

    private async Task<IEnumerable<(long ImageId, string Path, float Score)>> SearchByTextAsync(string searchText,
        long? libraryId = null, string? path = null, SearchTypeEnum searchType = SearchTypeEnum.Semantic)
    {
        // Generate embedding for the search text
        var embeddings = await _textEmbeddingService.GenerateEmbeddingAsync(searchText);
        
        // Since GenerateEmbeddingAsync returns IReadOnlyList<float[]>, we'll use the first embedding
        // Typically for text embeddings, we expect a single embedding vector
        if (embeddings.Count == 0)
        {
            return new List<(long ImageId, string Path, float Score)>();
        }

        if (searchType == SearchTypeEnum.Semantic)
        {
             return await _embeddingsRepository.SearchSimilarByVectorAsync(embeddings[0], _textEmbeddingService.ModelName(), 1000, libraryId, path);
        }

        // Otherwise, it's hybrid search
        return await _embeddingsRepository.SearchCombinedAsync(searchText,
            embeddings[0], _textEmbeddingService.ModelName(), _textEmbeddingService.EmbeddingSize(), 0.7f, 0.3f, 1000, libraryId, path);
    }
}