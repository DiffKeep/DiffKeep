using DiffKeep.Models;

namespace DiffKeep.Messages;

public class GenerateEmbeddingMessage(long imageId, EmbeddingSource embeddingSource, string text)
{
    public long ImageId { get; set; } = imageId;
    public EmbeddingSource EmbeddingSource { get; set; } = embeddingSource;
    public string Text { get; set; } = text;
}