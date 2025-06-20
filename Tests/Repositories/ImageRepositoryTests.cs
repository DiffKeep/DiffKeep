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

public class ImageRepositoryTests : IAsyncLifetime
{
    private DatabaseConnectionFactory _connectionFactory;
    private SqliteConnection _keepAliveConnection;
    private readonly string _connectionString;
    private ImageRepository _imageRepository;
    private LibraryRepository _libraryRepository;
    private EmbeddingsRepository _embeddingRepository;
    private readonly ITestOutputHelper _testOutputHelper;
    private long _libraryId;

    public ImageRepositoryTests(ITestOutputHelper testOutputHelper)
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
        _embeddingRepository = new EmbeddingsRepository(_connectionFactory);

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
    public async Task FindImagesWithoutEmbeddings_ShouldRestrictByLibraryId()
    {
        // Create a second library
        var secondLibrary = new Library { Path = "/test/second/library/path" };
        var secondLibraryId = await _libraryRepository.AddAsync(secondLibrary);

        // Add several fake images to the first library
        var firstLibraryImages = new[]
        {
            new Image { Path = "/test/library/path/image1.jpg", Hash = "234", LibraryId = _libraryId, PositivePrompt = "test"},
            new Image { Path = "/test/library/path/image2.jpg", Hash = "234", LibraryId = _libraryId, PositivePrompt = "test"},
            new Image { Path = "/test/library/path/image3.jpg", Hash = "234", LibraryId = _libraryId, PositivePrompt = "test"},
            new Image { Path = "/test/library/path/image4.jpg", Hash = "234", LibraryId = _libraryId, PositivePrompt = "test"}
        };

        foreach (var image in firstLibraryImages)
        {
            await _imageRepository.AddAsync(image);
        }

        // Add several fake images to the second library
        var secondLibraryImages = new[]
        {
            new Image { Path = "/test/second/library/path/image1.jpg", Hash = "234", LibraryId = secondLibraryId, PositivePrompt = "test"},
            new Image { Path = "/test/second/library/path/image2.jpg", Hash = "234", LibraryId = secondLibraryId, PositivePrompt = "test"},
            new Image { Path = "/test/second/library/path/image3.jpg", Hash = "234", LibraryId = secondLibraryId, PositivePrompt = "test"}
        };

        foreach (var image in secondLibraryImages)
        {
            await _imageRepository.AddAsync(image);
        }
        
        var library1Images = await _imageRepository.GetByLibraryIdAsync(_libraryId);
        Assert.Equal(4, library1Images.Count());
        var library2Images = await _imageRepository.GetByLibraryIdAsync(secondLibraryId);
        Assert.Equal(3, library2Images.Count());

        // Add embeddings to some images in the first library (2 out of 4)
        await _embeddingRepository.StoreEmbeddingAsync(
            library1Images.ElementAt(0).Id,
            EmbeddingSource.PositivePrompt,
            "test-model",
            [1, 2, 3, 4]
        );

        await _embeddingRepository.StoreEmbeddingAsync(
            library1Images.ElementAt(1).Id,
            EmbeddingSource.PositivePrompt,
            "test-model",
            [5, 6, 7, 8]
        );

        // Add embeddings to some images in the second library (1 out of 3)
        await _embeddingRepository.StoreEmbeddingAsync(
            library2Images.ElementAt(1).Id,
            EmbeddingSource.PositivePrompt,
            "test-model",
            [9, 10, 11, 12]
        );

        var allEmbeds = await _embeddingRepository.GetAllAsync();
        Assert.Equal(3,  allEmbeds.Count());

        // Search for images without embeddings in the first library
        var imagesWithoutEmbeddingsInFirstLibrary = await _imageRepository.GetImagesWithoutEmbeddingsAsync(
            "test-model",
            4,
            _libraryId);

        // There should be 2 images without embeddings in the first library
        Assert.Equal(2, imagesWithoutEmbeddingsInFirstLibrary.Count());
        Assert.Contains(imagesWithoutEmbeddingsInFirstLibrary, img => img.Id == library1Images.ElementAt(2).Id);
        Assert.Contains(imagesWithoutEmbeddingsInFirstLibrary, img => img.Id == library1Images.ElementAt(3).Id);

        // Search for images without embeddings in the second library
        var imagesWithoutEmbeddingsInSecondLibrary = await _imageRepository.GetImagesWithoutEmbeddingsAsync(
            "test-model",
            4,
            secondLibraryId);

        // There should be 2 images without embeddings in the second library
        Assert.Equal(2, imagesWithoutEmbeddingsInSecondLibrary.Count());
        Assert.Contains(imagesWithoutEmbeddingsInSecondLibrary, img => img.Id == library2Images.ElementAt(0).Id);
        Assert.Contains(imagesWithoutEmbeddingsInSecondLibrary, img => img.Id == library2Images.ElementAt(2).Id);

        // Search for images without embeddings in all libraries (null libraryId)
        var allImagesWithoutEmbeddings = await _imageRepository.GetImagesWithoutEmbeddingsAsync(
            "test-model",
            4);

        // There should be 4 images without embeddings in total
        Assert.Equal(4, allImagesWithoutEmbeddings.Count());
    }
}