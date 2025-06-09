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
    private double _windowWidth;
    [ObservableProperty]
    private GridLength _leftPanelWidth;
    [ObservableProperty]
    private double _leftPanelMaxWidth;
    public LeftPanelViewModel LeftPanel { get; }
    public ImageGalleryViewModel ImageGallery { get; }



    public MainWindowViewModel()
    {
        LeftPanel = Program.Services.GetRequiredService<LeftPanelViewModel>();
        ImageGallery = Program.Services.GetRequiredService<ImageGalleryViewModel>();
        LeftPanelWidth = new GridLength(250);
        
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
        Debug.Print($"Left panel width is now {value}");
        // Calculate max width (50% of window width)
        double maxWidth = WindowWidth * 0.5;
                
        // If the new value exceeds max width, cap it
        if (WindowWidth > 0 && value.Value > maxWidth)
        {
            LeftPanelWidth = new GridLength(maxWidth);
        }
        else
        {
            LeftPanelWidth = value;
        }
    }
    
    public void UpdateWindowSize(double width)
    {
        if (width <= 0) return;
        Debug.Print($"Window width is now {width}");
        WindowWidth = width;
            
        // Check if current left panel width exceeds the new max width
        double maxWidth = WindowWidth * 0.5;
        LeftPanelMaxWidth = maxWidth;
        if (_leftPanelWidth.Value > maxWidth)
        {
            LeftPanelWidth = new GridLength(maxWidth);
        }
    }

    [RelayCommand]
    private void ToggleLeftPanel()
    {
        IsLeftPanelOpen = !IsLeftPanelOpen;
        LeftPanelWidth = IsLeftPanelOpen ? new GridLength(250) : new GridLength(0);
    }
}