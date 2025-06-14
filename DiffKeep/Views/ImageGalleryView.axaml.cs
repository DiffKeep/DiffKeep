using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
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
    private double _currentScrollPosition;
    private double? _lastThumbnailUpdatePosition;
    private const double SCROLL_UPDATE_THRESHOLD = 800;
    private DispatcherTimer? _layoutDebounceTimer;
    private bool _canInteract = true;

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
                    _currentViewModel.SaveScrollPositionRequested -= SaveScrollPosition;
                    _currentViewModel.RestoreScrollPositionRequested -= RestoreScrollPosition;
                }

                _currentViewModel = vm;
                vm.ImagesCollectionChanged += OnImagesCollectionChanged;
                vm.ResetScrollRequested += ResetScroll;
                vm.SaveScrollPositionRequested += SaveScrollPosition;
                vm.RestoreScrollPositionRequested += RestoreScrollPosition;
            }
        };
    }

    private void SaveScrollPosition()
    {
        Debug.WriteLine("SaveScrollPosition called");
        if (_scrollViewer != null && _scrollViewer.Offset != null)
            _currentScrollPosition = _scrollViewer.Offset.Y;
    }

    private void RestoreScrollPosition()
    {
        Debug.WriteLine("RestoreScrollPosition called");
        if (_scrollViewer != null && _scrollViewer.Offset != null)
            _scrollViewer.Offset = new Vector(0, _currentScrollPosition);
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
            var pointer = e.KeyModifiers;
        
            // Normal click (no modifiers) - unselect all images
            if (pointer == KeyModifiers.None)
            {
                vm.ClearSelection();
                MakeCurrentImage(vm, imageItem, false);
            }
            // Ctrl+Click - toggle selection of this image
            else if (pointer == KeyModifiers.Control)
            {
                if (vm.SelectedImages.Contains(imageItem))
                {
                    vm.RemoveFromSelection(imageItem);
                    MakeCurrentImage(vm, imageItem, false);
                }
                else
                {
                    vm.AddToSelection(imageItem);
                    MakeCurrentImage(vm, imageItem, false);
                }
            }
            // Shift+Click - select range from current to this image
            else if (pointer == KeyModifiers.Shift && vm.CurrentImage != null)
            {
                vm.SelectRange(vm.CurrentImage, imageItem);
                MakeCurrentImage(vm, imageItem, true);
            }
        
            border.Focus();
        }
    }

    private void Border_OnDoubleTapped(object? sender, TappedEventArgs e)
    {
        OpenImageViewer();
    }
    
    private void MakeCurrentImage(ImageGalleryViewModel vm, ImageItemViewModel imageItem, bool scrollToView)
    {
        // Just update the CurrentImage property
        vm.CurrentImage = imageItem;
    
        if (scrollToView)
            ScrollSelectedItemIntoView();
    }

    private async void OnKeyDown(object? sender, KeyEventArgs e)
    {
        if (DataContext is not ImageGalleryViewModel vm || _itemsRepeater == null || vm.Images.Count == 0)
            return;

        if (!_canInteract)
            return;

        // non-navigation keys that will return after execution
        switch (e.Key)
        {
            case Key.Enter:
                if (vm.CurrentImage != null || vm.SelectedImages.Count > 0)
                {
                    OpenImageViewer();
                }

                e.Handled = true;
                return;

            case Key.Delete:
                if (vm.CurrentImage != null)
                {
                    _canInteract = false;
                    await DeleteSelectedImage();
                    _canInteract = true;
                }
                e.Handled = true;
                return;
            
            case Key.Space:
                if (vm.CurrentImage != null)
                {
                    // Toggle selection with Space key
                    if (vm.SelectedImages.Contains(vm.CurrentImage))
                    {
                        vm.RemoveFromSelection(vm.CurrentImage);
                    }
                    else
                    {
                        vm.AddToSelection(vm.CurrentImage);
                    }
                    e.Handled = true;
                }
                return;
            
            case Key.Escape:
                if (vm.CurrentImage != null)
                {
                    // Unselect everything
                    vm.CurrentImage = null;
                    vm.ClearSelection();
                }
                e.Handled = true;
                return;
        }

        int currentIndex = vm.CurrentImage != null ? vm.Images.IndexOf(vm.CurrentImage) : -1;
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
            MakeCurrentImage(vm, vm.Images[newIndex], true);
            e.Handled = true;
        }
    }
    
    private async Task DeleteSelectedImage()
    {
        if (DataContext is not ImageGalleryViewModel vm || (vm.CurrentImage == null && vm.SelectedImages.Count == 0))
            return;

        if (Application.Current?.ApplicationLifetime is IClassicDesktopStyleApplicationLifetime { MainWindow: not null } desktop)
        {
            if (vm.SelectedImages.Count > 0)
            {
                await vm.DeleteImages(vm.SelectedImages.ToList(), desktop.MainWindow);
            }
            else
            {
                await vm.DeleteImage(vm.CurrentImage, desktop.MainWindow);
            }
        }
    }

    
    private void ScrollSelectedItemIntoView()
    {
        if (_scrollViewer == null || _itemsRepeater == null) return;
        
        var viewModel = DataContext as ImageGalleryViewModel;
        if (viewModel?.CurrentImage == null) return;

        var selectedIndex = viewModel.Images.IndexOf(viewModel.CurrentImage);
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
            _itemsRepeater.SizeChanged += ItemsRepeater_SizeChanged;
        }
        
        // Initial layout calculation
        CalculateLayout();
    }

    protected override void OnUnloaded(RoutedEventArgs e)
    {
        base.OnUnloaded(e);
        if (_itemsRepeater != null)
        {
            _itemsRepeater.SizeChanged -= ItemsRepeater_SizeChanged;
        }
        
        // Clean up the timer
        if (_layoutDebounceTimer != null)
        {
            _layoutDebounceTimer.Stop();
            _layoutDebounceTimer.Tick -= LayoutDebounceTimer_Tick;
            _layoutDebounceTimer = null;
        }
    }

    private void ItemsRepeater_SizeChanged(object? sender, SizeChangedEventArgs e)
    {
        // Only respond to actual size changes
        if (!e.PreviousSize.Equals(e.NewSize))
        {
            if (_layoutDebounceTimer == null)
            {
                _layoutDebounceTimer = new DispatcherTimer
                {
                    Interval = TimeSpan.FromMilliseconds(300)
                };
                _layoutDebounceTimer.Tick += LayoutDebounceTimer_Tick;
            }

            _layoutDebounceTimer.Stop();
            _layoutDebounceTimer.Start();
        }
    }

    private void LayoutDebounceTimer_Tick(object? sender, EventArgs e)
    {
        _layoutDebounceTimer?.Stop();
        CalculateLayout();
    }

    private void CalculateLayout()
    {
        Debug.WriteLine("LayoutDebounceTimer_Tick called");
        // Try to find any realized element
        Control? anyElement = null;
        var itemsCount = _itemsRepeater.ItemsSource.Cast<object>().Count();
    
        for (int i = 0; i < itemsCount && anyElement == null; i++)
        {
            anyElement = _itemsRepeater.TryGetElement(i);
        }
        if (anyElement != null)
        {
            Debug.WriteLine("got an element, calculating");
            var containerWidth = _itemsRepeater.Bounds.Width;
            var itemWidth = anyElement.Bounds.Width;
            var itemHeight = anyElement.Bounds.Height;
            var wrapLayout = _itemsRepeater.Layout as WrapLayout;
            var horizontalSpacing = wrapLayout?.HorizontalSpacing ?? 0;
            var verticalSpacing = wrapLayout?.VerticalSpacing ?? 0;

            var effectiveItemWidth = itemWidth + horizontalSpacing;
            var newEffectiveItemHeight = itemHeight + verticalSpacing;
            var newColumnCount = Math.Max(1, (int)(containerWidth / effectiveItemWidth));

            if (newColumnCount != _columnCount || Math.Abs(_effectiveItemHeight - newEffectiveItemHeight) > 0.1)
            {
                _columnCount = newColumnCount;
                _effectiveItemHeight = newEffectiveItemHeight;
                Debug.WriteLine($"Layout updated - Columns: {_columnCount}, Item height: {_effectiveItemHeight}");
                // update thumbnails
                UpdateVisibleThumbnails();
            }
        }
    }

    private int GetColumnCount()
    {
        return _columnCount;
    }

    private void OpenImageViewer()
    {
        if (DataContext is ImageGalleryViewModel { CurrentImage: not null } vm)
        {
            var imageItem = vm.CurrentImage;

            if (string.IsNullOrEmpty(imageItem.Path)) return;
            // Create a new list with the selected items or the whole library
            
            ObservableCollection<ImageItemViewModel> imagesCopy;
            if (vm.SelectedImages.Count > 0)
            {
                // use the selected images for the viewer, but sort them by the order they appear in the full list
                imagesCopy = new ObservableCollection<ImageItemViewModel>(
                    vm.SelectedImages
                        .OrderBy(img => vm.Images.IndexOf(img))
                );
            }
            else
            {
                // use all the current images in the viewer
                imagesCopy = new ObservableCollection<ImageItemViewModel>(vm.Images);
            }
            var window = new ImageViewerWindow(imagesCopy, imageItem);
            window.Show();
        }
    }

    private void ScrollViewer_ScrollChanged(object? sender, ScrollChangedEventArgs e)
    {
        if (_scrollViewer == null) return;
    
        var currentPosition = _scrollViewer.Offset.Y;
        var scrollDelta = Math.Abs(currentPosition - _lastThumbnailUpdatePosition ?? 0);
    
        // Only update if we've scrolled more than the threshold
        if (scrollDelta >= SCROLL_UPDATE_THRESHOLD || _lastThumbnailUpdatePosition == null)
        {
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
    }


    private DispatcherTimer? _scrollDebounceTimer;

    private void ScrollDebounceTimer_Tick(object? sender, EventArgs e)
    {
        _scrollDebounceTimer?.Stop();
        Debug.WriteLine("Scroll debounce timer fired");
        _lastThumbnailUpdatePosition = _scrollViewer?.Offset.Y ?? 0;
        UpdateVisibleThumbnails();
    }

    private void UpdateVisibleThumbnails()
    {
        Debug.WriteLine("Updating visible thumbnails");
        var visibleItems = GetVisibleItems();
        if (DataContext is ImageGalleryViewModel viewModel)
        {
            viewModel.UpdateVisibleThumbnails(visibleItems).FireAndForget();
        }
    }

    private IEnumerable<ImageItemViewModel> GetVisibleItems()
    {
        var scrollViewer = this.GetControl<ScrollViewer>("ScrollViewer");
        var itemsRepeater = this.GetControl<ItemsRepeater>("ItemsRepeater");
    
        if (scrollViewer == null || itemsRepeater == null || itemsRepeater.ItemsSource == null || 
            DataContext is not ImageGalleryViewModel viewModel) 
            return Enumerable.Empty<ImageItemViewModel>();

        // Get the visible range with padding
        var scrollOffset = scrollViewer.Offset.Y;
        var viewportHeight = scrollViewer.Viewport.Height;
        var paddingMultiplier = 3; // Adjust this value as needed
        var padding = viewportHeight * paddingMultiplier;
    
        var visibleRangeStart = Math.Max(0, scrollOffset - padding);
        var visibleRangeEnd = scrollOffset + viewportHeight + padding;

        // Calculate approximate visible items based on item height and column count
        var firstVisibleRow = (int)(visibleRangeStart / _effectiveItemHeight);
        var lastVisibleRow = (int)Math.Ceiling(visibleRangeEnd / _effectiveItemHeight);
    
        var firstVisibleIndex = firstVisibleRow * _columnCount;
        var lastVisibleIndex = Math.Min((lastVisibleRow + 1) * _columnCount - 1, viewModel.Images.Count - 1);

        return viewModel.Images.Skip(firstVisibleIndex).Take(lastVisibleIndex - firstVisibleIndex + 1);
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