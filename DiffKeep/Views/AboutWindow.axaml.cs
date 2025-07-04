using Avalonia.Controls;
using Avalonia.Interactivity;
using DiffKeep.ViewModels;
using Window = ShadUI.Window;

namespace DiffKeep.Views;

public partial class AboutWindow : Window
{
    public AboutWindow()
    {
        InitializeComponent();
        DataContext = new AboutWindowViewModel();
    }

    private void CloseWindow(object sender, RoutedEventArgs e)
    {
        Close();
    }
}