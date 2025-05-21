using Avalonia.Controls;
using Avalonia.Interactivity;

namespace DiffKeep.Views;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
    }
    
    private async void ShowAboutDialog(object sender, RoutedEventArgs e)
    {
        var aboutWindow = new AboutWindow
        {
            ShowInTaskbar = false
        };
        await aboutWindow.ShowDialog(this);
    }

}