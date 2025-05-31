using System.Diagnostics;
using DiffKeep.Services;
using Xunit.Abstractions;

namespace Tests.Services;

using System.Threading.Tasks;
using Xunit;
using FluentAssertions;

public class LlamaSharpEmbeddingGenerateServiceTests
{
    private readonly ITestOutputHelper _testOutputHelper;
    private LlamaSharpEmbeddingGenerateService _service;

    public LlamaSharpEmbeddingGenerateServiceTests(ITestOutputHelper testOutputHelper)
    {
        _testOutputHelper = testOutputHelper;
    }

    private const string TestModelName = "gte-large.Q6_K.gguf";

    [Fact]
    public async Task GenerateEmbeddingAsync_WithValidText_ShouldReturnEmbeddings()
    {
        // Arrange
        _service = new LlamaSharpEmbeddingGenerateService();
        var inputText = "Test text for embedding";

        // Act
        var embeddings = await _service.GenerateEmbeddingAsync(inputText);

        // Assert
        embeddings.Should().NotBeNull();
        embeddings.Should().NotBeEmpty();
        embeddings[0].Should().NotBeEmpty();
        embeddings[0].Length.Should().Be(1024);
    }

    [Fact]
    public async Task LoadModelAsync_WithValidPath_ShouldLoadSuccessfully()
    {
        // Arrange
        _service = new LlamaSharpEmbeddingGenerateService();
        var modelPath = TestModelName;

        // Act & Assert
        await _service.LoadModelAsync(modelPath);
        // If no exception is thrown, the test passes
    }

    [Fact]
    public async Task GenerateEmbeddingAsync_WithoutExplicitModelLoad_ShouldLoadDefaultModelAndGenerateEmbeddings()
    {
        // Arrange
        _service = new LlamaSharpEmbeddingGenerateService();
        var inputText = "Test text for embedding";

        // Act
        var embeddings = await _service.GenerateEmbeddingAsync(inputText);

        // Assert
        embeddings.Should().NotBeNull();
        embeddings.Should().NotBeEmpty();
        embeddings[0].Should().NotBeEmpty();
        embeddings[0].Length.Should().Be(1024);
    }
    
    [Fact]
    public async Task GenerateEmbeddingAsync_WithNormalGenerativeModel_ShouldLoadAndGenerateEmbeddings()
    {
        // Arrange
        _service = new LlamaSharpEmbeddingGenerateService();
        var inputText = "Test text for embedding";
        var testModel = "gemma-3-4b-it-Q6_K.gguf";
        await _service.LoadModelAsync(testModel, false);

        // Act
        var embeddings = await _service.GenerateEmbeddingAsync(inputText);

        // Assert
        embeddings.Should().NotBeNull();
        embeddings.Should().NotBeEmpty();
        embeddings[0].Should().NotBeEmpty();
        embeddings[0].Length.Should().Be(2560);
    }
    
    [Fact]
    public async Task GenerateEmbedding_SimilarityTest()
    {
        // Arrange
        _service = new LlamaSharpEmbeddingGenerateService();
        var testModel = "gemma-3-4b-it-Q6_K.gguf";
        await _service.LoadModelAsync(testModel, false);
        
        var sentence1 = "The cat sits on the mat";
        var sentence2 = "A kitten is resting on the rug";
        var sentence3 = "A dog is sleeping in its kennel";
        var sentence4 = "Quantum mechanics describes the behavior of atoms";

        // Act
        var embeddings1 = await _service.GenerateEmbeddingAsync(sentence1);
        var embeddings2 = await _service.GenerateEmbeddingAsync(sentence2);
        var embeddings3 = await _service.GenerateEmbeddingAsync(sentence3);
        var embeddings4 = await _service.GenerateEmbeddingAsync(sentence4);

        // Calculate cosine similarities
        double similarity1_2 = CosineSimilarity(embeddings1[0], embeddings2[0]);
        double similarity1_3 = CosineSimilarity(embeddings1[0], embeddings3[0]);
        double similarity1_4 = CosineSimilarity(embeddings1[0], embeddings4[0]);
        double similarity2_3 = CosineSimilarity(embeddings2[0], embeddings3[0]);
        double similarity2_4 = CosineSimilarity(embeddings2[0], embeddings4[0]);
        
        // Output similarities
        _testOutputHelper.WriteLine($"Sentences:");
        _testOutputHelper.WriteLine($"1: {sentence1}");
        _testOutputHelper.WriteLine($"2: {sentence2}");
        _testOutputHelper.WriteLine($"3: {sentence3}");
        _testOutputHelper.WriteLine($"4: {sentence4}");
        _testOutputHelper.WriteLine($"\nSimilarities:");
        _testOutputHelper.WriteLine($"Similarity between 1 and 2 (should be highest): {similarity1_2}");
        _testOutputHelper.WriteLine($"Similarity between 1 and 3 (should be medium): {similarity1_3}");
        _testOutputHelper.WriteLine($"Similarity between 1 and 4 (should be lowest): {similarity1_4}");
        _testOutputHelper.WriteLine($"Similarity between 2 and 3 (should be around the same as similarity between 1 and 3): {similarity2_3}");
        _testOutputHelper.WriteLine($"Similarity between 2 and 4 (should be around the same as similarity between 1 and 4): {similarity2_4}");

        // Assert
        similarity1_2.Should().BeGreaterThan(similarity1_3,
            "because sentences about cats should be more similar than sentences about dogs");
        similarity1_3.Should().BeGreaterThan(similarity1_4,
            "because sentences about animals should be more similar than sentences about quantum mechanics");
        similarity2_3.Should().BeGreaterThan(similarity1_3,
            "because sentences about animals sleeping should more similar than sentences about dogs");
        similarity2_3.Should().BeGreaterThan(similarity2_4,
            "because sentences about animals should be more similar than sentences about quantum mechanics");
    }

    private double CosineSimilarity(float[] vec1, float[] vec2)
    {
        if (vec1.Length != vec2.Length)
            throw new ArgumentException("Vectors must be of the same length");

        double dotProduct = 0.0;
        double norm1 = 0.0;
        double norm2 = 0.0;

        for (int i = 0; i < vec1.Length; i++)
        {
            dotProduct += vec1[i] * vec2[i];
            norm1 += vec1[i] * vec1[i];
            norm2 += vec2[i] * vec2[i];
        }

        return dotProduct / (Math.Sqrt(norm1) * Math.Sqrt(norm2));
    }
}