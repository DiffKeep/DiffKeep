using Avalonia;
using System;
using System.IO;
using System.CommandLine;
using System.Diagnostics;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using DiffKeep.Settings;
using System.Text.Json;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.Messaging;
using DiffKeep.Database;
using DiffKeep.Extensions;
using DiffKeep.Parsing;
using DiffKeep.Repositories;
using DiffKeep.Services;
using DiffKeep.ViewModels;
using Microsoft.Data.Sqlite;

namespace DiffKeep;

sealed class Program
{
    public static IServiceProvider Services { get; private set; }
    public static IConfiguration Configuration { get; private set; }
    public static AppSettings Settings { get; set; }
    public static string DataPath { get; private set; }
    public static string ConfigPath { get; private set; }

    public const string DbFilename = "diffkeep.db";

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

        var deleteDbOption = new Option<bool>(
            new[] { "--delete-db" },
            "Delete the existing database and create a new one on startup"
        );

        var rootCommand = new RootCommand("DiffKeep - Manage AI generated assets")
        {
            dataPathOption,
            deleteDbOption
        };

        DataPath = DefaultDataPath;

        rootCommand.SetHandler((dataPath, deleteDb) =>
        {
            Debug.Print($"Data path: {dataPath}");
            DataPath = dataPath;

            if (deleteDb)
            {
                var dbPath = Path.Combine(dataPath, DbFilename);
                if (File.Exists(dbPath))
                {
                    File.Delete(dbPath);
                    Debug.Print("Existing database deleted");
                }
            }
        }, dataPathOption, deleteDbOption);

        rootCommand.Invoke(args);

        try
        {
            SetupConfiguration();
            BuildAvaloniaApp()
                .StartWithClassicDesktopLifetime(args);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Error: {ex}");
            Environment.Exit(1);
        }
    }

    private static void SetupConfiguration()
    {
        // Ensure directory exists
        Directory.CreateDirectory(DataPath);

        // Default config file path
        string configPath = Path.Combine(DataPath, "appsettings.json");
        string dbPath = Path.Combine(DataPath, DbFilename);

        ConfigPath = configPath;

        // Create default config file if it doesn't exist
        if (!File.Exists(configPath))
        {
            var wrapper = new AppSettingsWrapper();
            string jsonString = JsonSerializer.Serialize(wrapper, AppSettingsContext.Default.AppSettingsWrapper);
            File.WriteAllText(configPath, jsonString);
        }

        ReloadConfiguration();

        ConfigureServices().FireAndForget();
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

    private static async Task ConfigureServices()
    {
        var services = new ServiceCollection();

        var dbPath = Path.Combine(DataPath, DbFilename);
        var connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = dbPath,
            Mode = SqliteOpenMode.ReadWriteCreate
        }.ToString();

        var connectionFactory = new DatabaseConnectionFactory(connectionString);
        await connectionFactory.InitializeAsync();

        services.AddSingleton(connectionFactory);


        // Register repositories with the connection factory
        services.AddSingleton<ILibraryRepository>(sp =>
            new LibraryRepository(sp.GetRequiredService<DatabaseConnectionFactory>()));
        services.AddSingleton<IImageRepository>(sp =>
            new ImageRepository(sp.GetRequiredService<DatabaseConnectionFactory>()));
        services.AddSingleton<IEmbeddingsRepository>(sp =>
            new EmbeddingsRepository(sp.GetRequiredService<DatabaseConnectionFactory>()));

        // Register services
        services.AddSingleton<ImageParser>();
        services.AddSingleton<LibraryWatcherService>();
        services.AddSingleton<ImageLibraryScanner>();
        services.AddSingleton<PngMetadataParser>();
        services.AddSingleton<IEmbeddingGenerationService, LlamaSharpEmbeddingGenerateService>();
        services.AddSingleton<IImageService>(sp =>
            new ImageService(sp.GetRequiredService<IImageRepository>())
        );
        services.AddSingleton<SearchService>();

        // Register view models
        services.AddSingleton<MainWindowViewModel>();
        services.AddTransient<SettingsViewModel>(sp =>
            new SettingsViewModel(
                sp.GetRequiredService<ILibraryRepository>(),
                sp.GetRequiredService<IImageRepository>(),
                sp.GetRequiredService<IEmbeddingsRepository>(),
                Settings
            ));
        services.AddSingleton<AboutWindowViewModel>();
        services.AddSingleton<ImageGalleryViewModel>(sp =>
            new ImageGalleryViewModel(
                sp.GetRequiredService<IImageRepository>(),
                sp.GetRequiredService<IImageService>(),
                sp.GetRequiredService<SearchService>()
            ));
        services.AddSingleton<ImageViewerViewModel>();
        services.AddSingleton<LeftPanelViewModel>();
        services.AddSingleton<EmbeddingsGenerationViewModel>();

        Services = services.BuildServiceProvider();
    }
}