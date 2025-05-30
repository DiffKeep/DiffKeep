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
using System.Threading;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using DiffKeep.Services;

namespace DiffKeep.ViewModels;

public partial class ImageViewerViewModel : ViewModelBase
{
    private readonly ObservableCollection<ImageItemViewModel> _allImages;
    private readonly IImageParser _imageParser;
    private readonly IImageService _imageService;
    private int _currentIndex;

    [ObservableProperty]
    private Bitmap? _imageSource;

    [ObservableProperty]
    private string _imageName = string.Empty;

    [ObservableProperty]
    private bool _hasPrevious;

    [ObservableProperty]
    private bool _hasNext;

    [ObservableProperty]
    private bool _isInfoPanelVisible;

    [ObservableProperty]
    private string _detectedTool = string.Empty;

    [ObservableProperty]
    private string _generationPrompt = string.Empty;

    [ObservableProperty]
    private List<KeyValuePair<string, string?>>? _rawMetadata;
    
    [ObservableProperty]
    private double _infoPanelWidth = 300;

    [ObservableProperty]
    private string _imageFilePath = string.Empty;
    
    [ObservableProperty]
    private string _imageDimensions = string.Empty;

    [ObservableProperty]
    private string _fileSize = string.Empty;

    public ImageViewerViewModel(ObservableCollection<ImageItemViewModel> images, ImageItemViewModel currentImage, IImageService imageService)
    {
        _allImages = images;
        _currentIndex = images.IndexOf(currentImage);
        _imageService = imageService;
        _imageParser = new ImageParser(); // Composite parser that handles all formats
        LoadCurrentImage();
    }
    
    [RelayCommand]
    private async Task CopyPrompt()
    {
        Debug.Print("Copying prompt to clipboard");
        if (string.IsNullOrEmpty(GenerationPrompt)) return;

        if (App.Current.ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            Debug.Print("Got desktop lifetime");
            var clipboard = TopLevel.GetTopLevel(desktop.MainWindow)?.Clipboard;
            if (clipboard != null)
            {
                Debug.Print("Got clipboard");
                using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(20));
                try
                {
                    var clipboardTask = clipboard.SetTextAsync(GenerationPrompt);
                    var timeoutTask = Task.Delay(-1, cts.Token);

                    var completedTask = await Task.WhenAny(clipboardTask, timeoutTask);
                    if (completedTask == clipboardTask)
                    {
                        Debug.Print($"Copied text: {GenerationPrompt}");
                    }
                    else
                    {
                        Debug.Print("Clipboard operation timed out, but may have succeeded");
                    }
                }
                catch (OperationCanceledException)
                {
                    Debug.Print("Clipboard operation timed out, but may have succeeded");
                }
                catch (Exception ex)
                {
                    Debug.Print($"Clipboard operation failed: {ex}");
                }
            }
            else
            {
                Debug.Print("Clipboard was null");
            }
        }
    }

    public async void LoadCurrentImage()
    {
        Debug.Print($"Loading image {_currentIndex}");
        if (_currentIndex < 0 || _currentIndex >= _allImages.Count)
        {
            return;
        }
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
    
    public async Task<bool> DeleteCurrentImage(Window parentWindow)
    {
        ImageItemViewModel currentImage;
        try
        {
            currentImage = _allImages[_currentIndex];
        }
        catch (ArgumentOutOfRangeException ex)
        {
            Debug.WriteLine($"Failed finding image index {_currentIndex}, trying again after pause");
            await Task.Delay(100);
            currentImage = _allImages[_currentIndex];
        }

        var result = await _imageService.DeleteImageAsync(currentImage, parentWindow);
        if (result)
        {
            // Remove from gallery
            _allImages.Remove(currentImage);
        }
        return result;
    }

    private async Task LoadImageMetadataAsync()
    {
        try
        {
            var result = await Task.Run(() => _imageParser.ParseImage(_allImages[_currentIndex].Path));
        
            DetectedTool = result.Tool?.ToString() ?? "Unknown Tool";
            GenerationPrompt = result.Prompt ?? "No prompt found";
            RawMetadata = result.RawMetadata?.ToList() ?? new List<KeyValuePair<string, string?>> { new("Error", "No metadata found") };
        }
        catch (Exception ex)
        {
            DetectedTool = "Error detecting tool";
            GenerationPrompt = "Error extracting prompt";
            RawMetadata = new List<KeyValuePair<string, string?>> { new("Error", $"Error parsing metadata: {ex.Message}") };
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
    }

    public void Dispose()
    {
        ImageSource?.Dispose();
    }
}