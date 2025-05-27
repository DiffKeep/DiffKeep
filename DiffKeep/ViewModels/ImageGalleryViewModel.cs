using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Linq;
using System.Threading.Tasks;
using Avalonia.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using DiffKeep.Extensions;
using DiffKeep.Repositories;
using Image = DiffKeep.Models.Image;

namespace DiffKeep.ViewModels;

public partial class ImageGalleryViewModel : ViewModelBase
{
    private readonly IImageRepository _imageRepository;
    private ObservableCollection<ImageItemViewModel> _images;
    private long? _currentLibraryId;
    private string? _currentPath;
    public event EventHandler? ImagesCollectionChanged;
    public event Action? ResetScrollRequested;
    
    [ObservableProperty]
    private ImageItemViewModel? _selectedImage;
    
    [ObservableProperty]
    private string? _currentDirectory;
    
    [ObservableProperty]
    private ImageSortOption _currentSortOption = ImageSortOption.NewestFirst;

    public ObservableCollection<ImageItemViewModel> Images
    {
        get => _images;
        set => SetProperty(ref _images, value);
    }

    public ImageGalleryViewModel(IImageRepository imageRepository)
    {
        _imageRepository = imageRepository;
        _images = new ObservableCollection<ImageItemViewModel>();
        _currentDirectory = "";
        LoadImagesForLibraryAsync(null).FireAndForget();
    }

    public async Task LoadImagesForLibraryAsync(long? libraryId, string? path = null)
    {
        Debug.WriteLine($"Loading images for library {libraryId}, path: {path}");
        _currentLibraryId = libraryId;
        _currentPath = path;
        Images.Clear();

        IEnumerable<Image> dbImages;
        if (libraryId == null)
        {
            dbImages = await _imageRepository.GetAllAsync(CurrentSortOption);
            CurrentDirectory = "All Libraries";
        }
        else if (path == null)
        {
            dbImages = await _imageRepository.GetByLibraryIdAsync((long)libraryId, CurrentSortOption);
            CurrentDirectory = "Library ID #" + libraryId;
        }
        else
        {
            dbImages = await _imageRepository.GetByLibraryIdAndPathAsync((long)libraryId, path, CurrentSortOption);
            CurrentDirectory = path;
        }
        
        Debug.WriteLine($"Loaded {dbImages.Count()} images");
        
        // Request scroll reset before updating images
        ResetScrollRequested?.Invoke();

        foreach (var image in dbImages)
        {
            var viewModel = new ImageItemViewModel(image);
            Images.Add(viewModel);
        }
        Debug.WriteLine($"Created {Images.Count} view models");
        
        // Raise the collection changed event after loading new images
        ImagesCollectionChanged?.Invoke(this, EventArgs.Empty);
    }
    
    [RelayCommand]
    private Task SortImagesAsync(ImageSortOption sortOption)
    {
        Debug.WriteLine($"Sorting images by {sortOption}");
        if (CurrentSortOption == sortOption) return Task.CompletedTask;
        
        CurrentSortOption = sortOption;
        return _currentLibraryId.HasValue 
            ? LoadImagesForLibraryAsync(_currentLibraryId.Value) 
            : Task.CompletedTask;
    }
    
    partial void OnCurrentSortOptionChanged(ImageSortOption value)
    {
        Debug.WriteLine($"Current sort option changed to {value}");
        LoadImagesForLibraryAsync(_currentLibraryId, _currentPath).FireAndForget();
    }
    
    public async Task UpdateVisibleThumbnails(IEnumerable<long> visibleIds)
    {
        // Get thumbnails for visible items and some items ahead/behind
        var thumbnails = await _imageRepository.GetThumbnailsByIdsAsync(visibleIds);
    
        foreach (var image in Images)
        {
            if (thumbnails.TryGetValue(image.Id, out var thumbnail))
            {
                image.Thumbnail = thumbnail;
            } else
            {
                image.Thumbnail = null;
            }
        }
    }
}

public partial class ImageItemViewModel : ViewModelBase
{
    private readonly Models.Image _image;
    private Bitmap? _thumbnail;

    public long Id => _image.Id;
    public string Path => _image.Path;
    public string FileName => System.IO.Path.GetFileName(Path);
    public string Hash => _image.Hash;
    public string? PositivePrompt => _image.PositivePrompt;
    public string? NegativePrompt => _image.NegativePrompt;
    public DateTime Created => _image.Created;
    public Bitmap? Thumbnail
    {
        get => _thumbnail ?? _image.Thumbnail;
        set => SetProperty(ref _thumbnail, value);
    }
    
    [ObservableProperty]
    private bool _isSelected;

    public ImageItemViewModel(Models.Image image)
    {
        _image = image;
    }
}