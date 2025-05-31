using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using Avalonia.Media.Imaging;
using CommunityToolkit.Mvvm.Messaging;
using DiffKeep.Extensions;
using DiffKeep.Messages;
using DiffKeep.Models;
using DiffKeep.Parsing;
using DiffKeep.Repositories;
using DiffKeep.Services;

namespace DiffKeep.Database;

public class ImageLibraryScanner
{
    private readonly ILibraryRepository _libraryRepository;
    private readonly IImageRepository _imageRepository;
    private readonly ImageParser _imageParser;
    private readonly ConcurrentDictionary<long, CancellationTokenSource> _scanCancellations = new();
    private const int ThumbnailSize = 200;
    private const int MaxConcurrentThumbnails = 16;
    private const int BatchSize = 500; // Size of batches for database inserts

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
        var imageBatch = new ConcurrentBag<Image>();
        var processingTasks = new List<Task>();

        async Task ProcessBatchAsync()
        {
            var batchToProcess = imageBatch.Where(img => img != null).ToList();
            if (batchToProcess.Count > 0)
            {
                imageBatch = new ConcurrentBag<Image>();
                await _imageRepository.AddBatchAsync(batchToProcess);
                Debug.Print($"Inserted batch of {batchToProcess.Count} images");
            }
        }

        foreach (var file in files)
        {
            if (cancellationToken.IsCancellationRequested)
                break;

            try
            {
                if (!await _imageRepository.ExistsAsync(library.Id, file))
                {
                    await semaphore.WaitAsync(cancellationToken);

                    var task = Task.Run(async () =>
                    {
                        try
                        {
                            var image = await CreateImageFromFile(file, library.Id);

                            imageBatch.Add(image);
                            Debug.Print($"Processed {file}");

                            if (imageBatch.Count >= BatchSize)
                            {
                                await ProcessBatchAsync();
                            }
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

                    processingTasks.Add(task);
                }
            }
            catch (Exception ex)
            {
                Debug.Print($"Error processing file {file}: {ex.Message}");
            }

            processedFiles++;
            OnScanProgress(library.Id, processedFiles, totalFiles);
        }

        try
        {
            // Wait for all processing tasks to complete
            await Task.WhenAll(processingTasks);

            // Process any remaining images in the final batch
            await ProcessBatchAsync();
        }
        catch (Exception ex)
        {
            Debug.Print($"Error during batch processing: {ex}");
            throw;
        }

        OnScanCompleted(library.Id, processedFiles);
        WeakReferenceMessenger.Default.Send(new LibraryUpdatedMessage(library.Id));
    }

    public async Task CreateOrUpdateSingleFile(long libraryId, string filePath)
    {
        var dbImage = await _imageRepository.GetByLibraryIdAndPathAsync(libraryId, filePath);
        var image = await CreateImageFromFile(filePath, libraryId);
        if (dbImage.Count() == 1)
        {
            Debug.WriteLine($"Existing image found for {image.Path}, updating image");
            var i = dbImage.First();
            image.Id = i.Id;
            await _imageRepository.UpdateAsync(image);
        }
        else
        {
            Debug.WriteLine($"No previous image found for {image.Path}, inserting image");
            await _imageRepository.AddAsync(image);
        }
    }

    private void OnScanProgress(long libraryId, int processedFiles, int totalFiles)
    {
        ScanProgress?.Invoke(this, new ScanProgressEventArgs(libraryId, processedFiles, totalFiles));
    }

    private void OnScanCompleted(long libraryId, int processedFiles)
    {
        ScanCompleted?.Invoke(this, new ScanCompletedEventArgs(libraryId, processedFiles));
        
        Debug.WriteLine($"Finished scanning library {libraryId}, checking for images without embeddings");
        // find and queue all images in the library that don't have embeddings
        Task.Run(async () =>
        {
            try
            {
                // Get all images from this library
                var images = await _imageRepository.GetImagesWithoutEmbeddingsAsync(libraryId);
                Debug.WriteLine($"Found {images.Count()} images in library {libraryId} without embeddings");
            
                // Filter for images that have a positive prompt but no embedding
                foreach (var image in images)
                {
                    if (!string.IsNullOrWhiteSpace(image.PositivePrompt))
                    {
                        // Send message to generate embedding for this image
                        WeakReferenceMessenger.Default.Send(
                            new GenerateEmbeddingMessage(image.Id, EmbeddingSource.PositivePrompt, image.PositivePrompt)
                            );
                    }
                }
            }
            catch (Exception ex)
            {
                Debug.Print($"Error queuing embeddings generation: {ex}");
            }
        });
    }

    private async Task<Image?> CreateImageFromFile(string file, long libraryId)
    {
        var hash = await Hash(file);
        if (string.IsNullOrEmpty(hash))
        {
            Debug.Print($"Failed to generate hash for file: {file}");
            return null;
        }

        var metadata = await _imageParser.ParseImageAsync(file);
        var fileInfo = new FileInfo(file);

        Bitmap? thumbnail = null;
        try
        {
            using var vipsThumbnail = NetVips.Image.Thumbnail(file, ThumbnailSize);
            var buffer = vipsThumbnail.WriteToBuffer(".jpg[Q=95]");
            using var stream = new MemoryStream(buffer);
            thumbnail = new Bitmap(stream);
        }
        catch (Exception ex)
        {
            Debug.Print($"Failed to generate thumbnail for {file}: {ex.Message}");
            return null;
        }

        return new Image
        {
            LibraryId = libraryId,
            Path = file,
            Hash = hash,
            PositivePrompt = metadata?.Prompt,
            Created = fileInfo.CreationTime,
            Thumbnail = thumbnail
        };
    }

    private static async Task<string> Hash(string imagePath)
    {
        // Calculate file hash
        string hash;
        using (var md5 = MD5.Create())
        await using (var stream = File.OpenRead(imagePath))
        {
            var hashBytes = await md5.ComputeHashAsync(stream);
            hash = BitConverter.ToString(hashBytes).Replace("-", "").ToLowerInvariant();
        }

        return hash;
    }
}