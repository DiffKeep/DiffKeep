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
using System.Linq;

public class LicenseInfo
{
    public string Email { get; set; }
    public string VersionType { get; set; }  // "Beta", "Release", etc.
    public string Version { get; set; }      // Specific version if needed
    public DateTime? ValidFrom { get; set; }
    public DateTime? ValidUntil { get; set; }
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
    Task<bool> ValidateLicenseKeyAsync(string licenseKey, string email);
    Task<bool> CheckLicenseValidAsync();
    Task SaveLicenseKeyAsync(string licenseKey, string email);
}

public class LicenseService : ILicenseService
{
    private readonly LicenseKeyValidator _validator;
    
    public LicenseService()
    {
        _validator = new LicenseKeyValidator(null);
    }

    public async Task<bool> ValidateLicenseKeyAsync(string licenseKey, string email)
    {
        try
        {
            _validator.ValidateLicenseKey(licenseKey, GitVersion.FullVersion, email);
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
        var email = Program.Settings.Email;
        if (string.IsNullOrEmpty(licenseKey) || string.IsNullOrEmpty(email))
            return false;

        return await ValidateLicenseKeyAsync(licenseKey, email);
    }

    public async Task SaveLicenseKeyAsync(string licenseKey, string email)
    {
        Program.Settings.LicenseKey = licenseKey;
        Program.Settings.Email = email;
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
    private static readonly byte[] DefaultPublicKey = Convert.FromBase64String("MIGbMBAGByqGSM49AgEGBSuBBAAjA4GGAAQBSZ2zIeSebkXL1f54jBT53r/kT5jHKqpZT9k1uAWQ8fqC+Op98Xg15qrjq7Hp+SGUNLAzfFVOEa5WeS4bFVKMbMYACGgjNwj60OIW5a72epkE8JWS5h9qjCp/0wFsB5MeeWN0HlEgjGPyOX3eruXEohWqTXqiqUN0gT3/mBKBJtn/RAQ=");
    
    public LicenseKeyValidator(byte[]? publicKeyBytes)
    {
        _publicKey = ECDsa.Create();
        if (publicKeyBytes != null)
            _publicKey.ImportSubjectPublicKeyInfo(publicKeyBytes, out _);
        else 
            _publicKey.ImportSubjectPublicKeyInfo(DefaultPublicKey, out _);
    }

    public LicenseInfo ValidateLicenseKey(string licenseKey, string currentVersion, string email)
    {
        try
        {
            var licenseInfo = ValidateLicenseKeyInternal(licenseKey, email);
            ValidateVersion(licenseInfo.Version, currentVersion);
            return licenseInfo;
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException("Invalid license key.", ex);
        }
    }

    private LicenseInfo ValidateLicenseKeyInternal(string licenseKey, string email)
    {
        // Restore padding and convert from URL-safe base64
        var padding = licenseKey.Length % 4;
        if (padding > 0)
            licenseKey += new string('=', 4 - padding);
        
        var byteData = Convert.FromBase64String(
            licenseKey.Replace('-', '+').Replace('_', '/'));

        using var ms = new MemoryStream(byteData);
        using var reader = new BinaryReader(ms);

        // Read the data length
        var dataLength = reader.ReadUInt16();
        
        // Read the data
        var data = reader.ReadBytes(dataLength);
        
        // Read the signature
        var signature = reader.ReadBytes((int)(ms.Length - ms.Position));

        // Verify signature
        if (!_publicKey.VerifyData(data, signature, HashAlgorithmName.SHA256))
        {
            throw new InvalidOperationException("Invalid license key.");
        }

        // Parse the license info
        using var licenseReader = new BinaryReader(new MemoryStream(data));
        
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
        
        var now = DateTime.UtcNow;
        // Read dates
        DateTime? validFrom = null;
        var hasValidFromDate = licenseReader.ReadBoolean();
        if (hasValidFromDate)
        {
            var validFromYear = licenseReader.ReadUInt16();
            var validFromMonth = licenseReader.ReadByte();
            var validFromDay = licenseReader.ReadByte();
            validFrom = new DateTime(validFromYear, validFromMonth, validFromDay).ToUniversalTime();
        }

        DateTime? validUntil = null;
        var hasValidUntilDate = licenseReader.ReadBoolean();
        if (hasValidUntilDate)
        {
            var validUntilYear = licenseReader.ReadUInt16();
            var validUntilMonth = licenseReader.ReadByte();
            var validUntilDay = licenseReader.ReadByte();
            validUntil = new DateTime(validUntilYear, validUntilMonth, validUntilDay).ToUniversalTime();
        }

        // Read and verify email hash
        var storedEmailHash = licenseReader.ReadBytes(16); // MD5 produces 16 bytes
        using var md5 = MD5.Create();
        var providedEmailHash = md5.ComputeHash(Encoding.UTF8.GetBytes(email));
        
        if (!storedEmailHash.SequenceEqual(providedEmailHash))
        {
            throw new InvalidOperationException("Invalid email address for this license key.");
        }

        if (validFrom is not null && validFrom > now)
        {
            throw new InvalidOperationException("License is not yet valid");
        }
        if (validUntil is not null && validUntil < now)
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