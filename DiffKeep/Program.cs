using Avalonia;
using System;
using System.IO;
using System.CommandLine;
using System.Diagnostics;
using Microsoft.Extensions.Configuration;
using DiffKeep.Settings;
using System.Text.Json;

namespace DiffKeep;

sealed class Program
{
    public static IConfiguration Configuration { get; private set; }
    public static AppSettings Settings { get; set; }
    public static string DataPath { get; private set; }
    public static string ConfigPath { get; private set; }

    private static string DefaultDataPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "DiffKeep"
    );

    [STAThread]
    public static void Main(string[] args)
    {
        var dataPathOption = new Option<string>(
            new[] { "--datapath", "-d" },
            () => DefaultDataPath,
            "Directory where application data and configuration will be stored"
        );

        var rootCommand = new RootCommand("DiffKeep - Manage AI generated assets")
        {
            dataPathOption
        };

        DataPath = DefaultDataPath;

        rootCommand.SetHandler((dataPath) =>
        {
            Debug.Print($"Data path: {dataPath}");
            DataPath = dataPath;
        }, dataPathOption);

        rootCommand.Invoke(args);

        try
        {
            SetupConfiguration();
            BuildAvaloniaApp()
                .StartWithClassicDesktopLifetime(args);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Error: {ex.Message}");
            Environment.Exit(1);
        }
    }

    private static void SetupConfiguration()
    {
        // Ensure directory exists
        Directory.CreateDirectory(DataPath);

        // Default config file path
        string configPath = Path.Combine(DataPath, "appsettings.json");

        ConfigPath = configPath;

        // Create default config file if it doesn't exist
        if (!File.Exists(configPath))
        {
            var wrapper = new AppSettingsWrapper();
            string jsonString = JsonSerializer.Serialize(wrapper, AppSettingsContext.Default.AppSettingsWrapper);
            File.WriteAllText(configPath, jsonString);
        }

        ReloadConfiguration();
    }

    public static void ReloadConfiguration()
    {
        Configuration = new ConfigurationBuilder()
            .SetBasePath(DataPath)
            .AddJsonFile("appsettings.json", optional: false, reloadOnChange: true)
            .Build();

        // Bind the configuration to our settings class
        Settings = Configuration.GetSection("AppSettings").Get<AppSettings>()
                   ?? throw new InvalidOperationException("Failed to load application settings");
    }

    // Avalonia configuration, don't remove; also used by visual designer.
    public static AppBuilder BuildAvaloniaApp()
        => AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .WithInterFont()
            .LogToTrace();
}