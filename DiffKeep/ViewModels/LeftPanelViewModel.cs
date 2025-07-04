using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using DiffKeep.Database;
using DiffKeep.Repositories;
using DiffKeep.Extensions;
using System.Threading;
using System;
using System.Diagnostics;
using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Threading;
using DiffKeep.Services;
using Serilog;
using ShadUI;

namespace DiffKeep.ViewModels;

public partial class LeftPanelViewModel : ViewModelBase
{
    private readonly ILibraryRepository _libraryRepository;
    private readonly ImageLibraryScanner _imageLibraryScanner;
    private readonly LibraryWatcherService _libraryWatcherService;
    private readonly ToastManager _toastManager;
    public EmbeddingsGenerationViewModel EmbeddingsGenerationViewModel { get; }
    public HuggingFaceDownloaderViewModel HuggingFaceDownloaderViewModel { get; }
    private ObservableCollection<LibraryTreeItem> _items;
    [ObservableProperty]
    private LibraryTreeItem _selectedItem;
    private readonly SemaphoreSlim _scanSemaphore = new(1, 1);
    private DateTime _lastUpdateTime = DateTime.MinValue;
    private const int UPDATE_INTERVAL_MS = 100; // Update UI at most every 100ms
    
    public ObservableCollection<LibraryTreeItem> Items
    {
        get => _items;
        set => SetProperty(ref _items, value);
    }

    public LeftPanelViewModel(ILibraryRepository libraryRepository, ImageLibraryScanner imageLibraryScanner,
        LibraryWatcherService libraryWatcherService, ToastManager toastManager)
    {
        _libraryRepository = libraryRepository;
        _imageLibraryScanner = imageLibraryScanner;
        _libraryWatcherService = libraryWatcherService;
        _toastManager = toastManager;
        _items = new ObservableCollection<LibraryTreeItem>();
        EmbeddingsGenerationViewModel = App.GetService<EmbeddingsGenerationViewModel>();
        HuggingFaceDownloaderViewModel = App.GetService<HuggingFaceDownloaderViewModel>();

        // Subscribe to scanner events
        _imageLibraryScanner.ScanProgress += OnScanProgress;
        _imageLibraryScanner.ScanCompleted += OnScanCompleted;
        
        InitializeTreeItemsAsync().FireAndForget();
    }

    private void OnScanProgress(object? sender, ScanProgressEventArgs e)
    {
        // Only update UI at specified intervals
        if ((DateTime.Now - _lastUpdateTime).TotalMilliseconds < UPDATE_INTERVAL_MS)
            return;
        
        _lastUpdateTime = DateTime.Now;
        
        var libraryItem = FindLibraryItem(e.LibraryId);
        if (libraryItem != null)
        {
            libraryItem.ProcessedFiles = e.ProcessedFiles;
            libraryItem.TotalFiles = e.TotalFiles;
            libraryItem.ScanProgress = e.TotalFiles > 0 ? (double)e.ProcessedFiles / e.TotalFiles : 0;
            libraryItem.ScanStatus = $"Scanning: {e.ProcessedFiles}/{e.TotalFiles} files";
        }
    }

    private void OnScanCompleted(object? sender, ScanCompletedEventArgs e)
    {
        var libraryItem = FindLibraryItem(e.LibraryId);
        if (libraryItem != null)
        {
            libraryItem.IsScanning = false;
            libraryItem.ScanStatus = $"Scan complete: {e.ProcessedFiles} files processed";
            libraryItem.ScanProgress = 1.0;
        }
    }

    private LibraryTreeItem? FindLibraryItem(long libraryId)
    {
        if (Items.Count == 0) return null;
        return Items[0].Children.FirstOrDefault(item => item.Id == libraryId);
    }
    
    public async Task RefreshLibrariesAsync()
    {
        Log.Debug("Refreshing libraries");
        await InitializeTreeItemsAsync();
    }

    private async Task InitializeTreeItemsAsync()
    {
        Log.Debug("Initializing libraries");
        var libraries = await _libraryRepository.GetAllAsync();
        
        // Create the top-level "Libraries" item
        var librariesRoot = new LibraryTreeItem
        {
            Name = "Libraries",
            Path = "",
            IsExpanded = true
        };

        foreach (var library in libraries)
        {
            if (!Directory.Exists(library.Path))
            {
                _toastManager.CreateToast("Library Error")
                    .WithContent($"Library directory {library.Path} not found or inaccessible.")
                    .ShowError();
                Log.Warning("Library directory {LibraryPath} not found or inaccessible.", library.Path);
                continue;
            }

            var libraryItem = new LibraryTreeItem
            {
                Id = library.Id,
                Name = Path.GetFileName(library.Path) + (string.IsNullOrEmpty(library.Path) ? "" : $" ({library.Path})"),
                Path = library.Path,
                IsLibrary = true,
            };

            // Start background scan
            StartLibraryScan(libraryItem);

            PopulateChildren(libraryItem);
            librariesRoot.Children.Add(libraryItem);
        }

        // Clear ou the items before adding the new root
        Items.Clear();
        Items.Add(librariesRoot);
        
        // Auto-select the Libraries node
        SelectedItem = librariesRoot;
    }

    private void StartLibraryScan(LibraryTreeItem libraryItem)
    {
        Task.Run(async () =>
        {
            if (libraryItem.Id == null)
                return;
            Log.Debug("Delaying start of scan for library {LibraryItemName}", libraryItem.Name);
            await Task.Delay(1000);
            Log.Debug("Starting library scan for library {LibraryItemName}", libraryItem.Name);
            
            try
            {
                await _scanSemaphore.WaitAsync();
                libraryItem.IsScanning = true;
                libraryItem.ScanStatus = "Scanning...";

                await _imageLibraryScanner.ScanLibraryAsync((long)libraryItem.Id);
                _libraryWatcherService.AddWatcher(libraryItem.Path, (long)libraryItem.Id).FireAndForget();

                libraryItem.ScanStatus = "Scan complete";
            }
            catch (Exception ex)
            {
                libraryItem.ScanStatus = $"Scan failed: {ex.Message}";
            }
            finally
            {
                libraryItem.IsScanning = false;
                _scanSemaphore.Release();
            }
        });
    }

    public async Task RescanLibraryAsync(LibraryTreeItem libraryItem)
    {
        Log.Debug("Rescan library called");
        if (libraryItem.IsScanning || libraryItem.Id == 0)
            return;

        Log.Debug("Rescaning library");
        StartLibraryScan(libraryItem);
    }

    private void PopulateChildren(LibraryTreeItem item)
    {
        try
        {
            var directories = Directory.GetDirectories(item.Path)
                .OrderBy(Path.GetFileName)
                .ToArray();
            
            foreach (var dir in directories)
            {
                var childItem = new LibraryTreeItem
                {
                    Id = item.Id,
                    Name = Path.GetFileName(dir),
                    Path = dir,
                    IsLibrary = false,
                };
                
                PopulateChildren(childItem);
                item.Children.Add(childItem);
            }
        }
        catch
        {
            // Skip directories we can't access
        }
    }
}

public partial class LibraryTreeItem : ViewModelBase
{
    [ObservableProperty]
    private bool _isScanning;
    [ObservableProperty]
    private string _scanStatus;
    [ObservableProperty]
    private int _processedFiles;
    [ObservableProperty]
    private int _totalFiles;
    [ObservableProperty]
    private double _scanProgress;
    [ObservableProperty]
    private bool _isExpanded;
    [ObservableProperty]
    private bool _isSelected;


    public long? Id { get; set; }
    public string? Name { get; set; }
    public string? Path { get; set; }
    public bool IsLibrary { get; set; }
    public ObservableCollection<LibraryTreeItem> Children { get; } = new();
}