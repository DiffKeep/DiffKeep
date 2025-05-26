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

namespace DiffKeep.ViewModels;

public class LeftPanelViewModel : ViewModelBase
{
    private readonly ILibraryRepository _libraryRepository;
    private readonly ImageLibraryScanner _imageLibraryScanner;
    private ObservableCollection<LibraryTreeItem> _items;
    private LibraryTreeItem _selectedItem;
    private readonly SemaphoreSlim _scanSemaphore = new(1, 1);

    public LibraryTreeItem SelectedItem
    {
        get => _selectedItem;
        set => SetProperty(ref _selectedItem, value);
    }
    
    public ObservableCollection<LibraryTreeItem> Items
    {
        get => _items;
        set => SetProperty(ref _items, value);
    }
    
    public LeftPanelViewModel(ILibraryRepository libraryRepository, ImageLibraryScanner imageLibraryScanner)
    {
        _libraryRepository = libraryRepository;
        _imageLibraryScanner = imageLibraryScanner;
        _items = new ObservableCollection<LibraryTreeItem>();
        InitializeTreeItemsAsync().FireAndForget();
    }
    
    public async Task RefreshLibrariesAsync()
    {
        Items.Clear();
        await InitializeTreeItemsAsync();
    }

    private async Task InitializeTreeItemsAsync()
    {
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
                continue;

            var libraryItem = new LibraryTreeItem
            {
                Id = library.Id,
                Name = Path.GetFileName(library.Path) + (string.IsNullOrEmpty(library.Path) ? "" : $" ({library.Path})"),
                Path = library.Path,
            };

            // Start background scan
            StartLibraryScan(libraryItem);

            PopulateChildren(libraryItem);
            librariesRoot.Children.Add(libraryItem);
        }

        Items.Add(librariesRoot);
        
        // Auto-select the Libraries node
        SelectedItem = librariesRoot;
    }

    private void StartLibraryScan(LibraryTreeItem libraryItem)
    {
        Task.Run(async () =>
        {
            try
            {
                await _scanSemaphore.WaitAsync();
                libraryItem.IsScanning = true;
                libraryItem.ScanStatus = "Scanning...";

                await _imageLibraryScanner.ScanLibraryAsync(libraryItem.Id);

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
        if (libraryItem.IsScanning || libraryItem.Id == 0)
            return;

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
                    Name = Path.GetFileName(dir),
                    Path = dir
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

    public long Id { get; set; }
    public string Name { get; set; }
    public string Path { get; set; }
    public ObservableCollection<LibraryTreeItem> Children { get; } = new();
    public bool IsExpanded { get; set; }
    public bool IsSelected { get; set; }
}