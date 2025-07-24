
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using Xunit.Abstractions;
using Xunit.Sdk;
using Xunit;

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
        Assert.NotNull(prv);
        Assert.NotEmpty(prv);
        Assert.NotNull(pub);
        Assert.NotEmpty(pub);
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
        Assert.NotNull(licenseKey);
        Assert.NotEmpty(licenseKey);
        Assert.DoesNotContain("=", licenseKey); // Should not contain padding
        Assert.DoesNotContain("+", licenseKey); // Should use URL-safe base64
        Assert.DoesNotContain("/", licenseKey); // Should use URL-safe base64
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
        Assert.NotNull(validatedInfo);
        Assert.Equal(originalInfo.Email, validatedInfo.Email);
        Assert.Equal(originalInfo.VersionType, validatedInfo.VersionType);
        Assert.Equal(originalInfo.Version, validatedInfo.Version);
        Assert.Equal(originalInfo.ValidFrom?.Date, validatedInfo.ValidFrom?.Date);
        Assert.Equal(originalInfo.ValidUntil?.Date, validatedInfo.ValidUntil?.Date);
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
        var ex = Assert.Throws<InvalidOperationException>(() => 
            _validator.ValidateLicenseKey(licenseKey, expiredInfo.Version, expiredInfo.Email));
        Assert.Equal("Invalid license key.", ex.Message);
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
        var ex = Assert.Throws<InvalidOperationException>(() => 
            _validator.ValidateLicenseKey(licenseKey, futureInfo.Version, futureInfo.Email));
        Assert.Equal("Invalid license key.", ex.Message);
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
        Assert.Equal(undatedInfo.Email, licenseInfo.Email);
    }

    [Fact]
    public void ValidateLicenseKey_WithInvalidKey_ShouldThrowException()
    {
        // Arrange
        var invalidKey = "ThisIsNotAValidLicenseKey";

        // Act & Assert
        Assert.Throws<InvalidOperationException>(() => 
            _validator.ValidateLicenseKey(invalidKey, "1.0.0", "random@example.com"));
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
        var ex = Assert.Throws<InvalidOperationException>(() => 
            differentValidator.ValidateLicenseKey(licenseKey, licenseInfo.Version, licenseInfo.Email));
        Assert.Equal("Invalid license key.", ex.Message);
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
        Assert.Equal(versionType, validatedInfo.VersionType);
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
            Assert.Equal(licenseVersion, validatedInfo.Version);
        }
        else
        {
            var ex = Assert.Throws<InvalidOperationException>(() => 
                _validator.ValidateLicenseKey(licenseKey, currentVersion, licenseInfo.Email));
            Assert.Equal("Invalid license key.", ex.Message);
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
        Assert.NotNull(validatedInfo);

        // Should not work with different version
        Assert.Throws<InvalidOperationException>(() => 
            _validator.ValidateLicenseKey(licenseKey, "0.2.0-beta.2", licenseInfo.Email));

        // Should not work with release version
        Assert.Throws<InvalidOperationException>(() => 
            _validator.ValidateLicenseKey(licenseKey, "1.0.0", licenseInfo.Email));
    }
}