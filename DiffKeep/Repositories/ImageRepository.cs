using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using Avalonia.Media.Imaging;
using DiffKeep.Database;
using DiffKeep.Models;
using Microsoft.Data.Sqlite;

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
                : DateTime.MinValue,
            Thumbnail = BytesToBitmap(thumbnailBytes)
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

    public async Task<Image?> GetByPathAsync(long libraryId, string path)
    {
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT * FROM Images WHERE LibraryId = @LibraryId AND Path = @Path";
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

    public async Task<IEnumerable<Image>> GetByLibraryIdAsync(long libraryId)
    {
        var images = new List<Image>();
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT * FROM Images WHERE LibraryId = @LibraryId";
        command.CreateParameter("@LibraryId", libraryId);

        using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            images.Add(ReadImage(reader));
        }

        return images;
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
    
    public async Task DeleteAsync(long id)
    {
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "DELETE FROM Images WHERE Id = @Id";
        command.CreateParameter("@Id", id);

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