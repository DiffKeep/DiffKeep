
using System;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using FluentAssertions;
using Xunit;
using Xunit.Abstractions;

namespace Tests.Services;

public class LicenseKeyGenerator
{
    private readonly ECDsa _privateKey;
    
    public LicenseKeyGenerator(byte[] privateKeyBytes)
    {
        _privateKey = ECDsa.Create();
        _privateKey.ImportPkcs8PrivateKey(privateKeyBytes, out _);
    }

    public string GenerateLicenseKey(LicenseInfo licenseInfo)
    {
        using var ms = new MemoryStream();
        using (var writer = new BinaryWriter(ms, Encoding.UTF8, true))
        {
            // Write email length and email
            writer.Write((byte)licenseInfo.Email.Length);
            writer.Write(Encoding.UTF8.GetBytes(licenseInfo.Email));
            
            // Write version type as single char
            char versionTypeChar = licenseInfo.VersionType switch
            {
                "Release" => 'R',
                "Beta" => 'B',
                "Alpha" => 'A',
                "Enterprise" => 'E',
                _ => throw new ArgumentException("Invalid version type")
            };
            writer.Write(versionTypeChar);
            
            // Write version string
            writer.Write((byte)licenseInfo.Version.Length);
            writer.Write(Encoding.UTF8.GetBytes(licenseInfo.Version));
            
            // Write dates
            writer.Write(licenseInfo.ValidFrom.ToBinary());
            writer.Write(licenseInfo.ValidUntil.ToBinary());
        }

        // Compress the data
        byte[] compressed;
        using (var compressedStream = new MemoryStream())
        {
            using (var gzip = new GZipStream(compressedStream, CompressionLevel.Optimal))
            {
                ms.Position = 0;
                ms.CopyTo(gzip);
            }
            compressed = compressedStream.ToArray();
        }

        // Sign the compressed data
        byte[] signature = _privateKey.SignData(compressed, HashAlgorithmName.SHA256);

        // Combine length, compressed data and signature
        using var finalStream = new MemoryStream();
        using (var writer = new BinaryWriter(finalStream))
        {
            writer.Write((ushort)compressed.Length);
            writer.Write(compressed);
            writer.Write(signature);
        }

        // Convert to URL-safe base64
        return Convert.ToBase64String(finalStream.ToArray())
            .Replace('+', '-')
            .Replace('/', '_')
            .TrimEnd('=');
    }
}


public class LicenseServiceTests
{
    private readonly ITestOutputHelper _testOutputHelper;
    private readonly byte[] _privateKey;
    private readonly byte[] _publicKey;
    private readonly LicenseKeyGenerator _generator;
    private readonly LicenseKeyValidator _validator;

    public LicenseServiceTests(ITestOutputHelper testOutputHelper)
    {
        _testOutputHelper = testOutputHelper;
        // Generate test key pair
        using var ecdsa = ECDsa.Create();
        _privateKey = ecdsa.ExportPkcs8PrivateKey();
        _publicKey = ecdsa.ExportSubjectPublicKeyInfo();
        
        _generator = new LicenseKeyGenerator(_privateKey);
        _validator = new LicenseKeyValidator(_publicKey);
    }

    [Fact]
    public void Should_Generate_ECDsa_KeyPair()
    {
        using var ecdsa = ECDsa.Create();
        var prv = Convert.ToBase64String(ecdsa.ExportPkcs8PrivateKey());
        var pub = Convert.ToBase64String(ecdsa.ExportSubjectPublicKeyInfo());
        _testOutputHelper.WriteLine("Public:");
        _testOutputHelper.WriteLine(pub);
        _testOutputHelper.WriteLine("Private:");
        _testOutputHelper.WriteLine(prv);
        prv.Should().NotBeNullOrWhiteSpace();
        pub.Should().NotBeNullOrWhiteSpace();
    }

    [Fact]
    public void GenerateLicenseKey_WithValidInfo_ShouldGenerateValidKey()
    {
        // Arrange
        var licenseInfo = CreateValidLicenseInfo();

        // Act
        var licenseKey = _generator.GenerateLicenseKey(licenseInfo);
        _testOutputHelper.WriteLine("License key:");
        _testOutputHelper.WriteLine(licenseKey);

        // Assert
        licenseKey.Should().NotBeNullOrEmpty();
        licenseKey.Should().NotContain("="); // Should not contain padding
        licenseKey.Should().NotContain("+"); // Should use URL-safe base64
        licenseKey.Should().NotContain("/"); // Should use URL-safe base64
    }

    [Fact]
    public void ValidateLicenseKey_WithValidKey_ShouldReturnCorrectInfo()
    {
        // Arrange
        var originalInfo = CreateValidLicenseInfo();
        var licenseKey = _generator.GenerateLicenseKey(originalInfo);

        // Act
        var validatedInfo = _validator.ValidateLicenseKey(licenseKey, originalInfo.Version);

        // Assert
        validatedInfo.Should().NotBeNull();
        validatedInfo.Email.Should().Be(originalInfo.Email);
        validatedInfo.VersionType.Should().Be(originalInfo.VersionType);
        validatedInfo.Version.Should().Be(originalInfo.Version);
        validatedInfo.ValidFrom.Should().Be(originalInfo.ValidFrom);
        validatedInfo.ValidUntil.Should().Be(originalInfo.ValidUntil);
    }

    [Fact]
    public void ValidateLicenseKey_WithExpiredLicense_ShouldThrowException()
    {
        // Arrange
        var expiredInfo = new LicenseInfo
        {
            Email = "test@example.com",
            VersionType = "Release",
            Version = "1.0.0",
            ValidFrom = DateTime.UtcNow.AddDays(-30),
            ValidUntil = DateTime.UtcNow.AddDays(-1)
        };
        var licenseKey = _generator.GenerateLicenseKey(expiredInfo);

        // Act & Assert
        var action = () => _validator.ValidateLicenseKey(licenseKey, expiredInfo.Version);
        action.Should().Throw<InvalidOperationException>()
            .WithMessage("Invalid license key.");
    }

    [Fact]
    public void ValidateLicenseKey_WithFutureLicense_ShouldThrowException()
    {
        // Arrange
        var futureInfo = new LicenseInfo
        {
            Email = "test@example.com",
            VersionType = "Release",
            Version = "1.0.0",
            ValidFrom = DateTime.UtcNow.AddDays(1),
            ValidUntil = DateTime.UtcNow.AddDays(30)
        };
        var licenseKey = _generator.GenerateLicenseKey(futureInfo);

        // Act & Assert
        var action = () => _validator.ValidateLicenseKey(licenseKey, futureInfo.Version);
        action.Should().Throw<InvalidOperationException>()
            .WithMessage("Invalid license key.");
    }
    
    [Fact]
    public void ValidateLicenseKey_WithNoDates_ShouldReturnCorrectInfo()
    {
        // Arrange
        var undatedInfo = new LicenseInfo
        {
            Email = "test@example.com",
            VersionType = "Release",
            Version = "1.0.0",
            ValidFrom = DateTime.MinValue,
            ValidUntil = DateTime.MaxValue
        };
        var licenseKey = _generator.GenerateLicenseKey(undatedInfo);

        // Act & Assert
        var licenseInfo = _validator.ValidateLicenseKey(licenseKey, undatedInfo.Version);
        licenseInfo.Email.Should().Be(undatedInfo.Email);
    }

    [Fact]
    public void ValidateLicenseKey_WithTamperedKey_ShouldThrowException()
    {
        // Arrange
        var licenseInfo = CreateValidLicenseInfo();
        var licenseKey = _generator.GenerateLicenseKey(licenseInfo);
        var tamperedKey = licenseKey[..^1] + "X"; // Change last character

        // Act & Assert
        var action = () => _validator.ValidateLicenseKey(tamperedKey, licenseInfo.Version);
        action.Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public void ValidateLicenseKey_WithInvalidKey_ShouldThrowException()
    {
        // Arrange
        var invalidKey = "ThisIsNotAValidLicenseKey";

        // Act & Assert
        var action = () => _validator.ValidateLicenseKey(invalidKey, "1.0.0");
        action.Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public void ValidateLicenseKey_WithWrongPublicKey_ShouldThrowException()
    {
        // Arrange
        var licenseInfo = CreateValidLicenseInfo();
        var licenseKey = _generator.GenerateLicenseKey(licenseInfo);
    
        // Create a different key pair
        using var differentEcdsa = ECDsa.Create();
        var differentPublicKey = differentEcdsa.ExportSubjectPublicKeyInfo();
        var differentValidator = new LicenseKeyValidator(differentPublicKey);

        // Act & Assert
        var action = () => differentValidator.ValidateLicenseKey(licenseKey, licenseInfo.Version);
        action.Should().Throw<InvalidOperationException>()
            .WithMessage("Invalid license key.");
    }


    private static LicenseInfo CreateValidLicenseInfo()
    {
        return new LicenseInfo
        {
            Email = "test@example.com",
            VersionType = "Release",
            Version = "1.0.0",
            ValidFrom = DateTime.UtcNow.AddDays(-1),
            ValidUntil = DateTime.UtcNow.AddDays(30)
        };
    }
    
        [Theory]
    [InlineData("Beta")]
    [InlineData("Release")]
    [InlineData("Alpha")]
    [InlineData("Enterprise")]
    public void ValidateLicenseKey_WithDifferentVersionTypes_ShouldValidateCorrectly(string versionType)
    {
        // Arrange
        var licenseInfo = new LicenseInfo
        {
            Email = "test@example.com",
            VersionType = versionType,
            Version = "1.0.0",
            ValidFrom = DateTime.UtcNow.AddDays(-1),
            ValidUntil = DateTime.UtcNow.AddDays(30)
        };
        var licenseKey = _generator.GenerateLicenseKey(licenseInfo);

        // Act
        var validatedInfo = _validator.ValidateLicenseKey(licenseKey, licenseInfo.Version);

        // Assert
        validatedInfo.VersionType.Should().Be(versionType);
    }

    [Theory]
    [InlineData("1.0.0", "1.0.0", true)]  // Exact match
    [InlineData("1.0.0", "1.0.1", false)] // Different patch version
    [InlineData("1.0", "1.0.1", true)] // Different patch version but license is soft
    [InlineData("1.0.0", "1.1.0", false)] // Different minor version
    [InlineData("1", "1.1.0", true)] // Different minor version but license is soft
    [InlineData("1.0.0", "2.0.0", false)] // Different major version
    [InlineData("1.0.0-beta", "1.0.0-beta", true)]  // Exact match with pre-release
    [InlineData("1.0.0-beta", "1.0.0", false)]      // Pre-release vs release
    public void ValidateLicenseKey_VersionMatching_ShouldValidateCorrectly(string licenseVersion, 
        string currentVersion, bool shouldBeValid)
    {
        // Arrange
        var licenseInfo = new LicenseInfo
        {
            Email = "test@example.com",
            VersionType = "Release",
            Version = licenseVersion,
            ValidFrom = DateTime.UtcNow.AddDays(-1),
            ValidUntil = DateTime.UtcNow.AddDays(30)
        };
        var licenseKey = _generator.GenerateLicenseKey(licenseInfo);

        // Act & Assert
        if (shouldBeValid)
        {
            var validatedInfo = _validator.ValidateLicenseKey(licenseKey, currentVersion);
            validatedInfo.Version.Should().Be(licenseVersion);
        }
        else
        {
            var action = () => _validator.ValidateLicenseKey(licenseKey, currentVersion);
            action.Should().Throw<InvalidOperationException>()
                .WithMessage($"Invalid license key.");
        }
    }

    [Fact]
    public void ValidateLicenseKey_WithBetaVersion_ShouldHandlePreReleaseVersions()
    {
        // Arrange
        var licenseInfo = new LicenseInfo
        {
            Email = "test@example.com",
            VersionType = "Beta",
            Version = "1.0.0-beta.1",
            ValidFrom = DateTime.UtcNow.AddDays(-1),
            ValidUntil = DateTime.UtcNow.AddDays(30)
        };
        var licenseKey = _generator.GenerateLicenseKey(licenseInfo);

        // Act & Assert
        // Should work with exact beta version
        var validatedInfo = _validator.ValidateLicenseKey(licenseKey, "1.0.0-beta.1");
        validatedInfo.Should().NotBeNull();

        // Should not work with different beta version
        var action1 = () => _validator.ValidateLicenseKey(licenseKey, "1.0.0-beta.2");
        action1.Should().Throw<InvalidOperationException>();

        // Should not work with release version
        var action2 = () => _validator.ValidateLicenseKey(licenseKey, "1.0.0");
        action2.Should().Throw<InvalidOperationException>();
    }
}