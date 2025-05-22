using System;
using System.Text.Json;

namespace DiffKeep.Parsing;

public class Automatic1111Parser : IPromptParser
{
    public string ExtractPrompt(JsonDocument promptData)
    {
        // Implement A1111-specific prompt extraction
        // A1111 typically has a different format than ComfyUI
        throw new NotImplementedException();
    }

    public JsonDocument GetWorkflowData(JsonDocument workflowData)
    {
        throw new NotImplementedException();
    }
}