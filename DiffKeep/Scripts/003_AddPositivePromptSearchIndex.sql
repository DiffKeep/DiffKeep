-- Create FTS5 virtual table for prompt searching
CREATE VIRTUAL TABLE IF NOT EXISTS ImagePromptIndex USING fts5
(
    PositivePrompt,
    content='Images',  -- This links the FTS table to the Images table
    content_rowid='Id' -- This specifies which column to use as the document ID
);

-- Create triggers to keep the FTS index in sync with the Images table
CREATE TRIGGER IF NOT EXISTS Images_ai
    AFTER INSERT
    ON Images
BEGIN
    INSERT INTO ImagePromptIndex(rowid, PositivePrompt)
    VALUES (new.Id, new.PositivePrompt);
END;

CREATE TRIGGER IF NOT EXISTS Images_ad
    AFTER DELETE
    ON Images
BEGIN
    INSERT INTO ImagePromptIndex(ImagePromptIndex, rowid, PositivePrompt)
    VALUES ('delete', old.Id, old.PositivePrompt);
END;

CREATE TRIGGER IF NOT EXISTS Images_au
    AFTER UPDATE
    ON Images
BEGIN
    INSERT INTO ImagePromptIndex(ImagePromptIndex, rowid, PositivePrompt)
    VALUES ('delete', old.Id, old.PositivePrompt);
    INSERT INTO ImagePromptIndex(rowid, PositivePrompt)
    VALUES (new.Id, new.PositivePrompt);
END;

-- Populate the FTS index with existing data
INSERT INTO ImagePromptIndex(rowid, PositivePrompt)
SELECT Id, PositivePrompt
FROM Images
WHERE PositivePrompt IS NOT NULL;