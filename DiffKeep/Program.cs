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
using DiffKeep.Database;
using DiffKeep.Extensions;
using DiffKeep.Parsing;
using DiffKeep.Repositories;
using DiffKeep.Services;
using DiffKeep.ViewModels;
using LLama.Native;
using Microsoft.Data.Sqlite;
using Serilog;
using Serilog.Events;
using ShadUI;

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
            NativeLibraryConfig.All.WithLogCallback(delegate(LLamaLogLevel level, string message)
            {
                Log.Debug("{LLamaLogLevel}: {Message}", level, message);
            });
            SetupConfiguration();
            BuildAvaloniaApp()
                .StartWithClassicDesktopLifetime(args);
        }
        catch (Exception ex)
        {
            Log.Debug("Error: {Exception}", ex);
        }
        finally
        {
            Log.CloseAndFlush();
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
        
        // make sure the logs path exists
        if (Settings.LogToFile)
            Directory.CreateDirectory(Path.Combine(DataPath, "logs"));

        var logConf = new LoggerConfiguration();
        if (Settings.LogToConsole)
            logConf.WriteTo.Console();
        if (Settings.LogToDebug)
            logConf.WriteTo.Debug();
        if (Settings.LogToFile)
            logConf.WriteTo.Async(
                a => a.File(
                    Path.Combine(DataPath, "logs", "log.txt"),
                    rollingInterval: RollingInterval.Day)
                );
        switch (Settings.LogLevel)
        {
            case LogEventLevel.Verbose:
                logConf.MinimumLevel.Verbose();
                break;
            case LogEventLevel.Debug:
                logConf.MinimumLevel.Debug();
                break;
            case LogEventLevel.Information:
                logConf.MinimumLevel.Information();
                break;
            case LogEventLevel.Warning:
                logConf.MinimumLevel.Warning();
                break;
            case LogEventLevel.Error:
                logConf.MinimumLevel.Error();
                break;
            case LogEventLevel.Fatal:
                logConf.MinimumLevel.Fatal();
                break;
            default:    
                logConf.MinimumLevel.Warning();
                break;
        }
        
        Log.Logger = logConf.CreateLogger();
        Log.Information("Starting DiffKeep version {version}", GitVersion.FullVersion);

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
        services.AddSingleton<ILibraryRepository, LibraryRepository>();
        services.AddSingleton<IImageRepository, ImageRepository>();
        services.AddSingleton<IEmbeddingsRepository, EmbeddingsRepository>();

        // Register services
        services.AddSingleton<ImageParser>();
        services.AddSingleton<LibraryWatcherService>();
        services.AddSingleton<ImageLibraryScanner>();
        services.AddSingleton<PngMetadataParser>();
        services.AddSingleton<ITextEmbeddingGenerationService, LlamaSharpTextTextEmbeddingGenerationService>();
        services.AddSingleton<IImageService, ImageService>();
        services.AddSingleton<SearchService>();
        services.AddSingleton<ILicenseService, LicenseService>();
        services.AddSingleton<IAppStateService, AppStateService>();
        services.AddSingleton<ToastManager>();
        
        // App settings
        services.AddSingleton(Settings);

        // Register view models
        services.AddSingleton<MainWindowViewModel>();
        services.AddTransient<SettingsViewModel>();
        services.AddSingleton<AboutWindowViewModel>();
        services.AddSingleton<ImageGalleryViewModel>();
        services.AddSingleton<ImageViewerViewModel>();
        services.AddSingleton<LeftPanelViewModel>();
        services.AddSingleton<EmbeddingsGenerationViewModel>();
        services.AddSingleton<HuggingFaceDownloaderViewModel>();
        services.AddSingleton<FeedbackViewModel>();

        Services = services.BuildServiceProvider();
    }
}