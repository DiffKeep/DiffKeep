namespace DiffKeep.Parsing;

public interface IImageParser
{
    ImageMetadata ParseImage(string filePath);
}
