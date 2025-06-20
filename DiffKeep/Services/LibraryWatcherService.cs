using System.Collections.Generic;
using System.Threading.Tasks;
using DiffKeep.Database;
using DiffKeep.Repositories;

namespace DiffKeep.Services;

public class LibraryWatcherService
{
    private readonly List<LibraryWatcher> _watchers = new();
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
        var watcher = new LibraryWatcher(libraryPath, libraryId, _imageLibraryScanner, _libraryRepository);
        lock (_lockObject)
        {
            _watchers.Add(watcher);
        }
        await watcher.WatchLibrary();
    }

    public void RemoveWatcher(string libraryPath, long libraryId)
    {
        lock (_lockObject)
        {
            var watcher = _watchers.Find(w => w.LibraryId == libraryId && w.LibraryPath == libraryPath);
            if (watcher != null)
                _watchers.Remove(watcher);
        }
    }
}