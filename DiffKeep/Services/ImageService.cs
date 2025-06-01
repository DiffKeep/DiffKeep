using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using Avalonia.Controls;
using DiffKeep.ViewModels;
using System.Diagnostics;
using Avalonia.Media.Imaging;
using DiffKeep.Repositories;
using MsBox.Avalonia;
using MsBox.Avalonia.Dto;
using MsBox.Avalonia.Models;

namespace DiffKeep.Services;

public class ImageService : IImageService
{
    private readonly IImageRepository _imageRepository;
    private static bool _skipDeleteConfirmation;

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
            Debug.WriteLine($"Dialog result: {result}");

            if (result == "Cancel" || String.IsNullOrWhiteSpace(result))
            {
                Debug.WriteLine("Image delete cancelled");
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
                Debug.WriteLine($"Deleting from filesystem image {image.Path}");
                File.Delete(image.Path);
            }

            // Delete from the database
            Debug.WriteLine($"Deleting from database image {image.Id}");
            await _imageRepository.DeleteAsync(image.Id);

            return true;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"Error deleting image: {ex}");
            var errorDialog =
                MessageBoxManager.GetMessageBoxStandard("Error", $"Failed to delete the image: {ex.Message}");
            await errorDialog.ShowWindowDialogAsync(parentWindow);
            return false;
        }
    }

    public static async Task<Bitmap?> GenerateThumbnailAsync(string file, int size)
    {
        return await Task.Run(() =>
        {
            using var vipsThumbnail = NetVips.Image.Thumbnail(file, size);
            var buffer = vipsThumbnail.WriteToBuffer(".jpg[Q=95]");
            using var stream = new MemoryStream(buffer);
            return new Bitmap(stream);
        });
    }
}