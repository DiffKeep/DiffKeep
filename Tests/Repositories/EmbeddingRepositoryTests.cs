using System;
using System.Linq;
using System.Threading.Tasks;
using DiffKeep.Database;
using DiffKeep.Models;
using DiffKeep.Repositories;
using Microsoft.Data.Sqlite;
using Xunit;
using Xunit.Abstractions;

namespace Tests.Repositories;

public class EmbeddingRepositoryTests : IAsyncLifetime
{
    private DatabaseConnectionFactory _connectionFactory;
    private SqliteConnection _keepAliveConnection;
    private readonly string _connectionString;
    private ImageRepository _imageRepository;
    private LibraryRepository _libraryRepository;
    private readonly ITestOutputHelper _testOutputHelper;
    private long _libraryId;

    public EmbeddingRepositoryTests(ITestOutputHelper testOutputHelper)
    {
        _testOutputHelper = testOutputHelper;
        // Create a unique connection string for each test to isolate test data
        var dbName = $"InMemorySqlite-{Guid.NewGuid()}";
        _connectionString = $"Data Source={dbName};Mode=Memory;Cache=Shared";
        
        // Keep-alive connection is needed to keep the in-memory database alive for the duration of the test
        _keepAliveConnection = new SqliteConnection(_connectionString);
        _keepAliveConnection.Open();
    }

    public async Task InitializeAsync()
    {
        // Create the database connection factory
        _connectionFactory = new DatabaseConnectionFactory(_connectionString);
        
        // Initialize the database schema
        await DatabaseVersioning.InitializeAsync(_connectionFactory);
        
        // Create the repositories to test
        _imageRepository = new ImageRepository(_connectionFactory);
        _libraryRepository = new LibraryRepository(_connectionFactory);
        
        // Create a common library for tests
        var library = new Library { Path = "/test/library/path" };
        _libraryId = await _libraryRepository.AddAsync(library);
    }

    public Task DisposeAsync()
    {
        _keepAliveConnection?.Dispose();
        return Task.CompletedTask;
    }
    
    [Fact]
    public async Task AddAndGetImage_ShouldReturnSameImage()
    {
        // Arrange
        // Now create an image using that library ID
        var testImage = new Image
        {
            LibraryId = _libraryId,
            Path = "/test/image.png",
            Hash = "testHash123",
            PositivePrompt = "Test positive prompt",
            NegativePrompt = "Test negative prompt",
            Description = "Test description",
            Created = DateTime.UtcNow
        };
        
        // Act
        await _imageRepository.AddAsync(testImage);
        
        // Find the library by the ID
        var retrievedLibrary = await _libraryRepository.GetByIdAsync(_libraryId);
        // Find the image by path
        var retrievedImage = await _imageRepository.GetByPathAsync(testImage.LibraryId, testImage.Path);
        Assert.NotNull(retrievedImage);
        // GetAll only gets the id and path - have to fetch by ID to get the full image
        retrievedImage = await _imageRepository.GetByIdAsync(retrievedImage.Id);
        
        // Assert
        
        // Library
        Assert.NotNull(retrievedLibrary);
        Assert.Equal(_libraryId, retrievedLibrary.Id);
        
        // Image
        Assert.NotNull(retrievedImage);
        Assert.Equal(_libraryId, retrievedImage.LibraryId);
        Assert.Equal(testImage.Path, retrievedImage.Path);
        Assert.Equal(testImage.Hash, retrievedImage.Hash);
        Assert.Equal(testImage.PositivePrompt, retrievedImage.PositivePrompt);
        Assert.Equal(testImage.NegativePrompt, retrievedImage.NegativePrompt);
        Assert.Equal(testImage.Description, retrievedImage.Description);
        // We're not comparing Created exactly because SQLite may round datetime values
        Assert.True((testImage.Created - retrievedImage.Created).TotalSeconds < 1);
    }
    
    [Fact]
    public async Task SearchByPrompt_ShouldReturnMatchingImages()
    {
        // Arrange - Create multiple images with different prompts
        var images = new[]
        {
            new Image
            {
                LibraryId = _libraryId,
                Path = "/test/cat_image.png",
                Hash = "hash1",
                PositivePrompt = "A cat sitting on a windowsill in the sunlight",
                Created = DateTime.UtcNow.AddDays(-3)
            },
            new Image
            {
                LibraryId = _libraryId,
                Path = "/test/dog_image.png",
                Hash = "hash2",
                PositivePrompt = "A happy dog running in a park",
                Created = DateTime.UtcNow.AddDays(-2)
            },
            new Image
            {
                LibraryId = _libraryId,
                Path = "/test/mountain_image.png",
                Hash = "hash3",
                PositivePrompt = "Mountain landscape with a blue sky and fluffy clouds",
                Created = DateTime.UtcNow.AddDays(-1)
            },
            new Image
            {
                LibraryId = _libraryId,
                Path = "/test/beach_image.png",
                Hash = "hash4",
                PositivePrompt = "Sunset at the beach with palm trees and a dog playing in the sand",
                Created = DateTime.UtcNow
            }
        };
        
        // Add all images
        await _imageRepository.AddBatchAsync(images);
        
        // Verify all images were added successfully
        var allImages = await _imageRepository.GetAllAsync();
        Assert.Equal(4, allImages.Count());
        
        // Act & Assert - Test different search queries
        
        // 1. Search for "dog" - should find two images
        var dogResults = await _imageRepository.SearchByPromptAsync("dog");
        Assert.Equal(2, dogResults.Count());
        Assert.Contains(dogResults, img => img.Path.Contains("dog_image"));
        Assert.Contains(dogResults, img => img.Path.Contains("beach_image"));
        _testOutputHelper.WriteLine($"Scores: {dogResults.ElementAt(0).Score:f15}, {dogResults.ElementAt(1).Score:f15}");
        
        // 2. Search for "cat" - should find one image
        var catResults = await _imageRepository.SearchByPromptAsync("cat");
        Assert.Single(catResults);
        Assert.Contains(catResults, img => img.Path.Contains("cat_image"));
        
        // 3. Search for "mountain" - should find one image
        var mountainResults = await _imageRepository.SearchByPromptAsync("mountain");
        Assert.Single(mountainResults);
        Assert.Contains(mountainResults, img => img.Path.Contains("mountain_image"));
        
        // 4. Search for "sunset beach" - should find one image
        var beachResults = await _imageRepository.SearchByPromptAsync("sunset beach");
        Assert.Single(beachResults);
        Assert.Contains(beachResults, img => img.Path.Contains("beach_image"));
        
        // 5. Search for "zebra" - should find no images
        var zebraResults = await _imageRepository.SearchByPromptAsync("zebra");
        Assert.Empty(zebraResults);
        
        // Check search counts match actual results
        var dogCount = await _imageRepository.GetSearchCountAsync("dog");
        Assert.Equal(2, dogCount);
        
        var catCount = await _imageRepository.GetSearchCountAsync("cat");
        Assert.Equal(1, catCount);
        
        var zebraCount = await _imageRepository.GetSearchCountAsync("zebra");
        Assert.Equal(0, zebraCount);
        
        // Filter by library ID
        var dogInLibraryResults = await _imageRepository.SearchByPromptAsync("dog", _libraryId);
        Assert.Equal(2, dogInLibraryResults.Count());
        
        // The search should respect the ranks (relevance scoring)
        var dogWithSandResults = await _imageRepository.SearchByPromptAsync("dog sand");
        Assert.Equal(1, dogWithSandResults.Count());
        Assert.Contains(dogWithSandResults, img => img.Path.Contains("beach_image"));
        
        // Log the output for debugging
        foreach (var image in allImages)
        {
            _testOutputHelper.WriteLine($"Image: {image.Path}, Prompt: {image.PositivePrompt}");
        }
    }
    
    
}