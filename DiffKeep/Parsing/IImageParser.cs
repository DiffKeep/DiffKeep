using System.Threading.Tasks;

namespace DiffKeep.Parsing;

public interface IImageParser
{
    ImageMetadata ParseImage(string filePath);
    Task<ImageMetadata> ParseImageAsync(string filePath);
}
