using System.Collections.Generic;
using System.Text.Json;

namespace DiffKeep.Parsing;

public class ComfyUIParser : IPromptParser
{
    private JsonElement nodes;
    private JsonElement links;

    public ParsedImageMetadata ExtractPrompt(JsonDocument workflowData)
    {
        if (!workflowData.RootElement.TryGetProperty("nodes", out nodes) ||
            !workflowData.RootElement.TryGetProperty("links", out links))
            return new ParsedImageMetadata();

        // Find all active save nodes
        var saveNodes = FindSaveImageNodes();
        
        // For each save node, trace back to find the prompt
        foreach (var saveNode in saveNodes)
        {
            var prompt = TraceBackToPrompt(saveNode);
            if (!string.IsNullOrEmpty(prompt))
                return new ParsedImageMetadata{ PositivePrompt = prompt };
        }

        return new ParsedImageMetadata();
    }

    public ParsedImageMetadata ExtractPrompt(string promptData)
    {
        throw new System.NotImplementedException();
    }

    private List<JsonElement> FindSaveImageNodes()
    {
        var saveNodes = new List<JsonElement>();
        var previewNodes = new List<JsonElement>();
        var clipspaceNodes = new List<JsonElement>();
        
        foreach (var node in nodes.EnumerateArray())
        {
            // Check if node is active (mode == 0)
            if (node.TryGetProperty("mode", out var mode) && mode.GetInt32() != 0)
                continue;

            // Check node type
            if (!node.TryGetProperty("type", out var typeElement))
                continue;

            var type = typeElement.GetString()?.ToLowerInvariant();
            if (string.IsNullOrEmpty(type))
                continue;

            // Skip if it doesn't have an IMAGE input
            if (!HasInputOfType(node, "IMAGE"))
                continue;

            // Categorize nodes based on their type
            if (type.Contains("clipspace"))
            {
                clipspaceNodes.Add(node);
            }
            else if (type == "previewimage")
            {
                previewNodes.Add(node);
            }
            else if (type.Contains("save") || type == "vhs_videocombine")
            {
                saveNodes.Add(node);
            }
        }

        // Return nodes in priority order: regular save nodes first, then preview nodes, then clipspace nodes
        saveNodes.AddRange(previewNodes);
        saveNodes.AddRange(clipspaceNodes);
        return saveNodes;
    }

    private string? TraceBackToPrompt(JsonElement node)
    {
        var visitedNodes = new HashSet<int>();
        var currentNode = node;

        while (true)
        {
            if (!currentNode.TryGetProperty("id", out var idElement))
                break;

            int nodeId = idElement.GetInt32();
            if (!visitedNodes.Add(nodeId)) // Prevent cycles
                break;

            // Check for LoadImage node
            if (currentNode.TryGetProperty("type", out var typeElement))
            {
                var type = typeElement.GetString();
                if (type == "LoadImage")
                {
                    if (currentNode.TryGetProperty("widgets_values", out var values) &&
                        values.GetArrayLength() > 0)
                    {
                        return $"IMAGE: {values[0].GetString()}";
                    }
                }
                else if (type?.Contains("Eff. Loader") == true)
                {
                    if (currentNode.TryGetProperty("widgets_values", out var values) &&
                        values.GetArrayLength() >= 8)
                    {
                        return values[7].GetString();
                    }
                }
                else if (type == "Prompt Generator")
                {
                    if (currentNode.TryGetProperty("widgets_values", out var values) &&
                        values.GetArrayLength() >= 4)
                    {
                        var prompt = values[4];
                        if (prompt.ValueKind != JsonValueKind.String)
                            prompt = values[3];
                        return prompt.GetString();
                    }
                }
            }

            // Check for CLIP/T5 inputs with widget values
            if (
                (HasInputOfType(currentNode, "CLIP") || HasInputOfType(currentNode, "T5"))
                && !HasInputOfType(currentNode, "CONDITIONING")
                )
            {
                if (HasInputOfType(currentNode, "STRING"))
                {
                    // clip encode but the text for it is coming from another node
                    var nextNodeId = FollowInput(currentNode, "STRING");
                    if (nextNodeId.HasValue)
                    {
                        var nextNode = FindNodeById(nextNodeId.Value);
                        if (nextNode.HasValue)
                        {
                            if (nextNode.Value.TryGetProperty("widgets_values", out var vals)
                                && vals.GetArrayLength() > 0)
                            {
                                return vals[0].GetString();
                            }
                            
                        }
                    }
                }
                else if (currentNode.TryGetProperty("widgets_values", out var values) &&
                    values.GetArrayLength() > 0)
                {
                    return values[0].GetString();
                }
            }

            // Follow inputs in priority order
            string[] inputPriority = { "SDXL_TUPLE", "CONDITIONING", "IMAGE", "LATENT", "*" };
            foreach (var inputType in inputPriority)
            {
                var nextNodeId = FollowInput(currentNode, inputType);
                if (nextNodeId.HasValue)
                {
                    var nextNode = FindNodeById(nextNodeId.Value);
                    if (nextNode.HasValue)
                    {
                        currentNode = nextNode.Value;
                        goto continueTracing;
                    }
                }
            }

            break;

            continueTracing:
            continue;
        }

        return null;
    }

    private bool HasInputOfType(JsonElement node, string inputType)
    {
        if (!node.TryGetProperty("inputs", out var inputs))
            return false;

        foreach (var input in inputs.EnumerateArray())
        {
            if (input.TryGetProperty("type", out var type) &&
                type.GetString() == inputType)
                return true;
        }

        return false;
    }

    private int? FollowInput(JsonElement node, string inputType)
    {
        if (!node.TryGetProperty("inputs", out var inputs))
            return null;

        foreach (var input in inputs.EnumerateArray())
        {
            if (!input.TryGetProperty("type", out var type) ||
                type.GetString() != inputType)
                continue;

            if (!input.TryGetProperty("link", out var linkId))
                continue;

            return GetLinkSource(linkId.GetInt32());
        }

        return null;
    }

    private int? GetLinkSource(int linkId)
    {
        foreach (var link in links.EnumerateArray())
        {
            if (link.GetArrayLength() < 6)
                continue;

            if (link[0].GetInt32() == linkId)
                return link[1].GetInt32();
        }

        return null;
    }

    private JsonElement? FindNodeById(int id)
    {
        foreach (var node in nodes.EnumerateArray())
        {
            if (node.TryGetProperty("id", out var nodeId) &&
                nodeId.GetInt32() == id)
                return node;
        }

        return null;
    }
}