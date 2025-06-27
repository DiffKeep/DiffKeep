
using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Serilog;

namespace DiffKeep.ViewModels;

public partial class HuggingFaceDownloaderViewModel : ViewModelBase
{
    [ObservableProperty] private bool _isVisible;
    [ObservableProperty] private string _fileName = string.Empty;
    [ObservableProperty] private string _downloadSpeed = string.Empty;
    [ObservableProperty] private string _downloadTime = string.Empty;
    [ObservableProperty] private float _downloadPercentage;
    [ObservableProperty] private string _downloadSizeCompleted = string.Empty;

    private ulong _downloadBytesPerSecond;
    private ulong _totalSizeBytes;
    private ulong _downloadedSizeBytes;
    private readonly Stopwatch _downloadStopwatch = new();
    private readonly HttpClient _httpClient;
    private CancellationTokenSource? _cancellationTokenSource;

    public HuggingFaceDownloaderViewModel()
    {
        _httpClient = new HttpClient();
    }

    public async Task StartDownload(string url, string destinationPath, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrEmpty(url) || string.IsNullOrEmpty(destinationPath))
            return;

        _cancellationTokenSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var token = _cancellationTokenSource.Token;

        try
        {
            IsVisible = true;
            FileName = Path.GetFileName(destinationPath);
            _downloadedSizeBytes = 0;
            DownloadPercentage = 0;
            _downloadStopwatch.Restart();

            // Create directory if it doesn't exist
            Directory.CreateDirectory(Path.GetDirectoryName(destinationPath) ?? string.Empty);

            // Start the download
            await DownloadFileAsync(url, destinationPath, token);
        }
        catch (OperationCanceledException)
        {
            // Handle cancellation
        }
        catch (Exception ex)
        {
            // Handle errors
            Log.Error("Download error: {ExMessage}", ex.Message);
        }
        finally
        {
            _downloadStopwatch.Stop();
            _cancellationTokenSource?.Dispose();
            _cancellationTokenSource = null;
            IsVisible = false;
        }
    }

    [RelayCommand]
    public void CancelDownload()
    {
        _cancellationTokenSource?.Cancel();
    }

    private async Task DownloadFileAsync(string url, string destinationPath, CancellationToken cancellationToken)
    {
        using var response = await _httpClient.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        response.EnsureSuccessStatusCode();

        _totalSizeBytes = (ulong)response.Content.Headers.ContentLength;
        
        using var contentStream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var fileStream = new FileStream(destinationPath, FileMode.Create, FileAccess.Write, FileShare.None, 8192, true);
        
        var buffer = new byte[8192];
        var lastProgressUpdateTime = DateTime.Now;
        var bytesReadSinceLastUpdate = 0UL;
        
        // Start a timer to update the UI
        var updateTimer = new Timer(_ => UpdateDownloadStats(), null, 0, 500);

        try
        {
            int bytesRead;
            while ((bytesRead = await contentStream.ReadAsync(buffer, cancellationToken)) > 0)
            {
                await fileStream.WriteAsync(buffer.AsMemory(0, bytesRead), cancellationToken);
                
                // Update progress tracking
                _downloadedSizeBytes += (ulong)bytesRead;
                bytesReadSinceLastUpdate += (ulong)bytesRead;
                
                // Calculate download speed every second
                var now = DateTime.Now;
                if ((now - lastProgressUpdateTime).TotalSeconds >= 1)
                {
                    _downloadBytesPerSecond = bytesReadSinceLastUpdate / (ulong)(now - lastProgressUpdateTime).TotalSeconds;
                    bytesReadSinceLastUpdate = 0;
                    lastProgressUpdateTime = now;
                }
            }
        }
        finally
        {
            updateTimer.Dispose();
        }
    }

    private void UpdateDownloadStats()
    {
        // Update the UI with current download status
        if (_totalSizeBytes > 0)
        {
            DownloadPercentage = (float)(_downloadedSizeBytes * 100.0 / _totalSizeBytes);
        }
        
        DownloadSizeCompleted = FormatFileSize(_downloadedSizeBytes) + (_totalSizeBytes > 0 ? $" of {FormatFileSize(_totalSizeBytes)}" : "");
        DownloadSpeed = $"{FormatFileSize(_downloadBytesPerSecond)}/s";
        DownloadTime = $"Time elapsed: {_downloadStopwatch.Elapsed:hh\\:mm\\:ss}";
    }

    private string FormatFileSize(ulong bytes)
    {
        string[] suffixes = { "B", "KB", "MB", "GB", "TB" };
        int suffixIndex = 0;
        double size = bytes;
        
        while (size >= 1024 && suffixIndex < suffixes.Length - 1)
        {
            suffixIndex++;
            size /= 1024;
        }
        
        return $"{size:0.##} {suffixes[suffixIndex]}";
    }
}