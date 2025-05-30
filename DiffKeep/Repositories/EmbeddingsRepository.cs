using System;
using System.Collections.Generic;
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

    public async Task<IEnumerable<(long ImageId, string Path, float Score)>> SearchSimilarByVectorAsync(float[] embedding)
    {
        var results = new List<(long ImageId, string Path, float Score)>();
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();
        command.CommandText = @"
        WITH BestMatches AS (
            SELECT 
                e.ImageId,
                MIN(e.distance) as best_score  -- Get the best (lowest) distance score for each image
            FROM Embeddings e
            WHERE e.Embedding MATCH @Embedding
            GROUP BY e.ImageId
        )
        SELECT 
            bm.ImageId,
            i.Path,
            bm.best_score as score
        FROM BestMatches bm
        INNER JOIN Images i ON bm.ImageId = i.Id
        ORDER BY score ASC";

        command.CreateParameter("@Embedding", $"[{string.Join(",", embedding)}]");

        using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            var imageId = reader.GetInt64(0);
            var path = reader.GetString(1);
            var score = reader.GetFloat(2);
            results.Add((imageId, path, score));
        }

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
}