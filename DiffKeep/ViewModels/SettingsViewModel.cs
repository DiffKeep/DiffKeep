using System;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using DiffKeep.Settings;
using System.Text.Json;
using System.Threading.Tasks;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using DiffKeep.Models;
using DiffKeep.Repositories;
using DiffKeep.Extensions;
using DiffKeep.Services;
using MsBox.Avalonia;
using MsBox.Avalonia.Enums;
using Serilog;
using ShadUI.Toasts;

namespace DiffKeep.ViewModels;

public partial class SettingsViewModel : ViewModelBase
{
    private readonly ILibraryRepository _libraryRepository;
    private readonly IImageRepository _imageRepository;
    private readonly IEmbeddingsRepository _embeddingsRepository;
    private readonly ITextEmbeddingGenerationService _textEmbeddingGenerationService;
    private readonly HuggingFaceDownloaderViewModel _huggingFaceDownloaderViewModel;
    private readonly ToastManager  _toastManager;

    [ObservableProperty]
    private string _language;
    [ObservableProperty] private bool _storeThumbnails;
    [ObservableProperty] private bool _useEmbeddings;
    [ObservableProperty] private bool _modelExists;
    [ObservableProperty] private string? _modelName;

    public partial class LibraryItem : ObservableObject
    {
        [ObservableProperty]
        private string _path = string.Empty;

        public long? Id { get; set; }
    }

    public ObservableCollection<LibraryItem> Libraries { get; }

    public SettingsViewModel(ILibraryRepository libraryRepository, IImageRepository imageRepository,
        IEmbeddingsRepository embeddingsRepository, AppSettings settings,
        ITextEmbeddingGenerationService textEmbeddingGenerationService,
        HuggingFaceDownloaderViewModel huggingFaceDownloaderViewModel,
        ToastManager toastManager)
    {
        _libraryRepository = libraryRepository;
        _imageRepository = imageRepository;
        _embeddingsRepository = embeddingsRepository;
        _textEmbeddingGenerationService = textEmbeddingGenerationService;
        _huggingFaceDownloaderViewModel = huggingFaceDownloaderViewModel;
        _toastManager = toastManager;
        _language = settings.Language;
        Libraries = new ObservableCollection<LibraryItem>();
        LoadLibrariesAsync().FireAndForget();
    }
    
    public void LoadCurrentSettings()
    {
        var settings = Program.Settings;
        Log.Debug("Loading current settings for the window. StoreThumbnails: {SettingsStoreThumbnails}", settings.StoreThumbnails);
        
        Language = settings.Language;
        StoreThumbnails = settings.StoreThumbnails;
        UseEmbeddings = settings.UseEmbeddings;
        ModelExists = _textEmbeddingGenerationService.ModelExists();
        ModelName = _textEmbeddingGenerationService.ModelName();
        LoadLibrariesAsync().FireAndForget();
    }

    private async Task LoadLibrariesAsync()
    {
        var libraries = await _libraryRepository.GetAllAsync();
        Libraries.Clear();
        foreach (var lib in libraries)
        {
            Libraries.Add(new LibraryItem { Path = lib.Path, Id = lib.Id });
        }
    }

    [RelayCommand]
    private async Task Save()
    {
        // Save settings to AppSettings
        var settings = new AppSettings
        {
            Language = Language,
            StoreThumbnails = StoreThumbnails,
            UseEmbeddings = UseEmbeddings,
        };

        var wrapper = new AppSettingsWrapper { AppSettings = settings };
        var json = JsonSerializer.Serialize(wrapper, AppSettingsContext.Default.AppSettingsWrapper);
        File.WriteAllText(Program.ConfigPath, json);

        // Save libraries to database
        var currentLibraries = await _libraryRepository.GetAllAsync();
        var existingPaths = currentLibraries.ToDictionary(l => l.Path);

        foreach (var library in Libraries)
        {
            if (string.IsNullOrWhiteSpace(library.Path)) continue;

            if (library.Id.HasValue)
            {
                // Update existing library
                await _libraryRepository.UpdateAsync(new Library 
                { 
                    Id = library.Id.Value, 
                    Path = library.Path 
                });
            }
            else if (!existingPaths.ContainsKey(library.Path))
            {
                // Add new library
                var id = await _libraryRepository.AddAsync(new Library { Path = library.Path });
                library.Id = id;
            }
        }

        // Remove libraries that were deleted in the UI
        foreach (var existing in currentLibraries)
        {
            if (!Libraries.Any(l => l.Id == existing.Id))
            {
                await DeleteLibrary(new LibraryItem
                {
                    Id = existing.Id,
                    Path = existing.Path
                });
            }
        }
        
        Program.ReloadConfiguration();
        
        if (App.Current.ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            var window = desktop.Windows.OfType<Views.SettingsWindow>().FirstOrDefault();
            window?.Close();
        }
    }

    [RelayCommand]
    private void AddLibrary()
    {
        Libraries.Add(new LibraryItem { Path = "" });
    }
    
    [RelayCommand]
    private async Task BrowseLibrary(LibraryItem item)
    {
        var dialog = new OpenFolderDialog
        {
            Title = "Select Library Directory"
        };

        if (App.Current.ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            var window = desktop.Windows.FirstOrDefault(w => w.IsActive);
            if (window != null)
            {
                var result = await dialog.ShowAsync(window);
                if (!string.IsNullOrEmpty(result))
                {
                    item.Path = result;
                }
            }
        }
    }

    [RelayCommand]
    private async Task DownloadModel()
    {
        const string huggingFaceUrl = "https://huggingface.co/mradermacher/e5-base-v2-GGUF/resolve/main/e5-base-v2.Q6_K.gguf?download=true";
        const string modelFileName = "e5-base-v2.Q6_K.gguf";
        // Set the destination path
        string destinationPath = Path.Join(Program.DataPath, "models", modelFileName);
        
        try
        {
            // Start the download
            await _huggingFaceDownloaderViewModel.StartDownload(huggingFaceUrl, destinationPath);
            
            // Update the model status after successful download
            ModelExists = _textEmbeddingGenerationService.ModelExists();
        }
        catch (Exception ex)
        {
            // Show error message
            _toastManager.CreateToast("Error downloading model").WithContent($"Could not download model: {ex.Message}").ShowError();
            Log.Error("Could not download model: {ExMessage}", ex.Message);
        }
    }
    
    [RelayCommand]
    private async Task DeleteLibrary(LibraryItem item)
    {
        if (App.Current.ApplicationLifetime is IClassicDesktopStyleApplicationLifetime {MainWindow: not null} desktop)
        {
            if (item.Id == null)
                return;
            var dialog = MessageBoxManager.GetMessageBoxStandard(
                "Confirm Delete", $"Are you sure you want to remove this library?\n{item.Path}", ButtonEnum.OkCancel);

            if (await dialog.ShowWindowDialogAsync(desktop.MainWindow) == ButtonResult.Ok)
            {
                // delete all the embeddings associated with images associated with this library
                await _embeddingsRepository.DeleteEmbeddingsForLibraryAsync(item.Id.Value);
                // delete all the images associated with this library
                await _imageRepository.DeleteByLibraryIdAsync(item.Id.Value);
                // delete the library itself
                await _libraryRepository.DeleteAsync(item.Id.Value);
                Libraries.Remove(item);
            }
        }
    }
}