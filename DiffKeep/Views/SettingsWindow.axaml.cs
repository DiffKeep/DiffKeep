using Avalonia.Controls;
using Avalonia.Interactivity;
using DiffKeep.ViewModels;
using Microsoft.Extensions.DependencyInjection;

namespace DiffKeep.Views;

public partial class SettingsWindow : Window
{
    public SettingsWindow()
    {
        InitializeComponent();
        DataContext = Program.Services.GetRequiredService<SettingsViewModel>();
    }

    private void OnCancelClick(object? sender, RoutedEventArgs e)
    {
        Close();
    }
}