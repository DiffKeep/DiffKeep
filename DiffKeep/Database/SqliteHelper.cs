using System;
using System.Data;
using System.Threading.Tasks;
using Microsoft.Data.Sqlite;

namespace DiffKeep.Database;

public static class SqliteHelper
{
    public static SqliteParameter CreateParameter(this SqliteCommand command, string name, object value)
    {
        var param = command.CreateParameter();
        param.ParameterName = name;
        param.Value = value;
        command.Parameters.Add(param);
        return param;
    }

    public static T? GetValue<T>(this SqliteDataReader reader, string columnName)
    {
        if (HasColumn(reader, columnName))
        {
            var ordinal = reader.GetOrdinal(columnName);
            return reader.IsDBNull(ordinal) ? default : (T)reader.GetValue(ordinal);
        }
        return default;
    }
    
    public static bool HasColumn(IDataReader reader, string columnName)
    {
        for (int i = 0; i < reader.FieldCount; i++)
        {
            if (reader.GetName(i).Equals(columnName, StringComparison.OrdinalIgnoreCase))
                return true;
        }
        return false;
    }
    
    public static async Task<T?> ExecuteScalarAsync<T>(this SqliteCommand command)
    {
        var result = await command.ExecuteScalarAsync();
        return (T)Convert.ChangeType(result, typeof(T));
    }
}