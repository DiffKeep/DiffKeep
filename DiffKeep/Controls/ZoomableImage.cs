using System;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Media.Imaging;

namespace DiffKeep.Controls;

public class ZoomableImage : Control
{
    public static readonly DirectProperty<ZoomableImage, IImage?> SourceProperty =
        AvaloniaProperty.RegisterDirect<ZoomableImage, IImage?>(
            nameof(Source),
            o => o.Source,
            (o, v) => o.Source = v);

    private IImage? _source;
    public IImage? Source
    {
        get => _source;
        set
        {
            if (SetAndRaise(SourceProperty, ref _source, value))
            {
                if (value != null)
                {
                    _imageSize = new Size(value.Size.Width, value.Size.Height);
                    // Reset view when new image is loaded
                    ResetView();
                }
                else
                {
                    _imageSize = new Size(0, 0);
                }
                InvalidateVisual();
            }
        }
    }

    public static readonly DirectProperty<ZoomableImage, double> ZoomPercentageProperty =
        AvaloniaProperty.RegisterDirect<ZoomableImage, double>(
            nameof(ZoomPercentage),
            o => o.ZoomPercentage);

    public double ZoomPercentage => _zoom * 100;

    private Point _pan;
    private Point _startPan;
    private Point _startPointerPosition;
    private bool _isPanning;
    private double _zoom = 1.0;
    private const double MinZoom = 0.01;
    private const double MaxZoom = 10.0;
    private const double ZoomSpeed = 0.2;
    private Size _imageSize;
    private const double ZoomInFactor = 1.25;
    private const double ZoomOutFactor = 0.8;

    public ZoomableImage()
    {
        ClipToBounds = true;
    }

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);

        if (change.Property == BoundsProperty)
        {
            ResetView();
        }
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        if (Source != null)
        {
            return availableSize;
        }
        return base.MeasureOverride(availableSize);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        if (Source != null && (finalSize.Width > 0 && finalSize.Height > 0))
        {
            ResetView();
        }
        return base.ArrangeOverride(finalSize);
    }

    private void ResetView()
    {
        if (_imageSize.Width == 0 || _imageSize.Height == 0 || Bounds.Width == 0 || Bounds.Height == 0)
            return;

        var oldZoom = _zoom;
        
        // Check if the image is larger than the available space
        bool needsScaling = _imageSize.Width > Bounds.Width || _imageSize.Height > Bounds.Height;

        if (needsScaling)
        {
            // Calculate zoom to fit if image is larger than available space
            double zoomX = Bounds.Width / _imageSize.Width;
            double zoomY = Bounds.Height / _imageSize.Height;
            _zoom = Math.Min(zoomX, zoomY);
        }
        else
        {
            // Use 100% zoom for images that fit within the available space
            _zoom = 1.0;
        }

        // Center the image
        CenterImage();

        // Notify about zoom change
        RaisePropertyChanged(ZoomPercentageProperty, oldZoom * 100, _zoom * 100);
        InvalidateVisual();
    }

    private void CenterImage()
    {
        double scaledWidth = _imageSize.Width * _zoom;
        double scaledHeight = _imageSize.Height * _zoom;
        _pan = new Point(
            (Bounds.Width - scaledWidth) / 2,
            (Bounds.Height - scaledHeight) / 2
        );
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        if (e.GetCurrentPoint(this).Properties.IsLeftButtonPressed)
        {
            _isPanning = true;
            _startPan = _pan;
            _startPointerPosition = e.GetPosition(this);
            e.Pointer.Capture(this);
        }
        base.OnPointerPressed(e);
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        if (_isPanning)
        {
            var currentPosition = e.GetPosition(this);
            var delta = currentPosition - _startPointerPosition;
            _pan = new Point(
                _startPan.X + delta.X,
                _startPan.Y + delta.Y
            );
            InvalidateVisual();
        }
        base.OnPointerMoved(e);
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        _isPanning = false;
        e.Pointer.Capture(null);
        base.OnPointerReleased(e);
    }

    public void ZoomIn()
    {
        SetZoom(_zoom * ZoomInFactor);
    }

    public void ZoomOut()
    {
        SetZoom(_zoom * ZoomOutFactor);
    }

    public void ZoomToFit()
    {
        if (_imageSize.Width == 0 || _imageSize.Height == 0 || Bounds.Width == 0 || Bounds.Height == 0)
            return;

        double zoomX = Bounds.Width / _imageSize.Width;
        double zoomY = Bounds.Height / _imageSize.Height;
        SetZoom(Math.Min(zoomX, zoomY));
        CenterImage();
    }

    public void ZoomToActual()
    {
        SetZoom(1.0);
        CenterImage();
    }

    public void CenterToScreen()
    {
        CenterImage();
        InvalidateVisual();
    }

    private void SetZoom(double newZoom, Point? zoomCenter = null)
    {
        var oldZoom = _zoom;
        _zoom = Math.Clamp(newZoom, MinZoom, MaxZoom);

        if (Math.Abs(_zoom - oldZoom) > 0.0001)
        {
            // Use the provided zoom center or default to the center of the control
            var center = zoomCenter ?? new Point(Bounds.Width / 2, Bounds.Height / 2);
        
            // Calculate the point in image coordinates before zoom
            var beforeZoomX = (center.X - _pan.X) / oldZoom;
            var beforeZoomY = (center.Y - _pan.Y) / oldZoom;

            // Calculate the point in image coordinates after zoom
            var afterZoomX = (center.X - _pan.X) / _zoom;
            var afterZoomY = (center.Y - _pan.Y) / _zoom;

            // Adjust pan to keep the point under cursor in the same position
            _pan = new Point(
                _pan.X + (afterZoomX - beforeZoomX) * _zoom,
                _pan.Y + (afterZoomY - beforeZoomY) * _zoom
            );

            RaisePropertyChanged(ZoomPercentageProperty, oldZoom * 100, _zoom * 100);
            InvalidateVisual();
        }
    }

    // Update OnPointerWheelChanged to use SetZoom:
    protected override void OnPointerWheelChanged(PointerWheelEventArgs e)
    {
        var position = e.GetPosition(this);
        var newZoom = _zoom + (e.Delta.Y * ZoomSpeed * _zoom);
        SetZoom(newZoom, position);
    
        e.Handled = true;
        base.OnPointerWheelChanged(e);
    }

    public override void Render(DrawingContext context)
    {
        base.Render(context);

        if (Source == null) return;

        using var transform = context.PushTransform(Matrix.CreateTranslation(_pan.X, _pan.Y));
        using var scaleTransform = context.PushTransform(Matrix.CreateScale(_zoom, _zoom));

        context.DrawImage(Source, new Rect(0, 0, _imageSize.Width, _imageSize.Height));
    }
}