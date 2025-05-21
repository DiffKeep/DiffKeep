namespace DiffKeep;

public static class GitVersion
{
    public static string Version { get; } = ThisAssembly.Git.SemVer.Major + "." + 
                                            ThisAssembly.Git.SemVer.Minor + "." + 
                                            ThisAssembly.Git.SemVer.Patch +
                                            ThisAssembly.Git.SemVer.Label;
    
    public static string Branch { get; } = ThisAssembly.Git.Branch;
    public static string Commit { get; } = ThisAssembly.Git.Commit;
    public static bool IsDirty { get; } = ThisAssembly.Git.IsDirty;

    public static string FullVersion
    {
        get
        {
            var version = Version;
            if (version.StartsWith("0.0.0"))
            {
                version = $"{Branch}-{Commit[..7]}";
            }
            if (IsDirty)
            {
                version += "-dirty";
            }
            return version;
        }
    }
}