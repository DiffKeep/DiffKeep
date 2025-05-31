using DiffKeep.Services;
using LLama;
using LLama.Common;
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
        //var testModel = "gemma-3-4b-it-Q6_K.gguf";
        //await _service.LoadModelAsync(testModel, false);
        
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
    
    [Fact]
    public async Task GenerateEmbedding_SimilarityPromptSearchTest()
    {
        // Arrange
        _service = new LlamaSharpEmbeddingGenerateService();
        //var testModel = "gemma-3-4b-it-Q6_K.gguf";
        //await _service.LoadModelAsync(testModel, false);
        
        var search = "rain";
        var prompt1 = "rain, umbrella, girl, looking up, wet hair, city street, puddles, melancholic, atmospheric, soft lighting, bokeh, long hair, gentle expression, side view, full body, dynamic angle, blue tones, cozy, peaceful, shallow depth of field, realistic, cinematic, blurry background, raindrops, wind, motion blur, longing, vulnerable, youth, candid, street photography, overcast, detailed background, reflections, fashion, simple clothing, everyday life, artistic, emotional, vulnerable, natural light, wet pavement, city lights, urban scene, youth, lonely, thoughtful, side glance, wet clothes, pensive, cinematic lighting, diffused lighting, atmospheric, blurred motion, street fashion, realistic textures, detailed shadows, soft focus, realistic skin texture, natural pose, simple background, urban environment, quiet moment, emotional depth, muted colors, wet surfaces, street style, artistic photography, city life, lonely, pensive, side glance, realistic details, moody, rainy day, cozy atmosphere, blurred background, dynamic composition, artistic expression, atmospheric perspective, cinematic shot";
        var prompt2 = "rain, umbrella, girl, looking_up, wet_hair, smiling, city, street, puddles, bokeh, soft_lighting, long_hair, shallow_depth_of_field, dynamic_pose, colorful_raincoat, joyful, whimsical, atmospheric, street_photography, candid, full_body, side_view, motion_blur, rainy_day, cozy, vibrant, cute, happy, youth, indoors, studio_shot, portrait, 1girl, solo, detailed_background, hd, high_resolution, masterpiece, best_quality, illustration, digital_art, trending_on_artstation";
        var prompt3 = "angel, female, electricity, glowing, wings, halo, divine, ethereal, long hair, detailed eyes, full body, dynamic pose, energy, sparks, light, fantasy, otherworldly, celestial, beautiful, serene, soft lighting, intricate details, flowing hair, pale skin, blue eyes, white wings, gold halo, dramatic lighting, power, magic, highly detailed, digital art, concept art, illustration, 8k, uhd, masterpiece, intricate, complex, vibrant colors";
        var prompt4 = "nude, woman, riding, broomstick, night, stars, full_moon, silhouette, flying, dynamic_pose, long_hair, wind, fantasy, witch, dark_fantasy, cleavage, side_view, outdoors, magical, ethereal, detailed_background, realistic, nipples, spread_legs, provocative, dark_hair, breasts, buttocks, curvy, pale_skin, perfect_anatomy, detailed_shadows, highres, artistic, illustration, digital_art, 8k, uhd, masterpiece, looking_at_viewer, serene, expressionless, long_legs, arched_back, fantasy_setting, moonlit, dramatic_lighting, detailed_clothing, minimalist_clothing, witch_hat, windblown_hair, nipples_visible, suggestive, open_legs, fantasy_art, digital_painting, unreal_engine, cinematic, intricate_details, full_body, looking_down";

        // Act
        var embeddings1 = await make(search);
        var embeddings2 = await make(prompt1);
        var embeddings3 = await make(prompt2);
        var embeddings4 = await make(prompt3);
        var embeddings5 = await make(prompt4);
        
        _testOutputHelper.WriteLine($"Embeddings count for search: {embeddings1.Count} Size of first element: {embeddings1.First().Length}");
        _testOutputHelper.WriteLine($"Embeddings count for prompt 1: {embeddings2.Count} Size of first element: {embeddings2.First().Length}");

        // Calculate cosine similarities
        double similarity1_2 = CosineSimilarity(embeddings1[0], embeddings2[0]);
        double similarity1_3 = CosineSimilarity(embeddings1[0], embeddings3[0]);
        double similarity1_4 = CosineSimilarity(embeddings1[0], embeddings4[0]);
        double similarity1_5 = CosineSimilarity(embeddings1[0], embeddings5[0]);
        
        // Output similarities
        _testOutputHelper.WriteLine($"\nSearching for: {search}");
        _testOutputHelper.WriteLine($"Similarities:");
        _testOutputHelper.WriteLine($"prompt 1 (girl with umbrella in rain, city): {similarity1_2}");
        _testOutputHelper.WriteLine($"prompt 2 (girl with umbrella in rain, city): {similarity1_3}");
        _testOutputHelper.WriteLine($"prompt 3 (electric angel): {similarity1_4}");
        _testOutputHelper.WriteLine($"prompt 4 (witch on broom): {similarity1_5}");

        // Assert
    }

    private LLamaEmbedder? maker;
    private async Task<IReadOnlyList<float[]>> make(string text)
    {
        if (maker == null)
        {
            var testModel = "gemma-3-4b-it-Q6_K.gguf";
            var fullModelPath = Path.Join(Directory.GetCurrentDirectory(), "models", testModel);
            var parameters = new ModelParams(fullModelPath)
            {
                GpuLayerCount = 999,
                ContextSize = 1024,
                PoolingType = 0,
            };
            var loadedModel = await LLamaWeights.LoadFromFileAsync(parameters);
            maker = new LLamaEmbedder(loadedModel, parameters);
            _testOutputHelper.WriteLine($"Model: {fullModelPath}");
            _testOutputHelper.WriteLine($"Model has encoder: {maker.Context.NativeHandle.ModelHandle.HasEncoder}");
        }

        var embeddings = await maker.GetEmbeddings(text);
        return embeddings.Select(NormalizeEmbedding).ToList();
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
    
    private float[] NormalizeEmbedding(float[] embedding)
    {
        float sum = 0;
        for (int i = 0; i < embedding.Length; i++)
            sum += embedding[i] * embedding[i];
    
        float magnitude = (float)Math.Sqrt(sum);
        var normalized = new float[embedding.Length];
        for (int i = 0; i < embedding.Length; i++)
            normalized[i] = embedding[i] / magnitude;
    
        return normalized;
    }
}