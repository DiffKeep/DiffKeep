//! Strips ComfyUI/A1111 prompt syntax so the text-retrieval embedder sees
//! something close to natural language instead of markup:
//!   - `<lora:name:0.8>`, `<lyco:...>` and other `<name:...>` tags are dropped
//!   - `(text:1.2)` weight suffixes are removed, keeping `text`
//!   - grouping `((text))`, `[text]`, `<(text):0.9>` is unwrapped
//!   - `\(` `\)` `\[` `\]` escapes become literal characters
//!   - comma runs and whitespace runs are collapsed
//! Queries typed by users are natural language already and must NOT be
//! passed through this; it is for index-time prompt documents only.

const std = @import("std");

fn isGroupChar(c: u8) bool {
    return c == '(' or c == ')' or c == '[' or c == ']';
}

/// End index of a `<name:...>` network tag starting at `raw[i] == '<'`, or
/// null when the `<` opens something else (a weighted group, a placeholder).
fn tagEnd(raw: []const u8, i: usize) ?usize {
    var j = i + 1;
    while (j < raw.len and (std.ascii.isAlphanumeric(raw[j]) or raw[j] == '_' or raw[j] == '-')) j += 1;
    if (j == i + 1 or j >= raw.len or raw[j] != ':') return null;
    return std.mem.findScalarPos(u8, raw, j, '>');
}

/// Length of a numeric weight suffix at the start of `rest` (just after a
/// ':'), e.g. "1.2)" -> 3. Only treated as a weight when the number is
/// immediately followed by a closing ')', ']' or '>', so "16:9" survives.
fn weightSuffixLen(rest: []const u8) ?usize {
    var j: usize = 0;
    if (j < rest.len and (rest[j] == '+' or rest[j] == '-')) j += 1;
    var digits = false;
    while (j < rest.len and std.ascii.isDigit(rest[j])) : (j += 1) digits = true;
    if (j < rest.len and rest[j] == '.') {
        j += 1;
        while (j < rest.len and std.ascii.isDigit(rest[j])) : (j += 1) digits = true;
    }
    if (!digits) return null;
    if (j < rest.len and (rest[j] == ')' or rest[j] == ']' or rest[j] == '>')) return j;
    return null;
}

/// Returns a cleaned copy of `raw`. Caller owns the result.
/// May return an empty slice when the prompt was pure markup.
pub fn cleanPrompt(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var stripped: std.ArrayList(u8) = .empty;
    defer stripped.deinit(allocator);
    try stripped.ensureTotalCapacity(allocator, raw.len);

    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        switch (c) {
            '\\' => {
                if (i + 1 < raw.len and isGroupChar(raw[i + 1])) {
                    stripped.appendAssumeCapacity(raw[i + 1]);
                    i += 2;
                } else {
                    stripped.appendAssumeCapacity(c);
                    i += 1;
                }
            },
            '<' => {
                if (tagEnd(raw, i)) |end| {
                    i = end + 1;
                } else if (std.mem.findScalarPos(u8, raw, i + 1, '>') != null) {
                    i += 1; // opens a group: keep its text, drop the bracket
                } else {
                    stripped.appendAssumeCapacity(c);
                    i += 1;
                }
            },
            '>' => i += 1,
            '(', ')', '[', ']' => i += 1,
            ':' => {
                if (weightSuffixLen(raw[i + 1 ..])) |n| {
                    i += 1 + n;
                } else {
                    stripped.appendAssumeCapacity(c);
                    i += 1;
                }
            },
            else => {
                stripped.appendAssumeCapacity(c);
                i += 1;
            },
        }
    }

    // Normalize separators: split on commas/newlines, trim each piece, drop
    // empties (left behind by removed tags), rejoin with ", ".
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitAny(u8, stripped.items, ",\n");
    var first = true;
    while (it.next()) |piece_raw| {
        // A trailing ':' is left behind by "text:)" before a group weight.
        const piece = std.mem.trimEnd(u8, std.mem.trim(u8, piece_raw, " \t\r"), ":");
        if (piece.len == 0) continue;
        if (!first) try out.appendSlice(allocator, ", ");
        first = false;
        var last_space = false;
        for (piece) |ch| {
            const is_space = ch == ' ' or ch == '\t';
            if (is_space and last_space) continue;
            last_space = is_space;
            try out.append(allocator, if (is_space) ' ' else ch);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn expectClean(expected: []const u8, raw: []const u8) !void {
    const got = try cleanPrompt(std.testing.allocator, raw);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(expected, got);
}

test "cleanPrompt: weights and loras stripped" {
    try expectClean(
        "masterpiece, 1girl, long hair",
        "(masterpiece:1.2), <lora:detailer:0.8>, 1girl,  long hair",
    );
}

test "cleanPrompt: nested emphasis unwrapped" {
    try expectClean("best quality, dark alley", "((best quality)), [dark] alley");
}

test "cleanPrompt: escapes become literals" {
    try expectClean("pose (dynamic)", "pose \\(dynamic\\)");
}

test "cleanPrompt: aspect ratios and plain colons survive" {
    try expectClean("aspect 16:9, artist:someone", "aspect 16:9, artist:someone");
}

test "cleanPrompt: pure markup collapses to empty" {
    try expectClean("", "<lora:foo:1.0>, <hypernet:bar:0.5>,, ");
}

test "cleanPrompt: whitespace and newlines collapsed" {
    try expectClean(
        "a cat, sitting on a mat",
        "a   cat,\nsitting  on\ta mat",
    );
}

test "cleanPrompt: weighted angle groups keep their text" {
    try expectClean(
        "a summerscape sunset, light rain, perfect masterpiece, deep color, fantastical",
        "<(a summerscape sunset, light rain, perfect masterpiece:):1.0>,\n<(deep color, fantastical):0.9>",
    );
}

test "cleanPrompt: lyco and hypernet tags dropped, placeholders keep text" {
    try expectClean("the grinch, Main Subject", "the grinch,  <lyco:GoodHands-beta2:1.0>, <Main Subject>");
}

test "cleanPrompt: unclosed angle bracket kept verbatim" {
    try expectClean("score < 5", "score < 5");
}

test "cleanPrompt: weight without decimal" {
    try expectClean("detailed face", "(detailed face:2)");
}
