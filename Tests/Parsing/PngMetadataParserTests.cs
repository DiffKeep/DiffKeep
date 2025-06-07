using DiffKeep.Parsing;
using Xunit;

namespace Tests.Parsing;
public class PngMetadataParserTests
{
    private const string ExpectedPrompt = "this is the prompt text! it has lots of cool stuff in it";

    [Theory]
    [InlineData("comfyui-test.png", GenerationTool.ComfyUI)]
    [InlineData("automatic1111-test.png", GenerationTool.Automatic1111)]
    //[InlineData("fooocus-test.png", GenerationTool.Fooocus)]
    public void ParseImage_DetectsCorrectTool(string imageFile, GenerationTool expectedTool)
    {
        // Arrange
        var imagePath = Path.Combine(GetArtifactDirectory(), imageFile);
        var parser = new PngMetadataParser();

        // Act
        var metadata = parser.ParseImage(imagePath);

        // Assert
        Assert.Equal(expectedTool, metadata.Tool);
    }
    
    public static string GetArtifactDirectory()
    {
        return TestHelpers.GetTestArtifactPath("");
    }

    [Fact]
    public void ParseImage_ForComfyUI_ExtractsExpectedPrompt()
    {
        // Arrange
        var imagePath = Path.Combine(GetArtifactDirectory(), "comfyui-test.png");
        var parser = new PngMetadataParser();

        // Act
        var metadata = parser.ParseImage(imagePath);

        // Assert
        Assert.StartsWith("A young anime-style woman stands at a castle", metadata.PositivePrompt);
    }
    
    [Fact]
    public void ParseImage_ForAutomatic1111_ExtractsExpectedPrompt()
    {
        // Arrange
        var imagePath = Path.Combine(GetArtifactDirectory(), "automatic1111-test.png");
        var parser = new PngMetadataParser();

        // Act
        var metadata = parser.ParseImage(imagePath);

        // Assert
        Assert.StartsWith("8k beautiful elegant angel woman", metadata.PositivePrompt);
        Assert.StartsWith("BadDream FastNegativeEmbedding ((crossed", metadata.NegativePrompt);
    }

    [Fact]
    public void ParseImage_WithNonexistentFile_ThrowsFileNotFoundException()
    {
        var parser = new PngMetadataParser();
        Assert.Throws<NetVips.VipsException>(() => 
            parser.ParseImage("nonexistent.png"));
    }

    [Fact]
    public void ParseImage_WithInvalidPng_ThrowsException()
    {
        var invalidPngPath = Path.GetTempFileName();
        File.WriteAllText(invalidPngPath, "not a png");
        var parser = new PngMetadataParser();
        
        Assert.ThrowsAny<Exception>(() => 
            parser.ParseImage(invalidPngPath));
        
        File.Delete(invalidPngPath);
    }
}