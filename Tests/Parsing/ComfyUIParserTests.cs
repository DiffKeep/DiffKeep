using System.Text.Json;
using DiffKeep.Parsing;
using Xunit;

namespace Tests.Parsing;

public class ComfyUIParserTests
{
    private const string ExpectedPrompt = "this is the prompt text! it has lots of cool stuff in it";
    
    [Theory]
    [MemberData(nameof(GetWorkflowFiles))]
    public void ParsePrompt_FromWorkflow_ExtractsExpectedPrompt(string workflowFile)
    {
        // Arrange
        var parser = new ComfyUIParser();
        var promptJson = File.ReadAllText(workflowFile);
        var promptData = JsonDocument.Parse(promptJson);

        // Act
        var extractedPrompt = parser.ExtractPrompt(promptData);

        // Assert
        if (extractedPrompt.StartsWith("IMAGE:"))
        {
            Assert.Equal("IMAGE: image.png", extractedPrompt);
        }
        else
        {
            Assert.Equal(ExpectedPrompt, extractedPrompt);
        }

    }

    public static IEnumerable<object[]> GetWorkflowFiles()
    {
        var workflowDir = TestHelpers.GetTestArtifactPath("comfyui-workflows");
        return Directory.GetFiles(workflowDir, "*.json")
            .Select(file => new object[] { file });
    }

    [Fact]
    public void ParsePrompt_WithNoPromptNodes_ReturnsEmptyString()
    {
        // Arrange
        var parser = new ComfyUIParser();
        var emptyWorkflow = JsonDocument.Parse("{}");

        // Act
        var result = parser.ExtractPrompt(emptyWorkflow);

        // Assert
        Assert.Empty(result);
    }

    [Fact]
    public void ParsePrompt_WithInvalidJson_ThrowsJsonException()
    {
        // Arrange
        var parser = new ComfyUIParser();
        
        // Act & Assert
        Assert.Throws<JsonException>(() => 
            parser.ExtractPrompt(JsonDocument.Parse("invalid json")));
    }
}