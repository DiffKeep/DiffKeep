using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using DiffKeep.Repositories;
using DiffKeep.Extensions;

namespace DiffKeep.ViewModels;

public class LeftPanelViewModel : ViewModelBase
{
    private readonly ILibraryRepository _libraryRepository;
    private ObservableCollection<LibraryTreeItem> _items;
    private LibraryTreeItem _selectedItem;

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
    
    public LeftPanelViewModel(ILibraryRepository libraryRepository)
    {
        _libraryRepository = libraryRepository;
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
            Path = "", // Empty path for root
            IsExpanded = true // Auto-expand the Libraries node
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

            PopulateChildren(libraryItem);
            librariesRoot.Children.Add(libraryItem);
        }

        Items.Add(librariesRoot);
        
        // Auto-select the Libraries node
        SelectedItem = librariesRoot;
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

public class LibraryTreeItem : ViewModelBase
{
    public long Id { get; set; }
    public string Name { get; set; }
    public string Path { get; set; }
    public ObservableCollection<LibraryTreeItem> Children { get; } = new();
    public bool IsExpanded { get; set; }
    public bool IsSelected { get; set; }
}