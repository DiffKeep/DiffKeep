using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Linq;
using System.Threading;
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
using Serilog;
using ShadUI;
using Image = DiffKeep.Models.Image;
using Window = Avalonia.Controls.Window;

namespace DiffKeep.ViewModels;

public partial class ImageGalleryViewModel : ViewModelBase
{
    private readonly IImageRepository _imageRepository;
    private readonly IImageService _imageService;
    private readonly SearchService _searchService;
    private readonly ToastManager _toastManager;
    private ObservableCollection<ImageItemViewModel> _images;
    private long? _currentLibraryId;
    private string? _currentPath;
    private string? _currentName;
    public readonly ConcurrentDictionary<long, Bitmap?> Thumbnails = new();
    private CancellationTokenSource? _thumbnailCancellationTokenSource;
    private readonly ConcurrentDictionary<long, DateTime> _thumbnailLastVisibleTime = new();
    private readonly TimeSpan _thumbnailRetentionTime = TimeSpan.FromSeconds(60);
    private Timer? _thumbnailCleanupTimer;
    private readonly object _thumbnailCleanupLock = new object();
    private bool _isThumbnailCleanupRunning = false;
    public event EventHandler? ImagesCollectionChanged;
    public event Action? ResetScrollRequested;
    public event Action? SaveScrollPositionRequested;
    public event Action? RestoreScrollPositionRequested;

    [ObservableProperty] private ImageItemViewModel? _currentImage;
    private ImageItemViewModel? _previousCurrentImage;
    [ObservableProperty] private string? _currentDirectory;
    [ObservableProperty] private ImageSortOption _currentSortOption = ImageSortOption.NewestFirst;
    [ObservableProperty] private string _searchText = string.Empty;
    [ObservableProperty] private string _imagesCount;
    [ObservableProperty] private bool _isLoading;
    [ObservableProperty] private int _totalCount;
    [ObservableProperty] private string _selectedImagesCount = "";

    private ObservableCollection<ImageItemViewModel> _selectedImages = new();

    public ObservableCollection<ImageItemViewModel> SelectedImages => _selectedImages;

    public ObservableCollection<ImageItemViewModel> Images
    {
        get => _images;
        set => SetProperty(ref _images, value);
    }

    private ObservableCollection<SearchTypeEnum> _availableSearchTypes = new();

    public ObservableCollection<SearchTypeEnum> AvailableSearchTypes
    {
        get => _availableSearchTypes;
        set => SetProperty(ref _availableSearchTypes, value);
    }

// Current selected search type
    private SearchTypeEnum _currentSearchType;

    public SearchTypeEnum CurrentSearchType
    {
        get => _currentSearchType;
        set => SetProperty(ref _currentSearchType, value);
    }

    public ImageGalleryViewModel(IImageRepository imageRepository, IImageService imageService,
        SearchService searchService, ToastManager toastManager)
    {
        _imageRepository = imageRepository;
        _imageService = imageService;
        _searchService = searchService;
        _toastManager = toastManager;
        _images = new ObservableCollection<ImageItemViewModel>();
        _currentDirectory = "";

        // Initialize available search types with at least FullText
        AvailableSearchTypes.Add(SearchTypeEnum.FullText);

        // Set default search type
        CurrentSearchType = SearchTypeEnum.FullText;

        if (Program.Settings.UseEmbeddings)
        {
            AvailableSearchTypes.Add(SearchTypeEnum.Semantic);
            AvailableSearchTypes.Add(SearchTypeEnum.Hybrid);
        }

        // Subscribe to library updated messages
        WeakReferenceMessenger.Default.Register<LibraryUpdatedMessage>(this, (r, m) =>
        {
            Log.Debug("Received message for library updated for library ID {MessageLibraryId}", m.LibraryId);
            if (_currentLibraryId == m.LibraryId || _currentLibraryId == null)
            {
                LoadImagesAsync(null, true).FireAndForget();
            }
        });

        // Subscribe to image deleted messages
        WeakReferenceMessenger.Default.Register<ImageDeletedMessage>(this, (r, m) =>
        {
            Log.Debug("Gallery deleting from images {MessageImagePath}", m.ImagePath);
            var imageToRemove = Images.FirstOrDefault(img => img.Path == m.ImagePath);
            if (imageToRemove is not null)
            {
                var index = Images.IndexOf(imageToRemove);
                if (CurrentImage?.Id == imageToRemove.Id)
                {
                    CurrentImage = null;
                }

                // Remove from selection if selected
                if (_selectedImages.Contains(imageToRemove))
                {
                    _selectedImages.Remove(imageToRemove);
                    UpdateSelectedImagesCount();
                }

                Images.Remove(imageToRemove);
                // If there are any images left, select one
                if (Images.Count > 0)
                {
                    // If we deleted the last image, select the new last image
                    // Otherwise, select the image at the same index (which will be the next image)
                    var newIndex = Math.Min(index, Images.Count - 1);
                    CurrentImage = Images[newIndex];
                }
            }
        });

        // load initial images
        LoadImagesAsync(null).FireAndForget();
        
        // Start the thumbnail cleanup timer to run every 15 seconds
        _thumbnailCleanupTimer = new Timer(CleanupThumbnails, null, TimeSpan.FromSeconds(15), TimeSpan.FromSeconds(15));
    }

    public async Task LoadImagesAsync(LibraryTreeItem? item, bool preserveScroll = false)
    {
        if (item != null)
        {
            _currentLibraryId = item.Id;
            _currentPath = item.Path;
            _currentName = item.Name;
        }

        Log.Debug("Loading images for library {CurrentLibraryId}, path: {CurrentPath}", _currentLibraryId, _currentPath);
        IsLoading = true;

        try
        {
            await Task.Run(async () =>
            {
                IEnumerable<Image> dbImages;
                if (!string.IsNullOrWhiteSpace(SearchText))
                {
                    dbImages = await _searchService.TextSearchImagesAsync(SearchText, _currentLibraryId, _currentPath,
                        _currentSearchType);
                }
                else if (_currentLibraryId == null)
                {
                    dbImages = await _imageRepository.GetAllAsync(CurrentSortOption);
                }
                else if (_currentPath == null)
                {
                    dbImages = await _imageRepository.GetByLibraryIdAsync(_currentLibraryId.Value, CurrentSortOption);
                }
                else
                {
                    dbImages = await _imageRepository.GetByLibraryIdAndPathAsync(_currentLibraryId.Value,
                        _currentPath, CurrentSortOption);
                }

                TotalCount = dbImages.Count();

                ImagesCount = $"({TotalCount} images)";

                var viewModels = await Task.Run(() =>
                    dbImages.Select(image => new ImageItemViewModel(image, this)).ToList());
                if (Images != null && Images.Count > 0 && preserveScroll)
                {
                    await Dispatcher.UIThread.InvokeAsync(() => SaveScrollPositionRequested?.Invoke());

                    await Task.Run(() =>
                    {
                        Images?.Clear();
                        Images = new ObservableCollection<ImageItemViewModel>(viewModels);
                    });

                    await Dispatcher.UIThread.InvokeAsync(() => RestoreScrollPositionRequested?.Invoke());
                }
                else
                {
                    Images.Clear();
                    Images = new ObservableCollection<ImageItemViewModel>(viewModels);
                }

                // we don't want to mess with the selection if we are just loading some new images
                if (!preserveScroll)
                {
                    // Clear selected images when loading new images
                    _selectedImages.Clear();
                    UpdateSelectedImagesCount();
                }

                if (ImagesCollectionChanged != null)
                {
                    Log.Debug("Images collection changed");
                    ImagesCollectionChanged.Invoke(this, EventArgs.Empty);
                }
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
        Log.Debug("Searching images for {S}", SearchText);
        ResetScrollRequested?.Invoke();
        try
        {
            await LoadImagesAsync(null);
        }
        catch (Exception ex)
        {
            _toastManager.CreateToast("Error searching images")
                .WithContent(ex.Message)
                .WithAction("Open Settings",
                    () => WeakReferenceMessenger.Default.Send(new ShowSettingsMessage()))
                .ShowError();
            Log.Error("Error searching for images: {ExMessage}", ex.Message);
        }
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
        Log.Debug("Sorting images by {ImageSortOption}", sortOption);
        if (CurrentSortOption == sortOption) return Task.CompletedTask;

        CurrentSortOption = sortOption;
        return LoadImagesAsync(null);
    }

    partial void OnCurrentSortOptionChanged(ImageSortOption value)
    {
        Log.Debug("Current sort option changed to {ImageSortOption}", value);
        LoadImagesAsync(null).FireAndForget();
    }

    public async Task UpdateVisibleThumbnails(IEnumerable<ImageItemViewModel> visibleImages)
    {
        var visibleImageArray = visibleImages as ImageItemViewModel[] ?? visibleImages.ToArray();
        Log.Debug("Updating visible thumbnails for {Count} images", visibleImageArray.Count());
        Log.Debug("Size of thumbnails currently: {ThumbnailsCount}", Thumbnails?.Count);
        
        // Cancel any ongoing thumbnail generation
        _thumbnailCancellationTokenSource?.Cancel();
        _thumbnailCancellationTokenSource = new CancellationTokenSource();
        var cancellationToken = _thumbnailCancellationTokenSource.Token;
        
        // Get the current time once for all visible images
        var now = DateTime.UtcNow;
        
        // Update the last visible time for all visible images
        var visibleIds = new HashSet<long>();
        foreach (var image in visibleImageArray)
        {
            visibleIds.Add(image.Id);
            _thumbnailLastVisibleTime[image.Id] = now;
        }
        
        await Task.Run(async () =>
        {
            // Get thumbnails for visible items and some items ahead/behind
            if (Program.Settings.StoreThumbnails)
            {
                // Database-stored thumbnail scenario
                Log.Debug("Fetching thumbnails from database");
                var dbThumbnails = await _imageRepository
                    .GetThumbnailsByIdsAsync(visibleIds);
                
                // Clear existing thumbnails and add new ones from the database
                Thumbnails.Clear();
                foreach (var kvp in dbThumbnails)
                {
                    Thumbnails.TryAdd(kvp.Key, kvp.Value);
                }
                
                // Get the old keys before clearing
                var oldKeys = Thumbnails.Keys.ToList();
                
                // Update all image items that previously had thumbnails
                Dispatcher.UIThread.Post(() =>
                {
                    foreach (var image in Images.Where(i => oldKeys.Contains(i.Id)))
                    {
                        image.UpdateThumbnail();
                    }
                });
            }
            else
            {
                // On-the-fly thumbnail generation scenario
                var missingImages = visibleImageArray.Where(img => !Thumbnails.ContainsKey(img.Id)).ToArray();
                
                // Generate missing thumbnails
                try
                {
                    Log.Debug("Generating thumbnails for {MissingImagesLength} images", missingImages.Length);
                    await Parallel.ForEachAsync(
                        missingImages,
                        new ParallelOptions
                        {
                            MaxDegreeOfParallelism = Environment.ProcessorCount,
                            CancellationToken = cancellationToken
                        },
                        async (image, token) =>
                        {
                            token.ThrowIfCancellationRequested();
                            
                            if (image.Path != null)
                            {
                                var thumbnail = await ImageService.GenerateThumbnailAsync(
                                    image.Path,
                                    ImageLibraryScanner.ThumbnailSize);
                                
                                // Check again if we're cancelled before adding to the collection
                                if (!token.IsCancellationRequested)
                                {
                                    Dispatcher.UIThread.Post(() =>
                                    {
                                        // Update the Thumbnails dictionary immediately so it's available
                                        Thumbnails[image.Id] = thumbnail;
                                        
                                        // Update UI for this image
                                        image.UpdateThumbnail();
                                    });
                                }
                                else
                                {
                                    // If cancelled, dispose the thumbnail we just created
                                    thumbnail?.Dispose();
                                }
                            }
                            else
                            {
                                Log.Debug("Could not find image for path {ImagePath}", image.Path);
                            }
                        });
                }
                catch (OperationCanceledException)
                {
                    Log.Debug("Thumbnail generation was cancelled");
                }
                catch (Exception ex)
                {
                    Log.Debug("Error generating thumbnails: {ExMessage}", ex.Message);
                }
            }
        }, cancellationToken);
        
        Log.Debug("Finished fetching thumbnails for {Length} images", visibleImageArray.Length);
    }
    
    private async void CleanupThumbnails(object? state)
    {
        // Prevent multiple cleanup operations from running simultaneously
        if (_isThumbnailCleanupRunning || Thumbnails.IsEmpty)
            return;
            
        lock (_thumbnailCleanupLock)
        {
            if (_isThumbnailCleanupRunning)
                return;
                
            _isThumbnailCleanupRunning = true;
        }
        
        try
        {
            // Find the most recent thumbnail timestamp
            DateTime mostRecentTimestamp = DateTime.MinValue;
            foreach (var timestamp in _thumbnailLastVisibleTime.Values)
            {
                if (timestamp > mostRecentTimestamp)
                {
                    mostRecentTimestamp = timestamp;
                }
            }
        
            // If we have no timestamps at all, there's nothing to clean up
            if (mostRecentTimestamp == DateTime.MinValue)
                return;
            
            // Calculate the cutoff time as 5 seconds before the most recent activity
            var cutoffTime = mostRecentTimestamp.AddSeconds(-5);
            var keysToRemove = new List<long>();
        
            // Find thumbnails older than the cutoff time
            foreach (var entry in _thumbnailLastVisibleTime)
            {
                if (entry.Value < cutoffTime)
                {
                    keysToRemove.Add(entry.Key);
                }
            }
            
            if (keysToRemove.Count > 0)
            {
                Log.Debug("Cleaning up {Count} expired thumbnails", keysToRemove.Count);
                
                // Process removals in batches to reduce UI impact
                const int batchSize = 10;
                for (int i = 0; i < keysToRemove.Count; i += batchSize)
                {
                    var batch = keysToRemove.Skip(i).Take(batchSize);
                    
                    foreach (var key in batch)
                    {
                        // Remove the thumbnail from the image first, so the UI isn't trying to draw something that doesn't exist
                        await Dispatcher.UIThread.InvokeAsync(() =>
                        {
                            var affectedImage = Images.FirstOrDefault(img => img.Id == key);
                            affectedImage?.RemoveThumbnail();
                        });
                        // Remove the timestamp entry
                        _thumbnailLastVisibleTime.TryRemove(key, out _);
                        
                        // Remove and dispose the thumbnail
                        if (Thumbnails.TryRemove(key, out var bitmap))
                        {
                            bitmap?.Dispose();
                        }
                    }
                    
                    // Small delay between batches to prevent UI freezes
                    Thread.Sleep(10);
                }
            }
        }
        catch (Exception ex)
        {
            Log.Debug("Error during thumbnail cleanup: {ExMessage}", ex.Message);
        }
        finally
        {
            lock (_thumbnailCleanupLock)
            {
                _isThumbnailCleanupRunning = false;
            }
        }
    }

    public async Task DeleteImage(ImageItemViewModel image, Window parentWindow)
    {
        await _imageService.DeleteImageAsync(image, parentWindow);
    }

    public async Task DeleteImages(List<ImageItemViewModel> images, Window parentWindow)
    {
        await _imageService.DeleteImagesAsync(images, parentWindow);
    }

    public void AddToSelection(ImageItemViewModel image)
    {
        if (_previousCurrentImage != null && !_selectedImages.Contains(_previousCurrentImage))
        {
            _selectedImages.Add(_previousCurrentImage);
        }

        if (!_selectedImages.Contains(image))
        {
            _selectedImages.Add(image);
        }

        UpdateSelectedImagesCount();
        image.RefreshSelectionState(); // Notify the item
    }

    public void RemoveFromSelection(ImageItemViewModel image)
    {
        if (_selectedImages.Contains(image))
        {
            _selectedImages.Remove(image);
            UpdateSelectedImagesCount();
            image.RefreshSelectionState(); // Notify the item
        }
    }

    public void ClearSelection()
    {
        // Cache the items that were selected
        var previouslySelected = new List<ImageItemViewModel>(_selectedImages);

        _selectedImages.Clear();

        UpdateSelectedImagesCount();

        // Notify all previously selected items
        foreach (var item in previouslySelected)
        {
            item.RefreshSelectionState();
        }

        // Also notify current item if it wasn't in the list
        CurrentImage?.RefreshSelectionState();
    }

    public void SelectRange(ImageItemViewModel from, ImageItemViewModel to)
    {
        var fromIndex = Images.IndexOf(from);
        var toIndex = Images.IndexOf(to);

        if (fromIndex == -1 || toIndex == -1)
            return;

        var startIndex = Math.Min(fromIndex, toIndex);
        var endIndex = Math.Max(fromIndex, toIndex);

        for (int i = startIndex; i <= endIndex; i++)
        {
            var image = Images[i];
            AddToSelection(image);
        }
    }

    private void UpdateSelectedImagesCount()
    {
        SelectedImagesCount = _selectedImages.Count > 0 ? $"({_selectedImages.Count} Selected)" : "";
    }

    partial void OnCurrentImageChanged(ImageItemViewModel? value)
    {
        // Previously current image
        if (_previousCurrentImage != null)
        {
            _previousCurrentImage.RefreshSelectionState();
        }

        _previousCurrentImage = value;

        // Notify the new current image
        value?.RefreshSelectionState();
    }
}

public partial class ImageItemViewModel : ViewModelBase
{
    private readonly WeakReference<ImageGalleryViewModel> _galleryViewModel;

    [ObservableProperty] private Bitmap? _thumbnail;

    public long Id { get; }
    public string? Path { get; }
    public string? FileName { get; }
    public float? Score { get; }
    public bool HasScore => Score.HasValue;

    // Read-only property to check if this item is in the selected images collection
    public bool IsSelected =>
        _galleryViewModel.TryGetTarget(out var gallery) &&
        gallery.SelectedImages.Contains(this);

    // Read-only property to check if this is the current item with keyboard focus
    public bool IsCurrent =>
        _galleryViewModel.TryGetTarget(out var gallery) &&
        gallery.CurrentImage == this;

    public void UpdateThumbnail()
    {
        // Set new thumbnail (safely)
        if (_galleryViewModel.TryGetTarget(out var gallery))
        {
            gallery.Thumbnails.TryGetValue(Id, out var newThumbnail);

            // Only update if we have a valid thumbnail or need to clear it
            if (newThumbnail != null)
            {
                Thumbnail = newThumbnail;
            }
        }
        else
        {
            Log.Error("Cound not get gallery view model when trying to update thumbnail");
        }
    }

    public void RemoveThumbnail()
    {
        Thumbnail = null;
    }

    // Trigger property change notification for selection state
    public void RefreshSelectionState()
    {
        OnPropertyChanged(nameof(IsSelected));
        OnPropertyChanged(nameof(IsCurrent));
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