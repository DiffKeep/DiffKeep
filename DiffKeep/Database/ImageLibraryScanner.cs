using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using Avalonia.Media.Imaging;
using DiffKeep.Models;
using DiffKeep.Parsing;
using DiffKeep.Repositories;

namespace DiffKeep.Database;

public class ImageLibraryScanner
{
    private readonly ILibraryRepository _libraryRepository;
    private readonly IImageRepository _imageRepository;
    private readonly ImageParser _imageParser;
    private readonly ConcurrentDictionary<long, CancellationTokenSource> _scanCancellations = new();
    private const int ThumbnailSize = 200;
    private const int MaxConcurrentThumbnails = 16;

    public event EventHandler<ScanProgressEventArgs>? ScanProgress;
    public event EventHandler<ScanCompletedEventArgs>? ScanCompleted;

    public ImageLibraryScanner(
        ILibraryRepository libraryRepository,
        IImageRepository imageRepository,
        ImageParser imageParser)
    {
        _libraryRepository = libraryRepository;
        _imageRepository = imageRepository;
        _imageParser = imageParser;
    }

    public void CancelScan(long libraryId)
    {
        if (_scanCancellations.TryGetValue(libraryId, out var cts))
        {
            cts.Cancel();
        }
    }

    public async Task ScanLibraryAsync(long libraryId)
    {
        var library = await _libraryRepository.GetByIdAsync(libraryId);
        if (library == null) return;

        var cts = new CancellationTokenSource();
        _scanCancellations.TryAdd(libraryId, cts);

        try
        {
            await ScanLibraryInternalAsync(library, cts.Token);
        }
        finally
        {
            _scanCancellations.TryRemove(libraryId, out _);
            cts.Dispose();
        }
    }

    private async Task ScanLibraryInternalAsync(Library library, CancellationToken cancellationToken)
    {
        var files = Directory.EnumerateFiles(library.Path, "*.png", SearchOption.AllDirectories);
        var totalFiles = Directory.GetFiles(library.Path, "*.png", SearchOption.AllDirectories).Length;
        var processedFiles = 0;
        Debug.Print($"Scanning library {library.Id} ({library.Path})");
        Debug.Print($"Found {totalFiles} files");

        using var semaphore = new SemaphoreSlim(MaxConcurrentThumbnails);
        var tasks = new ConcurrentBag<Task>();

        foreach (var file in files)
        {
            if (cancellationToken.IsCancellationRequested)
                break;

            try
            {
                var relativePath = Path.GetRelativePath(library.Path, file);
                if (!await _imageRepository.ExistsAsync(library.Id, relativePath))
                {
                    var hash = await Hash(file);
                    var metadata = await _imageParser.ParseImageAsync(file);
                    var fileInfo = new FileInfo(file);
                    var image = new Image
                    {
                        LibraryId = library.Id,
                        Path = relativePath,
                        Hash = hash,
                        PositivePrompt = metadata.Prompt,
                        Created = fileInfo.CreationTime
                    };

                    // Generate thumbnail
                    await semaphore.WaitAsync(cancellationToken);
                    var task = Task.Run(async () =>
                    {
                        try
                        {
                            using var vipsThumbnail = NetVips.Image.Thumbnail(file, ThumbnailSize);
                            var buffer = vipsThumbnail.WriteToBuffer(".jpg[Q=95]");
                            using var stream = new MemoryStream(buffer);
                            using var bitmap = new Bitmap(stream);
                            image.Thumbnail = bitmap;

                            Debug.Print($"Generated thumbnail for {file}, size {bitmap.Size}");
                            await _imageRepository.AddAsync(image);
                        }
                        catch (Exception ex)
                        {
                            Debug.Print($"Error processing file {file}: {ex}");
                        }
                        finally
                        {
                            semaphore.Release();
                        }
                    }, cancellationToken);

                    tasks.Add(task);
                }
            }
            catch (Exception ex)
            {
                Debug.Print($"Error processing file {file}: {ex.Message}");
            }

            processedFiles++;
            OnScanProgress(library.Id, processedFiles, totalFiles);
        }

        await Task.WhenAll(tasks);
        OnScanCompleted(library.Id, processedFiles);
    }

    private void OnScanProgress(long libraryId, int processedFiles, int totalFiles)
    {
        ScanProgress?.Invoke(this, new ScanProgressEventArgs(libraryId, processedFiles, totalFiles));
    }

    private void OnScanCompleted(long libraryId, int processedFiles)
    {
        ScanCompleted?.Invoke(this, new ScanCompletedEventArgs(libraryId, processedFiles));
    }
    
    private static async Task<string> Hash(string imagePath)
    {
        // Calculate file hash
        string hash;
        using (var md5 = MD5.Create())
        using (var stream = File.OpenRead(imagePath))
        {
            var hashBytes = await md5.ComputeHashAsync(stream);
            hash = BitConverter.ToString(hashBytes).Replace("-", "").ToLowerInvariant();
        }

        return hash;
    }
}