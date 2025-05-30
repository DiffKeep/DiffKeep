namespace DiffKeep.Messages;

public class LibraryUpdatedMessage(long libraryId)
{
    public long LibraryId { get; } = libraryId;
}