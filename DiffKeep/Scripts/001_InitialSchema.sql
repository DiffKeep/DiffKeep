-- Create the libraries table with an auto-incrementing ID and path
CREATE TABLE IF NOT EXISTS Libraries
(
    Id   INTEGER PRIMARY KEY AUTOINCREMENT,
    Path TEXT NOT NULL UNIQUE
);

-- Create the images table
CREATE TABLE IF NOT EXISTS Images
(
    Id             INTEGER PRIMARY KEY AUTOINCREMENT,
    LibraryId      INTEGER  NOT NULL,
    Path           TEXT     NOT NULL,
    Hash           TEXT     NOT NULL,
    PositivePrompt TEXT,
    NegativePrompt TEXT,
    Description    TEXT,
    Created        DATETIME NOT NULL, -- file created date, not row created date
    FOREIGN KEY (LibraryId) REFERENCES Libraries (Id) ON DELETE CASCADE,
    UNIQUE (LibraryId, Path)
);

-- Create indexes for common query patterns
CREATE INDEX IF NOT EXISTS idx_images_library_id ON Images (LibraryId);
CREATE INDEX IF NOT EXISTS idx_images_path ON Images (Path);

-- Create embeddings table
CREATE TABLE IF NOT EXISTS Embeddings
(
    Id INTEGER PRIMARY KEY AUTOINCREMENT,
    ImageId INTEGER,
    Source TEXT NOT NULL,
    Size INTEGER,
    Model TEXT,
    Embedding blob
);