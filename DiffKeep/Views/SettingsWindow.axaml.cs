using Avalonia.Controls;
using Avalonia.Interactivity;
using DiffKeep.ViewModels;

namespace DiffKeep.Views;

public partial class SettingsWindow : Window
{
    public SettingsWindow()
    {
        InitializeComponent();
        DataContext = new SettingsViewModel(Program.Settings);
    }

    private void OnCancelClick(object? sender, RoutedEventArgs e)
    {
        Close();
    }
}