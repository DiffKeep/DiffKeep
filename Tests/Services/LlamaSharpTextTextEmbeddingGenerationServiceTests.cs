
using DiffKeep.Services;
using LLama;
using LLama.Common;
using Xunit;
using Xunit.Abstractions;

namespace Tests.Services;

public class LlamaSharpTextTextEmbeddingGenerationServiceTests
{
    private readonly ITestOutputHelper _testOutputHelper;
    private LlamaSharpTextTextEmbeddingGenerationService _service;

    public LlamaSharpTextTextEmbeddingGenerationServiceTests(ITestOutputHelper testOutputHelper)
    {
        _testOutputHelper = testOutputHelper;
    }

    private const string TestModelName = "snowflake-arctic-embed-l.Q8_0.gguf";

    [SkipOnCI]
    public async Task GenerateEmbeddingAsync_WithValidText_ShouldReturnEmbeddings()
    {
        // Arrange
        _service = new LlamaSharpTextTextEmbeddingGenerationService();
        var inputText = "Test text for embedding";

        // Act
        var embeddings = await _service.GenerateEmbeddingAsync(inputText);

        // Assert
        Assert.NotNull(embeddings);
        Assert.NotEmpty(embeddings);
        Assert.NotEmpty(embeddings[0]);
        Assert.Equal(768, embeddings[0].Length);
    }

    [SkipOnCI]
    public async Task LoadModelAsync_WithValidPath_ShouldLoadSuccessfully()
    {
        // Arrange
        _service = new LlamaSharpTextTextEmbeddingGenerationService();
        var modelPath = TestModelName;

        // Act & Assert
        await _service.LoadModelAsync(modelPath);
        // If no exception is thrown, the test passes
    }

    [SkipOnCI]
    public async Task GenerateEmbeddingAsync_WithoutExplicitModelLoad_ShouldLoadDefaultModelAndGenerateEmbeddings()
    {
        // Arrange
        _service = new LlamaSharpTextTextEmbeddingGenerationService();
        var inputText = "Test text for embedding";

        // Act
        var embeddings = await _service.GenerateEmbeddingAsync(inputText);

        // Assert
        Assert.NotNull(embeddings);
        Assert.NotEmpty(embeddings);
        Assert.NotEmpty(embeddings[0]);
        Assert.Equal(768, embeddings[0].Length);
    }

    [SkipOnCI]
    public async Task GenerateEmbeddingAsync_WithNormalGenerativeModel_ShouldLoadAndGenerateEmbeddings()
    {
        // Arrange
        _service = new LlamaSharpTextTextEmbeddingGenerationService();
        var inputText = "Test text for embedding";
        var testModel = "gemma-3-4b-it-Q6_K.gguf";
        await _service.LoadModelAsync(testModel, false);

        // Act
        var embeddings = await _service.GenerateEmbeddingAsync(inputText);

        // Assert
        Assert.NotNull(embeddings);
        Assert.NotEmpty(embeddings);
        Assert.NotEmpty(embeddings[0]);
        Assert.Equal(2560, embeddings[0].Length);
    }

    [SkipOnCI]
    public async Task GenerateEmbedding_SimilarityTest()
    {
        // Arrange
        _service = new LlamaSharpTextTextEmbeddingGenerationService();
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
        _testOutputHelper.WriteLine(
            $"Similarity between 2 and 3 (should be around the same as similarity between 1 and 3): {similarity2_3}");
        _testOutputHelper.WriteLine(
            $"Similarity between 2 and 4 (should be around the same as similarity between 1 and 4): {similarity2_4}");

        // Assert
        Assert.True(similarity1_2 > similarity1_3, 
            "Sentences about cats should be more similar than sentences about dogs");
        Assert.True(similarity1_3 > similarity1_4, 
            "Sentences about animals should be more similar than sentences about quantum mechanics");
        Assert.True(similarity2_3 > similarity1_3, 
            "Sentences about animals sleeping should more similar than sentences about dogs");
        Assert.True(similarity2_3 > similarity2_4, 
            "Sentences about animals should be more similar than sentences about quantum mechanics");
    }

    [SkipOnCI]
    public async Task GenerateEmbedding_SimilarityPromptSearchTest()
    {
        // Arrange
        _service = new LlamaSharpTextTextEmbeddingGenerationService();
        var testModel = "e5-base-v2.Q6_K.gguf";
        await _service.LoadModelAsync(testModel, false);
        var prependSearch = "query: ";
        var prependPrompt = "passage: ";
        var usePrepends = true;

        _testOutputHelper.WriteLine($"Using model {_service.ModelName()} with embedding size {_service.EmbeddingSize()}");

        var search = "splash";

        // Store prompts in a list for easier management
        var prompts = new List<string>
        {
            "rain, umbrella, girl, looking up, wet hair, city street, puddles, melancholic, atmospheric, soft lighting, bokeh, long hair, gentle expression, side view, full body, dynamic angle, blue tones, cozy, peaceful, shallow depth of field, realistic, cinematic, blurry background, raindrops, wind, motion blur, longing, vulnerable, youth, candid, street photography, overcast, detailed background, reflections, fashion, simple clothing, everyday life, artistic, emotional, vulnerable, natural light, wet pavement, city lights, urban scene, youth, lonely, thoughtful, side glance, wet clothes, pensive, cinematic lighting, diffused lighting, atmospheric, blurred motion, street fashion, realistic textures, detailed shadows, soft focus, realistic skin texture, natural pose, simple background, urban environment, quiet moment, emotional depth, muted colors, wet surfaces, street style, artistic photography, city life, lonely, pensive, side glance, realistic details, moody, rainy day, cozy atmosphere, blurred background, dynamic composition, artistic expression, atmospheric perspective, cinematic shot",
            "umbrella, girl, looking_up, wet_hair, smiling, city, street, puddles, bokeh, soft_lighting, long_hair, shallow_depth_of_field, dynamic_pose, colorful_raincoat, joyful, whimsical, atmospheric, street_photography, candid, full_body, side_view, motion_blur, rainy_day, cozy, vibrant, cute, happy, youth, indoors, studio_shot, portrait, 1girl, solo, detailed_background, hd, high_resolution, masterpiece, best_quality, illustration, digital_art, trending_on_artstation",
            "angel, female, electricity, glowing, wings, halo, divine, ethereal, long hair, detailed eyes, full body, dynamic pose, energy, sparks, light, fantasy, otherworldly, celestial, beautiful, serene, soft lighting, intricate details, flowing hair, pale skin, blue eyes, white wings, gold halo, dramatic lighting, power, magic, highly detailed, digital art, concept art, illustration, 8k, uhd, masterpiece, intricate, complex, vibrant colors",
            "woman, riding, broomstick, night, stars, full_moon, silhouette, flying, dynamic_pose, long_hair, wind, fantasy, witch, dark_fantasy, side_view, outdoors, magical, ethereal, detailed_background, realistic, dark_hair, pale_skin, perfect_anatomy, detailed_shadows, highres, artistic, illustration, digital_art, 8k, uhd, masterpiece, looking_at_viewer, serene, expressionless, long_legs, arched_back, fantasy_setting, moonlit, dramatic_lighting, detailed_clothing, witch_hat, windblown_hair, fantasy_art, digital_painting, unreal_engine, cinematic, intricate_details, full_body, looking_down",
            "nature",
            "fantasy art, absurdres, detailed, ancient aztec robot"
        };

        // Apply prepends if needed
        var searchText = usePrepends ? prependSearch + search : search;
        var promptTexts = usePrepends
            ? prompts.Select(p => prependPrompt + p).ToList()
            : prompts;

        // Act
        var searchEmbedding = await _service.GenerateEmbeddingAsync(searchText);

        // Generate all prompt embeddings
        var promptEmbeddings = new List<float[]>();
        foreach (var promptText in promptTexts)
        {
            var embedding = await _service.GenerateEmbeddingAsync(promptText);
            promptEmbeddings.Add(embedding[0]);
        }
        
        _testOutputHelper.WriteLine($"Number of prompts: {promptEmbeddings.Count}");

        // Calculate and store similarities
        var similarities = new List<(string Prompt, double Similarity)>();
        for (int i = 0; i < promptEmbeddings.Count; i++)
        {
            double similarity = CosineSimilarity(searchEmbedding[0], promptEmbeddings[i]);
            similarities.Add((prompts[i], similarity));
        }

        // Sort by similarity (highest first)
        similarities = similarities.OrderByDescending(s => s.Similarity).ToList();

        // Output similarities with prompt previews
        _testOutputHelper.WriteLine($"\nSearching for: {search}");
        _testOutputHelper.WriteLine($"Similarities:");

        for (int i = 0; i < similarities.Count; i++)
        {
            // Get the first 60 characters of the prompt (or the entire prompt if it's shorter)
            string promptPreview = similarities[i].Prompt.Length <= 60
                ? similarities[i].Prompt
                : similarities[i].Prompt.Substring(0, 60) + "...";

            _testOutputHelper.WriteLine($"prompt {i + 1} ({promptPreview}): {similarities[i].Similarity}");
        }
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