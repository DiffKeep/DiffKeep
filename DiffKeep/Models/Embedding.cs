namespace DiffKeep.Models;

public class Embedding
{
    public long Id { get; set; }
    public long ImageId { get; set; }
    public float[] Vector { get; set; }
    public EmbeddingType Type { get; set; }
}

public enum EmbeddingType
{
    Prompt,
    Description
}
