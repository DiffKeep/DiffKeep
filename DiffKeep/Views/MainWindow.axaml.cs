using Avalonia;
using Avalonia.Controls;
using System.Text.Json;
using System.IO;
using System.Linq;
using System.Text.Json.Serialization;
using Avalonia.Interactivity;
using Avalonia.Reactive;
using DiffKeep.ViewModels;
using Microsoft.Extensions.DependencyInjection;

namespace DiffKeep.Views;

public partial class MainWindow : Window
{
    private string StateFile => Path.Combine(
        Program.DataPath,
        "windowstate.json"
    );
    private readonly ILicenseService _licenseService;

    
    public MainWindow()
    {
        InitializeComponent();
        _licenseService = Program.Services.GetRequiredService<ILicenseService>();
        
        // Ensure directory exists
        var directory = Path.GetDirectoryName(StateFile);
        if (directory != null)
        {
            Directory.CreateDirectory(directory);
        }
        
        // Load and apply saved state
        LoadWindowState();
        
        this.GetObservable(WindowStateProperty).Subscribe(new AnonymousObserver<Avalonia.Controls.WindowState>(_ => 
            SaveWindowState()));

        this.PositionChanged += (s, e) =>
        {
            SaveWindowState();
        };

        this.GetObservable(ClientSizeProperty).Subscribe(new AnonymousObserver<Size>(_ => 
            SaveWindowState()));
    }
    
    protected override async void OnLoaded(RoutedEventArgs e)
    {
        base.OnLoaded(e);
        
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
    }


    private void LoadWindowState()
    {
        try
        {
            if (File.Exists(StateFile))
            {
                var json = File.ReadAllText(StateFile);
                var state = JsonSerializer.Deserialize(json, JsonContext.Default.WindowState);
            
                // Only set position if it would be visible on screen
                var screens = Screens.All;
                var isValidPosition = screens.Any(screen => 
                    screen.Bounds.Contains(new PixelPoint((int)state.X, (int)state.Y)));
            
                if (isValidPosition)
                {
                    Position = new PixelPoint((int)state.X, (int)state.Y);
                }

                if (state.Width > 0 && state.Height > 0)
                {
                    Width = state.Width;
                    Height = state.Height;
                }

                if (state.IsMaximized)
                {
                    WindowState = Avalonia.Controls.WindowState.Maximized;
                }
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

    private void SaveWindowState()
    {
        try
        {
            var state = new WindowState
            {
                Width = ClientSize.Width,
                Height = ClientSize.Height,
                X = Position.X,
                Y = Position.Y,
                IsMaximized = WindowState == Avalonia.Controls.WindowState.Maximized
            };

            var json = JsonSerializer.Serialize(state, JsonContext.Default.WindowState);
            File.WriteAllText(StateFile, json);
        }
        catch
        {
            // If there's any error saving state, just ignore it
        }
    }

    protected override void OnClosing(WindowClosingEventArgs e)
    {
        SaveWindowState();
        base.OnClosing(e);
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
}

public class WindowState
{
    public double Width { get; set; }
    public double Height { get; set; }
    public double X { get; set; }
    public double Y { get; set; }
    public bool IsMaximized { get; set; }
}

[JsonSourceGenerationOptions(WriteIndented = true)]
[JsonSerializable(typeof(WindowState))]
public partial class JsonContext : JsonSerializerContext
{
}
