using Avalonia;
using Avalonia.Controls;
using Avalonia.Markup.Xaml;
using System.Threading.Tasks;

namespace DiffKeep.Dialogs;

public partial class MessageDialog : Window
{
    public static readonly StyledProperty<string> MessageProperty =
        AvaloniaProperty.Register<MessageDialog, string>(nameof(Message), "");

    public string Message
    {
        get => GetValue(MessageProperty);
        set => SetValue(MessageProperty, value);
    }
    
    public MessageDialog()
    {
        InitializeComponent();
        DataContext = this;
#if DEBUG
        this.AttachDevTools();
#endif
    }

    private void InitializeComponent()
    {
        AvaloniaXamlLoader.Load(this);
    }
    
    private void OnOkClick(object? sender, global::Avalonia.Interactivity.RoutedEventArgs e)
    {
        Result = MessageDialogResult.Ok;
        Close();
    }
    
    private void OnCancelClick(object? sender, global::Avalonia.Interactivity.RoutedEventArgs e)
    {
        Result = MessageDialogResult.Cancel;
        Close();
    }
    
    public MessageDialogResult Result { get; private set; }
    
    public new async Task<MessageDialogResult> ShowAsync(Window parent)
    {
        await ShowDialog(parent);
        return Result;
    }
}

public enum MessageDialogResult
{
    Ok,
    Cancel
}