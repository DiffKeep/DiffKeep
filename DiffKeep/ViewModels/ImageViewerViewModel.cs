using System;
using System.Collections.Generic;
using Avalonia.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using DiffKeep.Parsing;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using System.Linq;
using System.Text.Json;
using System.Threading;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using CommunityToolkit.Mvvm.Messaging;
using DiffKeep.Messages;
using DiffKeep.Services;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using Serilog;
using ShadUI;
using JsonSerializer = Newtonsoft.Json.JsonSerializer;
using Window = Avalonia.Controls.Window;

namespace DiffKeep.ViewModels;

public partial class ImageViewerViewModel : ViewModelBase
{
    private readonly ObservableCollection<ImageItemViewModel> _allImages;
    private readonly IImageParser _imageParser;
    private readonly IImageService _imageService;
    private readonly IAppStateService _appStateService;
    private readonly ToastManager _toastManager;
    private int _currentIndex;

    [ObservableProperty] private Bitmap? _imageSource;

    [ObservableProperty] private string _imageName = string.Empty;

    [ObservableProperty] private bool _hasPrevious;

    [ObservableProperty] private bool _hasNext;

    [ObservableProperty] private bool _isInfoPanelVisible;

    [ObservableProperty] private string _detectedTool = string.Empty;

    [ObservableProperty] private string _generationPrompt = string.Empty;

    [ObservableProperty] private List<KeyValuePair<string, string?>>? _rawMetadata;

    [ObservableProperty] private double _infoPanelWidth = 300;

    [ObservableProperty] private string _imageFilePath = string.Empty;

    [ObservableProperty] private string _imageDimensions = string.Empty;

    [ObservableProperty] private string _fileSize = string.Empty;

    public ImageViewerViewModel(ObservableCollection<ImageItemViewModel> images, ImageItemViewModel currentImage,
        IImageService imageService, IAppStateService appStateService, ToastManager toastManager)
    {
        _allImages = images;
        _currentIndex = images.IndexOf(currentImage);
        _imageService = imageService;
        _appStateService = appStateService;
        _toastManager = toastManager;
        _imageParser = new ImageParser(); // Composite parser that handles all formats

        IsInfoPanelVisible = _appStateService.GetInfoPanelVisibility();
        
        // Subscribe to image deleted messages
        WeakReferenceMessenger.Default.Register<ImageDeletedMessage>(this, (r, m) =>
        {
            Log.Debug("Gallery deleting from images {MessageImagePath}", m.ImagePath);
            var imageToRemove = _allImages.FirstOrDefault(img => img.Path == m.ImagePath);
            if (imageToRemove is not null)
            {
                // if the image removed is the one we are currently on, we will need to reload
                bool reload = _allImages[_currentIndex].Id == imageToRemove.Id && _allImages[_currentIndex].Path == imageToRemove.Path;
                _allImages.Remove(imageToRemove);
                if (reload) LoadCurrentImage();
            }
        });
        
        LoadCurrentImage();
    }

    [RelayCommand]
    private async Task CopyPrompt()
    {
        Log.Debug("Copying prompt to clipboard");
        if (string.IsNullOrEmpty(GenerationPrompt)) return;

        if (App.Current.ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            Log.Debug("Got desktop lifetime");
            var clipboard = TopLevel.GetTopLevel(desktop.MainWindow)?.Clipboard;
            if (clipboard != null)
            {
                Log.Debug("Got clipboard");
                using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(20));
                try
                {
                    var clipboardTask = clipboard.SetTextAsync(GenerationPrompt);
                    var timeoutTask = Task.Delay(-1, cts.Token);

                    var completedTask = await Task.WhenAny(clipboardTask, timeoutTask);
                    if (completedTask == clipboardTask)
                    {
                        Log.Debug("Copied text: {S}", GenerationPrompt);
                    }
                    else
                    {
                        Log.Warning("Clipboard operation timed out, but may have succeeded");
                    }
                }
                catch (OperationCanceledException)
                {
                    Log.Warning("Clipboard operation timed out, but may have succeeded");
                }
                catch (Exception ex)
                {
                    Log.Error("Clipboard operation failed: {Exception}", ex);
                }
            }
            else
            {
                Log.Error("Clipboard was null");
            }
        }
    }

    public async void LoadCurrentImage()
    {
        Log.Debug("Loading image {CurrentIndex}", _currentIndex);
        if (_currentIndex < 0 || _currentIndex >= _allImages.Count)
        {
            return;
        }

        try
        {
            var currentItem = _allImages[_currentIndex];
            ImageSource?.Dispose();
            ImageSource = new Bitmap(currentItem.Path);
            // get the file name from the path
            ImageName = Path.GetFileName(currentItem.Path);
            ImageFilePath = currentItem.Path;

            // Add file info
            var fileInfo = new FileInfo(currentItem.Path);
            FileSize = $"{fileInfo.Length / 1024:N0} KB";
            ImageDimensions = $"{ImageSource.PixelSize.Width} × {ImageSource.PixelSize.Height}";

            HasPrevious = _currentIndex > 0;
            HasNext = _currentIndex < _allImages.Count - 1;

            await LoadImageMetadataAsync();
        }
        catch (Exception ex)
        {
            Log.Error("Failed loading image: {Error}", ex.Message);
            _toastManager.CreateToast("Image loading error")
                .WithContent($"The requested image could not be loaded: {ex.Message}")
                .ShowError();
        }
    }

    public async Task<bool> DeleteCurrentImage(Window parentWindow)
    {
        ImageItemViewModel currentImage;
        try
        {
            currentImage = _allImages[_currentIndex];
        }
        catch (ArgumentOutOfRangeException ex)
        {
            Log.Debug("Failed finding image index {CurrentIndex}, trying again after pause", _currentIndex);
            await Task.Delay(100);
            currentImage = _allImages[_currentIndex];
        }

        return await _imageService.DeleteImageAsync(currentImage, parentWindow);
    }

    private async Task LoadImageMetadataAsync()
    {
        try
        {
            var result = await Task.Run(() => _imageParser.ParseImage(_allImages[_currentIndex].Path));

            DetectedTool = result.Tool?.ToString() ?? "Unknown Tool";
            GenerationPrompt = result.PositivePrompt ?? "No prompt found";
            var formattedMetadata = new List<KeyValuePair<string, string?>>();
            if (result.RawMetadata != null)
            {
                foreach (var item in result.RawMetadata)
                {
                    if (IsJsonString(item.Value))
                    {
                        formattedMetadata.Add(new KeyValuePair<string, string?>(
                            item.Key, 
                            FormatJsonString(item.Value)));
                    }
                    else
                    {
                        formattedMetadata.Add(item);
                    }
                }
            }
            
            RawMetadata = formattedMetadata.Count > 0 ? formattedMetadata : 
                new List<KeyValuePair<string, string?>> { new("Error", "No metadata found") };

        }
        catch (Exception ex)
        {
            DetectedTool = "Error detecting tool";
            GenerationPrompt = "Error extracting prompt";
            RawMetadata = new List<KeyValuePair<string, string?>>
                { new("Error", $"Error parsing metadata: {ex.Message}") };
        }
    }
    
    /// <summary>
    /// Checks if a string is a valid JSON string
    /// </summary>
    private bool IsJsonString(string? value)
    {
        if (string.IsNullOrEmpty(value)) return false;
        
        value = value.Trim();
        if (!(value.StartsWith("{") && value.EndsWith("}")) && 
            !(value.StartsWith("[") && value.EndsWith("]")))
            return false;

        try
        {
            // Try to parse it as JSON to validate
            JsonDocument.Parse(value);
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Formats a JSON string to be more readable
    /// </summary>
    private string FormatJsonString(string? json)
    {
        if (string.IsNullOrEmpty(json)) return string.Empty;

        try
        {
            // Parse the JSON
            var parsedJson = JToken.Parse(json);
            
            // Format it with indentation
            return parsedJson.ToString(Formatting.Indented);
        }
        catch (Exception ex)
        {
            Log.Debug("Failed to format JSON: {Error}", ex.Message);
            return json; // Return the original string if formatting fails
        }
    }

    [RelayCommand]
    private void NavigatePrevious()
    {
        if (_currentIndex > 0)
        {
            _currentIndex--;
            LoadCurrentImage();
        }
    }

    [RelayCommand]
    private void NavigateNext()
    {
        if (_currentIndex < _allImages.Count - 1)
        {
            _currentIndex++;
            LoadCurrentImage();
        }
    }
    
    [RelayCommand]
    private void NavigateToFirst()
    {
        if (_allImages.Count > 0 && _currentIndex != 0)
        {
            _currentIndex = 0;
            LoadCurrentImage();
        }
    }

    [RelayCommand]
    private void NavigateToLast()
    {
        if (_allImages.Count > 0 && _currentIndex != _allImages.Count - 1)
        {
            _currentIndex = _allImages.Count - 1;
            LoadCurrentImage();
        }
    }

    /// <summary>
    /// Attempts to navigate to the next image. If not available, navigates to the previous.
    /// If that is not available, don't navigate.
    /// </summary>
    [RelayCommand]
    private void NavigateNextOrPrevious()
    {
        if (_currentIndex > 0)
        {
            _currentIndex--;
            LoadCurrentImage();
        }
        else if (_currentIndex < _allImages.Count - 1)
        {
            _currentIndex++;
            LoadCurrentImage();
        }
    }

    [RelayCommand]
    private void ToggleInfoPanel()
    {
        IsInfoPanelVisible = !IsInfoPanelVisible;
        _appStateService.UpdateInfoPanelVisibility(IsInfoPanelVisible);
    }

    [RelayCommand]
    private void OpenInFileExplorer()
    {
        if (string.IsNullOrEmpty(ImageFilePath) || !File.Exists(ImageFilePath))
            return;

        try
        {
            string filePath = ImageFilePath;

            // Cross-platform implementation
            if (OperatingSystem.IsWindows())
            {
                // On Windows, we can use explorer.exe to select the file
                Process.Start("explorer.exe", $"/select,\"{filePath}\"");
            }
            else if (OperatingSystem.IsMacOS())
            {
                // On macOS, we use the open command with the -R flag to reveal in Finder
                Process.Start("open", $"-R \"{filePath}\"");
            }
            else if (OperatingSystem.IsLinux())
            {
                // On Linux, try different file managers with their specific selection options
                string directory = Path.GetDirectoryName(filePath) ?? string.Empty;
                if (string.IsNullOrEmpty(directory))
                    return;

                bool success = false;

                // Try desktop-environment-specific file managers first with selection capability
                // For GNOME Nautilus (Files)
                try
                {
                    Process.Start("nautilus", $"--select \"{filePath}\"");
                    success = true;
                }
                catch { /* Continue to next option */ }

                // For KDE Dolphin
                if (!success)
                {
                    try
                    {
                        Process.Start("dolphin", $"--select \"{filePath}\"");
                        success = true;
                    }
                    catch { /* Continue to next option */ }
                }

                // For Cinnamon's Nemo
                if (!success)
                {
                    try
                    {
                        Process.Start("nemo", $"\"{filePath}\"");
                        success = true;
                    }
                    catch { /* Continue to next option */ }
                }

                // For XFCE's Thunar
                if (!success)
                {
                    try
                    {
                        // Thunar can select files, but syntax varies by version
                        Process.Start("thunar", $"\"{filePath}\"");
                        success = true;
                    }
                    catch { /* Continue to next option */ }
                }

                // Fallback to xdg-open on the directory if specific file managers failed
                if (!success)
                {
                    try
                    {
                        Process.Start("xdg-open", directory);
                        success = true;
                    }
                    catch { /* Continue to next option */ }
                }

                // Last resort: try common file managers with just the directory
                if (!success)
                {
                    string[] fileManagers = new[] 
                    { 
                        "pcmanfm",      // LXDE
                        "caja",         // MATE
                        "pantheon-files", // Elementary OS
                        "konqueror"     // Older KDE
                    };

                    foreach (string fileManager in fileManagers)
                    {
                        try
                        {
                            Process.Start(fileManager, directory);
                            success = true;
                            break;
                        }
                        catch
                        {
                            // Try the next file manager
                            continue;
                        }
                    }
                }

                // If all else fails, try to open the directory with the default application
                if (!success)
                {
                    try
                    {
                        Process.Start(new ProcessStartInfo
                        {
                            FileName = directory,
                            UseShellExecute = true
                        });
                    }
                    catch (Exception ex)
                    {
                        Log.Error("Failed to open directory: {ExMessage}", ex.Message);
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Log.Error("Error opening file in explorer: {ExMessage}", ex.Message);
        }
    }


    public void Dispose()
    {
        ImageSource?.Dispose();
    }
}