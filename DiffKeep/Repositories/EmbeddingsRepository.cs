using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using DiffKeep.Database;
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

    public async Task StorePromptEmbeddingAsync(long imageId, float[] embedding)
    {
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();
        command.CommandText = @"
            INSERT INTO PromptEmbeddings (ImageId, Embedding) 
            VALUES (@ImageId, @Embedding)
            ON CONFLICT(ImageId) DO UPDATE SET Embedding = @Embedding";

        command.CreateParameter("@ImageId", imageId);
        command.CreateParameter("@Embedding", VectorToBlob(embedding));

        await command.ExecuteNonQueryAsync();
    }

    public async Task StoreDescriptionEmbeddingAsync(long imageId, float[] embedding)
    {
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();
        command.CommandText = @"
            INSERT INTO DescriptionEmbeddings (ImageId, Embedding) 
            VALUES (@ImageId, @Embedding)
            ON CONFLICT(ImageId) DO UPDATE SET Embedding = @Embedding";

        command.CreateParameter("@ImageId", imageId);
        command.CreateParameter("@Embedding", VectorToBlob(embedding));

        await command.ExecuteNonQueryAsync();
    }

    public async Task<IEnumerable<(long ImageId, float Score)>> SearchSimilarPromptsByVectorAsync(float[] embedding, int limit = 10)
    {
        var results = new List<(long ImageId, float Score)>();
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();
        command.CommandText = @"
            WITH matches AS (
                SELECT rowid as ImageId, distance as score
                FROM prompt_index
                WHERE vec0_search(
                    vector,
                    vec0_from_blob(@Embedding),
                    @Limit
                )
            )
            SELECT ImageId, score
            FROM matches
            ORDER BY score DESC";

        command.CreateParameter("@Embedding", VectorToBlob(embedding));
        command.CreateParameter("@Limit", limit);

        using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            var imageId = reader.GetValue<long>("ImageId");
            var score = reader.GetValue<float>("score");
            results.Add((imageId, score));
        }

        return results;
    }

    public async Task<IEnumerable<(long ImageId, float Score)>> SearchSimilarDescriptionsByVectorAsync(float[] embedding, int limit = 10)
    {
        var results = new List<(long ImageId, float Score)>();
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();
        command.CommandText = @"
            WITH matches AS (
                SELECT rowid as ImageId, distance as score
                FROM description_index
                WHERE vec0_search(
                    vector,
                    vec0_from_blob(@Embedding),
                    @Limit
                )
            )
            SELECT ImageId, score
            FROM matches
            ORDER BY score DESC";

        command.CreateParameter("@Embedding", VectorToBlob(embedding));
        command.CreateParameter("@Limit", limit);

        using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            var imageId = reader.GetValue<long>("ImageId");
            var score = reader.GetValue<float>("score");
            results.Add((imageId, score));
        }

        return results;
    }

    public async Task DeleteEmbeddingsForImageAsync(long imageId)
    {
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();
        command.CommandText = @"
            DELETE FROM PromptEmbeddings WHERE ImageId = @ImageId;
            DELETE FROM DescriptionEmbeddings WHERE ImageId = @ImageId;";

        command.CreateParameter("@ImageId", imageId);

        await command.ExecuteNonQueryAsync();
    }
}