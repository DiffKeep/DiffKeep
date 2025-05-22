using System;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using Avalonia.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using NetVips;
using System.Threading.Tasks;
using System.Threading;
using Avalonia.Threading;

namespace DiffKeep.ViewModels;

public partial class ImageGalleryViewModel : ViewModelBase
{
    [ObservableProperty]
    private ObservableCollection<ImageItemViewModel> _images = new();

    [ObservableProperty]
    private ImageItemViewModel? _selectedImage;

    [ObservableProperty]
    private string? _currentDirectory;

    private readonly string[] _supportedExtensions = { ".jpg", ".jpeg", ".png", ".webp" };
    private const int ThumbnailSize = 200;
    private readonly SemaphoreSlim _throttle = new(Environment.ProcessorCount); // Limit concurrent operations
    private CancellationTokenSource? _cancellationTokenSource;

    public async Task LoadImagesFromDirectory(string directory)
    {
        // Cancel any ongoing operations
        _cancellationTokenSource?.Cancel();
        _cancellationTokenSource?.Dispose();
        _cancellationTokenSource = new CancellationTokenSource();

        CurrentDirectory = directory;
        Images.Clear();
        
        try 
        {
            await LoadImagesRecursively(directory, _cancellationTokenSource.Token);
        }
        catch (OperationCanceledException)
        {
            // Operation was cancelled, just ignore
        }

    }

    private async Task LoadImagesRecursively(string directory, CancellationToken cancellationToken)
    {
        try
        {
            var imageFiles = Directory.GetFiles(directory)
                .Where(file => _supportedExtensions.Contains(Path.GetExtension(file).ToLower()))
                .ToList();

            // Create tasks for all images in current directory
            var tasks = imageFiles.Select(async imagePath =>
            {
                await _throttle.WaitAsync(); // Acquire semaphore
                try
                {
                    // Check cancellation before starting each thumbnail
                    cancellationToken.ThrowIfCancellationRequested();

                    var thumbnailBitmap = await Task.Run(() => GenerateThumbnail(imagePath));
                    
                    // Check cancellation before adding to collection
                    cancellationToken.ThrowIfCancellationRequested();
                    
                    var item = new ImageItemViewModel
                    {
                        FilePath = imagePath,
                        FileName = Path.GetFileName(imagePath),
                        Thumbnail = thumbnailBitmap
                    };
                    
                    // Dispatch to UI thread for collection modification
                    await Dispatcher.UIThread.InvokeAsync(() => Images.Add(item));
                }
                finally
                {
                    _throttle.Release(); // Release semaphore
                }
            });

            // Process all images in parallel
            await Task.WhenAll(tasks);

            // Process subdirectories
            var subDirTasks = Directory.GetDirectories(directory)
                .Select(subDir => LoadImagesRecursively(subDir, cancellationToken));
            
            await Task.WhenAll(subDirTasks);
        }
        catch (UnauthorizedAccessException)
        {
            // Skip directories we don't have access to
        }
        catch (DirectoryNotFoundException)
        {
            // Skip directories that no longer exist
        }
    }

    private Bitmap GenerateThumbnail(string imagePath)
    {
        Debug.Print($"Generating thumbnail for {imagePath}");
        try
        {
            // Resize the image
            using var thumbnail = Image.Thumbnail(imagePath, ThumbnailSize);
        
            // Convert to JPEG format in memory with lower quality (0-100)
            var buffer = thumbnail.WriteToBuffer(".jpg[Q=95]");
        
            // Create Avalonia Bitmap directly from the buffer
            using var stream = new MemoryStream(buffer);
            return new Bitmap(stream);
        }
        catch (Exception e)
        {
            // Return a placeholder bitmap for failed thumbnails
            // You might want to create a proper placeholder image
            Debug.Print($"Failed to generate thumbnail for {imagePath}: {e} {e.Message}");
            return null!;
        }
    }
    
    // Remember to clean up
    public void Dispose()
    {
        _cancellationTokenSource?.Cancel();
        _cancellationTokenSource?.Dispose();
        _throttle.Dispose();
    }
}

public partial class ImageItemViewModel : ViewModelBase
{
    [ObservableProperty]
    private bool _isSelected;

    [ObservableProperty]
    private string? _filePath;

    [ObservableProperty]
    private string? _fileName;

    [ObservableProperty]
    private Bitmap? _thumbnail;
}