using System;

namespace DiffKeep.Models;

public class Image
{
    public long Id { get; set; }
    public long LibraryId { get; set; }
    public required string Path { get; set; }
    public required string Hash { get; set; }
    public string? PositivePrompt { get; set; }
    public string? NegativePrompt { get; set; }
    public string? Description { get; set; }
    public DateTime Created { get; set; }
    
    // Navigation property
    public Library? Library { get; set; }
}