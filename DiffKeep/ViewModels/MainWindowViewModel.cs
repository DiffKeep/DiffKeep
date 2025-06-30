using System.Diagnostics;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using DiffKeep.Database;
using DiffKeep.Extensions;
using DiffKeep.Repositories;
using DiffKeep.Services;
using DiffKeep.Views;
using Microsoft.Extensions.DependencyInjection;
using Serilog;
using ShadUI.Themes;
using ShadUI.Toasts;

namespace DiffKeep.ViewModels;

public partial class MainWindowViewModel : ViewModelBase
{
    private readonly IAppStateService _appStateService;
    [ObservableProperty]
    private bool _isLeftPanelOpen = true;
    [ObservableProperty]
    private double _windowWidth;
    [ObservableProperty]
    private GridLength _leftPanelWidth;
    [ObservableProperty]
    private double _leftPanelMaxWidth = 500;
    [ObservableProperty]
    private double _leftPanelMinWidth;
    public LeftPanelViewModel LeftPanel { get; }
    public bool CanSaveState = false;
    public ImageGalleryViewModel ImageGallery { get; }
    [ObservableProperty]
    private ToastManager _toastManager;
    [ObservableProperty]
    private ThemeMode _currentTheme;
    private ThemeWatcher _themeWatcher;

    public MainWindowViewModel(IAppStateService appStateService, ToastManager toastManager,
        LeftPanelViewModel leftPanelViewModel, ImageGalleryViewModel imageGalleryViewModel)
    {
        _appStateService = appStateService;
        _toastManager = toastManager;
        _themeWatcher = new ThemeWatcher(Application.Current!);
        LeftPanel = leftPanelViewModel;
        ImageGallery = imageGalleryViewModel;
        var state = _appStateService.GetState();
        if (state.LeftPanelOpen)
        {
            _leftPanelWidth = new GridLength(state.LeftPanelWidth);
            _leftPanelMinWidth = 100;
            _isLeftPanelOpen = true;
        }
        else
        {
            _leftPanelWidth = new GridLength(0);
            _leftPanelMinWidth = 0;
            _isLeftPanelOpen = false;
        }
        
        // set current theme
        SwitchTheme(state.Theme);

        // Subscribe to selection changes
        LeftPanel.PropertyChanged +=  async (s, e) =>
        {
            if (e.PropertyName == nameof(LeftPanelViewModel.SelectedItem) && LeftPanel.SelectedItem != null)
            {
                Log.Debug("Loading images for library called from main window");
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
        Log.Debug("Left panel width is now {GridLength}", value);
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

        if (LeftPanelWidth.Value > 0 && CanSaveState)
        {
            var state = _appStateService.GetState();
            state.LeftPanelWidth = LeftPanelWidth.Value;
            _appStateService.SaveState(state);
        }
    }
    
    public void UpdateWindowSize(double width)
    {
        if (width <= 0) return;
        Log.Debug("Window width is now {Width}", width);
        WindowWidth = width;
            
        // Check if current left panel width exceeds the new max width
        double maxWidth = WindowWidth * 0.5;
        LeftPanelMaxWidth = maxWidth;
        if (_leftPanelWidth.Value > maxWidth && CanSaveState)
        {
            LeftPanelWidth = new GridLength(maxWidth);
            var state = _appStateService.GetState();
            state.LeftPanelWidth = LeftPanelWidth.Value;
            _appStateService.SaveState(state);
        }
    }

    [RelayCommand]
    private void ToggleLeftPanel()
    {
        var state = _appStateService.GetState();
        IsLeftPanelOpen = !IsLeftPanelOpen;
        LeftPanelWidth = IsLeftPanelOpen ? new GridLength(state.LeftPanelWidth) : new GridLength(0);
        LeftPanelMinWidth = IsLeftPanelOpen ? 100 : 0;
        state.LeftPanelOpen = IsLeftPanelOpen;
        if (CanSaveState)
            _appStateService.SaveState(state);
    }
    
    [RelayCommand]
    private void SwitchTheme(ThemeMode? mode = null)
    {
        if (mode == null)
        {
            CurrentTheme = CurrentTheme switch
            {
                ThemeMode.System => ThemeMode.Light,
                ThemeMode.Light => ThemeMode.Dark,
                _ => ThemeMode.System
            };
        }
        else
        {
            CurrentTheme = mode.Value;
        }

        _themeWatcher.SwitchTheme(CurrentTheme);
        var state =  _appStateService.GetState();
        state.Theme = CurrentTheme;
        _appStateService.SaveState(state);
    }
}