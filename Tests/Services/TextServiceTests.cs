using DiffKeep.Services;
using Xunit;

namespace Tests.Services;

public class TextServiceTests
{
    [Fact]
    public void NullString_Should_ReturnNull()
    {
        // Act
        var result = TextService.TruncateIntelligently(null!, 10);

        // Assert
        Assert.Null(result);
    }

    [Fact]
    public void EmptyString_Should_ReturnEmptyString()
    {
        // Act
        var result = TextService.TruncateIntelligently("", 10);

        // Assert
        Assert.Empty(result);
    }

    [Fact]
    public void ShortString_Should_ReturnOriginalString()
    {
        // Arrange
        var text = "Short text";

        // Act
        var result = TextService.TruncateIntelligently(text, 20);

        // Assert
        Assert.Equal(text, result);
    }

    [Fact]
    public void BreakAtSentence_Should_TruncateAtSentenceEnd()
    {
        // Arrange
        var text = "This is one sentence. This is another one.";

        // Act
        var result = TextService.TruncateIntelligently(text, 25);

        // Assert
        Assert.Equal("This is one sentence.", result);
    }

    [Fact]
    public void BreakAtSentence_Should_HandleMultiplePunctuation()
    {
        // Arrange
        var text = "First sentence! Second sentence? Third sentence.";

        // Act
        var result = TextService.TruncateIntelligently(text, 35);

        // Assert
        Assert.Equal("First sentence! Second sentence?", result);
    }

    [Fact]
    public void BreakAtPunctuation_Should_TruncateAtCommaWhenNoSentenceBreak()
    {
        // Arrange
        var text = "This text has no sentence break, but has commas, and continues";

        // Act
        var result = TextService.TruncateIntelligently(text, 50);

        // Assert
        Assert.Equal("This text has no sentence break, but has commas,", result);
    }

    [Fact]
    public void BreakAtSpace_Should_TruncateAtWordBoundaryWhenNoPunctuation()
    {
        // Arrange
        var text = "This text has no punctuation but has spaces and continues";

        // Act
        var result = TextService.TruncateIntelligently(text, 25);

        // Assert
        Assert.Equal("This text has no", result);
    }

    [Fact]
    public void BreakAtExactLength_Should_TruncateWhenNoOtherBreaks()
    {
        // Arrange
        var text = "ThisTextHasNoBreaksAtAll";

        // Act
        var result = TextService.TruncateIntelligently(text, 10);

        // Assert
        Assert.Equal("ThisTextHa", result);
    }

    [Fact]
    public void Should_PreserveLeadingWhitespace()
    {
        // Arrange
        var text = "    Indented text. More text.";

        // Act
        var result = TextService.TruncateIntelligently(text, 20);

        // Assert
        Assert.Equal("    Indented text.", result);
    }

    [Fact]
    public void Should_RemoveTrailingWhitespace()
    {
        // Arrange
        var text = "Text with spaces    . More text";

        // Act
        var result = TextService.TruncateIntelligently(text, 20);

        // Assert
        Assert.Equal("Text with spaces", result);
    }

    [Fact]
    public void Should_HandleMultipleConsecutivePunctuation()
    {
        // Arrange
        var text = "This is a sentence...and more text";

        // Act
        var result = TextService.TruncateIntelligently(text, 25);

        // Assert
        Assert.Equal("This is a sentence...", result);
    }

    [Fact]
    public void ZeroMaxLength_Should_ReturnEmptyString()
    {
        // Arrange
        var text = "Some text";

        // Act
        var result = TextService.TruncateIntelligently(text, 0);

        // Assert
        Assert.Empty(result);
    }

    [Fact]
    public void NegativeMaxLength_Should_ReturnEmptyString()
    {
        // Arrange
        var text = "Some text";

        // Act
        var result = TextService.TruncateIntelligently(text, -5);

        // Assert
        Assert.Empty(result);
    }

    [Fact]
    public void MaxLengthExactlyStringLength_Should_ReturnOriginalString()
    {
        // Arrange
        var text = "Exactly20Characters!";

        // Act
        var result = TextService.TruncateIntelligently(text, 20);

        // Assert
        Assert.Equal(text, result);
    }
}