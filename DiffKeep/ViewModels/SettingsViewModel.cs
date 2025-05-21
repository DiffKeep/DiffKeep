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
using DiffKeep.Dialogs;

namespace DiffKeep.ViewModels;

public partial class SettingsViewModel : ViewModelBase
{
    [ObservableProperty]
    private string _theme;

    [ObservableProperty]
    private string _language;

    // Change to ObservableCollection<LibraryItem> to better handle bindings
    public partial class LibraryItem : ObservableObject
    {
        [ObservableProperty]
        private string _path = string.Empty;
    }

    public ObservableCollection<LibraryItem> Libraries { get; }

    public SettingsViewModel(AppSettings settings)
    {
        _theme = settings.Theme;
        _language = settings.Language;
        Libraries = new ObservableCollection<LibraryItem>(
            settings.Libraries.Select(l => new LibraryItem { Path = l })
        );
    }

    [RelayCommand]
    private void Save()
    {
        var settings = new AppSettings
        {
            Theme = Theme,
            Language = Language,
            Libraries = Libraries.Select(l => l.Path).ToArray()
        };

        var wrapper = new AppSettingsWrapper { AppSettings = settings };
        var json = JsonSerializer.Serialize(wrapper, AppSettingsContext.Default.AppSettingsWrapper);
        File.WriteAllText(Program.ConfigPath, json);
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
                var dialog = new MessageDialog
                {
                    Title = "Confirm Delete",
                    Message = $"Are you sure you want to remove this library?\n{item.Path}"
                };

                if (await dialog.ShowAsync(window) == MessageDialogResult.Ok)
                {
                    Libraries.Remove(item);
                }
            }
        }
    }


}