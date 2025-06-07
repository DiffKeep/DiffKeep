namespace DiffKeep.Messages;

public class ImageDeletedMessage(string imagePath)
{
    public string ImagePath { get; } = imagePath;
}