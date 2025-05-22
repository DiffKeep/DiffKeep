using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;

namespace DiffKeep;

public static class NativeLibraryLoader
{
    private static readonly Dictionary<string, string> _extractedLibraries = new();
    
    private static string GetPlatformSpecificLibraryName(string baseLibraryName)
    {
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            return $"{baseLibraryName}.dll";
        }
        if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
        {
            return $"{baseLibraryName}.dylib";
        }
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
        {
            return $"{baseLibraryName}.so";
        }
        throw new PlatformNotSupportedException("Current platform is not supported");
    }

    private static string GetResourcePath()
    {
        string architecture = RuntimeInformation.ProcessArchitecture switch
        {
            Architecture.X64 => "x64",
            Architecture.Arm64 => "arm64",
            _ => throw new PlatformNotSupportedException($"Architecture {RuntimeInformation.ProcessArchitecture} is not supported")
        };

        string platform = RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "win" :
                         RuntimeInformation.IsOSPlatform(OSPlatform.OSX) ? "osx" :
                         RuntimeInformation.IsOSPlatform(OSPlatform.Linux) ? "linux" :
                         throw new PlatformNotSupportedException("Current platform is not supported");

        return $"{platform}-{architecture}";
    }

    public static string ExtractAndLoadNativeLibrary(string baseLibraryName)
    {
        var libraryName = GetPlatformSpecificLibraryName(baseLibraryName);
        
        if (_extractedLibraries.TryGetValue(libraryName, out var existingPath))
        {
            return existingPath;
        }

        var resourcePath = GetResourcePath();
        var resourceName = $"DiffKeep.runtimes.{resourcePath}.native.{libraryName}";
        
        var assembly = Assembly.GetExecutingAssembly();
        using var stream = assembly.GetManifestResourceStream(resourceName);
        
        if (stream == null)
        {
            throw new InvalidOperationException(
                $"Could not find embedded resource {resourceName}. Available resources: {string.Join(", ", assembly.GetManifestResourceNames())}");
        }

        // Create a temporary directory for our native libraries
        var tempDir = Path.Combine(Path.GetTempPath(), "DiffKeep", Guid.NewGuid().ToString());
        Directory.CreateDirectory(tempDir);
        
        var libraryPath = Path.Combine(tempDir, libraryName);
        using (var fileStream = File.Create(libraryPath))
        {
            stream.CopyTo(fileStream);
        }

        // Store the path for future reference
        _extractedLibraries[libraryName] = libraryPath;

        // Ensure the library gets cleaned up when the app exits
        AppDomain.CurrentDomain.ProcessExit += (s, e) =>
        {
            try
            {
                if (File.Exists(libraryPath))
                    File.Delete(libraryPath);
                if (Directory.Exists(tempDir))
                    Directory.Delete(tempDir, true);
            }
            catch
            {
                // Best effort cleanup
            }
        };

        return libraryPath;
    }
}