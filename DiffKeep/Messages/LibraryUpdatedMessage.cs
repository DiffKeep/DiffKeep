namespace DiffKeep.Messages;

public class LibraryUpdatedMessage
{
    public long LibraryId { get; }

    public LibraryUpdatedMessage(long libraryId)
    {
        LibraryId = libraryId;
    }
}