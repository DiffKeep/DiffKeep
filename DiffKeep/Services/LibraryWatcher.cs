using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.Messaging;
using DiffKeep.Database;
using DiffKeep.Messages;
using DiffKeep.Repositories;

namespace DiffKeep.Services;

public class LibraryWatcher
{
    private readonly ImageLibraryScanner _imageLibraryScanner;
    private readonly ILibraryRepository _libraryRepository;
    public string LibraryPath { get; set; }
    public long LibraryId { get; set; }
    private readonly CancellationTokenSource? _cancellationSource;
    private readonly ConcurrentDictionary<string, CancellationTokenSource> _debounceDictionary;
    private readonly ConcurrentDictionary<long, CancellationTokenSource> _debounceLibraryDictionary;
    private const int DebounceDelayMs = 1000;
    private const int LibraryUpdateDebounceMs = 3000; // 1 second debounce for library updates

    private CancellationTokenSource? _libraryUpdateDebounceToken;

    public LibraryWatcher(string libraryPath, long libraryId, ImageLibraryScanner imageLibraryScanner,
        ILibraryRepository libraryRepository)
    {
        _imageLibraryScanner = imageLibraryScanner;
        _libraryRepository = libraryRepository;
        LibraryPath = libraryPath;
        LibraryId = libraryId;
        _cancellationSource = new CancellationTokenSource();
        _debounceDictionary = new ConcurrentDictionary<string, CancellationTokenSource>();
        _debounceLibraryDictionary = new ConcurrentDictionary<long, CancellationTokenSource>();
    }

    ~LibraryWatcher()
    {
        Debug.WriteLine($"Cleaning up LibraryWatched for {LibraryPath}");
    }

    public async Task WatchLibrary()
    {
        using var watcher = new FileSystemWatcher(LibraryPath);

        watcher.NotifyFilter = NotifyFilters.LastWrite;

        watcher.Changed += OnChanged;
        watcher.Created += OnChanged;
        watcher.Deleted += OnChanged;
        watcher.Renamed += OnChanged;
        watcher.Error += OnError;

        watcher.Filter = "*.*";
        watcher.IncludeSubdirectories = true;
        watcher.EnableRaisingEvents = true;

        Debug.WriteLine($"Watching library {LibraryPath}");
        try
        {
            await Task.Delay(Timeout.Infinite, _cancellationSource?.Token ?? CancellationToken.None);
        }
        catch (OperationCanceledException)
        {
            // Normal cancellation, can be ignored
        }
    }

    public void StopWatching()
    {
        _cancellationSource?.Cancel();
    }

    private async void OnChanged(object sender, FileSystemEventArgs e)
    {
        try
        {
            // Cancel any existing debounce task for this file
            if (_debounceDictionary.TryRemove(e.FullPath, out var existingCts))
            {
                existingCts.Cancel();
                existingCts.Dispose();
            }

            // Create new cancellation token source for this debounce operation
            var cts = new CancellationTokenSource();
            _debounceDictionary.TryAdd(e.FullPath, cts);

            try
            {
                // Wait for the debounce period
                await Task.Delay(DebounceDelayMs, cts.Token);

                // If we got here without cancellation, process the file
                Debug.WriteLine($"Debounced event: {e.ChangeType} filename: {e.FullPath}");

                // find out which libraries have this file in them
                // Get all libraries
                var libraries = await _libraryRepository.GetAllAsync();

                // Check which libraries contain this file
                var containingLibraries = libraries.Where(lib =>
                    e.FullPath.StartsWith(lib.Path, StringComparison.OrdinalIgnoreCase));

                foreach (var library in containingLibraries)
                {
                    Debug.WriteLine($"Detected that library {library.Path} contains image {e.FullPath}, creating or updating image");
                    await _imageLibraryScanner.CreateOrUpdateSingleFile(library.Id, e.FullPath);
                    await LibraryUpdated(library.Id);
                }
            }
            catch (OperationCanceledException)
            {
                // Debounce was canceled by another event, just ignore
            }
            finally
            {
                // Clean up
                _debounceDictionary.TryRemove(e.FullPath, out _);
                cts.Dispose();
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"Error in OnChanged handler: {ex}");
        }
    }

    private async Task LibraryUpdated(long libraryId)
    {
        try
        {
            // Cancel any existing debounce task for this library
            if (_debounceLibraryDictionary.TryRemove(libraryId, out var existingCts))
            {
                existingCts.Cancel();
                existingCts.Dispose();
            }

            // Create new cancellation token source
            var cts = new CancellationTokenSource();
            _debounceLibraryDictionary.TryAdd(libraryId, cts);

            try
            {
                // Wait for the debounce period
                await Task.Delay(LibraryUpdateDebounceMs, cts.Token);

                // Send the library updated message
                Debug.WriteLine($"Sending library update message for library ID {libraryId}");
                WeakReferenceMessenger.Default.Send(new LibraryUpdatedMessage(libraryId));
            }
            catch (OperationCanceledException)
            {
                // Debounce was canceled, ignore
            }
            finally
            {
                // Clean up
                _debounceLibraryDictionary.TryRemove(libraryId, out _);
                cts.Dispose();
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"Error in LibraryUpdated: {ex}");
        }

    }

    private void OnError(object sender, ErrorEventArgs e)
    {
        Debug.WriteLine($"error event: {e.GetException()}");
    }
}