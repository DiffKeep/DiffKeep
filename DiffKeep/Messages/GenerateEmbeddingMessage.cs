using DiffKeep.Models;

namespace DiffKeep.Messages;

public class GenerateEmbeddingMessage(long imageId, EmbeddingType embeddingType, string text)
{
    public long ImageId { get; set; } = imageId;
    public EmbeddingType EmbeddingType { get; set; } = embeddingType;
    public string Text { get; set; } = text;
}