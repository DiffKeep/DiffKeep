using System;
using System.IO;
using System.Threading.Tasks;

namespace DiffKeep.Parsing
{
    public class ImageParser : IImageParser
    {
        private readonly PngMetadataParser _pngParser;

        public ImageParser()
        {
            _pngParser = new PngMetadataParser();
        }

        public ImageMetadata ParseImage(string filePath)
        {
            if (string.IsNullOrEmpty(filePath))
                throw new ArgumentNullException(nameof(filePath));

            if (!File.Exists(filePath))
                throw new FileNotFoundException("Image file not found", filePath);

            string extension = Path.GetExtension(filePath).ToLowerInvariant();

            return extension switch
            {
                ".png" => _pngParser.ParseImage(filePath),
                ".jpg" or ".jpeg" => throw new NotImplementedException("JPEG parsing not yet implemented"),
                ".webp" => throw new NotImplementedException("WebP parsing not yet implemented"),
                ".gif" => throw new NotImplementedException("GIF parsing not yet implemented"),
                _ => throw new NotSupportedException($"Unsupported image format: {extension}")
            };
        }

        public async Task<ImageMetadata> ParseImageAsync(string filePath)
        {
            return await Task.Run(() => ParseImage(filePath));
        }
    }
}