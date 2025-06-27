using System;
using System.Diagnostics;
using Avalonia;
using Avalonia.Controls;
using System.Text.Json;
using System.IO;
using System.Linq;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;
using Avalonia.Interactivity;
using Avalonia.Reactive;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.Messaging;
using DiffKeep.Extensions;
using DiffKeep.Messages;
using DiffKeep.Services;
using DiffKeep.ViewModels;
using Microsoft.Extensions.DependencyInjection;
using Window = ShadUI.Controls.Window;

namespace DiffKeep.Views;

public partial class MainWindow : Window
{
    private string StateFile => Path.Combine(
        Program.DataPath,
        "windowstate.json"
    );
    private readonly ILicenseService _licenseService;
    private readonly IAppStateService _appStateService;
    private bool _canSaveState = false;
    private CancellationTokenSource _layoutDebounceTokenSource;
    private readonly TimeSpan _debounceDelay = TimeSpan.FromMilliseconds(100);


    
    public MainWindow()
    {
        InitializeComponent();
        _licenseService = Program.Services.GetRequiredService<ILicenseService>();
        _appStateService = Program.Services.GetRequiredService<IAppStateService>();
        
        // Ensure directory exists
        var directory = Path.GetDirectoryName(StateFile);
        if (directory != null)
        {
            Directory.CreateDirectory(directory);
        }
        
        this.GetObservable(WindowStateProperty).Subscribe(new AnonymousObserver<Avalonia.Controls.WindowState>(_ => 
            SaveWindowState()));

        this.PositionChanged += (s, e) =>
        {
            SaveWindowState();
        };

        this.GetObservable(ClientSizeProperty).Subscribe(new AnonymousObserver<Size>(size => 
        {
            // Apply left panel width when client size changes
            if (DataContext is MainWindowViewModel vm)
            {
                Debug.WriteLine("Client size property triggered");
                vm.WindowWidth = size.Width;
            
                // If this is the initial size, also apply the panel width
                var state = _appStateService.GetState();
                if (state.LeftPanelOpen && state.LeftPanelWidth > 0)
                {
                    Debug.WriteLine($"Setting left panel width to {state.LeftPanelWidth}");
                    vm.LeftPanelWidth = new GridLength(state.LeftPanelWidth);
                }

                vm.CanSaveState = true;
            }
            _canSaveState = true;
            SaveWindowState();
        }));
        
        // Listen for messages to show the settings dialog
        WeakReferenceMessenger.Default.Register<ShowSettingsMessage>(this, (r, m) =>
        {
            _showSettingsDialog();
        });
        
        // Subscribe to the LayoutUpdated event
        LayoutUpdated += OnLayoutUpdated;
    }
    
    protected override async void OnLoaded(RoutedEventArgs e)
    {
        base.OnLoaded(e);
        LoadWindowState();
        
#if !SKIP_LICENSE_CHECK
        if (!await _licenseService.CheckLicenseValidAsync())
        {
            var licenseWindow = new LicenseKeyWindow();
            await licenseWindow.ShowDialog(this);
        
            // Check again after dialog closes
            if (!await _licenseService.CheckLicenseValidAsync())
            {
                Close();
                return;
            }
        }
#endif

    }
    
    private void OnLayoutUpdated(object? sender, EventArgs e)
    {
        DebounceLayoutUpdate();
    }
    
    private void DebounceLayoutUpdate()
    {
        // Cancel previous debounce task if it exists
        _layoutDebounceTokenSource?.Cancel();
        _layoutDebounceTokenSource = new CancellationTokenSource();
        var token = _layoutDebounceTokenSource.Token;
        
        // Start new debounce task
        Task.Delay(_debounceDelay, token).ContinueWith(t => 
        {
            if (t.IsCanceled) return;
            
            // Execute on UI thread
            Dispatcher.UIThread.Post(() => 
            {
                if (DataContext is MainWindowViewModel vm && _canSaveState)
                {
                    Debug.WriteLine("Debounced layout updated - applying window size");
                    vm.UpdateWindowSize(Bounds.Width);
                }
            });
        }, TaskScheduler.Default);
    }

    private void LoadWindowState()
    {
        try
        {
            var state = _appStateService.GetState();
        
            // Apply the saved left panel width
            if (DataContext is MainWindowViewModel vm && state.LeftPanelWidth > 0)
            {
                if (state.LeftPanelOpen)
                {
                    Debug.WriteLine($"Setting left panel width to {state.LeftPanelWidth}");
                    vm.LeftPanelWidth = new GridLength(state.LeftPanelWidth);
                }
                else
                {
                    Debug.WriteLine($"Setting left panel width to 0 because it's closed right now.");
                    vm.LeftPanelWidth = new GridLength(0);
                }

                vm.IsLeftPanelOpen = state.LeftPanelOpen;
            }
        
            // Only set position if it would be visible on screen
            var screens = Screens.All;
            var isValidPosition = screens.Any(screen => 
                screen.Bounds.Contains(new PixelPoint((int)state.X, (int)state.Y)));
        
            if (isValidPosition)
            {
                Position = new PixelPoint((int)state.X, (int)state.Y);
            }

            if (state is { Width: > 200, Height: > 200 })
            {
                Width = state.Width;
                Height = state.Height;
            }

            if (state.IsMaximized)
            {
                WindowState = Avalonia.Controls.WindowState.Maximized;
            }
        }
        catch
        {
            Position = new PixelPoint(100, 100);
            Width = 800;
            Height = 600;
            WindowState = Avalonia.Controls.WindowState.Normal;
        }
    }

    private void SaveWindowState(bool closing = false)
    {
        try
        {
            if (DataContext is MainWindowViewModel vm && _canSaveState)
            {
                var state = _appStateService.GetState();
                state.Width = Width;
                state.Height = Height;
                state.X = Position.X;
                state.Y = Position.Y;
                state.IsMaximized = WindowState == Avalonia.Controls.WindowState.Maximized;
                state.LeftPanelWidth = vm.LeftPanelWidth.Value;
                state.LeftPanelOpen = vm.IsLeftPanelOpen;

                _appStateService.SaveState(state);
                if (closing)
                    _appStateService.SaveImmediately();
            
                // Update window width in ViewModel when window size changes
                vm.UpdateWindowSize(Bounds.Width);
            }
        }
        catch
        {
            // If there's any error saving state, just ignore it
        }
    }
    
    private async void ShowAboutDialog(object sender, RoutedEventArgs e)
    {
        var aboutWindow = new AboutWindow
        {
            ShowInTaskbar = false
        };
        await aboutWindow.ShowDialog(this);
    }
    
    private async void ShowSettingsDialog(object? sender, RoutedEventArgs e)
    {
        _showSettingsDialog();
    }

    private async void _showSettingsDialog()
    {
        var settingsVm = Program.Services.GetRequiredService<SettingsViewModel>();
        var dialog = new SettingsWindow
        {
            DataContext = settingsVm
        };

        await dialog.ShowDialog(this);
    
        // After settings are updated, refresh the libraries
        if (DataContext is MainWindowViewModel viewModel)
        {
            viewModel.RefreshLibraries();
        }
    }

    private void Exit(object? sender, RoutedEventArgs e)
    {
        Close();
    }
}

public class WindowState: ICloneable
{
    public double Width { get; set; } = 1024;
    public double Height { get; set; } = 768;
    public double X { get; set; }
    public double Y { get; set; }
    public bool IsMaximized { get; set; } = false;
    public double LeftPanelWidth { get; set; } = 150; // Default value
    public bool LeftPanelOpen { get; set; } = true;
    public bool ImageViewerInfoPanelOpen { get; set; } = false;
    
    public object Clone()
    {
        return new WindowState
        {
            Width = Width,
            Height = Height,
            X = X,
            Y = Y,
            IsMaximized = IsMaximized,
            LeftPanelWidth = LeftPanelWidth,
            LeftPanelOpen = LeftPanelOpen,
            ImageViewerInfoPanelOpen = ImageViewerInfoPanelOpen,
        };
    }
}

[JsonSourceGenerationOptions(WriteIndented = true)]
[JsonSerializable(typeof(WindowState))]
public partial class JsonContext : JsonSerializerContext
{
}
