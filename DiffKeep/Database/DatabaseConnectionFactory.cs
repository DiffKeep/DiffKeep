using System;
using Microsoft.Data.Sqlite;
using System.Data;
using System.Diagnostics;
using System.IO;
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
        // Verify the file exists and has proper permissions
        if (!File.Exists(_extensionPath))
        {
            throw new FileNotFoundException($"SQLite extension not found at: {_extensionPath}");
        }

        // Check file permissions
        try
        {
            var fileInfo = new FileInfo(_extensionPath);
            Debug.WriteLine($"Extension file permissions: {fileInfo.UnixFileMode}");
            
            // Verify the file is readable
            using (var stream = File.OpenRead(_extensionPath))
            {
                Debug.WriteLine("Extension file is readable");
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"Error checking extension file: {ex}");
            throw;
        }

        
        Debug.WriteLine($"vec0 extension found at {_extensionPath}");
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
    
    private bool IsVec0ExtensionLoaded(SqliteConnection connection)
    {
        try
        {
            using var command = connection.CreateCommand();
            command.CommandText = "PRAGMA module_list;";
            using var reader = command.ExecuteReader();
        
            while (reader.Read())
            {
                var moduleName = reader.GetString(0);
                if (moduleName.Equals("vec0", StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }
        
            Debug.WriteLine("vec0 extension is not loaded");
            return false;

        }
        catch (SqliteException e)
        {
            Debug.WriteLine($"vec0 extension is not loaded: {e}");
            return false;
        }
    }


    public IDbConnection CreateConnection()
    {
        try
        {
            var connection = new SqliteConnection(_connectionString);
            connection.Open();
            if (!IsVec0ExtensionLoaded(connection))
            {
                connection.EnableExtensions();

                using (var command = connection.CreateCommand())
                {
                    Debug.WriteLine($"Loading extension from: {_extensionPath}");
                    command.CommandText = $"SELECT load_extension('{_extensionPath}');";
                    command.ExecuteNonQuery();
                    Debug.WriteLine("Extension loaded successfully");
                }
                
                // Apply PRAGMA settings
                using (var command = connection.CreateCommand())
                {
                    command.CommandText = @"
                        PRAGMA journal_mode = WAL;
                        PRAGMA synchronous = NORMAL;
                        PRAGMA cache_size = -64000;
                        PRAGMA page_size = 4096;
                        PRAGMA mmap_size = 1073741824;
                        PRAGMA temp_store = MEMORY;
                        PRAGMA busy_timeout = 5000;
                        PRAGMA foreign_keys = ON;
                        PRAGMA journal_size_limit = 67108864;
                        PRAGMA threads = 4;";
                    command.ExecuteNonQuery();
                }
            }

            return connection;
        } catch (SqliteException ex)
        {
            Debug.WriteLine($"SQLite error loading extension: {ex.Message}");
            Debug.WriteLine($"SQLite error code: {ex.SqliteErrorCode}");
            Debug.WriteLine($"SQLite extended error code: {ex.SqliteExtendedErrorCode}");
                
            throw;
        } catch (Exception ex)
        {
            Debug.WriteLine($"Error initializing database connection: {ex}");
            throw;
        }
    }
}