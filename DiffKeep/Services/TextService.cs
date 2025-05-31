using System;

namespace DiffKeep.Services;

public class TextService
{
    public static string? TruncateIntelligently(string? text, int maxLength)
    {
        if (text == null)
            return null;
            
        if (string.IsNullOrEmpty(text) || maxLength <= 0)
            return "";

        if (text.Length <= maxLength)
            return text;

        // Try to break at sentence end (.!?)
        var lastSentenceBreak = FindLastBreakingCharacter(text, maxLength, ".!?");
        if (lastSentenceBreak > 0)
            return text[..lastSentenceBreak].TrimEnd();

        // Try to break at punctuation (,;:)
        var lastPunctuationBreak = FindLastBreakingCharacter(text, maxLength, ",;:");
        if (lastPunctuationBreak > 0)
            return text[..lastPunctuationBreak].TrimEnd();

        // Try to break at whitespace
        var lastSpaceBreak = text.LastIndexOf(' ', Math.Min(maxLength - 1, text.Length - 1));
        if (lastSpaceBreak > 0)
            return text[..lastSpaceBreak].TrimEnd();

        // If all else fails, just cut at maxLength
        return text[..Math.Min(maxLength, text.Length)].TrimEnd();
    }

    private static int FindLastBreakingCharacter(string text, int maxLength, string breakingChars)
    {
        var searchEnd = Math.Min(text.Length, maxLength);
        var lastIndex = -1;

        foreach (var breakChar in breakingChars)
        {
            var index = text.LastIndexOf(breakChar, searchEnd - 1);
            if (index > lastIndex)
                lastIndex = index + 1; // Include the breaking character
        }

        return lastIndex;
    }

}