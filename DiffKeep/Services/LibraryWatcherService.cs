using System.Collections.Generic;
using System.Threading.Tasks;
using DiffKeep.Database;
using DiffKeep.Repositories;
using Serilog;

namespace DiffKeep.Services;

public class LibraryWatcherService
{
    private readonly Dictionary<long, LibraryWatcher> _watchers = new();
    private readonly object _lockObject = new();
    private readonly ImageLibraryScanner _imageLibraryScanner;
    private readonly ILibraryRepository _libraryRepository;

    public LibraryWatcherService(ImageLibraryScanner scanner, ILibraryRepository libraryRepository)
    {
        _imageLibraryScanner = scanner;
        _libraryRepository = libraryRepository;
    }

    public async Task AddWatcher(string libraryPath, long libraryId)
    {
        if (_watchers.ContainsKey(libraryId))
        {
            Log.Debug("Already added library {Id}, skipping", libraryId);
            return;
        }
        
        var watcher = new LibraryWatcher(libraryPath, libraryId, _imageLibraryScanner, _libraryRepository);
        lock (_lockObject)
        {
            _watchers.Add(libraryId, watcher);
        }
        await watcher.WatchLibrary();
    }

    public void RemoveWatcher(long libraryId)
    {
        lock (_lockObject)
        {
            _watchers.Remove(libraryId);
        }
    }
}