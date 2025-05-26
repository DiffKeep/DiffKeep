using System;
using System.Collections.Generic;

namespace DiffKeep.Models;

public class Library
{
    public long Id { get; set; }
    public required string Path { get; set; }
    
    // Navigation property
    public ICollection<Image>? Images { get; set; }
}