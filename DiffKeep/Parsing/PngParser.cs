using System;
using System.Collections.Generic;
using System.Linq;
using NetVips;
using System.Text.Json;
using DiffKeep.Parsing;

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
    public string Prompt { get; set; }
    public JsonDocument WorkflowData { get; set; }
    public Dictionary<string, string> RawMetadata { get; set; }
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
        var metadataChunks = new Dictionary<string, string>();
        
        // Get all fields that start with "png-" as these contain the PNG chunks
        foreach (var field in image.GetFields())
        {
            if (field.StartsWith("png-"))
            {
                // Remove "png-" prefix to get the actual chunk name
                var chunkName = field.Substring(4);
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
            
            if (metadataChunks.TryGetValue("tEXt-prompt", out var promptJson) || 
                metadataChunks.TryGetValue("iTXt-prompt", out promptJson))
            {
                var promptData = JsonDocument.Parse(promptJson);
                result.Prompt = parser.ExtractPrompt(promptData);
            }

            if (metadataChunks.TryGetValue("tEXt-workflow", out var workflowJson) || 
                metadataChunks.TryGetValue("iTXt-workflow", out workflowJson))
            {
                var workflowData = JsonDocument.Parse(workflowJson);
                result.WorkflowData = parser.GetWorkflowData(workflowData);
            }
        }

        return result;
    }

    private static ImageGenerationTool DetectGenerationTool(Dictionary<string, string> metadata)
    {
        // ComfyUI typically has both 'prompt' and 'workflow' in iTXt chunks
        if (metadata.ContainsKey("prompt") && metadata.ContainsKey("workflow"))
        {
            try
            {
                var promptData = JsonDocument.Parse(metadata["prompt"]);
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
        if (metadata.ContainsKey("parameters"))
        {
            try
            {
                var parameters = metadata["parameters"];
                if (parameters.Contains("Steps:") || parameters.Contains("Sampler:"))
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