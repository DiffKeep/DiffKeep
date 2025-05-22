using System;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using DiffKeep.ViewModels;

namespace DiffKeep.Views;

public partial class ImageGalleryView : UserControl
{
    private ItemsRepeater? _itemsRepeater;
    
    public ImageGalleryView()
    {
        InitializeComponent();
        _itemsRepeater = this.FindControl<ItemsRepeater>("ItemsRepeater");
    }

    private void Border_OnTapped(object? sender, TappedEventArgs e)
    {
        if (DataContext is ImageGalleryViewModel vm && 
            sender is Border border && 
            border.DataContext is ImageItemViewModel imageItem)
        {
            SelectImage(vm, imageItem);
            border.Focus();
        }
    }

    private void Border_OnDoubleTapped(object? sender, TappedEventArgs e)
    {
        OpenImageViewer();
    }

    private void SelectImage(ImageGalleryViewModel vm, ImageItemViewModel imageItem)
    {
        if (vm.SelectedImage != null)
        {
            vm.SelectedImage.IsSelected = false;
        }

        imageItem.IsSelected = true;
        vm.SelectedImage = imageItem;
    }

    private void OnKeyDown(object? sender, KeyEventArgs e)
    {
        if (DataContext is not ImageGalleryViewModel vm || _itemsRepeater == null || vm.Images.Count == 0)
            return;

        if (e.Key == Key.Enter && vm.SelectedImage != null)
        {
            OpenImageViewer();
            e.Handled = true;
            return;
        }

        int currentIndex = vm.SelectedImage != null ? vm.Images.IndexOf(vm.SelectedImage) : -1;
        int columns = GetColumnCount();
        int newIndex = currentIndex;

        switch (e.Key)
        {
            case Key.Left:
                newIndex = currentIndex > 0 ? currentIndex - 1 : currentIndex;
                break;
            case Key.Right:
                newIndex = currentIndex < vm.Images.Count - 1 ? currentIndex + 1 : currentIndex;
                break;
            case Key.Up:
                newIndex = currentIndex - columns;
                if (newIndex < 0) newIndex = currentIndex;
                break;
            case Key.Down:
                newIndex = currentIndex + columns;
                if (newIndex >= vm.Images.Count) newIndex = currentIndex;
                break;
            default:
                return;
        }

        if (newIndex != currentIndex && newIndex >= 0 && newIndex < vm.Images.Count)
        {
            SelectImage(vm, vm.Images[newIndex]);
            e.Handled = true;
        }
    }

    private int GetColumnCount()
    {
        if (_itemsRepeater?.Layout is UniformGridLayout gridLayout)
        {
            // Calculate approximate number of columns based on container width and minimum item width
            var containerWidth = _itemsRepeater.Bounds.Width;
            var itemWidth = gridLayout.MinItemWidth + gridLayout.MinColumnSpacing;
            return Math.Max(1, (int)(containerWidth / itemWidth));
        }
        return 1;
    }

    private void OpenImageViewer()
    {
        var imageItem = new ImageItemViewModel();
        if (DataContext is ImageGalleryViewModel { SelectedImage: not null } vm)
        {
            imageItem = vm.SelectedImage;
        
            if (string.IsNullOrEmpty(imageItem.FilePath)) return;
            var window = new ImageViewerWindow(vm.Images, imageItem);
        window.Show();
        }
    }
    
    
}