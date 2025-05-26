using System;

namespace DiffKeep.Database;

public class ScanProgressEventArgs : EventArgs
{
    public long LibraryId { get; }
    public int ProcessedFiles { get; }
    public int TotalFiles { get; }
    
    public ScanProgressEventArgs(long libraryId, int processedFiles, int totalFiles)
    {
        LibraryId = libraryId;
        ProcessedFiles = processedFiles;
        TotalFiles = totalFiles;
    }
}

public class ScanCompletedEventArgs : EventArgs
{
    public long LibraryId { get; }
    public int ProcessedFiles { get; }
    
    public ScanCompletedEventArgs(long libraryId, int processedFiles)
    {
        LibraryId = libraryId;
        ProcessedFiles = processedFiles;
    }
}