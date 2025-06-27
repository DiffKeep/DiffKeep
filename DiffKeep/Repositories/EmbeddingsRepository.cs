using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Threading.Tasks;
using DiffKeep.Database;
using DiffKeep.Models;
using Microsoft.Data.Sqlite;
using Serilog;

namespace DiffKeep.Repositories;

public class EmbeddingsRepository : IEmbeddingsRepository
{
    private readonly DatabaseConnectionFactory _connectionFactory;

    public EmbeddingsRepository(DatabaseConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    private SqliteConnection CreateConnection()
        => (SqliteConnection)_connectionFactory.CreateConnection();

    private byte[] VectorToBlob(float[] vector)
    {
        return vector.SelectMany(BitConverter.GetBytes).ToArray();
    }

    public async Task StoreEmbeddingAsync(long imageId, EmbeddingSource source, string embeddingModel,
        float[] embedding)
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
        float[] embedding, string modelName, int limit = 100, long? libraryId = null, string path = null)
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
        WHERE e.Model = @ModelName
        AND e.Size = @Size";

        command.Parameters.AddWithValue("@ModelName", modelName);
        command.Parameters.AddWithValue("@Size", embedding.Length);

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
        Log.Debug("Search returned {ResultsCount} results with a limit of {Limit}", results.Count, limit);

        return results;
    }

    public async Task<IEnumerable<(long ImageId, string Path, float Score)>> SearchCombinedAsync(
        string textQuery,
        float[] embedding,
        string modelName,
        int embeddingSize,
        float vectorWeight = 0.7f, // Adjustable weight for vector search
        float textWeight = 0.3f, // Adjustable weight for FTS5 search
        int limit = 100,
        long? libraryId = null,
        string path = null)
    {
        // Results container
        var combinedResults = new Dictionary<long, (long ImageId, string Path, float Score)>();

        await using var connection = CreateConnection();
        await using var command = connection.CreateCommand();

        // Combined query that uses both vector similarity and FTS5
        command.CommandText = @"
    WITH vector_results AS (
    SELECT 
        e.ImageId,
        i.Path,
        exp(vec_distance_cosine(e.Embedding, @Embedding)) AS vector_score,
        MIN(exp(vec_distance_cosine(e.Embedding, @Embedding))) 
           OVER () AS min_vector,
        MAX(exp(vec_distance_cosine(e.Embedding, @Embedding))) 
           OVER () AS max_vector
    FROM Embeddings e
    INNER JOIN Images i ON e.ImageId = i.Id
    WHERE e.Model = @ModelName
      AND e.Size = @Size
),
vector_norm AS (
    SELECT 
        ImageId,
        Path,
        -- Normalize to a 0-1 range for vector scores:
        (vector_score - min_vector) / (max_vector - min_vector) AS norm_vector_score
    FROM vector_results
),
text_results AS (
    SELECT
        i.Id as ImageId,
        i.Path,
        fts.rank as text_rank,
        exp(-fts.rank / 10) as text_score,
        MIN(exp(-fts.rank / 10)) OVER () as min_text,
        MAX(exp(-fts.rank / 10)) OVER () as max_text
    FROM Images i
    INNER JOIN ImagePromptIndex fts ON i.Id = fts.rowid
    WHERE fts.PositivePrompt MATCH @TextQuery
),
text_norm AS (
    SELECT 
        ImageId,
        Path,
        (text_score - min_text) / (max_text - min_text) AS norm_text_score
    FROM text_results
)

SELECT
    COALESCE(v.ImageId, t.ImageId) AS ImageId,
    COALESCE(v.Path, t.Path) AS Path,
    (
        COALESCE(@VectorWeight * v.norm_vector_score, 0) +
        COALESCE(@TextWeight   * t.norm_text_score  , 0)
    ) AS combined_score
FROM vector_norm v
FULL OUTER JOIN text_norm t ON v.ImageId = t.ImageId
WHERE v.ImageId IS NOT NULL OR t.ImageId IS NOT NULL";

        // Add filters if needed
        if (libraryId.HasValue)
        {
            command.CommandText += @" 
        AND (
            (v.ImageId IS NOT NULL AND v.ImageId IN (SELECT Id FROM Images WHERE LibraryId = @LibraryId))
            OR 
            (t.ImageId IS NOT NULL AND t.ImageId IN (SELECT Id FROM Images WHERE LibraryId = @LibraryId))
        )";
            command.Parameters.AddWithValue("@LibraryId", libraryId.Value);
        }

        if (!string.IsNullOrEmpty(path))
        {
            command.CommandText += @" 
        AND (
            (v.Path IS NOT NULL AND v.Path LIKE @DirectoryPath || '%')
            OR 
            (t.Path IS NOT NULL AND t.Path LIKE @DirectoryPath || '%')
        )";
            command.Parameters.AddWithValue("@DirectoryPath", path);
        }

        // Order and limit
        command.CommandText += @"
    ORDER BY combined_score DESC
    LIMIT @Limit";

        // Set parameters
        command.Parameters.AddWithValue("@TextQuery", textQuery ?? "");
        command.Parameters.AddWithValue("@Embedding", VectorToBlob(embedding));
        command.Parameters.AddWithValue("@ModelName", modelName);
        command.Parameters.AddWithValue("@Size", embedding.Length);
        command.Parameters.AddWithValue("@VectorWeight", vectorWeight);
        command.Parameters.AddWithValue("@TextWeight", textWeight);
        command.Parameters.AddWithValue("@Limit", limit);

        // Execute query
        await using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            var imageId = reader.GetInt64(0);
            var imgPath = reader.GetString(1);
            var score = reader.GetFloat(2);

            combinedResults[imageId] = (imageId, imgPath, score);
        }

        return combinedResults.Values.OrderByDescending(r => r.Score);
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

    public async Task<IEnumerable<Embedding>> GetAllAsync()
    {
        var results = new List<Embedding>();
        await using var connection = CreateConnection();
        await using var command = connection.CreateCommand();
    
        command.CommandText = @"
    SELECT Id, ImageId, Source, Size, Model, Embedding
    FROM Embeddings";
    
        await using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            var id = reader.GetInt64(0);
            var imageId = reader.GetInt64(1);
            var source = reader.GetString(2);
            var size = reader.GetInt32(3);
            var model = reader.GetString(4);
            var embeddingString = reader.GetString(5);
        
            // Parse the embedding string back to float array
            var embeddingValues = embeddingString.Trim('[', ']').Split(',')
                .Select(float.Parse).ToArray();
        
            results.Add(new Embedding
            {
                Id = id,
                ImageId = imageId,
                Source = Enum.Parse<EmbeddingSource>(source),
                Size = size,
                Model = model,
                Vector = embeddingValues
            });
        }
    
        return results;
    }
}