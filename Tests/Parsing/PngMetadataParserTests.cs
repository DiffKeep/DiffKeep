using DiffKeep.Parsing;
using Xunit;

namespace Tests.Parsing;
public class PngMetadataParserTests
{
    private const string ExpectedPrompt = "this is the prompt text! it has lots of cool stuff in it";

    [Theory]
    [InlineData("comfyui-test.png", ImageGenerationTool.ComfyUI)]
    [InlineData("automatic1111-test.png", ImageGenerationTool.Automatic1111)]
    //[InlineData("fooocus-test.png", ImageGenerationTool.Fooocus)]
    public void ParseImage_DetectsCorrectTool(string imageFile, ImageGenerationTool expectedTool)
    {
        // Arrange
        var imagePath = Path.Combine(GetArtifactDirectory(), imageFile);

        // Act
        var metadata = PngMetadataParser.ParseImage(imagePath);

        // Assert
        Assert.Equal(expectedTool, metadata.Tool);
    }
    
    public static string GetArtifactDirectory()
    {
        return TestHelpers.GetTestArtifactPath("");
    }

    [Theory]
    [InlineData("comfyui-test.png")]
    public void ParseImage_ExtractsExpectedPrompt(string imageFile)
    {
        // Arrange
        var imagePath = Path.Combine(GetArtifactDirectory(), imageFile);

        // Act
        var metadata = PngMetadataParser.ParseImage(imagePath);

        // Assert
        Assert.StartsWith("A young anime-style woman stands at a castle", metadata.Prompt);
    }

    [Fact]
    public void ParseImage_WithNonexistentFile_ThrowsFileNotFoundException()
    {
        Assert.Throws<NetVips.VipsException>(() => 
            PngMetadataParser.ParseImage("nonexistent.png"));
    }

    [Fact]
    public void ParseImage_WithInvalidPng_ThrowsException()
    {
        var invalidPngPath = Path.GetTempFileName();
        File.WriteAllText(invalidPngPath, "not a png");
        
        Assert.ThrowsAny<Exception>(() => 
            PngMetadataParser.ParseImage(invalidPngPath));
        
        File.Delete(invalidPngPath);
    }
}