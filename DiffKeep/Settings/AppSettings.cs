using System;
using System.Text.Json.Serialization;

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
    public string Theme { get; set; } = "Dark";
    public string Language { get; set; } = "en-US";
    public bool StoreThumbnails { get; set; } = false;
    public bool UseEmbeddings { get; set; } = false;
    public string? LicenseKey { get; set; }
}