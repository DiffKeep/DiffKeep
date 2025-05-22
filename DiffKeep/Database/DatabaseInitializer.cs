using System;
using Microsoft.Data.Sqlite;
using System.IO;

namespace DiffKeep.Database;

public static class DatabaseInitializer
{
    public static void Initialize(string dbPath)
    {
        var fullPath = Path.GetFullPath(dbPath);
        var connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = fullPath,
            Mode = SqliteOpenMode.ReadWriteCreate
        }.ToString();

        using var connection = new SqliteConnection(connectionString);
        connection.Open();
        connection.EnableExtensions();

        // Extract and load the native library
        var extensionPath = NativeLibraryLoader.ExtractAndLoadNativeLibrary("vec0");

        // Enable vector extension with extracted path
        using var command = connection.CreateCommand();
        command.CommandText = $"SELECT load_extension('{extensionPath}');";
        
        try
        {
            command.ExecuteNonQuery();
        }
        catch (SqliteException e)
        {
            Console.WriteLine($"Warning: Vector extension not available. Please ensure SQLite vector extension is properly installed. {e.Message}");
        }
    }
}