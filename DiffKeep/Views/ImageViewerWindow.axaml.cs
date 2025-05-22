using System;
using Avalonia.Controls;
using Avalonia.Input;
using DiffKeep.ViewModels;
using System.Collections.ObjectModel;
using Avalonia.Interactivity;

namespace DiffKeep.Views;

public partial class ImageViewerWindow : Window
{
    private bool _isFullScreen;
    private Avalonia.Controls.WindowState _previousWindowState;

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
        DataContext = new ImageViewerViewModel(images, currentImage);
        
        KeyDown += ImageViewerWindow_KeyDown;
        
        // Handle window opened event
        Opened += (s, e) => Focus();
    }

    private void ImageViewerWindow_KeyDown(object? sender, KeyEventArgs e)
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

    protected override void OnKeyUp(KeyEventArgs e)
    {
        base.OnKeyUp(e);
        
        if (e.Key == Key.F11)
        {
            ToggleFullScreen(null, new RoutedEventArgs());
            e.Handled = true;
        }
    }
}