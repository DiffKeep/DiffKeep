using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Linq;
using System.Threading.Tasks;
using Avalonia.Controls;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using CommunityToolkit.Mvvm.Messaging;
using DiffKeep.Database;
using DiffKeep.Extensions;
using DiffKeep.Messages;
using DiffKeep.Repositories;
using DiffKeep.Services;
using Image = DiffKeep.Models.Image;

namespace DiffKeep.ViewModels;

public partial class ImageGalleryViewModel : ViewModelBase
{
    private readonly IImageRepository _imageRepository;
    private readonly IImageService _imageService;
    private readonly SearchService _searchService;
    private ObservableCollection<ImageItemViewModel> _images;
    private long? _currentLibraryId;
    private string? _currentPath;
    private string? _currentName;
    public Dictionary<long, Bitmap?> Thumbnails;
    public event EventHandler? ImagesCollectionChanged;
    public event Action? ResetScrollRequested;
    public event Action? SaveScrollPositionRequested;
    public event Action? RestoreScrollPositionRequested;


    [ObservableProperty] private ImageItemViewModel? _selectedImage;
    [ObservableProperty] private string? _currentDirectory;
    [ObservableProperty] private ImageSortOption _currentSortOption = ImageSortOption.NewestFirst;
    [ObservableProperty] private string _searchText = string.Empty;
    [ObservableProperty] private string _imagesCount;
    [ObservableProperty] private bool _isLoading;
    [ObservableProperty] private int _totalCount;

    public ObservableCollection<ImageItemViewModel> Images
    {
        get => _images;
        set => SetProperty(ref _images, value);
    }

    public ImageGalleryViewModel(IImageRepository imageRepository, IImageService imageService,
        SearchService searchService)
    {
        _imageRepository = imageRepository;
        _imageService = imageService;
        _searchService = searchService;
        _images = new ObservableCollection<ImageItemViewModel>();
        _currentDirectory = "";

        // Subscribe to library updated messages
        WeakReferenceMessenger.Default.Register<LibraryUpdatedMessage>(this, (r, m) =>
        {
            Debug.WriteLine($"Received message for library updated for library ID {m.LibraryId}");
            if (_currentLibraryId == m.LibraryId || _currentLibraryId == null)
            {
                LoadImagesAsync(null).FireAndForget();
            }
        });
        
        // Subscribe to image deleted messages
        WeakReferenceMessenger.Default.Register<ImageDeletedMessage>(this, (r, m) =>
        {
            Debug.WriteLine($"Gallery deleting from images {m.ImagePath}");
            var imageToRemove = Images.FirstOrDefault(img => img.Path == m.ImagePath);
            if (imageToRemove is not null)
            {
                var index = Images.IndexOf(imageToRemove);
                if (SelectedImage?.Id == imageToRemove.Id)
                {
                    SelectedImage = null;
                }
                Images.Remove(imageToRemove);
                // If there are any images left, select one
                if (Images.Count > 0)
                {
                    // If we deleted the last image, select the new last image
                    // Otherwise, select the image at the same index (which will be the next image)
                    var newIndex = Math.Min(index, Images.Count - 1);
                    SelectedImage = Images[newIndex];
                    SelectedImage.IsSelected = true;
                }
            }
        });
    }

    public async Task LoadImagesAsync(LibraryTreeItem? item)
    {
        if (item != null)
        {
            _currentLibraryId = item.Id;
            _currentPath = item.Path;
            _currentName = item.Name;
        }

        Debug.WriteLine($"Loading images for library {_currentLibraryId}, path: {_currentPath}");
        IsLoading = true;

        try
        {
            IEnumerable<Image> dbImages;
            if (!string.IsNullOrWhiteSpace(SearchText))
            {
                dbImages = await _searchService.TextSearchImagesAsync(SearchText);
            }
            else if (_currentLibraryId == null)
            {
                dbImages = await _imageRepository.GetPagedAllAsync(0, null, CurrentSortOption);
            }
            else if (_currentPath == null)
            {
                dbImages = await _imageRepository.GetPagedByLibraryIdAsync(_currentLibraryId.Value, 0, null,
                    CurrentSortOption);
            }
            else
            {
                dbImages = await _imageRepository.GetPagedByLibraryIdAndPathAsync(_currentLibraryId.Value, _currentPath,
                    0, null, CurrentSortOption);
            }

            TotalCount = dbImages.Count();

            ImagesCount = $"({TotalCount} images)";

            var viewModels = await Task.Run(() =>
                dbImages.Select(image => new ImageItemViewModel(image, this)).ToList());

            await Task.Run(async () =>
            {
                if (Images != null && Images.Count > 0)
                {
                    var selectedId = SelectedImage?.Id;
                    await Dispatcher.UIThread.InvokeAsync(() => SaveScrollPositionRequested?.Invoke());

                    await Task.Run(() =>
                    {
                        Images.Clear();
                        Images = new ObservableCollection<ImageItemViewModel>(viewModels);
                    });

                    await Dispatcher.UIThread.InvokeAsync(() => RestoreScrollPositionRequested?.Invoke());
                    if (selectedId != null)
                    {
                        SelectedImage = Images.FirstOrDefault(image => image.Id == selectedId);
                        if (SelectedImage != null)
                            SelectedImage.IsSelected = true;
                    }
                }
                else
                {
                    Images.Clear();
                    Images = new ObservableCollection<ImageItemViewModel>(viewModels);
                }

                if (ImagesCollectionChanged != null)
                    ImagesCollectionChanged.Invoke(this, EventArgs.Empty);
            });
        }
        finally
        {
            IsLoading = false;
        }
    }

    [RelayCommand]
    private async Task SearchPrompts()
    {
        Debug.WriteLine($"Searching images for {SearchText}");
        ResetScrollRequested?.Invoke();
        await LoadImagesAsync(null);
    }

    [RelayCommand]
    private async Task ClearSearch()
    {
        SearchText = string.Empty;
        await SearchPrompts();
    }

    [RelayCommand]
    private Task SortImagesAsync(ImageSortOption sortOption)
    {
        Debug.WriteLine($"Sorting images by {sortOption}");
        if (CurrentSortOption == sortOption) return Task.CompletedTask;

        CurrentSortOption = sortOption;
        return LoadImagesAsync(null);
    }

    partial void OnCurrentSortOptionChanged(ImageSortOption value)
    {
        Debug.WriteLine($"Current sort option changed to {value}");
        LoadImagesAsync(null).FireAndForget();
    }

    public async Task UpdateVisibleThumbnails(IEnumerable<ImageItemViewModel> visibleImages)
    {
        var visibleImageArray = visibleImages as ImageItemViewModel[] ?? visibleImages.ToArray();
        Debug.WriteLine($"Updating visible thumbnails for {visibleImageArray.Count()} images");

        await Task.Run(async () =>
        {
            // Get thumbnails for visible items and some items ahead/behind
            if (Program.Settings.StoreThumbnails)
                Thumbnails = await _imageRepository.GetThumbnailsByIdsAsync(visibleImageArray.Select(i => i.Id));
            else
            {
                Thumbnails = new Dictionary<long, Bitmap?>();
                var lockObject = new object();

                await Parallel.ForEachAsync(
                    visibleImageArray,
                    new ParallelOptions
                    {
                        MaxDegreeOfParallelism = Environment.ProcessorCount
                    },
                    async (image, token) =>
                    {
                        if (image.Path != null)
                        {
                            var thumbnail = await ImageService.GenerateThumbnailAsync(
                                image.Path,
                                ImageLibraryScanner.ThumbnailSize);

                            lock (lockObject)
                            {
                                Thumbnails[image.Id] = thumbnail;
                            }

                            image.UpdateThumbnail();
                        }
                    });
            }

            // Update the view models
            foreach (var image in Images)
            {
                image.UpdateThumbnail();
            }
        });
    }

    public async Task DeleteImage(ImageItemViewModel image, Window parentWindow)
    {
        await _imageService.DeleteImageAsync(image, parentWindow);
    }
}

public partial class ImageItemViewModel : ViewModelBase
{
    private readonly WeakReference<ImageGalleryViewModel> _galleryViewModel;

    [ObservableProperty] private Bitmap? _thumbnail;
    [ObservableProperty] private bool _isSelected;

    public long Id { get; }
    public string? Path { get; }
    public string? FileName { get; }
    public float? Score { get; }
    public bool HasScore => Score.HasValue;

    public void UpdateThumbnail()
    {
        Thumbnail = _galleryViewModel.TryGetTarget(out var gallery) ? gallery.Thumbnails?.GetValueOrDefault(Id) : null;
    }

    public ImageItemViewModel(Image image, ImageGalleryViewModel galleryViewModel)
    {
        Id = image.Id;
        Path = image.Path;
        FileName = System.IO.Path.GetFileName(image.Path);
        Score = image.Score;
        _galleryViewModel = new WeakReference<ImageGalleryViewModel>(galleryViewModel);
        UpdateThumbnail(); // Initial thumbnail value
    }
}