using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Threading.Tasks;
using Avalonia.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using DiffKeep.Extensions;
using DiffKeep.Repositories;
using Image = DiffKeep.Models.Image;

namespace DiffKeep.ViewModels;

public partial class ImageGalleryViewModel : ViewModelBase
{
    private readonly IImageRepository _imageRepository;
    private ObservableCollection<ImageItemViewModel> _images;
    private long? _currentLibraryId;
    
    [ObservableProperty]
    private ImageItemViewModel? _selectedImage;
    
    [ObservableProperty]
    private string? _currentDirectory;

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
        LoadImagesForLibraryAsync(null).FireAndForget();
    }

    public async Task LoadImagesForLibraryAsync(long? libraryId, string? path = null)
    {
        _currentLibraryId = libraryId;
        Images.Clear();

        IEnumerable<Image> dbImages;
        if (libraryId == null)
        {
            dbImages = await _imageRepository.GetAllAsync();
            CurrentDirectory = "All Libraries";
        }
        else if (path == null)
        {
            dbImages = await _imageRepository.GetByLibraryIdAsync((long)libraryId);
            CurrentDirectory = "Library ID #" + libraryId;
        }
        else
        {
            dbImages = await _imageRepository.GetByLibraryIdAndPathAsync((long)libraryId, path);
            CurrentDirectory = path;
        }

        foreach (var image in dbImages)
        {
            var viewModel = new ImageItemViewModel(image);
            Images.Add(viewModel);
        }
    }
}

public partial class ImageItemViewModel : ViewModelBase
{
    private readonly Models.Image _image;

    public long Id => _image.Id;
    public string Path => _image.Path;
    public string FileName => System.IO.Path.GetFileName(Path);
    public string Hash => _image.Hash;
    public string? PositivePrompt => _image.PositivePrompt;
    public string? NegativePrompt => _image.NegativePrompt;
    public DateTime Created => _image.Created;
    public Bitmap? Thumbnail => _image.Thumbnail;
    
    [ObservableProperty]
    private bool _isSelected;

    public ImageItemViewModel(Models.Image image)
    {
        _image = image;
    }
}