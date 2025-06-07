using System;
using System.Text.Json;

namespace DiffKeep.Parsing;

public class Automatic1111Parser : IPromptParser
{
    public ParsedImageMetadata ExtractPrompt(JsonDocument promptData)
    {
        throw new NotImplementedException();
    }

    public ParsedImageMetadata ExtractPrompt(string promptData)
    {
        if (string.IsNullOrWhiteSpace(promptData))
        {
            return new ParsedImageMetadata();
        }

        // Initialize result
        var result = new ParsedImageMetadata();
        
        // Check if the string contains a negative prompt marker
        const string negativePromptMarker = "\nNegative prompt:";
        int negativePromptIndex = promptData.IndexOf(negativePromptMarker, StringComparison.OrdinalIgnoreCase);
        
        if (negativePromptIndex == -1)
        {
            // No negative prompt found, treat the entire string as positive prompt
            // Look for other metadata markers to trim the positive prompt
            int metadataIndex = promptData.IndexOf("\nSteps:", StringComparison.OrdinalIgnoreCase);
            if (metadataIndex == -1)
            {
                // No metadata markers found, use the entire string
                result.PositivePrompt = promptData.Trim();
            }
            else
            {
                // Trim at metadata marker
                result.PositivePrompt = promptData.Substring(0, metadataIndex).Trim();
            }
        }
        else
        {
            // Extract positive prompt (everything before the negative prompt marker)
            result.PositivePrompt = promptData.Substring(0, negativePromptIndex).Trim();
            
            // Find where the metadata starts (after negative prompt)
            int metadataIndex = promptData.IndexOf("\nSteps:", negativePromptIndex, StringComparison.OrdinalIgnoreCase);
            if (metadataIndex == -1)
            {
                // No metadata markers found, use the rest as negative prompt
                result.NegativePrompt = promptData.Substring(negativePromptIndex + negativePromptMarker.Length).Trim();
            }
            else
            {
                // Extract negative prompt (between negative prompt marker and metadata)
                result.NegativePrompt = promptData
                    .Substring(
                        negativePromptIndex + negativePromptMarker.Length, 
                        metadataIndex - (negativePromptIndex + negativePromptMarker.Length))
                    .Trim();
            }
        }
        
        // handle trimming and replacing and \n with newlines
        result.PositivePrompt = result.PositivePrompt?
            .Trim();
        result.NegativePrompt = result.NegativePrompt?
            .Trim();
        
        return result;
    }
}