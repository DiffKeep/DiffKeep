using Avalonia.Controls;
using Avalonia.Interactivity;
using DiffKeep.ViewModels;
using Microsoft.Extensions.DependencyInjection;
using Window = ShadUI.Window;

namespace DiffKeep.Views;

public partial class SettingsWindow : Window
{
    public SettingsWindow()
    {
        InitializeComponent();
        Loaded += (s, e) =>
        {
            if (DataContext is SettingsViewModel vm)
            {
                vm.LoadCurrentSettings();
            }
        };

    }

    private void OnCancelClick(object? sender, RoutedEventArgs e)
    {
        Close();
    }
}