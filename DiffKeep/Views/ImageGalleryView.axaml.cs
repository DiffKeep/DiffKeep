using System;
using System.Collections.Generic;
using System.Linq;
using System.Numerics;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Threading;
using DiffKeep.ViewModels;

namespace DiffKeep.Views;

public partial class ImageGalleryView : UserControl
{
    private ItemsRepeater? _itemsRepeater;
    
    public ImageGalleryView()
    {
        InitializeComponent();
        _itemsRepeater = this.FindControl<ItemsRepeater>("ItemsRepeater");
        InitializeScrollTracking();
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
        if (DataContext is ImageGalleryViewModel { SelectedImage: not null } vm)
        {
            var imageItem = vm.SelectedImage;
        
            if (string.IsNullOrEmpty(imageItem.Path)) return;
            var window = new ImageViewerWindow(vm.Images, imageItem);
            window.Show();
        }
    }
    
    private void InitializeScrollTracking()
    {
        var scrollViewer = this.GetControl<ScrollViewer>("ScrollViewer");
        if (scrollViewer != null)
        {
            scrollViewer.ScrollChanged += ScrollViewer_ScrollChanged;
        }
    }

    private void ScrollViewer_ScrollChanged(object? sender, ScrollChangedEventArgs e)
    {
        // Debounce the scroll events to avoid too frequent updates
        if (_scrollDebounceTimer == null)
        {
            _scrollDebounceTimer = new DispatcherTimer
            {
                Interval = TimeSpan.FromMilliseconds(150)
            };
            _scrollDebounceTimer.Tick += ScrollDebounceTimer_Tick;
        }

        _scrollDebounceTimer.Stop();
        _scrollDebounceTimer.Start();
    }

    private DispatcherTimer? _scrollDebounceTimer;

    private void ScrollDebounceTimer_Tick(object? sender, EventArgs e)
    {
        _scrollDebounceTimer?.Stop();
        UpdateVisibleThumbnails();
    }

    private void UpdateVisibleThumbnails()
    {
        var visibleItems = GetVisibleItems();
        if (DataContext is ImageGalleryViewModel viewModel)
        {
            viewModel.UpdateVisibleThumbnails(visibleItems.Select(i => i.Id));
        }
    }
    
    private IEnumerable<ImageItemViewModel> GetVisibleItems()
    {
        var scrollViewer = this.GetControl<ScrollViewer>("ScrollViewer");
        var itemsRepeater = this.GetControl<ItemsRepeater>("ItemsRepeater");
    
        if (scrollViewer == null || itemsRepeater == null) 
            return Enumerable.Empty<ImageItemViewModel>();

        Point scrollOffset = new Point(scrollViewer.Offset.X, scrollViewer.Offset.Y);
        Size viewportSize = new Size(new Vector2((float)scrollViewer.Viewport.Width, (float)scrollViewer.Viewport.Height * (float)1.5));
        var viewport = new Rect(scrollOffset, viewportSize);

        var visibleItems = new List<ImageItemViewModel>();
        
        var itemCount = itemsRepeater.ItemsSource.Cast<object>().Count();
    
        for (var i = 0; i < itemCount; i++)
        {
            if (itemsRepeater.TryGetElement(i) is Control element)
            {
                var bounds = element.Bounds;
                // Transform the bounds to account for scroll position
                var elementPosition = element.TranslatePoint(new Point(), scrollViewer)
                                      ?? new Point();
                var transformedBounds = new Rect(elementPosition, bounds.Size);

                if (viewport.Intersects(transformedBounds))
                {
                    if (element.DataContext is ImageItemViewModel item)
                    {
                        visibleItems.Add(item);
                    }
                }
            }
        }

        return visibleItems;
    }
}