namespace DiffKeep.Models;

public class Embedding
{
    public long Id { get; set; }
    public long ImageId { get; set; }
    public float[] Vector { get; set; }
    public EmbeddingSource Source { get; set; }
    public int Size { get; set; }
    public string Model { get; set; }
}

public enum EmbeddingSource
{
    PositivePrompt,
    NegativePrompt,
    Description,
    Image,
}
