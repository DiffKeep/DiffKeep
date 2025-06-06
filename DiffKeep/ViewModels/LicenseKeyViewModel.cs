using System;
using System.Threading.Tasks;
using Avalonia.Controls;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using CommunityToolkit.Mvvm.Messaging;
using DiffKeep.Messages;

namespace DiffKeep.ViewModels;

public partial class LicenseKeyViewModel : ObservableObject
{
    private readonly ILicenseService _licenseService;

    [ObservableProperty]
    private string _licenseKey = string.Empty;
    
    [ObservableProperty]
    private string _email = string.Empty;

    [ObservableProperty]
    private string _errorMessage = string.Empty;

    [ObservableProperty]
    private bool _hasError;

    public event EventHandler? RequestClose;

    public LicenseKeyViewModel(ILicenseService licenseService)
    {
        _licenseService = licenseService;
    }

    [RelayCommand]
    private async Task ValidateAsync()
    {
        if (string.IsNullOrWhiteSpace(LicenseKey))
        {
            HasError = true;
            ErrorMessage = "License key cannot be empty";
            return;
        }
        
        if (string.IsNullOrWhiteSpace(Email))
        {
            HasError = true;
            ErrorMessage = "Email is required";
            return;
        }

        if (await _licenseService.ValidateLicenseKeyAsync(LicenseKey, Email))
        {
            await _licenseService.SaveLicenseKeyAsync(LicenseKey, Email);
            RequestClose?.Invoke(this, EventArgs.Empty);
        }
        else
        {
            HasError = true;
            ErrorMessage = "Invalid license key or email";
        }
    }
}