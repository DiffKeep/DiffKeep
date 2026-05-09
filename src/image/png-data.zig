const std = @import("std");

/// PNG Chunk Type codes
pub const ChunkType = struct {
    pub const IHDR: [4]u8 = .{'I', 'H', 'D', 'R'};
    pub const IDAT: [4]u8 = .{'I', 'D', 'A', 'T'};
    pub const IEND: [4]u8 = .{'I', 'E', 'N', 'D'};
    pub const iTXt: [4]u8 = .{'i', 'T', 'X', 't'};
    pub const tEXt: [4]u8 = .{'t', 'E', 'X', 't'};
    pub const zTXt: [4]u8 = .{'z', 'T', 'X', 't'};
};

/// PNG Chunk structure
pub const Chunk = struct {
    length: u32,
    type: [4]u8,
    data: []u8,
    crc: u32,

    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// PNG Parser for extracting chunks
pub const PngParser = struct {
    allocator: std.mem.Allocator,
    chunks: std.ArrayList(Chunk),
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !PngParser {
        return .{
            .allocator = allocator,
            .chunks = try std.ArrayList(Chunk).initCapacity(allocator, 512),
            .io = io,
        };
    }

    pub fn deinit(self: *PngParser) void {
        for (self.chunks.items) |*chunk| {
            chunk.deinit(self.allocator);
        }
        self.chunks.deinit(self.allocator);
    }

    /// Parse a PNG file and extract all chunks
    pub fn parseFile(self: *PngParser, file_path: []const u8) !void {
        const file = try std.Io.Dir.cwd().openFile(self.io,file_path, .{});
        defer file.close(self.io);

        const file_size = try file.length(self.io);
        const buffer = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(buffer);

        const bytes_read = try file.readPositionalAll(self.io, buffer, 0);
        if (bytes_read != file_size) {
            return error.IncompleteRead;
        }

        try self.parseBuffer(buffer);
    }

    /// Parse a PNG from a reader stream
    pub fn parseStream(self: *PngParser, reader: anytype) !void {
        var buffer = try std.ArrayList(u8).initCapacity(self.allocator, 512);
        defer buffer.deinit();
        try reader.readAllArrayList(&buffer, std.math.maxInt(usize));

        try self.parseBuffer(buffer.items);
    }

    /// Parse a PNG from a buffer
    pub fn parseBuffer(self: *PngParser, buffer: []const u8) !void {
        // Clear any previous chunks
        for (self.chunks.items) |*chunk| chunk.deinit(self.allocator);
        self.chunks.clearRetainingCapacity();

        var reader: std.Io.Reader = .fixed(buffer);

        // Check PNG signature
        const png_signature = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };
        var signature: [8]u8 = undefined;
        try reader.readSliceAll(&signature);

        if (!std.mem.eql(u8, &signature, &png_signature)) {
            return error.InvalidPngSignature;
        }

        // Read chunks until IEND
        while (true) {
            // Read chunk length (4 bytes, big endian)
            const length = try reader.takeInt(u32, .big);

            // Read chunk type (4 bytes)
            var chunk_type: [4]u8 = undefined;
            try reader.readSliceAll(&chunk_type);

            // Allocate and read chunk data
            const data = try self.allocator.alloc(u8, length);
            errdefer self.allocator.free(data);
            try reader.readSliceAll(data);

            // Read CRC (4 bytes)
            const crc = try reader.takeInt(u32, .big);

            // Store the chunk
            try self.chunks.append(self.allocator, .{
                .length = length,
                .type = chunk_type,
                .data = data,
                .crc = crc,
            });

            // If this is the IEND chunk, we're done
            if (std.mem.eql(u8, &chunk_type, &ChunkType.IEND)) {
                break;
            }
        }
    }

    /// Get all tEXt chunks
    pub fn getTExtChunks(self: *const PngParser) ![]const Chunk {
        var result = try std.ArrayList(Chunk).initCapacity(self.allocator, 25);
        defer result.deinit(self.allocator);

        for (self.chunks.items) |chunk| {
            if (std.mem.eql(u8, &chunk.type, &ChunkType.tEXt)) {
                result.append(self.allocator, chunk) catch continue;
            }
        }

        return result.toOwnedSlice(self.allocator) catch &[_]Chunk{};
    }

    /// Get all iTXt chunks
    pub fn getITxtChunks(self: *const PngParser) ![]const Chunk {
        var result = try std.ArrayList(Chunk).initCapacity(self.allocator, 25);
        defer result.deinit(self.allocator);

        for (self.chunks.items) |chunk| {
            if (std.mem.eql(u8, &chunk.type, &ChunkType.iTXt)) {
                result.append(self.allocator, chunk) catch continue;
            }
        }

        return result.toOwnedSlice(self.allocator) catch &[_]Chunk{};
    }

    /// Parse an iTXt chunk into its components
    pub fn parseITxtChunk(self: *const PngParser, chunk: Chunk) !ITxtContent {
        var i: usize = 0;

        // Find the keyword (null-terminated)
        const keyword_start = i;
        while (i < chunk.data.len and chunk.data[i] != 0) {
            i += 1;
        }
        const keyword = chunk.data[keyword_start..i];
        i += 1; // Skip null terminator

        if (i >= chunk.data.len) return error.InvalidITxtChunk;

        // Compression flag (1 byte)
        const compression_flag = chunk.data[i];
        i += 1;

        if (i >= chunk.data.len) return error.InvalidITxtChunk;

        // Compression method (1 byte)
        const compression_method = chunk.data[i];
        i += 1;

        // Find the language tag (null-terminated)
        const lang_start = i;
        while (i < chunk.data.len and chunk.data[i] != 0) {
            i += 1;
        }
        const language = chunk.data[lang_start..i];
        i += 1; // Skip null terminator

        if (i >= chunk.data.len) return error.InvalidITxtChunk;

        // Find the translated keyword (null-terminated)
        const translated_keyword_start = i;
        while (i < chunk.data.len and chunk.data[i] != 0) {
            i += 1;
        }
        const translated_keyword = chunk.data[translated_keyword_start..i];
        i += 1; // Skip null terminator

        if (i >= chunk.data.len) return error.InvalidITxtChunk;

        // The rest is the text
        const text = chunk.data[i..];

        // If compressed, decompress the text
        if (compression_flag == 1) {
            // Implement decompression if needed
            // For now, just return the compressed data
        }

        return ITxtContent{
            .keyword = try self.allocator.dupe(u8, keyword),
            .language = try self.allocator.dupe(u8, language),
            .translated_keyword = try self.allocator.dupe(u8, translated_keyword),
            .text = try self.allocator.dupe(u8, text),
            .compressed = compression_flag == 1,
            .compression_method = compression_method,
        };
    }

    /// Parse a tEXt chunk into its components
    pub fn parseTExtChunk(self: *const PngParser, chunk: Chunk) !TExtContent {
        var i: usize = 0;

        // Find the keyword (null-terminated)
        const keyword_start = i;
        while (i < chunk.data.len and chunk.data[i] != 0) {
            i += 1;
        }
        const keyword = chunk.data[keyword_start..i];
        i += 1; // Skip null terminator

        if (i >= chunk.data.len) return error.InvalidTExtChunk;

        // The rest is the text
        const text = chunk.data[i..];

        return TExtContent{
            .keyword = try self.allocator.dupe(u8, keyword),
            .text = try self.allocator.dupe(u8, text),
        };
    }
};

/// Structure to hold parsed iTXt content
pub const ITxtContent = struct {
    keyword: []u8,
    language: []u8,
    translated_keyword: []u8,
    text: []u8,
    compressed: bool,
    compression_method: u8,

    pub fn deinit(self: *ITxtContent, allocator: std.mem.Allocator) void {
        allocator.free(self.keyword);
        allocator.free(self.language);
        allocator.free(self.translated_keyword);
        allocator.free(self.text);
    }
};

/// Structure to hold parsed tEXt content
pub const TExtContent = struct {
    keyword: []u8,
    text: []u8,

    pub fn deinit(self: *TExtContent, allocator: std.mem.Allocator) void {
        allocator.free(self.keyword);
        allocator.free(self.text);
    }
};
test "parse PNG and extract tEXt chunks" {
    const testing = std.testing;
    const test_file_path = "test-artifacts/chunk-data.png"; // Adjust path as needed

    var parser = try PngParser.init(testing.allocator);
    defer parser.deinit();

    try parser.parseFile(test_file_path);

    // Check if we have any iTXt chunks
    const text_chunks = parser.getTExtChunks();
    defer testing.allocator.free(text_chunks);
    var found: i64 = 0;

    for (text_chunks) |chunk| {
        found += 1;
        var content = try parser.parseTExtChunk(chunk);
        defer content.deinit(testing.allocator);
    }
    try testing.expect(found == 2);
}
