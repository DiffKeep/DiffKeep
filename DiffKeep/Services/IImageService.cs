using System.Threading.Tasks;
using Avalonia.Controls;
using DiffKeep.ViewModels;

namespace DiffKeep.Services;

public interface IImageService
{
    Task<bool> DeleteImageAsync(ImageItemViewModel image, Window parentWindow);
}