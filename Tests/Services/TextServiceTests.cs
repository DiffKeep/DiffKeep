using DiffKeep.Services;
using FluentAssertions;

namespace Tests.Services;

public class TextServiceTests
{
    [Fact]
    public void NullString_Should_ReturnNull()
    {
        // Act
        var result = TextService.TruncateIntelligently(null!, 10);

        // Assert
        result.Should().BeNull();
    }

    [Fact]
    public void EmptyString_Should_ReturnEmptyString()
    {
        // Act
        var result = TextService.TruncateIntelligently("", 10);

        // Assert
        result.Should().BeEmpty();
    }

    [Fact]
    public void ShortString_Should_ReturnOriginalString()
    {
        // Arrange
        var text = "Short text";

        // Act
        var result = TextService.TruncateIntelligently(text, 20);

        // Assert
        result.Should().Be(text);
    }

    [Fact]
    public void BreakAtSentence_Should_TruncateAtSentenceEnd()
    {
        // Arrange
        var text = "This is one sentence. This is another one.";

        // Act
        var result = TextService.TruncateIntelligently(text, 25);

        // Assert
        result.Should().Be("This is one sentence.");
    }

    [Fact]
    public void BreakAtSentence_Should_HandleMultiplePunctuation()
    {
        // Arrange
        var text = "First sentence! Second sentence? Third sentence.";

        // Act
        var result = TextService.TruncateIntelligently(text, 35);

        // Assert
        result.Should().Be("First sentence! Second sentence?");
    }

    [Fact]
    public void BreakAtPunctuation_Should_TruncateAtCommaWhenNoSentenceBreak()
    {
        // Arrange
        var text = "This text has no sentence break, but has commas, and continues";

        // Act
        var result = TextService.TruncateIntelligently(text, 50);

        // Assert
        result.Should().Be("This text has no sentence break, but has commas,");
    }

    [Fact]
    public void BreakAtSpace_Should_TruncateAtWordBoundaryWhenNoPunctuation()
    {
        // Arrange
        var text = "This text has no punctuation but has spaces and continues";

        // Act
        var result = TextService.TruncateIntelligently(text, 25);

        // Assert
        result.Should().Be("This text has no");
    }

    [Fact]
    public void BreakAtExactLength_Should_TruncateWhenNoOtherBreaks()
    {
        // Arrange
        var text = "ThisTextHasNoBreaksAtAll";

        // Act
        var result = TextService.TruncateIntelligently(text, 10);

        // Assert
        result.Should().Be("ThisTextHa");
    }

    [Fact]
    public void Should_PreserveLeadingWhitespace()
    {
        // Arrange
        var text = "    Indented text. More text.";

        // Act
        var result = TextService.TruncateIntelligently(text, 20);

        // Assert
        result.Should().Be("    Indented text.");
    }

    [Fact]
    public void Should_RemoveTrailingWhitespace()
    {
        // Arrange
        var text = "Text with spaces    . More text";

        // Act
        var result = TextService.TruncateIntelligently(text, 20);

        // Assert
        result.Should().Be("Text with spaces");
    }

    [Fact]
    public void Should_HandleMultipleConsecutivePunctuation()
    {
        // Arrange
        var text = "This is a sentence...and more text";

        // Act
        var result = TextService.TruncateIntelligently(text, 25);

        // Assert
        result.Should().Be("This is a sentence...");
    }

    [Fact]
    public void ZeroMaxLength_Should_ReturnEmptyString()
    {
        // Arrange
        var text = "Some text";

        // Act
        var result = TextService.TruncateIntelligently(text, 0);

        // Assert
        result.Should().BeEmpty();
    }

    [Fact]
    public void NegativeMaxLength_Should_ReturnEmptyString()
    {
        // Arrange
        var text = "Some text";

        // Act
        var result = TextService.TruncateIntelligently(text, -5);

        // Assert
        result.Should().BeEmpty();
    }

    [Fact]
    public void MaxLengthExactlyStringLength_Should_ReturnOriginalString()
    {
        // Arrange
        var text = "Exactly20Characters!";

        // Act
        var result = TextService.TruncateIntelligently(text, 20);

        // Assert
        result.Should().Be(text);
    }

}