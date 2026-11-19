//! Which tool generated an image, from its metadata sections (the same
//! keyword + text sections the prompt parser reads).
//!
//! - TensorPencil writes A1111-style `parameters` text with a
//!   `Version: TensorPencil <ver>` field. Its images from before that field
//!   are told apart by `Prompt syntax:`, a field only TensorPencil writes.
//! - ComfyUI writes `workflow` and/or `prompt` JSON. A ComfyUI image may also
//!   carry an A1111-compatible `parameters` block (some save nodes add one),
//!   so the JSON decides first.
//! - Any other `parameters` block is A1111's format: Forge marks itself with
//!   a `Version: f<digit>...` field; everything else counts as A1111.
//!
//! `Generator.name` is the stored value (`images.generator`) and the filter
//! value. These are product names, the same in every language.

const std = @import("std");
const RawSection = @import("comfy.zig").ComfyParser.RawSection;

pub const Generator = enum {
    comfyui,
    a1111,
    forge,
    tensorpencil,

    /// The stored and displayed name.
    pub fn name(g: Generator) []const u8 {
        return switch (g) {
            .comfyui => "ComfyUI",
            .a1111 => "A1111",
            .forge => "Forge",
            .tensorpencil => "TensorPencil",
        };
    }

    pub fn fromName(s: []const u8) ?Generator {
        inline for (@typeInfo(Generator).@"enum".field_names) |f| {
            const g = @field(Generator, f);
            if (std.mem.eql(u8, s, g.name())) return g;
        }
        return null;
    }
};

/// The generator of an image with these metadata sections, or null when
/// nothing identifies one.
pub fn detect(sections: []const RawSection) ?Generator {
    var parameters: ?[]const u8 = null;
    var comfy = false;
    for (sections) |s| {
        if (std.mem.eql(u8, s.keyword, "parameters")) {
            if (parameters == null) parameters = s.text;
        } else if (std.mem.eql(u8, s.keyword, "workflow")) {
            comfy = true;
        } else if (std.mem.eql(u8, s.keyword, "prompt")) {
            // ComfyUI's execution graph is a JSON object; other tools use a
            // "prompt" key for plain text.
            const body = std.mem.trimStart(u8, s.text, " \t\r\n");
            if (body.len > 0 and body[0] == '{') comfy = true;
        }
    }

    const version = if (parameters) |p| settingValue(p, "Version") else null;
    if (parameters) |p| {
        if (version) |v| {
            if (std.mem.startsWith(u8, v, "TensorPencil")) return .tensorpencil;
        } else if (settingValue(p, "Prompt syntax") != null) {
            return .tensorpencil;
        }
    }
    if (comfy) return .comfyui;
    if (parameters != null) {
        if (version) |v| {
            if (v.len >= 2 and v[0] == 'f' and std.ascii.isDigit(v[1])) return .forge;
        }
        return .a1111;
    }
    return null;
}

/// The value of `key` in the settings line (`Steps: 20, Sampler: X, ...`) of
/// A1111-style `text`, or null. Only that line is searched, and a key only at
/// its start or after ", ", so a prompt that merely contains the words doesn't
/// count; a value runs to the next ", " or the end of the line.
fn settingValue(text: []const u8, key: []const u8) ?[]const u8 {
    const line = settingsLine(text) orelse return null;
    var from: usize = 0;
    while (std.mem.findPos(u8, line, from, key)) |at| : (from = at + 1) {
        const starts_field = at == 0 or (at >= 2 and std.mem.eql(u8, line[at - 2 .. at], ", "));
        const after = at + key.len;
        if (!starts_field or !std.mem.startsWith(u8, line[after..], ": ")) continue;
        const v_start = after + 2;
        const v_end = std.mem.findPos(u8, line, v_start, ", ") orelse line.len;
        return line[v_start..v_end];
    }
    return null;
}

/// The settings line: the last line starting with one of the keys A1111
/// opens it with (the prompts come before it).
fn settingsLine(text: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        for ([_][]const u8{ "Steps: ", "Sampler: ", "CFG scale: " }) |k| {
            if (std.mem.startsWith(u8, line, k)) found = line;
        }
    }
    return found;
}

const t = std.testing;

fn sec(keyword: []const u8, text: []const u8) RawSection {
    return .{ .keyword = keyword, .text = text };
}

test "TensorPencil by its Version field" {
    const p = "a cat\nNegative prompt: dog\nSteps: 20, Sampler: Euler, Seed: 1, Version: TensorPencil 0.4.0";
    try t.expectEqual(Generator.tensorpencil, detect(&.{sec("parameters", p)}).?);
}

test "TensorPencil before the Version field, by Prompt syntax" {
    const p = "a cat\nSteps: 20, Sampler: Euler, CFG scale: 7.0, Seed: 1, Size: 512x512, Model: sdxl, Prompt syntax: ComfyUI";
    try t.expectEqual(Generator.tensorpencil, detect(&.{sec("parameters", p)}).?);
}

test "the words in a prompt are not a field" {
    const p = "Prompt syntax: is a poem\nSteps: 20, Sampler: Euler";
    try t.expectEqual(Generator.a1111, detect(&.{sec("parameters", p)}).?);
}

test "ComfyUI by its JSON, even with an A1111 block" {
    try t.expectEqual(Generator.comfyui, detect(&.{sec("workflow", "{}")}).?);
    try t.expectEqual(Generator.comfyui, detect(&.{sec("prompt", "  {\"3\":{}}")}).?);
    try t.expectEqual(Generator.comfyui, detect(&.{
        sec("parameters", "a cat\nSteps: 20, Sampler: Euler"),
        sec("prompt", "{\"3\":{}}"),
    }).?);
}

test "a plain-text prompt key is not ComfyUI" {
    try t.expect(detect(&.{sec("prompt", "a cat")}) == null);
}

test "Forge and A1111" {
    try t.expectEqual(Generator.forge, detect(&.{sec("parameters", "x\nSteps: 20, Version: f2.0.1v1.10.1-previous-669")}).?);
    try t.expectEqual(Generator.a1111, detect(&.{sec("parameters", "x\nSteps: 20, Version: v1.10.1")}).?);
    try t.expectEqual(Generator.a1111, detect(&.{sec("parameters", "x\nSteps: 20, Sampler: Euler")}).?);
}

test "nothing to go on" {
    try t.expect(detect(&.{}) == null);
    try t.expect(detect(&.{sec("Software", "something")}) == null);
}

test "name round-trips" {
    inline for (@typeInfo(Generator).@"enum".field_names) |f| {
        const g = @field(Generator, f);
        try t.expectEqual(g, Generator.fromName(g.name()).?);
    }
    try t.expect(Generator.fromName("comfyui") == null);
}
