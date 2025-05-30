using System.Collections.ObjectModel;
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
using MsBox.Avalonia;
using MsBox.Avalonia.Enums;

namespace DiffKeep.ViewModels;

public partial class SettingsViewModel : ViewModelBase
{
    private readonly ILibraryRepository _libraryRepository;
    private readonly IImageRepository _imageRepository;
    private readonly IEmbeddingsRepository _embeddingsRepository;

    [ObservableProperty]
    private string _theme;

    [ObservableProperty]
    private string _language;

    public partial class LibraryItem : ObservableObject
    {
        [ObservableProperty]
        private string _path = string.Empty;

        public long? Id { get; set; }
    }

    public ObservableCollection<LibraryItem> Libraries { get; }

    public SettingsViewModel(ILibraryRepository libraryRepository, IImageRepository imageRepository, IEmbeddingsRepository embeddingsRepository, AppSettings settings)
    {
        _libraryRepository = libraryRepository;
        _imageRepository = imageRepository;
        _embeddingsRepository = embeddingsRepository;
        _theme = settings.Theme;
        _language = settings.Language;
        Libraries = new ObservableCollection<LibraryItem>();
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
        // Save theme and language to AppSettings
        var settings = new AppSettings
        {
            Theme = Theme,
            Language = Language,
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
    private async Task DeleteLibrary(LibraryItem item)
    {
        if (App.Current.ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            var window = desktop.Windows.FirstOrDefault(w => w.IsActive);
            if (window != null)
            {
                if (item.Id == null)
                    return;
                var dialog = MessageBoxManager.GetMessageBoxStandard(
                    "Confirm Delete", $"Are you sure you want to remove this library?\n{item.Path}", ButtonEnum.OkCancel);

                if (await dialog.ShowAsync() == ButtonResult.Ok)
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
}