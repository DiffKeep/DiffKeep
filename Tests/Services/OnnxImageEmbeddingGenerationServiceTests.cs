using DiffKeep.Services;
using Xunit.Abstractions;
using FluentAssertions;

namespace Tests.Services;

public class OnnxImageEmbeddingGenerationServiceTests
{
    private readonly ITestOutputHelper _testOutputHelper;
    private OnnxImageEmbeddingGenerationService _service;

    public OnnxImageEmbeddingGenerationServiceTests(ITestOutputHelper testOutputHelper)
    {
        _testOutputHelper = testOutputHelper;
    }

    private const string TestModelName = "clip.onnx";

    [Fact]
    public async Task GenerateEmbeddingAsync_WithValidText_ShouldReturnEmbeddings()
    {
        // Arrange
        _service = new OnnxImageEmbeddingGenerationService();
        var inputText = "Test text for embedding";

        // Act
        var embeddings = await _service.GenerateEmbeddingAsync(inputText);

        _testOutputHelper.WriteLine($"Embedding size: {embeddings[0].Length}");
        _testOutputHelper.WriteLine("\nFirst values of embedding:");
        for (int i = 0; i < Math.Min(50, embeddings[0].Length); i++)
        {
            _testOutputHelper.WriteLine($"Index {i}: {embeddings[0][i]}");
        }


        // Assert
        embeddings.Should().NotBeNull();
        embeddings.Should().NotBeEmpty();
        embeddings[0].Should().NotBeEmpty();
        embeddings[0].Length.Should().Be(512);
    }

    [Fact]
    public async Task LoadModelAsync_WithValidPath_ShouldLoadSuccessfully()
    {
        // Arrange
        _service = new OnnxImageEmbeddingGenerationService();
        var modelPath = TestModelName;

        // Act & Assert
        await _service.LoadModelAsync(modelPath);
        // If no exception is thrown, the test passes
    }

    [Fact]
    public async Task GenerateEmbedding_SimilarityTest()
    {
        // Arrange
        _service = new OnnxImageEmbeddingGenerationService();

        var sentence1 = "The cat sits on the mat";
        var sentence2 = "A kitten is resting on the rug";
        var sentence3 = "A dog is sleeping in its kennel";
        var sentence4 = "Quantum mechanics describes the behavior of atoms";

        // Act
        var embeddings1 = await _service.GenerateEmbeddingAsync(sentence1);
        var embeddings2 = await _service.GenerateEmbeddingAsync(sentence2);
        var embeddings3 = await _service.GenerateEmbeddingAsync(sentence3);
        var embeddings4 = await _service.GenerateEmbeddingAsync(sentence4);

        // Check if embeddings are all zeros or identical
        bool allZeros1 = embeddings1[0].All(x => Math.Abs(x) < 1e-6);
        bool allZeros2 = embeddings2[0].All(x => Math.Abs(x) < 1e-6);
        bool identical = true;

        // Compare first few values from each embedding
        _testOutputHelper.WriteLine("\nFirst 10 values of each embedding:");
        for (int i = 0; i < Math.Min(10, embeddings1[0].Length); i++)
        {
            _testOutputHelper.WriteLine(
                $"Index {i}: {embeddings1[0][i]}, {embeddings2[0][i]}, {embeddings3[0][i]}, {embeddings4[0][i]}");
            if (Math.Abs(embeddings1[0][i] - embeddings2[0][i]) > 1e-6)
            {
                identical = false;
            }
        }

        _testOutputHelper.WriteLine($"\nAre embeddings 1 all zeros: {allZeros1}");
        _testOutputHelper.WriteLine($"Are embeddings 2 all zeros: {allZeros2}");
        _testOutputHelper.WriteLine($"Are embeddings identical: {identical}");

        // Calculate L2 norms to check if vectors are normalized
        double norm1 = Math.Sqrt(embeddings1[0].Sum(x => x * x));
        double norm2 = Math.Sqrt(embeddings2[0].Sum(x => x * x));
        _testOutputHelper.WriteLine($"\nL2 norm of embedding 1: {norm1}");
        _testOutputHelper.WriteLine($"L2 norm of embedding 2: {norm2}");


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
        _service = new OnnxImageEmbeddingGenerationService();

        var search = "rain";
        var prompt1 =
            "rain, umbrella, girl, looking up, wet hair, city street, puddles, melancholic, atmospheric, soft lighting, bokeh, long hair, gentle expression, side view, full body, dynamic angle, blue tones, cozy, peaceful, shallow depth of field, realistic, cinematic, blurry background, raindrops, wind, motion blur, longing, vulnerable, youth, candid, street photography, overcast, detailed background, reflections, fashion, simple clothing, everyday life, artistic, emotional, vulnerable, natural light, wet pavement, city lights, urban scene, youth, lonely, thoughtful, side glance, wet clothes, pensive, cinematic lighting, diffused lighting, atmospheric, blurred motion, street fashion, realistic textures, detailed shadows, soft focus, realistic skin texture, natural pose, simple background, urban environment, quiet moment, emotional depth, muted colors, wet surfaces, street style, artistic photography, city life, lonely, pensive, side glance, realistic details, moody, rainy day, cozy atmosphere, blurred background, dynamic composition, artistic expression, atmospheric perspective, cinematic shot";
        var prompt2 =
            "rain, umbrella, girl, looking_up, wet_hair, smiling, city, street, puddles, bokeh, soft_lighting, long_hair, shallow_depth_of_field, dynamic_pose, colorful_raincoat, joyful, whimsical, atmospheric, street_photography, candid, full_body, side_view, motion_blur, rainy_day, cozy, vibrant, cute, happy, youth, indoors, studio_shot, portrait, 1girl, solo, detailed_background, hd, high_resolution, masterpiece, best_quality, illustration, digital_art, trending_on_artstation";
        var prompt3 =
            "angel, female, electricity, glowing, wings, halo, divine, ethereal, long hair, detailed eyes, full body, dynamic pose, energy, sparks, light, fantasy, otherworldly, celestial, beautiful, serene, soft lighting, intricate details, flowing hair, pale skin, blue eyes, white wings, gold halo, dramatic lighting, power, magic, highly detailed, digital art, concept art, illustration, 8k, uhd, masterpiece, intricate, complex, vibrant colors";
        var prompt4 =
            "nude, woman, riding, broomstick, night, stars, full_moon, silhouette, flying, dynamic_pose, long_hair, wind, fantasy, witch, dark_fantasy, cleavage, side_view, outdoors, magical, ethereal, detailed_background, realistic, nipples, spread_legs, provocative, dark_hair, breasts, buttocks, curvy, pale_skin, perfect_anatomy, detailed_shadows, highres, artistic, illustration, digital_art, 8k, uhd, masterpiece, looking_at_viewer, serene, expressionless, long_legs, arched_back, fantasy_setting, moonlit, dramatic_lighting, detailed_clothing, minimalist_clothing, witch_hat, windblown_hair, nipples_visible, suggestive, open_legs, fantasy_art, digital_painting, unreal_engine, cinematic, intricate_details, full_body, looking_down";

        // Act
        var embeddings1 = await _service.GenerateEmbeddingAsync(search);
        var embeddings2 = await _service.GenerateEmbeddingAsync(prompt1);
        var embeddings3 = await _service.GenerateEmbeddingAsync(prompt2);
        var embeddings4 = await _service.GenerateEmbeddingAsync(prompt3);
        var embeddings5 = await _service.GenerateEmbeddingAsync(prompt4);

        _testOutputHelper.WriteLine(
            $"Embeddings count for search: {embeddings1.Count} Size of first element: {embeddings1.First().Length}");
        _testOutputHelper.WriteLine(
            $"Embeddings count for prompt 1: {embeddings2.Count} Size of first element: {embeddings2.First().Length}");

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

    [Fact]
    public void VerifySimilarityFunction()
    {
        // Create embeddings with clear semantic differences
        var catEmbedding = new float[10] { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        var dogEmbedding = new float[10] { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        var quantumEmbedding = new float[10] { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

        // Set cat embedding values
        catEmbedding[0] = 1.0f; // Primary cat dimension
        catEmbedding[1] = 0.8f; // Secondary cat dimension
        catEmbedding[7] = 0.1f; // Small overlap with quantum

        // Set dog embedding values (somewhat similar to cat)
        dogEmbedding[0] = 0.7f; // Some overlap with cat
        dogEmbedding[1] = 0.5f; // Some overlap with cat
        dogEmbedding[2] = 0.9f; // Primary dog dimension
        dogEmbedding[6] = 0.1f; // Small overlap with quantum

        // Set quantum embedding (mostly different but with small overlaps)
        quantumEmbedding[5] = 0.9f; // Primary quantum dimension
        quantumEmbedding[6] = 0.8f; // Secondary quantum dimension
        quantumEmbedding[7] = 0.2f; // Small overlap with cat
        quantumEmbedding[0] = 0.05f; // Tiny overlap with both cat and dog

        // No need to normalize if using CosineSimilarity correctly
        // But let's print the magnitudes to make sure they're not zero
        _testOutputHelper.WriteLine($"Cat magnitude: {Math.Sqrt(catEmbedding.Sum(x => x * x))}");
        _testOutputHelper.WriteLine($"Dog magnitude: {Math.Sqrt(dogEmbedding.Sum(x => x * x))}");
        _testOutputHelper.WriteLine($"Quantum magnitude: {Math.Sqrt(quantumEmbedding.Sum(x => x * x))}");

        // Calculate similarities
        double catDogSim = CosineSimilarity(catEmbedding, dogEmbedding);
        double catQuantumSim = CosineSimilarity(catEmbedding, quantumEmbedding);
        double dogQuantumSim = CosineSimilarity(dogEmbedding, quantumEmbedding);

        // Output
        _testOutputHelper.WriteLine($"Cat-Dog similarity: {catDogSim}");
        _testOutputHelper.WriteLine($"Cat-Quantum similarity: {catQuantumSim}");
        _testOutputHelper.WriteLine($"Dog-Quantum similarity: {dogQuantumSim}");

        // Verify that similarities make sense
        catDogSim.Should().BeGreaterThan(catQuantumSim, "because cat and dog are more related than cat and quantum");
        dogQuantumSim.Should().BeGreaterThan(0, "because there should be some non-zero similarity");
    }


    private void NormalizeEmbedding(float[] embedding)
    {
        float sumSquared = 0;
        foreach (float f in embedding)
        {
            sumSquared += f * f;
        }

        float norm = (float)Math.Sqrt(sumSquared);
        if (norm > 0)
        {
            for (int i = 0; i < embedding.Length; i++)
            {
                embedding[i] /= norm;
            }
        }
    }

    private double CosineSimilarity(float[] vec1, float[] vec2)
    {
        if (vec1.Length != vec2.Length)
            throw new ArgumentException("Vectors must be of the same length");

        double dotProduct = 0;
        double magnitude1 = 0;
        double magnitude2 = 0;

        for (int i = 0; i < vec1.Length; i++)
        {
            dotProduct += vec1[i] * vec2[i];
            magnitude1 += vec1[i] * vec1[i];
            magnitude2 += vec2[i] * vec2[i];
        }

        magnitude1 = Math.Sqrt(magnitude1);
        magnitude2 = Math.Sqrt(magnitude2);

        // Handle zero magnitude vectors
        if (magnitude1 < 1e-10 || magnitude2 < 1e-10)
        {
            _testOutputHelper.WriteLine(
                $"Warning: Near-zero magnitude detected. Mag1: {magnitude1}, Mag2: {magnitude2}");
            return 0;
        }

        return dotProduct / (magnitude1 * magnitude2);
    }
}