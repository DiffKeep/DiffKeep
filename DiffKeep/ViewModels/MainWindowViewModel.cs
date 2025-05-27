using System.Diagnostics;
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
        var libraryRepository = Program.Services.GetRequiredService<ILibraryRepository>();
        var imageRepository = Program.Services.GetRequiredService<IImageRepository>();
        var imageLibraryScanner = Program.Services.GetRequiredService<ImageLibraryScanner>();
        LeftPanel = new LeftPanelViewModel(libraryRepository, imageLibraryScanner);
        ImageGallery = new ImageGalleryViewModel(imageRepository);
        _leftPanelWidth = new GridLength(250);
        
        // Subscribe to selection changes
        LeftPanel.PropertyChanged +=  async (s, e) =>
        {
            if (e.PropertyName == nameof(LeftPanelViewModel.SelectedItem) && LeftPanel.SelectedItem != null)
            {
                if (LeftPanel.SelectedItem.IsLibrary)
                    ImageGallery.LoadImagesForLibraryAsync(LeftPanel.SelectedItem).FireAndForget();
                else
                    ImageGallery.LoadImagesForLibraryAsync(LeftPanel.SelectedItem).FireAndForget();
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