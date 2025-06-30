using System.Text.Json;
using DiffKeep.Parsing;
using Xunit;

namespace Tests.Parsing;

public class Automatic1111ParserTests
{
    private const string ExpectedPrompt = "this is the prompt text! it has lots of cool stuff in it";
    private const string ExpectedNegativePrompt = "this is a prompt too but it's negative!";
    
    [Theory]
    [MemberData(nameof(GetTestFiles))]
    public void ParsePrompt_FromWorkflow_ExtractsExpectedPrompt(string workflowFile)
    {
        // Arrange
        var parser = new Automatic1111Parser();
        var parameters = File.ReadAllText(workflowFile);

        // Act
        var prompts = parser.ExtractPrompt(parameters);

        // Assert
        Assert.Equal(ExpectedPrompt, prompts.PositivePrompt);
        Assert.Equal(ExpectedNegativePrompt, prompts.NegativePrompt);
    }

    public static IEnumerable<object[]> GetTestFiles()
    {
        var workflowDir = TestHelpers.GetTestArtifactPath("automatic1111-metadata");
        return Directory.GetFiles(workflowDir, "*.txt")
            .Select(file => new object[] { file });
    }

    [Fact]
    public void ParsePrompt_WithNoMetadata_ReturnsEmptyString()
    {
        // Arrange
        var parser = new Automatic1111Parser();
        var emptyParameters = "";

        // Act
        var result = parser.ExtractPrompt(emptyParameters);

        // Assert
        Assert.Null(result.PositivePrompt);
        Assert.Null(result.NegativePrompt);
    }
}