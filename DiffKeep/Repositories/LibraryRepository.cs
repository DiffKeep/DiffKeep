using System.Collections.Generic;
using System.Threading.Tasks;
using DiffKeep.Database;
using DiffKeep.Models;
using Microsoft.Data.Sqlite;

namespace DiffKeep.Repositories;

public class LibraryRepository : ILibraryRepository
{
    private readonly DatabaseConnectionFactory _connectionFactory;

    public LibraryRepository(DatabaseConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    private SqliteConnection CreateConnection()
    {
        return (SqliteConnection)_connectionFactory.CreateConnection();
    }

    public async Task<Library?> GetByIdAsync(long id)
    {
        await using var connection = CreateConnection();
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT * FROM Libraries WHERE Id = @Id";
        command.CreateParameter("@Id", id);

        await using var reader = await command.ExecuteReaderAsync();
        if (!await reader.ReadAsync())
            return null;

        return new Library
        {
            Id = reader.GetValue<long>("Id"),
            Path = reader.GetValue<string>("Path")
        };
    }

    public async Task<Library?> GetByPathAsync(string path)
    {
        await using var connection = CreateConnection();
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT * FROM Libraries WHERE Path = @Path";
        command.CreateParameter("@Path", path);

        await using var reader = await command.ExecuteReaderAsync();
        if (!await reader.ReadAsync())
            return null;

        return new Library
        {
            Id = reader.GetValue<long>("Id"),
            Path = reader.GetValue<string>("Path")
        };
    }

    public async Task<IEnumerable<Library>> GetAllAsync()
    {
        var libraries = new List<Library>();
        await using var connection = CreateConnection();
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT * FROM Libraries";

        await using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            libraries.Add(new Library
            {
                Id = reader.GetValue<long>("Id"),
                Path = reader.GetValue<string>("Path")
            });
        }

        return libraries;
    }

    public async Task<long> AddAsync(Library library)
    {
        await using var connection = CreateConnection();
        await using var command = connection.CreateCommand();
        command.CommandText = "INSERT INTO Libraries (Path) VALUES (@Path) RETURNING Id";
        command.CreateParameter("@Path", library.Path);

        return await command.ExecuteScalarAsync<long>();
    }

    public async Task UpdateAsync(Library library)
    {
        await using var connection = CreateConnection();
        await using var command = connection.CreateCommand();
        command.CommandText = "UPDATE Libraries SET Path = @Path WHERE Id = @Id";
        command.CreateParameter("@Path", library.Path);
        command.CreateParameter("@Id", library.Id);

        await command.ExecuteNonQueryAsync();
    }

    public async Task DeleteAsync(long id)
    {
        await using var connection = CreateConnection();
        await using var command = connection.CreateCommand();
        command.CommandText = "DELETE FROM Libraries WHERE Id = @Id";
        command.CreateParameter("@Id", id);

        await command.ExecuteNonQueryAsync();
    }

    public async Task<bool> ExistsAsync(string path)
    {
        await using var connection = CreateConnection();
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT EXISTS(SELECT 1 FROM Libraries WHERE Path = @Path)";
        command.CreateParameter("@Path", path);

        return await command.ExecuteScalarAsync<bool>();
    }
}