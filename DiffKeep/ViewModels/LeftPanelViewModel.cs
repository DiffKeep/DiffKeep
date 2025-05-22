using System.Collections.ObjectModel;
using System.IO;
using System.Linq;

namespace DiffKeep.ViewModels;

public class LeftPanelViewModel : ViewModelBase
{
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
    
    public LeftPanelViewModel()
    {
        _items = new ObservableCollection<LibraryTreeItem>();
        InitializeTreeItems();
    }
    
    public void RefreshLibraries()
    {
        Items.Clear();
        InitializeTreeItems();
    }

    private void InitializeTreeItems()
    {
        foreach (var libraryPath in Program.Settings.Libraries)
        {
            if (!Directory.Exists(libraryPath))
                continue;

            var libraryItem = new LibraryTreeItem
            {
                Name = Path.GetFileName(libraryPath) + (string.IsNullOrEmpty(libraryPath) ? "" : $" ({libraryPath})"),
                Path = libraryPath,
            };

            PopulateChildren(libraryItem);
            Items.Add(libraryItem);
        }
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
    public string Name { get; set; }
    public string Path { get; set; }
    public ObservableCollection<LibraryTreeItem> Children { get; } = new();
    public bool IsExpanded { get; set; }
    public bool IsSelected { get; set; }
}