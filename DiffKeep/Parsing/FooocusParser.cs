using System;
using System.Text.Json;

namespace DiffKeep.Parsing;

public class FooocusParser : IPromptParser
{
    public ParsedImageMetadata ExtractPrompt(JsonDocument promptData)
    {
        // Implement Fooocus-specific prompt extraction
        throw new NotImplementedException();
    }

    public ParsedImageMetadata ExtractPrompt(string promptData)
    {
        throw new NotImplementedException();
    }
}