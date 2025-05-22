using Avalonia.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using System.Collections.ObjectModel;

namespace DiffKeep.ViewModels;

public partial class ImageViewerViewModel : ViewModelBase
{
    private readonly ObservableCollection<ImageItemViewModel> _allImages;
    private int _currentIndex;

    [ObservableProperty]
    private Bitmap? _imageSource;

    [ObservableProperty]
    private string _imageName = string.Empty;

    [ObservableProperty]
    private bool _hasPrevious;

    [ObservableProperty]
    private bool _hasNext;

    public ImageViewerViewModel(ObservableCollection<ImageItemViewModel> images, ImageItemViewModel currentImage)
    {
        _allImages = images;
        _currentIndex = images.IndexOf(currentImage);
        LoadCurrentImage();
    }

    private void LoadCurrentImage()
    {
        var currentItem = _allImages[_currentIndex];
        ImageSource?.Dispose();
        ImageSource = new Bitmap(currentItem.FilePath!);
        ImageName = currentItem.FileName ?? string.Empty;
        
        HasPrevious = _currentIndex > 0;
        HasNext = _currentIndex < _allImages.Count - 1;
    }

    [RelayCommand]
    private void NavigatePrevious()
    {
        if (_currentIndex > 0)
        {
            _currentIndex--;
            LoadCurrentImage();
        }
    }

    [RelayCommand]
    private void NavigateNext()
    {
        if (_currentIndex < _allImages.Count - 1)
        {
            _currentIndex++;
            LoadCurrentImage();
        }
    }

    public void Dispose()
    {
        ImageSource?.Dispose();
    }
}