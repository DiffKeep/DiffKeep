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

namespace DiffKeep.ViewModels;

public partial class ImageViewerViewModel : ViewModelBase
{
    private readonly ObservableCollection<ImageItemViewModel> _allImages;
    private readonly IImageParser _imageParser;
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

    public ImageViewerViewModel(ObservableCollection<ImageItemViewModel> images, ImageItemViewModel currentImage)
    {
        _allImages = images;
        _currentIndex = images.IndexOf(currentImage);
        _imageParser = new ImageParser(); // Composite parser that handles all formats
        LoadCurrentImage();
    }

    private async void LoadCurrentImage()
    {
        Debug.Print($"Loading image {_currentIndex}");
        var currentItem = _allImages[_currentIndex];
        ImageSource?.Dispose();
        ImageSource = new Bitmap(currentItem.FilePath!);
        ImageName = currentItem.FileName ?? string.Empty;
        ImageFilePath = currentItem.FilePath ?? string.Empty;
        
        // Add file info
        var fileInfo = new FileInfo(currentItem.FilePath!);
        FileSize = $"{fileInfo.Length / 1024:N0} KB";
        ImageDimensions = $"{ImageSource.PixelSize.Width} × {ImageSource.PixelSize.Height}";
        
        HasPrevious = _currentIndex > 0;
        HasNext = _currentIndex < _allImages.Count - 1;

        await LoadImageMetadataAsync();
    }

    private async Task LoadImageMetadataAsync()
    {
        if (_allImages[_currentIndex].FilePath == null) return;

        try
        {
            var result = await Task.Run(() => _imageParser.ParseImage(_allImages[_currentIndex].FilePath!));
        
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