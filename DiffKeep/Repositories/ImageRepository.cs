using System;
using System.Collections.Generic;
using System.Threading.Tasks;
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

    private static Image ReadImage(SqliteDataReader reader)
    {
        return new Image
        {
            Id = reader.GetValue<long>("Id"),
            LibraryId = reader.GetValue<long>("LibraryId"),
            Path = reader.GetValue<string>("Path"),
            Hash = reader.GetValue<string>("Hash"),
            PositivePrompt = reader.GetValue<string>("PositivePrompt"),
            NegativePrompt = reader.GetValue<string>("NegativePrompt"),
            Description = reader.GetValue<string>("Description"),
            Created = reader.GetValue<DateTime>("Created")
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
            INSERT INTO Images (LibraryId, Path, Hash, PositivePrompt, NegativePrompt, Description, Created)
            VALUES (@LibraryId, @Path, @Hash, @PositivePrompt, @NegativePrompt, @Description, @Created)
            RETURNING Id";

        command.CreateParameter("@LibraryId", image.LibraryId);
        command.CreateParameter("@Path", image.Path);
        command.CreateParameter("@Hash", image.Hash);
        command.CreateParameter("@PositivePrompt", (object?)image.PositivePrompt ?? DBNull.Value);
        command.CreateParameter("@NegativePrompt", (object?)image.NegativePrompt ?? DBNull.Value);
        command.CreateParameter("@Description", (object?)image.Description ?? DBNull.Value);
        command.CreateParameter("@Created", image.Created);

        return await command.ExecuteScalarAsync<long>();
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
                Created = @Created
            WHERE Id = @Id";

        command.CreateParameter("@Id", image.Id);
        command.CreateParameter("@LibraryId", image.LibraryId);
        command.CreateParameter("@Path", image.Path);
        command.CreateParameter("@Hash", image.Hash);
        command.CreateParameter("@PositivePrompt", (object?)image.PositivePrompt ?? DBNull.Value);
        command.CreateParameter("@NegativePrompt", (object?)image.NegativePrompt ?? DBNull.Value);
        command.CreateParameter("@Description", (object?)image.Description ?? DBNull.Value);
        command.CreateParameter("@Created", image.Created);

        await command.ExecuteNonQueryAsync();
    }

    public async Task DeleteAsync(long id)
    {
        using var connection = CreateConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "DELETE FROM Images WHERE Id = @Id";
        command.CreateParameter("@Id", id);

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