const std = @import("std");
const zigimg = @import("zigimg");
const Image = zigimg.Image;
const png = zigimg.formats.png.Types;
const PixelFormat = zigimg.formats.png.PixelFormat;
const ReaderProcessor = zigimg.formats.png.ReaderProcessor;
const ChunkProcessData = zigimg.formats.png.ChunkProcessData;
const PaletteProcessData = zigimg.formats.png.PaletteProcessData;
const isChunkCritical = zigimg.formats.png.isChunkCritical;

pub const PngInfoOptions = struct {
    processor: Self,
    processors: [1]zigimg.formats.png.ReaderProcessor = undefined,

    pub fn get(self: *@This()) zigimg.formats.png.ReaderOptions {
        self.processors[0] = self.processor.processor();
        return .{ .temp_allocator = .{ .ptr = undefined, .vtable = &zigimg.formats.png.NoopAllocator }, .processors = self.processors[0..] };
    }
};

const Self = @This();

writer: std.io.StreamSource.Writer,
allocator: std.mem.Allocator,
idat_count: u32 = 0,
idat_size: u64 = 0,
prompt: ?[]u8 = null,
workflow: ?[]u8 = null,

pub fn init(writer: std.io.StreamSource.Writer, allocator: std.mem.Allocator) Self {
    return .{
        .writer = writer,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    if (self.prompt) |prompt| {
        self.allocator.free(prompt);
        self.prompt = null;
    }
    if (self.workflow) |workflow| {
        self.allocator.free(workflow);
        self.workflow = null;
    }
}

pub fn processor(self: *Self) ReaderProcessor {
    return ReaderProcessor.init(
        png.Chunks.Any.id,
        self,
        processChunk,
        processPalette,
        null,
    );
}

fn processChunk(self: *Self, data: *ChunkProcessData) Image.ReadError!PixelFormat {
    const result_format = data.current_format;

    var reader = data.stream.reader();
    var buffer: [1024*1024]u8 = undefined;

    // This is critical chunk so it is already read and there is no need to read it here
    if (!isChunkCritical(data.chunk_id)) {
        switch (data.chunk_id) {
            png.Chunks.tEXt.id => {
                const to_read = if (data.chunk_length <= buffer.len) data.chunk_length else buffer.len;
                var txt = buffer[0..to_read];
                try reader.readNoEof(txt);
                if (data.chunk_length > buffer.len) try data.stream.seekBy(@as(i64, data.chunk_length) - buffer.len);
                const strEnd = std.mem.indexOfScalar(u8, txt, 0).?;
                if (std.mem.eql(u8, txt[0..strEnd], "prompt")) {
                    // store the data in prompt
                    self.prompt = try self.allocator.dupe(u8, txt[strEnd+1..]);
                }
                else if (std.mem.eql(u8, txt[0..strEnd], "workflow")) {
                    // store the data in workflow
                    self.workflow = try self.allocator.dupe(u8, txt[strEnd+1..]);
                }
            },
            else => {
                try data.stream.seekBy(data.chunk_length);
            },
        }
        try data.stream.seekBy(@sizeOf(u32));
    }

    return result_format;
}

fn processPalette(_: *Self, _: *PaletteProcessData) Image.ReadError!void {
    return;
}
