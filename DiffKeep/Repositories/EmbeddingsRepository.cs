using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Threading.Tasks;
using DiffKeep.Database;
using DiffKeep.Models;
using Microsoft.Data.Sqlite;

namespace DiffKeep.Repositories;

public class EmbeddingsRepository : IEmbeddingsRepository
{
    private readonly DatabaseConnectionFactory _connectionFactory;
    private const int VectorDimension = 1024;

    public EmbeddingsRepository(DatabaseConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    private SqliteConnection CreateConnection()
        => (SqliteConnection)_connectionFactory.CreateConnection();

    private byte[] VectorToBlob(float[] vector)
    {
        if (vector.Length != VectorDimension)
            throw new ArgumentException($"Vector must have exactly {VectorDimension} dimensions");

        return vector.SelectMany(BitConverter.GetBytes).ToArray();
    }

    public async Task StoreEmbeddingAsync(long imageId, EmbeddingType type, float[] embedding)
    {
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();
        command.CommandText = @"
        INSERT INTO Embeddings (ImageId, EmbeddingType, Embedding) 
        VALUES (@ImageId, @EmbeddingType, @Embedding)";

        command.CreateParameter("@ImageId", imageId);
        command.CreateParameter("@EmbeddingType", type.ToString());
        command.CreateParameter("@Embedding", $"[{string.Join(",", embedding)}]");

        await command.ExecuteNonQueryAsync();
    }

    public async Task<IEnumerable<(long ImageId, string Path, float Score)>> SearchSimilarByVectorAsync(
        float[] embedding, int limit = 100)
    {
        var results = new List<(long ImageId, string Path, float Score)>();
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();

        // it's a little funky, but because we are querying inside a query and vec0 queries require a limit but
        // the limit the yser expects is for the outer query, and we want to get good results from all embeddings an image might have,
        // we use a tripled limit clause in the inner vec0 query
        var innerLimit = limit * 3;

        command.CommandText = @"
            SELECT 
                e.ImageId,
                i.Path,
                e.distance
            FROM Embeddings e
            INNER JOIN Images i ON e.ImageId = i.Id
            WHERE e.Embedding MATCH @Embedding
            AND k = @Limit
            ORDER BY e.distance ASC";


        command.CreateParameter("@Embedding", $"[{string.Join(",", embedding)}]");
        command.CreateParameter("@Limit", limit);

        using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            var imageId = reader.GetInt64(0);
            var path = reader.GetString(1);
            var score = reader.GetFloat(2);
            results.Add((imageId, path, score));
        }

        Debug.WriteLine($"Search returned {results.Count} results with a limit of {limit}");

        return results;
    }

    public async Task DeleteEmbeddingsForImageAsync(long imageId)
    {
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "DELETE FROM Embeddings WHERE ImageId = @ImageId";
        command.CreateParameter("@ImageId", imageId);
        await command.ExecuteNonQueryAsync();
    }
    
    public async Task DeleteEmbeddingsForLibraryAsync(long libraryId)
    {
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();
        command.CommandText = @"
        DELETE FROM Embeddings 
        WHERE ImageId IN (
            SELECT Id 
            FROM Images 
            WHERE LibraryId = @LibraryId
        )";
        command.CreateParameter("@LibraryId", libraryId);
        await command.ExecuteNonQueryAsync();
    }
}