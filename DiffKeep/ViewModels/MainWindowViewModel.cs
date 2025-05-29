using System.Diagnostics;
using System.Threading.Tasks;
using Avalonia.Controls;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using DiffKeep.Database;
using DiffKeep.Extensions;
using DiffKeep.Repositories;
using Microsoft.Extensions.DependencyInjection;

namespace DiffKeep.ViewModels;

public partial class MainWindowViewModel : ViewModelBase
{
    [ObservableProperty]
    private bool _isLeftPanelOpen = true;
    
    [ObservableProperty]
    private GridLength _leftPanelWidth;

    public string Greeting { get; } = "Welcome to DiffKeep!";
    public LeftPanelViewModel LeftPanel { get; }
    public ImageGalleryViewModel ImageGallery { get; }


    public MainWindowViewModel()
    {
        LeftPanel = Program.Services.GetRequiredService<LeftPanelViewModel>();
        ImageGallery = Program.Services.GetRequiredService<ImageGalleryViewModel>();
        _leftPanelWidth = new GridLength(250);
        
        // Subscribe to selection changes
        LeftPanel.PropertyChanged +=  async (s, e) =>
        {
            if (e.PropertyName == nameof(LeftPanelViewModel.SelectedItem) && LeftPanel.SelectedItem != null)
            {
                Debug.WriteLine("Loading images for library called from main window");
                await Task.Delay(100);
                ImageGallery.LoadImagesAsync(LeftPanel.SelectedItem).FireAndForget();
            }
        };
    }
    
    public void RefreshLibraries()
    {
        LeftPanel.RefreshLibrariesAsync().FireAndForget();
    }

    partial void OnLeftPanelWidthChanged(GridLength value)
    {
        Debug.Print($"Width is now {value}");
    }

    [RelayCommand]
    private void ToggleLeftPanel()
    {
        IsLeftPanelOpen = !IsLeftPanelOpen;
        LeftPanelWidth = IsLeftPanelOpen ? new GridLength(250) : new GridLength(0);
    }
}