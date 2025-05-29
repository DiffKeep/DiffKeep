using System;
using Avalonia.Controls;
using Avalonia.Input;
using DiffKeep.ViewModels;
using System.Collections.ObjectModel;
using Avalonia;
using Avalonia.Interactivity;
using DiffKeep.Services;

namespace DiffKeep.Views;

public partial class ImageViewerWindow : Window
{
    private bool _isFullScreen;
    private Avalonia.Controls.WindowState _previousWindowState;
    private bool _isResizing;
    private Point _lastPos;

    public ImageViewerWindow()
    {
        InitializeComponent();

        ZoomInButton.Click += (_, _) => ImageViewer.ZoomIn();
        ZoomOutButton.Click += (_, _) => ImageViewer.ZoomOut();
        FitToScreenButton.Click += (_, _) => ImageViewer.ZoomToFit();
        ActualSizeButton.Click += (_, _) => ImageViewer.ZoomToActual();
        CenterButton.Click += (_, _) => ImageViewer.CenterToScreen();
    }

    public ImageViewerWindow(ObservableCollection<ImageItemViewModel> images, ImageItemViewModel currentImage) : this()
    {
        DataContext = new ImageViewerViewModel(images, currentImage, App.GetService<IImageService>());

        KeyDown += ImageViewerWindow_KeyDown;

        // Handle window opened event
        Opened += (s, e) => Focus();
    }

    private async void ImageViewerWindow_KeyDown(object? sender, KeyEventArgs e)
    {
        if (DataContext is ImageViewerViewModel vm)
        {
            switch (e.Key)
            {
                case Key.Left:
                case Key.Up:
                    vm.NavigatePreviousCommand.Execute(null);
                    e.Handled = true;
                    break;
                case Key.Right:
                case Key.Down:
                    vm.NavigateNextCommand.Execute(null);
                    e.Handled = true;
                    break;
                case Key.Escape:
                    Close();
                    e.Handled = true;
                    break;
                case Key.F11:
                    ToggleFullScreen(null, new RoutedEventArgs());
                    e.Handled = true;
                    break;
                case Key.I:
                    if (DataContext is ImageViewerViewModel vm1)
                    {
                        vm1.IsInfoPanelVisible = !vm1.IsInfoPanelVisible;
                    }

                    e.Handled = true;
                    break;
                case Key.Delete:
                    if (DataContext is ImageViewerViewModel vm2)
                    {
                        var result = await vm2.DeleteCurrentImage(this);
                        if (result)
                        {
                            vm2.LoadCurrentImage();
                        }
                    }

                    e.Handled = true;
                    break;
            }
        }
    }

    protected override void OnClosed(EventArgs e)
    {
        base.OnClosed(e);
        if (DataContext is ImageViewerViewModel vm)
        {
            vm.Dispose();
        }
    }

    private void ToggleFullScreen(object? sender, RoutedEventArgs e)
    {
        if (!_isFullScreen)
        {
            _previousWindowState = WindowState;
        }

        _isFullScreen = !_isFullScreen;
        WindowState = _isFullScreen ? Avalonia.Controls.WindowState.FullScreen : _previousWindowState;
    }

    private void OnInfoPanelResizeStarted(object? sender, PointerPressedEventArgs e)
    {
        _isResizing = true;
        _lastPos = e.GetPosition(this);
        e.Pointer.Capture((IInputElement)sender!);
    }

    private void OnInfoPanelResizing(object? sender, PointerEventArgs e)
    {
        if (!_isResizing) return;

        var pos = e.GetPosition(this);
        var delta = _lastPos.X - pos.X;

        if (DataContext is ImageViewerViewModel vm)
        {
            var newWidth = Math.Max(200, Math.Min(600, vm.InfoPanelWidth + delta));
            vm.InfoPanelWidth = newWidth;
        }

        _lastPos = pos;
    }

    private void OnInfoPanelResizeEnded(object? sender, PointerReleasedEventArgs e)
    {
        _isResizing = false;
        e.Pointer.Capture(null);
    }
}