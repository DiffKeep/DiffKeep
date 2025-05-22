using System.Collections.Generic;

namespace DiffKeep.Parsing;

public class ImageMetadata
{
    public GenerationTool? Tool { get; set; }
    public string? Prompt { get; set; }
    public List<KeyValuePair<string, string?>>? RawMetadata { get; set; }
}

public enum GenerationTool
{
    Unknown,
    ComfyUI,
    Automatic1111,
    Fooocus
}
