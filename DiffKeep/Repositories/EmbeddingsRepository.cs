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

    public async Task StoreEmbeddingAsync(long imageId, EmbeddingSource source, string embeddingModel, float[] embedding)
    {
        await StoreBatchEmbeddingsAsync([
            (imageId, source, embeddingModel, embedding)
        ]);
    }

    public async Task StoreBatchEmbeddingsAsync(
        IEnumerable<(long ImageId, EmbeddingSource Source, string Model, float[] Embedding)> embeddings)
    {
        await using var connection = CreateConnection();
        await using var transaction = connection.BeginTransaction();
        try
        {
            await using var command = connection.CreateCommand();
            var embeddingSize = embeddings.First().Embedding.Length;
            command.Transaction = transaction;
            command.CommandText = @"
            INSERT INTO Embeddings (ImageId, Source, Size, Model, Embedding) 
            VALUES (@ImageId, @Source, @Size, @Model, @Embedding)";

            var imageIdParam = command.CreateParameter();
            imageIdParam.ParameterName = "@ImageId";
            command.Parameters.Add(imageIdParam);

            var sourceParam = command.CreateParameter();
            sourceParam.ParameterName = "@Source";
            command.Parameters.Add(sourceParam);

            var modelParam = command.CreateParameter();
            modelParam.ParameterName = "@Model";
            command.Parameters.Add(modelParam);

            var sizeParam = command.CreateParameter();
            sizeParam.ParameterName = "@Size";
            command.Parameters.Add(sizeParam);

            var embeddingParam = command.CreateParameter();
            embeddingParam.ParameterName = "@Embedding";
            command.Parameters.Add(embeddingParam);

            foreach (var (imageId, source, model, embedding) in embeddings)
            {
                if (embedding.Length != embeddingSize)
                    throw new ArgumentException($"Vectors must have equal dimensions");

                imageIdParam.Value = imageId;
                sourceParam.Value = source.ToString();
                modelParam.Value = model;
                sizeParam.Value = embeddingSize;
                embeddingParam.Value = $"[{string.Join(",", embedding)}]";

                await command.ExecuteNonQueryAsync();
            }

            await transaction.CommitAsync();
        }
        catch
        {
            await transaction.RollbackAsync();
            throw;
        }
    }

    public async Task<IEnumerable<(long ImageId, string Path, float Score)>> SearchSimilarByVectorAsync(
        float[] embedding, int limit = 100, long? libraryId = null, string? path = null)
    {
        var resultDict = new Dictionary<long, (long ImageId, string Path, float Score)>();
        await using var connection = CreateConnection();
        await using var command = connection.CreateCommand();

        command.CommandText = @"
        SELECT 
            e.ImageId,
            i.Path,
            vec_distance_L2(e.Embedding, @Embedding) as distance
        FROM Embeddings e
        INNER JOIN Images i ON e.ImageId = i.Id
        WHERE 1 = 1";
        
        if (libraryId.HasValue)
        {
            command.CommandText += " AND i.LibraryId = @LibraryId";
            command.Parameters.AddWithValue("@LibraryId", libraryId.Value);
        }

        if (!string.IsNullOrEmpty(path))
        {
            command.CommandText += " AND i.Path LIKE @DirectoryPath || '%'";
            command.Parameters.AddWithValue("@DirectoryPath", path);
        }
        
        command.CommandText += @" ORDER BY distance ASC
        LIMIT @Limit";

        command.Parameters.AddWithValue("@Embedding", VectorToBlob(embedding));
        command.Parameters.AddWithValue("@Limit", limit);

        await using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            var imageId = reader.GetInt64(0);
            var imgPath = reader.GetString(1);
            var score = reader.GetFloat(2);

            if (resultDict.TryGetValue(imageId, out var existing))
            {
                if (score < existing.Score) // Lower distance means better match
                {
                    resultDict[imageId] = (imageId, imgPath, score);
                }
            }
            else
            {
                resultDict[imageId] = (imageId, imgPath, score);
            }
        }

        var results = resultDict.Values.ToList();
        Debug.WriteLine($"Search returned {results.Count} results with a limit of {limit}");

        return results;
    }

    public async Task DeleteEmbeddingsForImageAsync(long imageId)
    {
        await using var connection = CreateConnection();
        await using var command = connection.CreateCommand();
        command.CommandText = "DELETE FROM Embeddings WHERE ImageId = @ImageId";
        command.CreateParameter("@ImageId", imageId);
        await command.ExecuteNonQueryAsync();
    }
    
    public async Task DeleteEmbeddingsForLibraryAsync(long libraryId)
    {
        await using var connection = CreateConnection();
        await using var command = connection.CreateCommand();
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