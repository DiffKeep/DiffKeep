using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using NetVips;
using System.Text.Json;

namespace DiffKeep.Parsing;

public enum ImageGenerationTool
{
    Unknown,
    ComfyUI,
    Automatic1111,
    Fooocus,
    // Add more tools as needed
}

public interface IPromptParser
{
    string ExtractPrompt(JsonDocument promptData);
    JsonDocument GetWorkflowData(JsonDocument workflowData);
}

public class ImageMetadata
{
    public ImageGenerationTool Tool { get; set; }
    public string? Prompt { get; set; }
    public JsonDocument? WorkflowData { get; set; }
    public Dictionary<string, string?>? RawMetadata { get; set; }
}

public class PngMetadataParser
{
    private static readonly Dictionary<ImageGenerationTool, IPromptParser> Parsers = new();

    static PngMetadataParser()
    {
        // Register parsers for different tools
        Parsers[ImageGenerationTool.ComfyUI] = new ComfyUIParser();
        Parsers[ImageGenerationTool.Automatic1111] = new Automatic1111Parser();
        Parsers[ImageGenerationTool.Fooocus] = new FooocusParser();
    }

    public static ImageMetadata ParseImage(string filePath)
    {
        using var image = Image.NewFromFile(filePath);
        
        // Collect all metadata chunks
        var metadataChunks = new Dictionary<string, string?>();
        
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
                metadataChunks[chunkName] = value;
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
        if (tool != ImageGenerationTool.Unknown && metadataChunks.Any())
        {
            var parser = Parsers[tool];
            

            if (metadataChunks.TryGetValue("workflow", out var workflowJson))
            {
                if (workflowJson != null)
                {
                    var workflowData = JsonDocument.Parse(workflowJson);
                    result.WorkflowData = parser.GetWorkflowData(workflowData);
                    result.Prompt = parser.ExtractPrompt(workflowData);
                }
            }

            if (!metadataChunks.TryGetValue("prompt", out var promptJson) || promptJson == null) return result;
            var promptData = JsonDocument.Parse(promptJson);
            
        }

        return result;
    }

    private static ImageGenerationTool DetectGenerationTool(Dictionary<string, string?> metadata)
    {
        // ComfyUI typically has both 'prompt' and 'workflow' in tEXt chunks
        if (metadata.TryGetValue("prompt", out string? value) && metadata.ContainsKey("workflow"))
        {
            try
            {
                var promptData = JsonDocument.Parse(value ?? throw new InvalidDataException());
                // ComfyUI prompts typically have numbered nodes with class_type
                if (promptData.RootElement.EnumerateObject()
                    .Any(prop => prop.Value.TryGetProperty("class_type", out _)))
                {
                    return ImageGenerationTool.ComfyUI;
                }
            }
            catch { }
        }

        // Automatic1111 typically stores parameters in 'parameters'
        if (metadata.TryGetValue("parameters", out string? parameters))
        {
            try
            {
                if (parameters != null && (parameters.Contains("Steps:") || parameters.Contains("Sampler:")))
                {
                    return ImageGenerationTool.Automatic1111;
                }
            }
            catch { }
        }

        // Fooocus has its own specific metadata pattern
        if (metadata.Any(m => m.Key.Contains("fooocus", StringComparison.OrdinalIgnoreCase)))
        {
            return ImageGenerationTool.Fooocus;
        }

        return ImageGenerationTool.Unknown;
    }
}