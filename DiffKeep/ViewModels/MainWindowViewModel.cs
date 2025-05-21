using System.Diagnostics;
using Avalonia.Controls;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

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
        LeftPanel = new LeftPanelViewModel();
        ImageGallery = new ImageGalleryViewModel();
        _leftPanelWidth = new GridLength(250);
        
        // Subscribe to selection changes
        LeftPanel.PropertyChanged +=  async (s, e) =>
        {
            if (e.PropertyName == nameof(LeftPanelViewModel.SelectedItem) && 
                LeftPanel.SelectedItem != null)
            {
                await ImageGallery.LoadImagesFromDirectory(LeftPanel.SelectedItem.Path);
            }
        };

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