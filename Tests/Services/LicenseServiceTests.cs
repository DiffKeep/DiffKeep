using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using FluentAssertions;
using Xunit.Abstractions;
using Xunit.Sdk;

namespace Tests.Services;

public class LicenseKeyGenerator
{
    private readonly ECDsa _privateKey;
    private readonly ITestOutputHelper _testOutputHelper;

    public LicenseKeyGenerator(byte[] privateKeyBytes, ITestOutputHelper testOutputHelper)
    {
        _privateKey = ECDsa.Create();
        _privateKey.ImportPkcs8PrivateKey(privateKeyBytes, out _);
        _testOutputHelper = testOutputHelper;
    }

    public string GenerateLicenseKey(LicenseInfo licenseInfo)
    {
        using var ms = new MemoryStream();
        using (var writer = new BinaryWriter(ms, Encoding.UTF8, true))
        {
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
            // We only store the date, not the time. 8 bytes total for both dates
            if (licenseInfo.ValidFrom is not null)
            {
                writer.Write((byte)1); // indicates presence of a valid-from date
                writer.Write((ushort)licenseInfo.ValidFrom?.Year); // 2 bytes
                writer.Write((byte)licenseInfo.ValidFrom?.Month); // 1 byte
                writer.Write((byte)licenseInfo.ValidFrom?.Day); // 1 byte
            }
            else
            {
                writer.Write((byte)0); // no valid from date
            }

            if (licenseInfo.ValidUntil is not null)
            {
                writer.Write((byte)1); // indicates presence of a valid-until date
                writer.Write((ushort)licenseInfo.ValidUntil?.Year); // 2 bytes
                writer.Write((byte)licenseInfo.ValidUntil?.Month); // 1 byte
                writer.Write((byte)licenseInfo.ValidUntil?.Day); // 1 byte
            }
            else
            {
                writer.Write((byte)0); // no valid until date
            }

            // Create a hash of the email to bind it to the license - using MD5 for smaller size
            using var md5 = MD5.Create();
            byte[] emailHash = md5.ComputeHash(Encoding.UTF8.GetBytes(licenseInfo.Email));
            writer.Write(emailHash);
        }

        // Get the raw data to sign
        ms.Position = 0;
        byte[] rawData = ms.ToArray();
        _testOutputHelper.WriteLine("1. Raw data (Base64):");
        _testOutputHelper.WriteLine(Convert.ToBase64String(rawData));
        _testOutputHelper.WriteLine($"Raw data length: {rawData.Length} bytes");

        // Hex dump of raw data for byte-by-byte comparison
        _testOutputHelper.WriteLine("Raw data (hex):");
        _testOutputHelper.WriteLine(BitConverter.ToString(rawData).Replace("-", ""));

        // Calculate SHA256 hash of data (for signature verification)
        using (var sha256 = SHA256.Create())
        {
            var hash = sha256.ComputeHash(rawData);
            _testOutputHelper.WriteLine("\nSHA256 hash of data (hex):");
            _testOutputHelper.WriteLine(BitConverter.ToString(hash).Replace("-", ""));
        }

        // sign the data
        byte[] signature = _privateKey.SignData(rawData, HashAlgorithmName.SHA256);

        // Output the signature
        _testOutputHelper.WriteLine("\n2. Signature (Base64):");
        _testOutputHelper.WriteLine(Convert.ToBase64String(signature));
        _testOutputHelper.WriteLine($"Signature length: {signature.Length} bytes");

        // Hex dump of signature
        _testOutputHelper.WriteLine("Signature (hex):");
        _testOutputHelper.WriteLine(BitConverter.ToString(signature).Replace("-", ""));
        
        // Let's print out information about our private key
        _testOutputHelper.WriteLine("\nPrivate Key Information:");
        _testOutputHelper.WriteLine($"Key Algorithm: {_privateKey.KeySize} bit ECDSA");
    
        // Verify the signature ourselves to ensure it's valid
        bool verified = _privateKey.VerifyData(rawData, signature, HashAlgorithmName.SHA256);
        _testOutputHelper.WriteLine($"Self-verification result: {verified}");
    
        // Export the key parameters to check curve details
        ECParameters parameters = _privateKey.ExportParameters(true);
        _testOutputHelper.WriteLine($"Curve: {parameters.Curve.Oid.FriendlyName}");

        // Combine length, data and signature
        using var finalStream = new MemoryStream();
        using (var writer = new BinaryWriter(finalStream))
        {
            writer.Write((ushort)rawData.Length);
            writer.Write(rawData);
            writer.Write(signature);
        }

        // Output the final combined data before base64 encoding
        byte[] finalData = finalStream.ToArray();
        _testOutputHelper.WriteLine("\n3. Final combined data (Base64):");
        _testOutputHelper.WriteLine(Convert.ToBase64String(finalData));
        _testOutputHelper.WriteLine($"Final data length: {finalData.Length} bytes");

        // Output first 10 and last 10 bytes of the final data for quick reference
        byte[] firstBytes = finalData.Take(Math.Min(10, finalData.Length)).ToArray();
        byte[] lastBytes = finalData.Skip(Math.Max(0, finalData.Length - 10)).Take(10).ToArray();
        _testOutputHelper.WriteLine("First 10 bytes (hex): " + BitConverter.ToString(firstBytes).Replace("-", ""));
        _testOutputHelper.WriteLine("Last 10 bytes (hex): " + BitConverter.ToString(lastBytes).Replace("-", ""));

        // Convert to URL-safe base64 without padding
        string result = Convert.ToBase64String(finalData)
            .Replace('+', '-')
            .Replace('/', '_')
            .TrimEnd('=');

        _testOutputHelper.WriteLine("\n4. Final license key:");
        _testOutputHelper.WriteLine(result);

        return result;
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

        _generator = new LicenseKeyGenerator(_privateKey, _testOutputHelper);
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
        var validatedInfo = _validator.ValidateLicenseKey(licenseKey, originalInfo.Version, originalInfo.Email);

        // Assert
        validatedInfo.Should().NotBeNull();
        validatedInfo.Email.Should().Be(originalInfo.Email);
        validatedInfo.VersionType.Should().Be(originalInfo.VersionType);
        validatedInfo.Version.Should().Be(originalInfo.Version);
        validatedInfo.ValidFrom?.Date.Should().Be(originalInfo.ValidFrom?.Date);
        validatedInfo.ValidUntil?.Date.Should().Be(originalInfo.ValidUntil?.Date);
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
        var action = () => _validator.ValidateLicenseKey(licenseKey, expiredInfo.Version, expiredInfo.Email);
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
        var action = () => _validator.ValidateLicenseKey(licenseKey, futureInfo.Version, futureInfo.Email);
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
            Version = "1.0.0"
        };
        var licenseKey = _generator.GenerateLicenseKey(undatedInfo);

        // Act & Assert
        var licenseInfo = _validator.ValidateLicenseKey(licenseKey, undatedInfo.Version, undatedInfo.Email);
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
        var action = () => _validator.ValidateLicenseKey(tamperedKey, licenseInfo.Version, licenseInfo.Email);
        action.Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public void ValidateLicenseKey_WithInvalidKey_ShouldThrowException()
    {
        // Arrange
        var invalidKey = "ThisIsNotAValidLicenseKey";

        // Act & Assert
        var action = () => _validator.ValidateLicenseKey(invalidKey, "1.0.0", "random@example.com");
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
        var action = () => differentValidator.ValidateLicenseKey(licenseKey, licenseInfo.Version, licenseInfo.Email);
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
        var validatedInfo = _validator.ValidateLicenseKey(licenseKey, licenseInfo.Version, licenseInfo.Email);

        // Assert
        validatedInfo.VersionType.Should().Be(versionType);
    }

    [Theory]
    [InlineData("1.0.0", "1.0.0", true)] // Exact match
    [InlineData("1.0.0", "1.0.1", false)] // Different patch version
    [InlineData("1.0", "1.0.1", true)] // Different patch version but license is soft
    [InlineData("1.0.0", "1.1.0", false)] // Different minor version
    [InlineData("1", "1.1.0", true)] // Different minor version but license is soft
    [InlineData("1.0.0", "2.0.0", false)] // Different major version
    [InlineData("1.0.0-beta", "1.0.0-beta", true)] // Exact match with pre-release
    [InlineData("1.0.0-beta", "1.0.0", true)] // Pre-release vs release
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
            var validatedInfo = _validator.ValidateLicenseKey(licenseKey, currentVersion, licenseInfo.Email);
            validatedInfo.Version.Should().Be(licenseVersion);
        }
        else
        {
            var action = () => _validator.ValidateLicenseKey(licenseKey, currentVersion, licenseInfo.Email);
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
            Version = "0.1",
            ValidFrom = DateTime.UtcNow.AddDays(-1),
            ValidUntil = DateTime.UtcNow.AddDays(30)
        };
        var licenseKey = _generator.GenerateLicenseKey(licenseInfo);

        // Act & Assert
        // Should work with exact beta version
        var validatedInfo = _validator.ValidateLicenseKey(licenseKey, "0.1.0-beta.1", licenseInfo.Email);
        validatedInfo.Should().NotBeNull();

        // Should not work with different version
        var action1 = () => _validator.ValidateLicenseKey(licenseKey, "0.2.0-beta.2", licenseInfo.Email);
        action1.Should().Throw<InvalidOperationException>();

        // Should not work with release version
        var action2 = () => _validator.ValidateLicenseKey(licenseKey, "1.0.0", licenseInfo.Email);
        action2.Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public void LicenseKeyGenerated_ShouldMatch_KeyGeneratedByGolang()
    {
        var licenseKey =
            "HQBSAzEuMAEAAQEBAAEBqpmzUSRUQbjKldVKUtKZjDCBiAJCAet_swvLdlJQiUJxgSDK_3szoN58nmrcQsCnqzqZKQMyqlHfrJJ-9P7D9ewlCsArH42EmlZOM4yaUaxwewpcG9nMAkIBWIH3bQvZ0z3N47o0M9M7raMcyUIOXAZZqHYjFPe5taZXGHjfpCWOzsbolyiMDWVm902gZjHLO0s5bNT2_jjhIjs";
        var prvKey = Convert.FromBase64String(
            "MIHuAgEAMBAGByqGSM49AgEGBSuBBAAjBIHWMIHTAgEBBEIB225zUO5OZwsGcwuGLULB68Qdo4x5vn7C5xIjyoN9+hDEjgwdf9RUcCKXL7nen8dURnJVdlBa9v4ePavFVZc7/RmhgYkDgYYABAFJnbMh5J5uRcvV/niMFPnev+RPmMcqqllP2TW4BZDx+oL46n3xeDXmquOrsen5IZQ0sDN8VU4RrlZ5LhsVUoxsxgAIaCM3CPrQ4hblrvZ6mQTwlZLmH2qMKn/TAWwHkx55Y3QeUSCMY/I5fd6u5cSiFapNeqKpQ3SBPf+YEoEm2f9EBA==");
        var generator = new LicenseKeyGenerator(prvKey, _testOutputHelper);
        var licenseInfo = new LicenseInfo
        {
            Email = "test@example.com",
            Version = "0",
            VersionType = "Beta",
        };
        var ourLicenseKey = generator.GenerateLicenseKey(licenseInfo);
        ourLicenseKey.Should().NotBeNullOrEmpty();
        var publicKey = Convert.FromBase64String(
            "MIGbMBAGByqGSM49AgEGBSuBBAAjA4GGAAQBSZ2zIeSebkXL1f54jBT53r/kT5jHKqpZT9k1uAWQ8fqC+Op98Xg15qrjq7Hp+SGUNLAzfFVOEa5WeS4bFVKMbMYACGgjNwj60OIW5a72epkE8JWS5h9qjCp/0wFsB5MeeWN0HlEgjGPyOX3eruXEohWqTXqiqUN0gT3/mBKBJtn/RAQ="
        );
        var validator = new LicenseKeyValidator(publicKey);
        var cSharpLicenseInfo = validator.ValidateLicenseKey(ourLicenseKey, "0.1.1", licenseInfo.Email);
        cSharpLicenseInfo.Should().NotBeNull();
        cSharpLicenseInfo.Email.Should().Be(licenseInfo.Email);
        var golangLicenseInfo = validator.ValidateLicenseKey(licenseKey, "0.1.1", licenseInfo.Email);
        golangLicenseInfo.Should().NotBeNull();
        golangLicenseInfo.Email.Should().Be(licenseInfo.Email);
    }

    [Fact]
    public void ValidateLicenseKey_GeneratedByGolang_ShouldBeValid()
    {
        var licenseKey =
            "HQBSAzEuMAEAAQEBAAEBqpmzUSRUQbjKldVKUtKZjDCBhwJCARIwTgp0HMBJpxEFmL-bG_KFz9bviFTJHhJlxwh2e622srTfX0Q0URFalZ330xXsCCMRhRtlaCTxoLGqa-35o6-RAkEvcyA7btXMV89fyZMeMcup7NyM3I0rRFz3kh4cMuzPogd6F__eIS2QzR5uO_q9QeplnwBmBgSCFN_gkYySgLjPPQ";
        var publicKey = Convert.FromBase64String(
            "MIGbMBAGByqGSM49AgEGBSuBBAAjA4GGAAQAO0SD3ncynDRzRvXJ6WKtLHAjQb39g+mpatQdzj84rAH/oRckQaxXrG0+7KjxTFv//lYK/2GjPLJTlunSxgej6ygAyM9gKAG2C2J/fAedITBOP1eEDefTXyQREQ/q2GIabT7BfGp6BHY5wX+zw/bszg+hjlizSml07gSrA528JAf9OHk="
        );
        var validator = new LicenseKeyValidator(publicKey);
        var licenseInfo = validator.ValidateLicenseKey(licenseKey, "1.0.1", "test1@example.com");
        licenseInfo.Should().NotBeNull();
        licenseInfo.Email.Should().Be("test1@example.com");
    }
}