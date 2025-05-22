using System;
using System.Text.Json;

namespace DiffKeep.Parsing;

public class FooocusParser : IPromptParser
{
    public string ExtractPrompt(JsonDocument promptData)
    {
        // Implement Fooocus-specific prompt extraction
        throw new NotImplementedException();
    }

    public JsonDocument GetWorkflowData(JsonDocument workflowData)
    {
        throw new NotImplementedException();
    }
}