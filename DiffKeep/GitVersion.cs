namespace DiffKeep;

public static class GitVersion
{
    public static string Version { get; } = ThisAssembly.Git.SemVer.Major + "." + 
                                            ThisAssembly.Git.SemVer.Minor + "." + 
                                            ThisAssembly.Git.BaseVersion.Patch +
                                            ThisAssembly.Git.SemVer.DashLabel;
    
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
            if (Branch != "master")
            {
                version = $"{Branch}";
            }
            if (int.Parse(ThisAssembly.Git.Commits) > 0)
            {
                version += $"-{ThisAssembly.Git.Commit}";
            }
            if (IsDirty)
            {
                version += "-dirty";
            }
            return version;
        }
    }
}