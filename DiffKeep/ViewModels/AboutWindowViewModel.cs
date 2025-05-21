namespace DiffKeep.ViewModels;

public class AboutWindowViewModel : ViewModelBase
{
    public string Version => $"Version: {GitVersion.FullVersion}";
}