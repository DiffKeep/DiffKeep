using System;
using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Data.Core.Plugins;
using System.Linq;
using System.Reflection;
using Avalonia.Controls;
using Avalonia.Markup.Xaml;
using DiffKeep.ViewModels;
using DiffKeep.Views;
using Microsoft.Extensions.DependencyInjection;
using Serilog;

namespace DiffKeep;

public partial class App : Application
{
    public new static App Current => (App)Application.Current!;
    public IServiceProvider Services { get; private set; }

    public override void Initialize()
    {
        AvaloniaXamlLoader.Load(this);
        Services = Program.Services;
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            // Avoid duplicate validations from both Avalonia and the CommunityToolkit. 
            // More info: https://docs.avaloniaui.net/docs/guides/development-guides/data-validation#manage-validationplugins
            DisableAvaloniaDataAnnotationValidation();
            desktop.MainWindow = new MainWindow
            {
                DataContext = Services.GetRequiredService<MainWindowViewModel>()
            };
            // Set window icon
            try
            {
                var assembly = Assembly.GetExecutingAssembly();
                using var iconStream = assembly.GetManifestResourceStream("DiffKeep.Assets.diffkeep.ico");
                if (iconStream != null)
                {
                    var bitmap = new Avalonia.Media.Imaging.Bitmap(iconStream);
                    desktop.MainWindow.Icon = new WindowIcon(bitmap);
                    Log.Information("Successfully loaded application icon from embedded resource");
                }
                else
                {
                    Log.Error("Could not load application icon from embedded resource");
                }
            }
            catch (Exception ex)
            {
                Log.Error(ex, "Failed to load application icon");
            }

        }

        base.OnFrameworkInitializationCompleted();
    }

    private void DisableAvaloniaDataAnnotationValidation()
    {
        // Get an array of plugins to remove
        var dataValidationPluginsToRemove =
            BindingPlugins.DataValidators.OfType<DataAnnotationsValidationPlugin>().ToArray();

        // remove each entry found
        foreach (var plugin in dataValidationPluginsToRemove)
        {
            BindingPlugins.DataValidators.Remove(plugin);
        }
    }
    
    // Helper method to get services from anywhere in the app
    public static T GetService<T>() where T : notnull
        => Current.Services.GetRequiredService<T>();
}