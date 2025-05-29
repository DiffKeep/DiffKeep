using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using DiffKeep.Extensions;
using DiffKeep.Repositories;
using Image = DiffKeep.Models.Image;

namespace DiffKeep.ViewModels;

public partial class ImageGalleryViewModel : ViewModelBase
{
    private const int PAGE_SIZE = 300;
    private int _currentOffset;
    private bool _isLoadingMore;
    private CancellationTokenSource? _loadingCts;

    private readonly IImageRepository _imageRepository;
    private ObservableCollection<ImageItemViewModel> _images;
    private long? _currentLibraryId;
    private string? _currentPath;
    private string? _currentName;
    public event EventHandler? ImagesCollectionChanged;
    public event Action? ResetScrollRequested;
    
    [ObservableProperty]
    private ImageItemViewModel? _selectedImage;
    [ObservableProperty]
    private string? _currentDirectory;
    [ObservableProperty]
    private ImageSortOption _currentSortOption = ImageSortOption.NewestFirst;
    [ObservableProperty]
    private string _searchText = string.Empty;
    [ObservableProperty]
    private string _imagesCount;
    [ObservableProperty]
    private bool _isLoading;
    [ObservableProperty]
    private double _scrollOffset;
    [ObservableProperty]
    private double _viewportHeight;
    [ObservableProperty]
    private double _extentHeight;
    [ObservableProperty]
    private int _totalCount;

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
    }

    public void UpdateVirtualHeight(int columnCount, double itemHeight)
    {
        if (columnCount <= 0) return;
        
        // Calculate how many rows we'll need for all images
        var totalRows = Math.Ceiling((double)_totalCount / columnCount);
        ExtentHeight = totalRows * itemHeight;
        Debug.WriteLine($"Updated virtual height to {ExtentHeight} for {_totalCount} items in {columnCount} columns");
    }

    public async Task LoadImagesAsync(LibraryTreeItem item)
    {
        // Cancel any ongoing loading
        _loadingCts?.Cancel();
        _loadingCts = new CancellationTokenSource();
        
        Debug.WriteLine($"Loading images for library {item.Id}, path: {item.Path}");
        IsLoading = true;
        _currentOffset = 0;
        _currentLibraryId = item.Id;
        _currentPath = item.Path;
        _currentName = item.Name;

        try
        {
            // First, get only the total count
            if (!String.IsNullOrWhiteSpace(SearchText))
            {
                TotalCount = await _imageRepository.GetSearchCountAsync(SearchText, _currentLibraryId, _currentPath);
            }
            else
            {
                TotalCount = await _imageRepository.GetCountAsync(item.Id, item.Path);
            }

            ImagesCount = $"({TotalCount} images)";
        
            // Clear existing images
            Images.Clear();

            // Load initial page
            await LoadMoreImagesAsync(_loadingCts.Token);
        
            // Note: Initial ExtentHeight will be set when ItemsRepeater_LayoutUpdated is called
        }
        finally
        {
            IsLoading = false;
        }
    }

    private async Task LoadMoreImagesAsync(CancellationToken ct)
    {
        if (_isLoadingMore || _currentOffset >= TotalCount) return;
        Debug.WriteLine($"Loading more images for library {_currentLibraryId}, path: {_currentPath}");
        
        _isLoadingMore = true;
        try
        {
            IEnumerable<Image> dbImages;
            if (!string.IsNullOrWhiteSpace(SearchText))
            {
                dbImages = await _imageRepository.SearchByPromptAsync(SearchText, _currentOffset, PAGE_SIZE, _currentLibraryId, _currentPath);
            }
            else if (_currentLibraryId == null)
            {
                dbImages = await _imageRepository.GetPagedAllAsync(_currentOffset, PAGE_SIZE, CurrentSortOption);
            }
            else if (_currentPath == null)
            {
                dbImages = await _imageRepository.GetPagedByLibraryIdAsync(_currentLibraryId.Value, _currentOffset, PAGE_SIZE, CurrentSortOption);
            }
            else
            {
                dbImages = await _imageRepository.GetPagedByLibraryIdAndPathAsync(_currentLibraryId.Value, _currentPath, _currentOffset, PAGE_SIZE, CurrentSortOption);
            }

            if (ct.IsCancellationRequested) return;

            var viewModels = await Task.Run(() => 
                dbImages.Select(image => new ImageItemViewModel(image)).ToList(), ct);

            if (ct.IsCancellationRequested) return;

            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                foreach (var vm in viewModels)
                {
                    Images.Add(vm);
                }
            }, DispatcherPriority.Background);

            _currentOffset += viewModels.Count;
        }
        finally
        {
            _isLoadingMore = false;
        }
    }

    // Call this when scroll position changes
    [RelayCommand]
    public async Task OnScrollChanged()
    {
        Debug.WriteLine($"ScrollOffset: {ScrollOffset} Viewport Height: {ViewportHeight} ExtentHeight: {ExtentHeight}");
        
        // Calculate which range of items should be visible based on scroll position
        var itemsPerViewport = (int)(ViewportHeight / (ExtentHeight / TotalCount));
        var buffer = itemsPerViewport * 2; // Buffer of 2 viewport heights worth of items
        
        // Calculate the target offset based on scroll position
        var scrollProgress = ScrollOffset / ExtentHeight;
        var targetOffset = (int)(scrollProgress * TotalCount);
        
        // Adjust target offset to ensure we load items before and after the visible area
        var startOffset = Math.Max(0, targetOffset - buffer);
        var endOffset = Math.Min(TotalCount, targetOffset + itemsPerViewport + buffer);
        
        // Check if we need to load this range
        if (!IsRangeLoaded(startOffset, endOffset))
        {
            Debug.WriteLine($"Loading images for range {startOffset} to {endOffset}");
            await LoadImagesForRangeAsync(startOffset, endOffset, _loadingCts?.Token ?? CancellationToken.None);
        }
    }

    private bool IsRangeLoaded(int startOffset, int endOffset)
    {
        // Check if we have items in this range
        return Images.Any(img => img.Index >= startOffset && img.Index < endOffset);
    }

    private async Task LoadImagesForRangeAsync(int startOffset, int endOffset, CancellationToken ct)
    {
        if (_isLoadingMore) return;
        
        _isLoadingMore = true;
        try
        {
            // First, ensure we have placeholder items for the entire range
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                // Fill any gaps before our range
                if (Images.Count == 0 || Images[0].Index > 0)
                {
                    for (int i = 0; i < startOffset; i++)
                    {
                        if (!Images.Any(img => img.Index == i))
                        {
                            Images.Add(new PlaceholderImageItem(i));
                        }
                    }
                }

                // Fill any gaps in and after our range up to endOffset
                for (int i = startOffset; i < endOffset; i++)
                {
                    if (!Images.Any(img => img.Index == i))
                    {
                        Images.Add(new PlaceholderImageItem(i));
                    }
                }

                // Sort the collection by index
                var sorted = Images.OrderBy(x => x.Index).ToList();
                Images.Clear();
                foreach (var item in sorted)
                {
                    Images.Add(item);
                }
            });

            // Load actual images
            IEnumerable<Image> dbImages;
            // ... your existing database loading code ...

            if (!string.IsNullOrWhiteSpace(SearchText))
            {
                dbImages = await _imageRepository.SearchByPromptAsync(SearchText, startOffset, endOffset - startOffset, _currentLibraryId, _currentPath);
            }
            else if (_currentLibraryId == null)
            {
                dbImages = await _imageRepository.GetPagedAllAsync(startOffset, endOffset - startOffset, CurrentSortOption);
            }
            else if (_currentPath == null)
            {
                dbImages = await _imageRepository.GetPagedByLibraryIdAsync(_currentLibraryId.Value, startOffset, endOffset - startOffset, CurrentSortOption);
            }
            else
            {
                dbImages = await _imageRepository.GetPagedByLibraryIdAndPathAsync(_currentLibraryId.Value, _currentPath, startOffset, endOffset - startOffset, CurrentSortOption);
            }

            if (ct.IsCancellationRequested) return;

            var viewModels = await Task.Run(() => 
                dbImages.Select((image, idx) => new ImageItemViewModel(image) { Index = startOffset + idx }).ToList(), ct);

            if (ct.IsCancellationRequested) return;

            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                // Replace placeholders with actual items
                foreach (var vm in viewModels)
                {
                    var placeholder = Images.FirstOrDefault(x => x.Index == vm.Index);
                    if (placeholder != null)
                    {
                        var index = Images.IndexOf(placeholder);
                        Images[index] = vm;
                    }
                }
            }, DispatcherPriority.Background);
        }
        finally
        {
            _isLoadingMore = false;
        }
    }
    
    [RelayCommand]
    private async Task SearchPrompts()
    {
        Debug.WriteLine($"Searching images for {SearchText}");
        ResetScrollRequested?.Invoke();
        await LoadImagesAsync(new LibraryTreeItem
        {
            Name = _currentName,
            Id = _currentLibraryId,
            Path = _currentPath,
        });
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
        return LoadImagesAsync(new LibraryTreeItem
            {
                Id = _currentLibraryId,
                Path = _currentPath,
                Name = _currentName,
            });
    }
    
    partial void OnCurrentSortOptionChanged(ImageSortOption value)
    {
        Debug.WriteLine($"Current sort option changed to {value}");
        LoadImagesAsync(new LibraryTreeItem
        {
            Id = _currentLibraryId,
            Path = _currentPath,
            Name = _currentName,
        }).FireAndForget();
    }
    
    public async Task UpdateVisibleThumbnails(IEnumerable<long> visibleIds)
    {
        Debug.WriteLine($"Updating visible thumbnails for {visibleIds.Count()} images");
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
    public int Index {get; set;}
    public virtual bool IsPlaceholder => false;
    public virtual bool IsRealImage => true;
    
    [ObservableProperty]
    private bool _isSelected;

    public ImageItemViewModel(Models.Image image)
    {
        _image = image;
    }
}

public class PlaceholderImageItem : ImageItemViewModel
{
    public override bool IsPlaceholder => true;
    public override bool IsRealImage => false;

    public PlaceholderImageItem(int index) : base(null!)
    {
        Index = index;
    }
}