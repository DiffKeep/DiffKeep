using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using Avalonia.Controls;
using DiffKeep.ViewModels;
using System.Diagnostics;
using System.Linq;
using System.Threading;
using Avalonia.Media.Imaging;
using CommunityToolkit.Mvvm.Messaging;
using DiffKeep.Messages;
using DiffKeep.Repositories;
using MsBox.Avalonia;
using MsBox.Avalonia.Dto;
using MsBox.Avalonia.Models;
using Serilog;

namespace DiffKeep.Services;

public class ImageService : IImageService
{
    private readonly IImageRepository _imageRepository;
    private static bool _skipDeleteConfirmation;
    private static readonly ImageBufferPool _bufferPool = new ImageBufferPool(20);

    public ImageService(IImageRepository imageRepository)
    {
        _imageRepository = imageRepository;
    }

    public async Task<bool> DeleteImageAsync(ImageItemViewModel image, Window parentWindow)
    {
        if (!_skipDeleteConfirmation)
        {
            var dialog = MessageBoxManager.GetMessageBoxCustom(new MessageBoxCustomParams()
            {
                ButtonDefinitions = new List<ButtonDefinition>
                {
                    new() { Name = "Yes and don't ask again this session", },
                    new() { Name = "Yes", },
                    new() { Name = "Cancel", },
                },
                ContentTitle = "Confirm Delete",
                ContentMessage =
                    $"Are you sure you want to delete the image: {image.Path}? This action cannot be undone.",
                Topmost = true,
                WindowStartupLocation = WindowStartupLocation.CenterOwner,
            });

            var result = await dialog.ShowWindowDialogAsync(parentWindow);

            if (result == "Cancel" || String.IsNullOrWhiteSpace(result))
            {
                Log.Debug("Image delete cancelled");
                return false;
            }

            if (result == "Yes and don't ask again this session")
            {
                _skipDeleteConfirmation = true;
            }
        }

        try
        {
            // Delete the file from filesystem
            if (File.Exists(image.Path))
            {
                Log.Debug("Deleting from filesystem image {ImagePath}", image.Path);
                File.Delete(image.Path);
            }

            // Delete from the database
            Log.Debug("Deleting from database image {ImageId}", image.Id);
            await _imageRepository.DeleteAsync(image.Id);

            WeakReferenceMessenger.Default.Send(new ImageDeletedMessage(image.Path));

            return true;
        }
        catch (Exception ex)
        {
            Log.Error("Error deleting image: {Exception}", ex);
            var errorDialog =
                MessageBoxManager.GetMessageBoxStandard("Error", $"Failed to delete the image: {ex.Message}");
            await errorDialog.ShowWindowDialogAsync(parentWindow);
            return false;
        }
    }
    
    public async Task DeleteImagesAsync(List<ImageItemViewModel> images, Window parentWindow)
    {
        var dialog = MessageBoxManager.GetMessageBoxCustom(new MessageBoxCustomParams()
        {
            ButtonDefinitions = new List<ButtonDefinition>
            {
                new() { Name = "Yes", },
                new() { Name = "Cancel", },
            },
            ContentTitle = "Confirm Delete",
            ContentMessage =
                $"Are you sure you want to delete {images.Count} images? This action cannot be undone.",
            Topmost = true,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
        });

        var result = await dialog.ShowWindowDialogAsync(parentWindow);

        if (result == "Cancel" || String.IsNullOrWhiteSpace(result))
        {
            Log.Debug("Image delete cancelled");
            return;
        }

        try
        {
            images.ForEach((image) =>
            {
                // Delete the file from filesystem
                if (File.Exists(image.Path))
                {
                    Log.Debug("Deleting from filesystem image {ImagePath}", image.Path);
                    File.Delete(image.Path);

                    WeakReferenceMessenger.Default.Send(new ImageDeletedMessage(image.Path));
                }
            });

            // Delete from the database
            Log.Debug("Deleting {ImagesCount} images from database", images.Count);
            await _imageRepository.DeleteAsync(images.Select(img => img.Id).ToArray()
            );
        }
        catch (Exception ex)
        {
            Log.Error("Error deleting images: {Exception}", ex);
            var errorDialog =
                MessageBoxManager.GetMessageBoxStandard("Error", $"Failed to delete the images: {ex.Message}");
            await errorDialog.ShowWindowDialogAsync(parentWindow);
        }
    }

    public static async Task<Bitmap?> GenerateThumbnailAsync(string file, int size, int quality = 85)
    {
        if (!File.Exists(file))
            return null;
        
        return await Task.Run(() =>
        {
            try
            {
                using var vipsThumbnail = NetVips.Image.Thumbnail(file, size, height: size);
            
                // Use a lower quality setting to reduce memory usage
                var jpgOptions = $".jpg[Q={quality}]";
                byte[] buffer = vipsThumbnail.WriteToBuffer(jpgOptions);
            
                // Use the buffer pool for the memory stream
                var stream = _bufferPool.Rent();
                try
                {
                    stream.Write(buffer, 0, buffer.Length);
                    stream.Position = 0;
                    return new Bitmap(stream);
                }
                catch (Exception ex)
                {
                    Log.Error("Error creating bitmap: {ExMessage}", ex.Message);
                    _bufferPool.Return(stream);
                    return null;
                }
                finally
                {
                    // Explicitly release NetVips memory
                    GC.Collect(0, GCCollectionMode.Forced);
                }
            }
            catch (Exception ex)
            {
                Log.Error("Error generating thumbnail for {File}: {ExMessage}", file, ex.Message);
                return null;
            }
        });
    }

}

public class ImageBufferPool
{
    private readonly ConcurrentBag<MemoryStream> _streamPool = new();
    private readonly int _maxPoolSize;
    private int _currentPoolSize;

    public ImageBufferPool(int maxPoolSize = 20)
    {
        _maxPoolSize = maxPoolSize;
    }

    public MemoryStream Rent()
    {
        if (_streamPool.TryTake(out var stream))
        {
            stream.SetLength(0);
            stream.Position = 0;
            return stream;
        }
        
        Interlocked.Increment(ref _currentPoolSize);
        return new MemoryStream();
    }

    public void Return(MemoryStream stream)
    {
        if (stream == null) return;
        
        // Only keep streams up to our max pool size
        if (Interlocked.CompareExchange(ref _currentPoolSize, 0, 0) <= _maxPoolSize)
        {
            stream.SetLength(0);
            stream.Position = 0;
            _streamPool.Add(stream);
        }
        else
        {
            Interlocked.Decrement(ref _currentPoolSize);
            stream.Dispose();
        }
    }

    public void Clear()
    {
        while (_streamPool.TryTake(out var stream))
        {
            stream.Dispose();
            Interlocked.Decrement(ref _currentPoolSize);
        }
    }
}