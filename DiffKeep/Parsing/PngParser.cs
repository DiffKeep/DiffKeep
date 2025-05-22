using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using NetVips;
using System.Text.Json;

namespace DiffKeep.Parsing;

public interface IPromptParser
{
    string ExtractPrompt(JsonDocument promptData);
    JsonDocument GetWorkflowData(JsonDocument workflowData);
}

public class PngMetadataParser : IImageParser
{
    private static readonly Dictionary<GenerationTool, IPromptParser> Parsers = new();

    static PngMetadataParser()
    {
        // Register parsers for different tools
        Parsers[GenerationTool.ComfyUI] = new ComfyUIParser();
        Parsers[GenerationTool.Automatic1111] = new Automatic1111Parser();
        Parsers[GenerationTool.Fooocus] = new FooocusParser();
    }

    public ImageMetadata ParseImage(string filePath)
    {
        Debug.Print($"Parsing PNG metadata for {filePath}");
        using var image = Image.NewFromFile(filePath);
        
        // Collect all metadata chunks
        var metadataChunks = new List<KeyValuePair<string, string?>>();
        
        // Get all fields that start with "png-" as these contain the PNG chunks
        foreach (var field in image.GetFields())
        {
            Debug.Print($"Found field: {field} with value: {image.Get(field)}");
            if (field.StartsWith("png-comment-"))
            {
                // Format is "png-comment-0-{chunk name}" where the 0 will be incremented for each chunk
                // We want to remove everything but the chunk name
                // This won't work for images that have more than 10 chunks, but we don't expect that to happen
                var chunkName = field.Substring(14);
                var value = image.Get(field).ToString();
                metadataChunks.Add(new KeyValuePair<string, string?>(chunkName, value));
            }
        }

        // Detect which tool generated the image
        var tool = DetectGenerationTool(metadataChunks);

        var result = new ImageMetadata
        {
            Tool = tool,
            RawMetadata = metadataChunks
        };

        // If we recognize the tool, use its specific parser
        if (tool != GenerationTool.Unknown && metadataChunks.Any())
        {
            // Check for non-JSON prompt chunks first
            // This fixes the case where there is an additional "prompt" metadata entry that is just the image prompt
            // Check for non-JSON prompt chunks first
            var promptEntries = metadataChunks.Where(m => m.Key == "prompt");
            foreach (var promptEntry in promptEntries)
            {
                var value = promptEntry.Value?.Trim();
                if (string.IsNullOrEmpty(value)) continue;

                // If it doesn't start with { or [, it's likely a plain text prompt
                if (!value.StartsWith("{") && !value.StartsWith("["))
                {
                    result.Prompt = value;
                    return result;
                }
            }

            // If we get here, we didn't find any non-JSON prompts, so try parsing JSON
            var parser = Parsers[tool];
    
            var workflowEntry = metadataChunks.FirstOrDefault(m => m.Key == "workflow");
            if (workflowEntry.Value != null)
            {
                try
                {
                    var workflowData = JsonDocument.Parse(workflowEntry.Value);
                    result.Prompt = parser.ExtractPrompt(workflowData);
                    return result;
                }
                catch
                {
                    // Invalid JSON in workflow, continue
                }
            }

            // Try JSON prompts as last resort
            foreach (var promptEntry in promptEntries)
            {
                if (promptEntry.Value == null) continue;

                try
                {
                    var promptData = JsonDocument.Parse(promptEntry.Value);
                    result.Prompt = parser.ExtractPrompt(promptData);
                    return result;
                }
                catch
                {
                    // Invalid JSON, skip
                }
            }
        }

        return result;
    }

    private static GenerationTool DetectGenerationTool(List<KeyValuePair<string, string?>> metadata)
    {
        // ComfyUI typically has both 'prompt' and 'workflow' in tEXt chunks
        var promptEntries = metadata.Where(m => m.Key == "prompt");
        var hasWorkflow = metadata.Any(m => m.Key == "workflow");

        if (hasWorkflow)
        {
            foreach (var promptEntry in promptEntries)
            {
                try
                {
                    var promptData = JsonDocument.Parse(promptEntry.Value ?? throw new InvalidDataException());
                    // ComfyUI prompts typically have numbered nodes with class_type
                    if (promptData.RootElement.EnumerateObject()
                        .Any(prop => prop.Value.TryGetProperty("class_type", out _)))
                    {
                        return GenerationTool.ComfyUI;
                    }
                }
                catch 
                {
                    // Not a JSON prompt, continue to next one
                    continue;
                }
            }
        }

        // Automatic1111 typically stores parameters in 'parameters'
        var parametersEntry = metadata.FirstOrDefault(m => m.Key == "parameters");
        if (parametersEntry.Value != null)
        {
            try
            {
                if (parametersEntry.Value.Contains("Steps:") || parametersEntry.Value.Contains("Sampler:"))
                {
                    return GenerationTool.Automatic1111;
                }
            }
            catch { }
        }

        // Fooocus has its own specific metadata pattern
        if (metadata.Any(m => m.Key.Contains("fooocus", StringComparison.OrdinalIgnoreCase)))
        {
            return GenerationTool.Fooocus;
        }

        return GenerationTool.Unknown;
    }
}