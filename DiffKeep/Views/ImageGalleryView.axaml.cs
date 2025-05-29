using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Threading;
using DiffKeep.Extensions;
using DiffKeep.ViewModels;

namespace DiffKeep.Views;

public partial class ImageGalleryView : UserControl
{
    private ItemsRepeater? _itemsRepeater;
    private ImageGalleryViewModel? _currentViewModel;
    private ScrollViewer? _scrollViewer;
    private int _columnCount = 1;
    private double _effectiveItemHeight = 240; // Default value
    private Point _pointerPressPosition;
    private bool _isDragging;
    private const double DragThreshold = 5.0;

    public ImageGalleryView()
    {
        InitializeComponent();
        _itemsRepeater = this.FindControl<ItemsRepeater>("ItemsRepeater");
        
        DataContextChanged += (_, _) =>
        {
            if (DataContext is ImageGalleryViewModel vm)
            {
                // Unsubscribe from previous event (if any)
                if (_currentViewModel != null)
                {
                    _currentViewModel.ImagesCollectionChanged -= OnImagesCollectionChanged;
                    _currentViewModel.ResetScrollRequested -= ResetScroll;
                }

                _currentViewModel = vm;
                vm.ImagesCollectionChanged += OnImagesCollectionChanged;
                vm.ResetScrollRequested += ResetScroll;
            }
        };
    }
    
    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ImageGalleryViewModel.Images))
        {
            Debug.WriteLine("Images collection changed - updating scrollviewer");
            // Use dispatcher to ensure this runs after the UI has updated
            Dispatcher.UIThread.Post(() =>
            {
                _scrollViewer?.ScrollToHome();
            }, DispatcherPriority.Background);
        }
    }
    
    private void ResetScroll()
    {
        if (this.GetControl<ScrollViewer>("ScrollViewer") is ScrollViewer scrollViewer)
        {
            Debug.WriteLine("Resetting scroll");
            scrollViewer.ScrollToHome();
        }
    }
    
    private void OnImagesCollectionChanged(object? sender, EventArgs e)
    {
        Debug.WriteLine("Images collection changed - updating thumbnails");
        Dispatcher.UIThread.Post(UpdateVisibleThumbnails, DispatcherPriority.Render);
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
        ScrollSelectedItemIntoView();
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

        if (e.Key == Key.Delete && vm.SelectedImage != null)
        {
            DeleteSelectedImage();
            e.Handled = true;
            return;
        }

        int currentIndex = vm.SelectedImage != null ? vm.Images.IndexOf(vm.SelectedImage) : -1;
        int columns = GetColumnCount();
        int newIndex = currentIndex;

        // navigation keys
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
                Debug.WriteLine($"New index: {newIndex}, count: {vm.Images.Count}");
                if (newIndex >= vm.Images.Count) newIndex = currentIndex;
                break;
            case Key.PageUp:
                if (_scrollViewer != null)
                {
                    var visibleRows = (int)(_scrollViewer.Viewport.Height / _effectiveItemHeight);
                    newIndex = currentIndex - (visibleRows * columns);
                    if (newIndex < 0) newIndex = 0;
                }
                break;
            case Key.PageDown:
                if (_scrollViewer != null)
                {
                    var visibleRows = (int)(_scrollViewer.Viewport.Height / _effectiveItemHeight);
                    newIndex = currentIndex + (visibleRows * columns);
                    if (newIndex >= vm.Images.Count) newIndex = vm.Images.Count - 1;
                }
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
    
    private async void DeleteSelectedImage()
    {
        if (DataContext is not ImageGalleryViewModel vm || vm.SelectedImage == null)
            return;

        if (Application.Current?.ApplicationLifetime is IClassicDesktopStyleApplicationLifetime { MainWindow: not null } desktop)
        {
            await vm.DeleteImage(vm.SelectedImage, desktop.MainWindow);
        }
    }

    
    private void ScrollSelectedItemIntoView()
    {
        if (_scrollViewer == null || _itemsRepeater == null) return;
        
        var viewModel = DataContext as ImageGalleryViewModel;
        if (viewModel?.SelectedImage == null) return;

        var selectedIndex = viewModel.Images.IndexOf(viewModel.SelectedImage);
        if (selectedIndex == -1) return;

        // Calculate the position of the item
        var columns = GetColumnCount();
        var row = selectedIndex / columns;
        var targetScrollPosition = row * _effectiveItemHeight;

        // Determine if we need to scroll up or down
        var currentOffset = _scrollViewer.Offset.Y;
        var viewportHeight = _scrollViewer.Viewport.Height;
        
        // If the target is above the current viewport
        if (targetScrollPosition < currentOffset)
        {
            _scrollViewer.Offset = new Vector(0, targetScrollPosition);
        }
        // If the target is below the current viewport
        else if (targetScrollPosition + _effectiveItemHeight > currentOffset + viewportHeight)
        {
            var newOffset = targetScrollPosition + _effectiveItemHeight - viewportHeight;
            _scrollViewer.Offset = new Vector(0, newOffset);
        }
    }

    protected override void OnLoaded(RoutedEventArgs e)
    {
        base.OnLoaded(e);
        
        _scrollViewer = this.GetControl<ScrollViewer>("ScrollViewer");
        if (_itemsRepeater != null)
        {
            _itemsRepeater.LayoutUpdated += ItemsRepeater_LayoutUpdated;
        }
    }

    protected override void OnUnloaded(RoutedEventArgs e)
    {
        base.OnUnloaded(e);
        if (_itemsRepeater != null)
        {
            _itemsRepeater.LayoutUpdated -= ItemsRepeater_LayoutUpdated;
        }
    }

    private void ItemsRepeater_LayoutUpdated(object? sender, EventArgs e)
    {
        if (_itemsRepeater?.ItemsSource == null || !_itemsRepeater.ItemsSource.Cast<object>().Any())
            return;

        // Get any realized element to calculate measurements
        var anyElement = _itemsRepeater.TryGetElement(0) as Control;
        if (anyElement != null)
        {
            var containerWidth = _itemsRepeater.Bounds.Width;
            var itemWidth = anyElement.Bounds.Width;
            var horizontalSpacing = (_itemsRepeater.Layout as WrapLayout)?.HorizontalSpacing ?? 0;
    
            var effectiveItemWidth = itemWidth + horizontalSpacing;
            var newColumnCount = Math.Max(1, (int)(containerWidth / effectiveItemWidth));
    
            if (newColumnCount != _columnCount)
            {
                _columnCount = newColumnCount;
                Debug.WriteLine($"Column count updated to: {_columnCount}");
            }
        }
    }

    private int GetColumnCount()
    {
        return _columnCount;
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
        Debug.WriteLine("Scroll debounce timer fired");
        UpdateVisibleThumbnails();
    }

    private void UpdateVisibleThumbnails()
    {
        Debug.WriteLine("Updating visible thumbnails");
        var visibleItems = GetVisibleItems();
        if (DataContext is ImageGalleryViewModel viewModel)
        {
            viewModel.UpdateVisibleThumbnails(visibleItems.Select(i => i.Id)).FireAndForget();
        }
    }

    private IEnumerable<ImageItemViewModel> GetVisibleItems()
    {
        var scrollViewer = this.GetControl<ScrollViewer>("ScrollViewer");
        var itemsRepeater = this.GetControl<ItemsRepeater>("ItemsRepeater");
        
        if (scrollViewer == null || itemsRepeater == null || itemsRepeater.ItemsSource == null) 
            return Enumerable.Empty<ImageItemViewModel>();

        // Get the visible range with padding
        var scrollOffset = scrollViewer.Offset.Y;
        var viewportHeight = scrollViewer.Viewport.Height;
        var padding = viewportHeight * 3; // Three viewport height padding for smoother scrolling
        
        var visibleRangeStart = Math.Max(0, scrollOffset - padding);
        var visibleRangeEnd = scrollOffset + viewportHeight + padding;

        var visibleItems = new List<ImageItemViewModel>();
        var itemCount = itemsRepeater.ItemsSource.Cast<object>().Count();
        
        for (var i = 0; i < itemCount; i++)
        {
            if (itemsRepeater.TryGetElement(i) is Control element)
            {
                var elementBounds = element.Bounds;
                var elementTop = elementBounds.Y;
                var elementBottom = elementTop + elementBounds.Height;

                if (elementBottom >= visibleRangeStart && elementTop <= visibleRangeEnd)
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

    private void Image_OnPointerPressed(object? sender, PointerPressedEventArgs e)
    {
        Debug.WriteLine("Image pressed");
        _pointerPressPosition = e.GetPosition(null);
        _isDragging = false;
        e.Handled = true;
    }

    private async void Image_OnPointerMoved(object? sender, PointerEventArgs e)
    {
        if (!e.GetCurrentPoint(null).Properties.IsLeftButtonPressed) return;
        
        var currentPosition = e.GetPosition(null);
        var dx = currentPosition.X - _pointerPressPosition.X;
        var dy = currentPosition.Y - _pointerPressPosition.Y;
        var distance = Math.Sqrt(dx * dx + dy * dy);
        
        if (!_isDragging && distance > DragThreshold)
        {
            _isDragging = true;
            Debug.WriteLine("Image drag started");
        
            if (sender is IDataContextProvider contextProvider && 
                contextProvider.DataContext is ImageItemViewModel imageItem && 
                !string.IsNullOrEmpty(imageItem.Path))
            {
                Debug.WriteLine($"Dragging file {imageItem.Path} to clipboard...");
                var dataObject = new DataObject();
                dataObject.Set(DataFormats.Files, new[] { imageItem.Path });
            
                try
                {
                    await DragDrop.DoDragDrop(e, dataObject, DragDropEffects.Copy);
                }
                catch (Exception ex)
                {
                    Debug.WriteLine($"Drag and drop operation failed: {ex}");
                }
            }
        }
    }
}