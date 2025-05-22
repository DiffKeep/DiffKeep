using System.Reflection;

namespace Tests;

public static class TestHelpers
{
    public static string GetTestArtifactPath(string relativePath)
    {
        var assemblyLocation = Assembly.GetExecutingAssembly().Location;
        var assemblyDirectory = Path.GetDirectoryName(assemblyLocation)
                                ?? throw new InvalidOperationException("Could not determine assembly directory");
        
        // Navigate up from bin/Debug/net9.0 to the test project root
        var projectRoot = Path.GetFullPath(Path.Combine(assemblyDirectory, "../../.."));
        
        return Path.Combine(projectRoot, "test-artifacts", relativePath);
    }
}