using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using DiffKeep;
using DiffKeep.Settings;
using Microsoft.Extensions.Configuration;
using System.IO.Compression;

public class LicenseInfo
{
    public string Email { get; set; }
    public string VersionType { get; set; }  // "Beta", "Release", etc.
    public string Version { get; set; }      // Specific version if needed
    public DateTime ValidFrom { get; set; }
    public DateTime ValidUntil { get; set; }
}

public class Version
{
    public int Major { get; }
    public int Minor { get; }
    public int Patch { get; }
    public string PreRelease { get; }
    private readonly int _partsSpecified;

    public Version(string version)
    {
        var parts = version.Split(new[] { '-' }, 2);
        var numbers = parts[0].Split('.');
        
        if (numbers.Length < 1 || numbers.Length > 3)
            throw new ArgumentException("Invalid version format", nameof(version));

        Major = int.Parse(numbers[0]);
        Minor = numbers.Length > 1 ? int.Parse(numbers[1]) : 0;
        Patch = numbers.Length > 2 ? int.Parse(numbers[2]) : 0;
        PreRelease = parts.Length > 1 ? parts[1] : null;
        _partsSpecified = numbers.Length;
    }

    public bool Matches(Version other)
    {
        // If versions have different pre-release tags, they must match exactly
        if (PreRelease != null || other.PreRelease != null)
        {
            return Major == other.Major && 
                   Minor == other.Minor && 
                   Patch == other.Patch && 
                   PreRelease == other.PreRelease;
        }

        // Match based on specified parts
        return _partsSpecified switch
        {
            1 => Major == other.Major,                           // Match only major
            2 => Major == other.Major && Minor == other.Minor,  // Match major and minor
            _ => Major == other.Major && Minor == other.Minor && Patch == other.Patch  // Match exact version
        };
    }

    public override string ToString()
    {
        var version = $"{Major}";
        if (_partsSpecified > 1) version += $".{Minor}";
        if (_partsSpecified > 2) version += $".{Patch}";
        if (PreRelease != null) version += $"-{PreRelease}";
        return version;
    }
}

public interface ILicenseService
{
    Task<bool> ValidateLicenseKeyAsync(string licenseKey);
    Task<bool> CheckLicenseValidAsync();
    Task SaveLicenseKeyAsync(string licenseKey);
}

public class LicenseService : ILicenseService
{
    private readonly LicenseKeyValidator _validator;
    
    public LicenseService()
    {
        _validator = new LicenseKeyValidator(null);
    }

    public async Task<bool> ValidateLicenseKeyAsync(string licenseKey)
    {
        try
        {
            _validator.ValidateLicenseKey(licenseKey, GitVersion.FullVersion);
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    public async Task<bool> CheckLicenseValidAsync()
    {
        var licenseKey = Program.Settings.LicenseKey;
        if (string.IsNullOrEmpty(licenseKey))
            return false;

        return await ValidateLicenseKeyAsync(licenseKey);
    }

    public async Task SaveLicenseKeyAsync(string licenseKey)
    {
        Program.Settings.LicenseKey = licenseKey;
        var configPath = Program.ConfigPath;
        var wrapper = new AppSettingsWrapper { AppSettings = Program.Settings };
        string jsonString = System.Text.Json.JsonSerializer.Serialize(wrapper, AppSettingsContext.Default.AppSettingsWrapper);
        await File.WriteAllTextAsync(configPath, jsonString);
        Program.ReloadConfiguration();
    }
}

public class LicenseKeyValidator
{
    private readonly ECDsa _publicKey;
    private static readonly byte[] DefaultPublicKey = Convert.FromBase64String("MIGbMBAGByqGSM49AgEGBSuBBAAjA4GGAAQAO0SD3ncynDRzRvXJ6WKtLHAjQb39g+mpatQdzj84rAH/oRckQaxXrG0+7KjxTFv//lYK/2GjPLJTlunSxgej6ygAyM9gKAG2C2J/fAedITBOP1eEDefTXyQREQ/q2GIabT7BfGp6BHY5wX+zw/bszg+hjlizSml07gSrA528JAf9OHk=");
    
    public LicenseKeyValidator(byte[]? publicKeyBytes)
    {
        _publicKey = ECDsa.Create();
        if (publicKeyBytes != null)
            _publicKey.ImportSubjectPublicKeyInfo(publicKeyBytes, out _);
        else 
            _publicKey.ImportSubjectPublicKeyInfo(DefaultPublicKey, out _);
    }


    public LicenseInfo ValidateLicenseKey(string licenseKey, string currentVersion)
    {
        try
        {
            var licenseInfo = ValidateLicenseKeyInternal(licenseKey);
            ValidateVersion(licenseInfo.Version, currentVersion);
            return licenseInfo;
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException("Invalid license key.", ex);
        }
    }

    private LicenseInfo ValidateLicenseKeyInternal(string licenseKey)
    {
        // Restore padding and convert from URL-safe base64
        var padding = licenseKey.Length % 4;
        if (padding > 0)
            licenseKey += new string('=', 4 - padding);
        
        var data = Convert.FromBase64String(
            licenseKey.Replace('-', '+').Replace('_', '/'));

        using var ms = new MemoryStream(data);
        using var reader = new BinaryReader(ms);

        // Read the compressed data length
        var compressedLength = reader.ReadUInt16();
        
        // Read the compressed data
        var compressed = reader.ReadBytes(compressedLength);
        
        // Read the signature
        var signature = reader.ReadBytes((int)(ms.Length - ms.Position));

        // Verify signature
        if (!_publicKey.VerifyData(compressed, signature, HashAlgorithmName.SHA256))
        {
            throw new InvalidOperationException("Invalid license key.");
        }

        // Decompress the data
        byte[] decompressed;
        using (var decompressedStream = new MemoryStream())
        using (var compressedStream = new MemoryStream(compressed))
        using (var gzip = new GZipStream(compressedStream, CompressionMode.Decompress))
        {
            gzip.CopyTo(decompressedStream);
            decompressed = decompressedStream.ToArray();
        }

        // Parse the license info
        using var licenseReader = new BinaryReader(new MemoryStream(decompressed));
        
        // Read email
        var emailLength = licenseReader.ReadByte();
        var email = Encoding.UTF8.GetString(licenseReader.ReadBytes(emailLength));
        
        // Read version type
        var versionTypeChar = licenseReader.ReadChar();
        var versionType = versionTypeChar switch
        {
            'R' => "Release",
            'B' => "Beta",
            'A' => "Alpha",
            'E' => "Enterprise",
            _ => throw new InvalidOperationException("Invalid version type")
        };
        
        // Read version
        var versionLength = licenseReader.ReadByte();
        var version = Encoding.UTF8.GetString(licenseReader.ReadBytes(versionLength));
        
        // Read dates
        var now = DateTime.Now;
        var validFrom = DateTime.FromBinary(licenseReader.ReadInt64());
        var validUntil = DateTime.FromBinary(licenseReader.ReadInt64());
        if (validFrom > now)
        {
            throw new InvalidOperationException("License is not yet valid");
        }
        if (validUntil < now)
        {
            throw new InvalidOperationException("License has expired");
        }

        return new LicenseInfo
        {
            Email = email,
            VersionType = versionType,
            Version = version,
            ValidFrom = validFrom,
            ValidUntil = validUntil
        };
    }

    private void ValidateVersion(string licenseVersion, string currentVersion)
    {
        var licVer = new Version(licenseVersion);
        var curVer = new Version(currentVersion);
        
        if (!licVer.Matches(curVer))
        {
            throw new InvalidOperationException($"License is not valid for version {currentVersion}");
        }
    }
}