using System;
using System.Text.Json.Serialization;
using Serilog.Events;

namespace DiffKeep.Settings;

[JsonSourceGenerationOptions(WriteIndented = true)]
[JsonSerializable(typeof(AppSettings))]
[JsonSerializable(typeof(AppSettingsWrapper))]
internal partial class AppSettingsContext : JsonSerializerContext { }

public class AppSettingsWrapper
{
    public AppSettings AppSettings { get; set; } = new();
}

public class AppSettings
{
    public bool LogToFile { get; set; } = true;
    public bool LogToConsole { get; set; }
    public bool LogToDebug { get; set; } = true;
    public LogEventLevel LogLevel { get; set; }
    public string Language { get; set; } = "en-US";
    public bool StoreThumbnails { get; set; } = false;
    public bool UseEmbeddings { get; set; } = false;
    public string? LicenseKey { get; set; }
    public string? Email { get; set; }
    public bool IsRegistered { get; set; }
}