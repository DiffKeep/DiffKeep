using System;
using Microsoft.Data.Sqlite;
using System.Data;
using System.Diagnostics;
using System.Threading.Tasks;

namespace DiffKeep.Database;

public class DatabaseConnectionFactory
{
    private readonly string _connectionString;
    private readonly string _extensionPath;
    private bool _initialized;

    public DatabaseConnectionFactory(string connectionString)
    {
        _connectionString = connectionString;
        _extensionPath = NativeLibraryLoader.ExtractAndLoadNativeLibrary("vec0");
        Debug.WriteLine($"vec0 extension loading from {_extensionPath}");
        _initialized = false;
    }

    public async Task InitializeAsync()
    {
        if (_initialized)
            return;

        await DatabaseVersioning.InitializeAsync(this);
        Debug.WriteLine("Database initialized");
        _initialized = true;
    }

    public IDbConnection CreateConnection()
    {
        try
        {
            var connection = new SqliteConnection(_connectionString);
            connection.Open();
            if (!_initialized)
            {
                connection.EnableExtensions();

                using (var command = connection.CreateCommand())
                {
                    command.CommandText = $"SELECT load_extension('{_extensionPath}');";
                    command.ExecuteNonQuery();
                }
            }

            return connection;
        } catch (Exception ex)
        {
            Debug.WriteLine($"Error initializing database connection: {ex}");
            throw;
        }
    }
}