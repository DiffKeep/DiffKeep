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
    /// The header and text chunks (IHDR, tEXt, iTXt, zTXt). Image data and
    /// other chunks are skipped, not copied.
    chunks: std.ArrayList(Chunk),
    io: std.Io,
    /// The last parse ran out of bytes before IEND (a file still being written,
    /// or a damaged one). `chunks` holds what came before the cut.
    truncated: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !PngParser {
        return .{
            .allocator = allocator,
            .chunks = .empty,
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

    /// Parse a PNG from a buffer. A buffer that ends before IEND is not an
    /// error: the chunks read so far are kept and `truncated` is set.
    pub fn parseBuffer(self: *PngParser, buffer: []const u8) !void {
        // Clear any previous chunks
        for (self.chunks.items) |*chunk| chunk.deinit(self.allocator);
        self.chunks.clearRetainingCapacity();
        self.truncated = false;

        const png_signature = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };
        if (buffer.len < png_signature.len or !std.mem.eql(u8, buffer[0..8], &png_signature))
            return error.InvalidPngSignature;

        var pos: usize = png_signature.len;
        while (true) {
            // length (4, big endian) + type (4) + data + CRC (4). The length is
            // untrusted: check it against what's left before using it.
            if (buffer.len - pos < 8) break;
            const length = std.mem.readInt(u32, buffer[pos..][0..4], .big);
            const chunk_type: [4]u8 = buffer[pos + 4 ..][0..4].*;
            pos += 8;
            if (buffer.len - pos < @as(usize, length) + 4) break;
            const data = buffer[pos..][0..length];
            const crc = std.mem.readInt(u32, buffer[pos + length ..][0..4], .big);
            pos += @as(usize, length) + 4;

            if (std.mem.eql(u8, &chunk_type, &ChunkType.IEND)) return;
            if (!isKeptChunk(chunk_type)) continue;

            const owned = try self.allocator.dupe(u8, data);
            errdefer self.allocator.free(owned);
            try self.chunks.append(self.allocator, .{
                .length = length,
                .type = chunk_type,
                .data = owned,
                .crc = crc,
            });
        }
        self.truncated = true;
    }

    fn isKeptChunk(t: [4]u8) bool {
        return std.mem.eql(u8, &t, &ChunkType.IHDR) or
            std.mem.eql(u8, &t, &ChunkType.tEXt) or
            std.mem.eql(u8, &t, &ChunkType.iTXt) or
            std.mem.eql(u8, &t, &ChunkType.zTXt);
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
fn testChunk(out: *std.ArrayList(u8), kind: []const u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(std.testing.allocator, &len);
    try out.appendSlice(std.testing.allocator, kind);
    try out.appendSlice(std.testing.allocator, data);
    try out.appendSlice(std.testing.allocator, &.{ 0, 0, 0, 0 }); // CRC (unchecked)
}

const png_sig = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };

test "png: the sample file's two tEXt chunks parse" {
    var parser = try PngParser.init(std.testing.allocator, std.testing.io);
    defer parser.deinit();
    try parser.parseFile("test-artifacts/chunk-data.png");
    const text_chunks = try parser.getTExtChunks();
    defer std.testing.allocator.free(text_chunks);
    try std.testing.expectEqual(@as(usize, 2), text_chunks.len);
    for (text_chunks) |chunk| {
        var content = try parser.parseTExtChunk(chunk);
        content.deinit(std.testing.allocator);
    }
}

test "png: only metadata chunks are kept, not the image data" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, &png_sig);
    try testChunk(&buf, "IHDR", &@as([13]u8, @splat(0)));
    try testChunk(&buf, "tEXt", "prompt\x00{}");
    try testChunk(&buf, "IDAT", &@as([4096]u8, @splat(0xAB)));
    try testChunk(&buf, "IEND", "");

    var parser = try PngParser.init(std.testing.allocator, std.testing.io);
    defer parser.deinit();
    try parser.parseBuffer(buf.items);
    for (parser.chunks.items) |c| try std.testing.expect(!std.mem.eql(u8, &c.type, &ChunkType.IDAT));
    try std.testing.expect(!parser.truncated);
}

test "png: a truncated file keeps the metadata before the cut, without trusting its lengths" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, &png_sig);
    try testChunk(&buf, "tEXt", "prompt\x00{}");
    // A chunk claiming ~4 GB in a file that ends right after its header (a file
    // still being written, or a hostile one).
    try buf.appendSlice(std.testing.allocator, &.{ 0xFF, 0xFF, 0xFF, 0xF0 });
    try buf.appendSlice(std.testing.allocator, "tEXt");

    // Little memory to spare: the parser must not allocate the claimed length.
    var mem: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&mem);
    var parser = try PngParser.init(fba.allocator(), std.testing.io);
    defer parser.deinit();
    try parser.parseBuffer(buf.items);
    try std.testing.expect(parser.truncated);
    const text_chunks = try parser.getTExtChunks();
    try std.testing.expectEqual(@as(usize, 1), text_chunks.len);
}
