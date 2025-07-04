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
using Serilog;
using ShadUI;

namespace DiffKeep.Database;

public class ImageLibraryScanner
{
    private readonly ILibraryRepository _libraryRepository;
    private readonly IImageRepository _imageRepository;
    private readonly ImageParser _imageParser;
    private readonly ITextEmbeddingGenerationService _textEmbeddingGenerationService;
    private readonly ToastManager _toastManager;
    private readonly ConcurrentDictionary<long, CancellationTokenSource> _scanCancellations = new();
    public const int ThumbnailSize = 200;
    private const int MaxConcurrentThumbnails = 16;
    private const int BatchSize = 500; // Size of batches for database inserts

    public event EventHandler<ScanProgressEventArgs>? ScanProgress;
    public event EventHandler<ScanCompletedEventArgs>? ScanCompleted;

    public ImageLibraryScanner(
        ILibraryRepository libraryRepository,
        IImageRepository imageRepository,
        ImageParser imageParser,
        ITextEmbeddingGenerationService textEmbeddingGenerationService,
        ToastManager toastManager)
    {
        _libraryRepository = libraryRepository;
        _imageRepository = imageRepository;
        _imageParser = imageParser;
        _textEmbeddingGenerationService = textEmbeddingGenerationService;
        _toastManager = toastManager;
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
        Log.Debug("Scanning library {LibraryId} ({LibraryPath})", library.Id, library.Path);
        Log.Debug("Found {TotalFiles} files", totalFiles);
        var foundNewFiles = false;

        using var semaphore = new SemaphoreSlim(MaxConcurrentThumbnails);
        var imageBatch = new List<Image>();
        var processingTasks = new List<Task>();

        foreach (var file in files)
        {
            if (cancellationToken.IsCancellationRequested)
                break;

            try
            {
                if (imageBatch.Count >= BatchSize)
                {
                    // Wait for any ongoing processing tasks to complete
                    await Task.WhenAll(processingTasks);
                    processingTasks.Clear();
                    
                    // Process the current batch
                    await ProcessBatchAsync();
                }

                if (!await _imageRepository.ExistsAsync(library.Id, file))
                {
                    await semaphore.WaitAsync(cancellationToken);

                    var task = Task.Run(async () =>
                    {
                        try
                        {
                            var image = await CreateImageFromFile(file, library.Id);
                            if (image != null)
                            {
                                lock (imageBatch)
                                {
                                    imageBatch.Add(image);
                                    foundNewFiles = true;
                                }
                                Log.Verbose("Processed {File}", file);
                            }
                        }
                        catch (Exception ex)
                        {
                            Log.Error("Error processing file {File}: {Exception}", file, ex);
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
                Log.Error("Error processing file {File}: {ExMessage}", file, ex.Message);
            }

            processedFiles++;
            OnScanProgress(library.Id, processedFiles, totalFiles);
        }

        try
        {
            // Wait for all remaining processing tasks to complete
            await Task.WhenAll(processingTasks);

            // Process any remaining images in the final batch
            await ProcessBatchAsync();
        }
        catch (Exception ex)
        {
            Log.Error("Error during batch processing: {Exception}", ex);
            throw;
        }

        OnScanCompleted(library.Id, processedFiles).FireAndForget();
        if (foundNewFiles)
            WeakReferenceMessenger.Default.Send(new LibraryUpdatedMessage(library.Id));
        return;

        async Task ProcessBatchAsync()
        {
            if (imageBatch.Count > 0)
            {
                var batchToProcess = imageBatch.ToList();
                await _imageRepository.AddBatchAsync(batchToProcess);
                Log.Information("Inserted batch of {Count} images", batchToProcess.Count);
                imageBatch.Clear();
            }
        }
    }

    public async Task CreateOrUpdateSingleFile(long libraryId, string filePath)
    {
        var dbImage = await _imageRepository.GetByLibraryIdAndPathAsync(libraryId, filePath);
        var image = await CreateImageFromFile(filePath, libraryId);
        var foundImages = dbImage as Image[] ?? dbImage.ToArray();
        if (foundImages.Length == 1)
        {
            Log.Debug("Existing image found for {ImagePath}, updating image", image?.Path);
            var i = foundImages.First();
            if (image != null)
            {
                image.Id = i.Id;
                await _imageRepository.UpdateAsync(image);
            }
        }
        else
        {
            Log.Debug("No previous image found for {ImagePath}, inserting image", image?.Path);
            if (image != null) await _imageRepository.AddAsync(image);
            // get the image we just added, so we have the ID
            var addedImage = await _imageRepository.GetByLibraryIdAndPathAsync(libraryId, filePath);
            if (addedImage.Count() == 1)
            {
                image.Id = addedImage.First().Id;
            }
        }

        if (Program.Settings.UseEmbeddings && image is { Id: not 0, PositivePrompt: not null })
        {
            WeakReferenceMessenger.Default.Send(new GenerateEmbeddingMessage(image.Id, EmbeddingSource.PositivePrompt, image.PositivePrompt));
        }
    }

    private void OnScanProgress(long libraryId, int processedFiles, int totalFiles)
    {
        ScanProgress?.Invoke(this, new ScanProgressEventArgs(libraryId, processedFiles, totalFiles));
    }

    private async Task OnScanCompleted(long libraryId, int processedFiles)
    {
        ScanCompleted?.Invoke(this, new ScanCompletedEventArgs(libraryId, processedFiles));
        
        if (!Program.Settings.UseEmbeddings)
            return;
        
        Log.Information("Finished scanning library {LibraryId}, checking for images without embeddings", libraryId);
        // find and queue all images in the library that don't have embeddings
        await Task.Run(async () =>
        {
            try
            {
                // Get all images from this library
                var images = await _imageRepository.GetImagesWithoutEmbeddingsAsync(_textEmbeddingGenerationService.ModelName(), _textEmbeddingGenerationService.EmbeddingSize(), libraryId);
                var imageArray = images as Image[] ?? images.ToArray();
                Log.Information("Found {ImageArrayLength} images in library {LibraryId} without embeddings", imageArray.Length, libraryId);
            
                // Filter for images that have a positive prompt but no embedding
                foreach (var image in imageArray)
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
                Log.Error("Error queuing embeddings generation: {Exception}", ex);
                // Dispatch to UI thread before showing toast
                await Avalonia.Threading.Dispatcher.UIThread.InvokeAsync(() => {
                    _toastManager.CreateToast("Semantic search error")
                        .WithContent($"Semantic search is enabled, but the indexing failed: {ex.Message}")
                        .WithAction("Open Settings",
                            () => WeakReferenceMessenger.Default.Send(new ShowSettingsMessage()))
                        .ShowError();
                });
            }
        });
    }

    private async Task<Image?> CreateImageFromFile(string file, long libraryId)
    {
        var hash = await Hash(file);
        if (string.IsNullOrEmpty(hash))
        {
            Log.Error("Failed to generate hash for file: {File}", file);
            return null;
        }

        var metadata = await _imageParser.ParseImageAsync(file);
        var fileInfo = new FileInfo(file);

        Bitmap? thumbnail = null;
        if (Program.Settings.StoreThumbnails)
        {
            try
            {
                thumbnail = await ImageService.GenerateThumbnailAsync(file, ThumbnailSize);
            }
            catch (Exception ex)
            {
                Log.Error("Failed to generate thumbnail for {File}: {ExMessage}", file, ex.Message);
                return null;
            }
        }

        return new Image
        {
            LibraryId = libraryId,
            Path = file,
            Hash = hash,
            PositivePrompt = metadata.PositivePrompt,
            Created = fileInfo.CreationTime,
            Thumbnail = thumbnail
        };
    }

    private static async Task<string> Hash(string imagePath)
    {
        // Calculate file hash
        using var md5 = MD5.Create();
        await using var stream = File.OpenRead(imagePath);
        var hashBytes = await md5.ComputeHashAsync(stream);
        var hash = Convert.ToHexStringLower(hashBytes);

        return hash;
    }
}