using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using Avalonia.Media.Imaging;
using DiffKeep.Database;
using DiffKeep.Models;
using Microsoft.Data.Sqlite;
using System.Diagnostics;
using System.Linq;

namespace DiffKeep.Repositories;

public class ImageRepository : IImageRepository
{
    private readonly DatabaseConnectionFactory _connectionFactory;

    public ImageRepository(DatabaseConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    private SqliteConnection CreateConnection()
        => (SqliteConnection)_connectionFactory.CreateConnection();

    private static byte[]? BitmapToBytes(Bitmap? bitmap)
    {
        if (bitmap == null) return null;

        using var memStream = new MemoryStream();
        bitmap.Save(memStream);
        return memStream.ToArray();
    }

    private static Bitmap? BytesToBitmap(byte[]? bytes)
    {
        if (bytes == null) return null;

        using var memStream = new MemoryStream(bytes);
        return new Bitmap(memStream);
    }

    private static Image ReadImage(SqliteDataReader reader)
    {
        var thumbnailBytes = reader.IsDBNull(reader.GetOrdinal("Thumbnail"))
            ? null
            : reader.GetValue<byte[]>("Thumbnail");

        return new Image
        {
            Id = reader.GetValue<long>("Id"),
            LibraryId = reader.GetValue<long>("LibraryId"),
            Path = reader.GetValue<string>("Path"),
            Hash = reader.GetValue<string>("Hash"),
            PositivePrompt = reader.GetValue<string>("PositivePrompt"),
            NegativePrompt = reader.GetValue<string>("NegativePrompt"),
            Description = reader.GetValue<string>("Description"),
            Created = reader.GetValue<string>("Created") != null
                ? DateTime.Parse(reader.GetValue<string>("Created"))
                : DateTime.MinValue
        };
    }
    
    public async Task<int> GetCountAsync(long? libraryId = null, string? path = null)
    {
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();
    
        var sql = "SELECT COUNT(*) FROM Images WHERE 1=1";
        if (libraryId.HasValue)
        {
            sql += " AND LibraryId = @LibraryId";
            command.CreateParameter("@LibraryId", libraryId.Value);
        }
        if (!string.IsNullOrEmpty(path))
        {
            sql += " AND Path LIKE @Path || '%'";
            command.CreateParameter("@Path", path);
        }
    
        command.CommandText = sql;
        return await command.ExecuteScalarAsync<int>();
    }

    public async Task<int> GetSearchCountAsync(string searchText, long? libraryId = null, string? directoryPath = null)
    {
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();

        // Base query using FTS5 virtual table for full-text search
        var baseQuery = @"
        SELECT COUNT(*)
        FROM Images i
        INNER JOIN ImagePromptIndex fts ON i.Id = fts.rowid
        WHERE fts.PositivePrompt MATCH @SearchText";

        if (libraryId.HasValue)
        {
            baseQuery += " AND i.LibraryId = @LibraryId";
        }

        if (!string.IsNullOrEmpty(directoryPath))
        {
            baseQuery += " AND i.Path LIKE @DirectoryPath || '%'";
        }

        baseQuery += " ORDER BY rank"; // FTS5 automatically provides the rank column

        command.CommandText = baseQuery;
        command.CreateParameter("@SearchText", searchText);

        if (libraryId.HasValue)
        {
            command.CreateParameter("@LibraryId", libraryId.Value);
        }

        if (!string.IsNullOrEmpty(directoryPath))
        {
            command.CreateParameter("@DirectoryPath", directoryPath);
        }

        return await command.ExecuteScalarAsync<int>();
    }

    public async Task<IEnumerable<Image>> SearchByPromptAsync(string searchText, int offset, int? limit, long? libraryId = null, string? directoryPath = null)
    {
        var images = new List<Image>();
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();

        // Base query using FTS5 virtual table for full-text search
        var baseQuery = @"
        SELECT i.*
        FROM Images i
        INNER JOIN ImagePromptIndex fts ON i.Id = fts.rowid
        WHERE fts.PositivePrompt MATCH @SearchText";

        if (libraryId.HasValue)
        {
            baseQuery += " AND i.LibraryId = @LibraryId";
        }

        if (!string.IsNullOrEmpty(directoryPath))
        {
            baseQuery += " AND i.Path LIKE @DirectoryPath || '%'";
        }

        baseQuery += " ORDER BY rank"; // FTS5 automatically provides the rank column

        command.CommandText = baseQuery;
        command.CreateParameter("@SearchText", searchText);

        if (libraryId.HasValue)
        {
            command.CreateParameter("@LibraryId", libraryId.Value);
        }

        if (!string.IsNullOrEmpty(directoryPath))
        {
            command.CreateParameter("@DirectoryPath", directoryPath);
        }

        using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            images.Add(ReadImage(reader));
        }

        return images;
    }

    private async Task<IEnumerable<Image>> ExecutePagedQueryAsync(string baseQuery, Dictionary<string, object> parameters, 
        int offset, int? limit, ImageSortOption sortOption)
    {
        var images = new List<Image>();
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();

        var limitClause = limit.HasValue ? "LIMIT @Limit" : "";
        command.CommandText = $"{baseQuery} {GetSortClause(sortOption)} {limitClause} OFFSET @Offset";
        
        foreach (var param in parameters)
        {
            command.CreateParameter(param.Key, param.Value);
        }
        if (limit.HasValue)
        {
            command.CreateParameter("@Limit", limit.Value);
        }
        command.CreateParameter("@Offset", offset);

        using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            images.Add(ReadImage(reader));
        }

        return images;
    }

    public async Task<IEnumerable<Image>> GetPagedAllAsync(int offset, int? limit, ImageSortOption sortOption = ImageSortOption.NewestFirst)
    {
        return await ExecutePagedQueryAsync(
            "SELECT * FROM Images",
            new Dictionary<string, object>(),
            offset, limit, sortOption);
    }

    public async Task<IEnumerable<Image>> GetPagedByLibraryIdAsync(long libraryId, int offset, int? limit, 
        ImageSortOption sortOption = ImageSortOption.NewestFirst)
    {
        return await ExecutePagedQueryAsync(
            "SELECT * FROM Images WHERE LibraryId = @LibraryId",
            new Dictionary<string, object> { ["@LibraryId"] = libraryId },
            offset, limit, sortOption);
    }

    public async Task<IEnumerable<Image>> GetPagedByLibraryIdAndPathAsync(long libraryId, string path, int offset, int? limit,
        ImageSortOption sortOption = ImageSortOption.NewestFirst)
    {
        return await ExecutePagedQueryAsync(
            "SELECT * FROM Images WHERE LibraryId = @LibraryId AND Path LIKE @Path || '%'",
            new Dictionary<string, object> 
            { 
                ["@LibraryId"] = libraryId,
                ["@Path"] = path
            },
            offset, limit, sortOption);
    }

    // Update existing methods to use the paged versions without limit
    public async Task<IEnumerable<Image>> GetAllAsync(ImageSortOption sortOption = ImageSortOption.NewestFirst)
    {
        return await GetPagedAllAsync(0, null, sortOption);
    }

    public async Task<IEnumerable<Image>> GetByLibraryIdAsync(long libraryId, 
        ImageSortOption sortOption = ImageSortOption.NewestFirst)
    {
        return await GetPagedByLibraryIdAsync(libraryId, 0, null, sortOption);
    }

    public async Task<IEnumerable<Image>> GetByLibraryIdAndPathAsync(long libraryId, string path,
        ImageSortOption sortOption = ImageSortOption.NewestFirst)
    {
        return await GetPagedByLibraryIdAndPathAsync(libraryId, path, 0, null, sortOption);
    }

    private string GetSortClause(ImageSortOption sortOption)
    {
        return sortOption switch
        {
            ImageSortOption.NewestFirst => "ORDER BY Created DESC",
            ImageSortOption.OldestFirst => "ORDER BY Created ASC",
            ImageSortOption.NameAscending => "ORDER BY Path ASC",
            ImageSortOption.NameDescending => "ORDER BY Path DESC",
            _ => "ORDER BY Created DESC"
        };
    }

    public async Task<Image?> GetByIdAsync(long id)
    {
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT * FROM Images WHERE Id = @Id";
        command.CreateParameter("@Id", id);

        using var reader = await command.ExecuteReaderAsync();
        return await reader.ReadAsync() ? ReadImage(reader) : null;
    }

    public async Task<Image?> GetByPathAsync(long libraryId, string path,
        ImageSortOption sortOption = ImageSortOption.NewestFirst)
    {
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();

        var orderBy = sortOption switch
        {
            ImageSortOption.NewestFirst => "ORDER BY Created DESC",
            ImageSortOption.OldestFirst => "ORDER BY Created ASC",
            ImageSortOption.NameAscending => "ORDER BY Path ASC",
            ImageSortOption.NameDescending => "ORDER BY Path DESC",
            _ => "ORDER BY Created DESC"
        };

        command.CommandText = $"SELECT * FROM Images WHERE LibraryId = @LibraryId AND Path = @Path {orderBy}";
        command.CreateParameter("@LibraryId", libraryId);
        command.CreateParameter("@Path", path);

        using var reader = await command.ExecuteReaderAsync();
        return await reader.ReadAsync() ? ReadImage(reader) : null;
    }

    public async Task<Image?> GetByHashAsync(string hash)
    {
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT * FROM Images WHERE Hash = @Hash";
        command.CreateParameter("@Hash", hash);

        using var reader = await command.ExecuteReaderAsync();
        return await reader.ReadAsync() ? ReadImage(reader) : null;
    }


    public async Task<Dictionary<long, Bitmap?>> GetThumbnailsByIdsAsync(IEnumerable<long> ids)
    {
        var thumbnails = new Dictionary<long, Bitmap?>();
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();

        // Create a parameter string with the correct number of parameters
        var parameters = string.Join(",", ids.Select((_, index) => $"@Id{index}"));
        command.CommandText = $"SELECT Id, Thumbnail FROM Images WHERE Id IN ({parameters})";

        // Add parameters
        var index = 0;
        foreach (var id in ids)
        {
            command.CreateParameter($"@Id{index}", id);
            index++;
        }

        using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            var id = reader.GetValue<long>("Id");
            var thumbnailBytes = reader.IsDBNull(reader.GetOrdinal("Thumbnail"))
                ? null
                : reader.GetValue<byte[]>("Thumbnail");

            thumbnails[id] = BytesToBitmap(thumbnailBytes);
        }

        return thumbnails;
    }

    public async Task<long> AddAsync(Image image)
    {
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();
        command.CommandText = @"
            INSERT INTO Images (LibraryId, Path, Hash, PositivePrompt, NegativePrompt, Description, Created, Thumbnail)
            VALUES (@LibraryId, @Path, @Hash, @PositivePrompt, @NegativePrompt, @Description, @Created, @Thumbnail)
            RETURNING Id";

        command.CreateParameter("@LibraryId", image.LibraryId);
        command.CreateParameter("@Path", image.Path);
        command.CreateParameter("@Hash", image.Hash);
        command.CreateParameter("@PositivePrompt", (object?)image.PositivePrompt ?? DBNull.Value);
        command.CreateParameter("@NegativePrompt", (object?)image.NegativePrompt ?? DBNull.Value);
        command.CreateParameter("@Description", (object?)image.Description ?? DBNull.Value);
        command.CreateParameter("@Created", image.Created);
        command.CreateParameter("@Thumbnail", (object?)BitmapToBytes(image.Thumbnail) ?? DBNull.Value);

        return await command.ExecuteScalarAsync<long>();
    }

    public async Task AddBatchAsync(IEnumerable<Image> images)
    {
        using var connection = CreateConnection();
        using var transaction = connection.BeginTransaction();
        try
        {
            using var command = connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText = @"
            INSERT INTO Images (LibraryId, Path, Hash, PositivePrompt, NegativePrompt, Description, Created, Thumbnail)
            VALUES (@LibraryId, @Path, @Hash, @PositivePrompt, @NegativePrompt, @Description, @Created, @Thumbnail)";

            var libIdParam = command.CreateParameter();
            libIdParam.ParameterName = "@LibraryId";

            var pathParam = command.CreateParameter();
            pathParam.ParameterName = "@Path";

            var hashParam = command.CreateParameter();
            hashParam.ParameterName = "@Hash";

            var posPromptParam = command.CreateParameter();
            posPromptParam.ParameterName = "@PositivePrompt";

            var negPromptParam = command.CreateParameter();
            negPromptParam.ParameterName = "@NegativePrompt";

            var descParam = command.CreateParameter();
            descParam.ParameterName = "@Description";

            var createdParam = command.CreateParameter();
            createdParam.ParameterName = "@Created";

            var thumbParam = command.CreateParameter();
            thumbParam.ParameterName = "@Thumbnail";

            command.Parameters.Add(libIdParam);
            command.Parameters.Add(pathParam);
            command.Parameters.Add(hashParam);
            command.Parameters.Add(posPromptParam);
            command.Parameters.Add(negPromptParam);
            command.Parameters.Add(descParam);
            command.Parameters.Add(createdParam);
            command.Parameters.Add(thumbParam);

            foreach (var image in images)
            {
                libIdParam.Value = image.LibraryId;
                pathParam.Value = image.Path;
                hashParam.Value = image.Hash;
                posPromptParam.Value = (object?)image.PositivePrompt ?? DBNull.Value;
                negPromptParam.Value = (object?)image.NegativePrompt ?? DBNull.Value;
                descParam.Value = (object?)image.Description ?? DBNull.Value;
                createdParam.Value = image.Created;
                thumbParam.Value = (object?)BitmapToBytes(image.Thumbnail) ?? DBNull.Value;

                await command.ExecuteNonQueryAsync();
            }

            transaction.Commit();
        }
        catch (Exception ex)
        {
            Debug.Print($"Error in batch insert: {ex}");
            transaction.Rollback();
            throw;
        }
    }

    public async Task DeleteAsync(long id)
    {
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "DELETE FROM Images WHERE Id = @Id";
        command.CreateParameter("@Id", id);

        await command.ExecuteNonQueryAsync();
    }

    public async Task DeleteByLibraryIdAsync(long libraryId)
    {
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "DELETE FROM Images WHERE LibraryId = @LibraryId";
        command.CreateParameter("@LibraryId", libraryId);
        await command.ExecuteNonQueryAsync();
    }

    public async Task UpdateAsync(Image image)
    {
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();
        command.CommandText = @"
            UPDATE Images 
            SET LibraryId = @LibraryId,
                Path = @Path,
                Hash = @Hash,
                PositivePrompt = @PositivePrompt,
                NegativePrompt = @NegativePrompt,
                Description = @Description,
                Created = @Created,
                Thumbnail = @Thumbnail,
            WHERE Id = @Id";

        command.CreateParameter("@Id", image.Id);
        command.CreateParameter("@LibraryId", image.LibraryId);
        command.CreateParameter("@Path", image.Path);
        command.CreateParameter("@Hash", image.Hash);
        command.CreateParameter("@PositivePrompt", (object?)image.PositivePrompt ?? DBNull.Value);
        command.CreateParameter("@NegativePrompt", (object?)image.NegativePrompt ?? DBNull.Value);
        command.CreateParameter("@Description", (object?)image.Description ?? DBNull.Value);
        command.CreateParameter("@Created", image.Created);
        command.CreateParameter("@Thumbnail", (object?)BitmapToBytes(image.Thumbnail) ?? DBNull.Value);

        await command.ExecuteNonQueryAsync();
    }

    // Add method to update just the thumbnail
    public async Task UpdateThumbnailAsync(long imageId, Bitmap? thumbnail)
    {
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();
        command.CommandText = @"
            UPDATE Images 
            SET Thumbnail = @Thumbnail
            WHERE Id = @Id";

        command.CreateParameter("@Id", imageId);
        command.CreateParameter("@Thumbnail", (object?)BitmapToBytes(thumbnail) ?? DBNull.Value);

        await command.ExecuteNonQueryAsync();
    }

    public async Task<bool> ExistsAsync(long libraryId, string path)
    {
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT EXISTS(SELECT 1 FROM Images WHERE LibraryId = @LibraryId AND Path = @Path)";
        command.CreateParameter("@LibraryId", libraryId);
        command.CreateParameter("@Path", path);

        return await command.ExecuteScalarAsync<bool>();
    }
}