using System;
using System.Data;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading.Tasks;
using Microsoft.Data.Sqlite;

namespace DiffKeep.Database;

public static class DatabaseVersioning
{
    private const string CreateVersionTableSql = @"
        CREATE TABLE IF NOT EXISTS SchemaVersions (
            Version INTEGER PRIMARY KEY,
            Applied DATETIME NOT NULL
        );";

    private const string GetCurrentVersionSql = @"
        SELECT COALESCE(MAX(Version), 0) 
        FROM SchemaVersions;";

    public static async Task InitializeAsync(DatabaseConnectionFactory connectionFactory)
    {
        using var connection = connectionFactory.CreateConnection();
        await CreateVersionTableAsync(connection);
        
        var currentVersion = await GetCurrentVersionAsync(connection);
        await ApplyMigrations(connection, currentVersion);
    }

    private static async Task CreateVersionTableAsync(IDbConnection connection)
    {
        using var command = connection.CreateCommand();
        command.CommandText = CreateVersionTableSql;
        await ((SqliteCommand)command).ExecuteNonQueryAsync();
    }

    private static async Task<int> GetCurrentVersionAsync(IDbConnection connection)
    {
        using var command = connection.CreateCommand();
        command.CommandText = GetCurrentVersionSql;
        var result = await ((SqliteCommand)command).ExecuteScalarAsync();
        return Convert.ToInt32(result);
    }

    private static async Task ApplyMigrations(IDbConnection connection, int currentVersion)
    {
        var assembly = Assembly.GetExecutingAssembly();
        var resourceNames = assembly.GetManifestResourceNames()
            .Where(x => x.EndsWith(".sql") && x.Contains(".Scripts."))
            .OrderBy(x => x);

        foreach (var resourceName in resourceNames)
        {
            Debug.WriteLine($"Checking migration: {resourceName}");
            // Extract version number from filename
            var fileName = resourceName.Split('.').Reverse().Skip(1).First();
            var version = int.Parse(fileName.Split('_')[0]);
            
            if (version <= currentVersion)
                continue;
            
            Debug.WriteLine($"Applying migration: {version}");

            using var stream = assembly.GetManifestResourceStream(resourceName);
            using var reader = new StreamReader(stream!);
            var sql = await reader.ReadToEndAsync();

            var transaction = ((SqliteConnection)connection).BeginTransaction();
            try
            {
                // Execute the migration script
                using (var command = connection.CreateCommand())
                {
                    command.Transaction = transaction;
                    command.CommandText = sql;
                    await ((SqliteCommand)command).ExecuteNonQueryAsync();
                }
                
                // Record the applied migration
                using (var command = connection.CreateCommand())
                {
                    command.Transaction = transaction;
                    command.CommandText = @"
                        INSERT INTO SchemaVersions (Version, Applied) 
                        VALUES (@Version, @Applied)";
                    
                    var versionParam = command.CreateParameter();
                    versionParam.ParameterName = "@Version";
                    versionParam.Value = version;
                    command.Parameters.Add(versionParam);

                    var appliedParam = command.CreateParameter();
                    appliedParam.ParameterName = "@Applied";
                    appliedParam.Value = DateTime.UtcNow;
                    command.Parameters.Add(appliedParam);

                    await ((SqliteCommand)command).ExecuteNonQueryAsync();
                }

                await ((SqliteTransaction)transaction).CommitAsync();
            }
            catch (Exception)
            {
                await ((SqliteTransaction)transaction).RollbackAsync();
                throw;
            }
        }
    }
}