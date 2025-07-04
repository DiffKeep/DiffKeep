using Avalonia;
using Avalonia.Controls;
using DiffKeep.ViewModels;
using Microsoft.Extensions.DependencyInjection;
using Window = ShadUI.Window;

namespace DiffKeep.Views;

public partial class LicenseKeyWindow : Window
{
    public LicenseKeyWindow()
    {
        InitializeComponent();
        var viewModel = new LicenseKeyViewModel(Program.Services.GetRequiredService<ILicenseService>());
        viewModel.RequestClose += (s, e) => Close();
        DataContext = viewModel;
    }
}