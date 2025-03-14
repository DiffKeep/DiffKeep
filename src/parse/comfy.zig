const std = @import("std");

// enable to output parsing debug statements
const debug = false;

pub const ComfyParser = struct {
    allocator: std.mem.Allocator,
    nodes: std.json.Array,
    links: std.json.Array,

    pub fn init(allocator: std.mem.Allocator) ComfyParser {
        return .{
            .allocator = allocator,
            .nodes = undefined,
            .links = undefined,
        };
    }

    fn getNodeByType(self: *ComfyParser, nodeType: []const u8, active: bool) ?std.json.Value {
        for (self.nodes.items) |node| {
            if (node != .object) continue;
            if (active) {
                // get the node's mode
                if (node.object.get("mode")) |mode| {
                    if (mode != .integer) continue;
                    if (mode.integer != 0) continue;
                }
            }
            if (node.object.get("type")) |nType| {
                if (nType != .string) continue;
                if (std.mem.eql(u8, nType.string, nodeType)) return node;
            }
        }
        return null;
    }

    fn getNodeById(self: *ComfyParser, id: i64) ?std.json.Value {
        for (self.nodes.items) |node| {
            if (node != .object) continue;
            if (node.object.get("id")) |nodeId| {
                if (nodeId != .integer) continue;
                if (nodeId.integer == id) return node;
            }
        }
        return null;
    }

    fn getLinkSource(self: *ComfyParser, linkId: i64) ?i64 {
        for (self.links.items) |link| {
            if (link != .array or link.array.items.len < 6) continue;
            const link_index = link.array.items[0];
            if (link_index != .integer) continue;
            if (link_index.integer != linkId) continue;

            const source_id = link.array.items[1];
            if (source_id != .integer) continue;
            return source_id.integer;
        }
        return null;
    }

    pub fn parseWorkflow(self: *ComfyParser, workflow_json: []const u8) !?[]const u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, workflow_json, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return null;

        if (root.object.get("nodes")) |nodes| {
            if (nodes != .array) return null;
            self.nodes = nodes.array;
        }
        if (root.object.get("links")) |links| {
            if (links != .array) return null;
            self.links = links.array;
        }

        // Find KSampler node
        const ksampler = self.getNodeByType("KSampler", true) orelse return null;
        if (debug) std.debug.print("Found KSampler node\n", .{});

        // Get positive link ID from KSampler inputs
        var positive_link_id: ?i64 = null;
        if (ksampler.object.get("inputs")) |inputs| {
            if (inputs != .array) return null;

            for (inputs.array.items) |input| {
                if (input != .object) continue;
                if (input.object.get("name")) |name| {
                    if (name != .string) continue;
                    if (!std.mem.eql(u8, name.string, "positive")) continue;

                    if (input.object.get("link")) |link| {
                        if (link != .integer) continue;
                        positive_link_id = link.integer;
                        if (debug) std.debug.print("Found positive link ID: {?}\n", .{positive_link_id});
                        break;
                    }
                }
            }
        }

        // Trace back through links to find source node
        var current_link_id = positive_link_id orelse return null;
        var current_node_id = self.getLinkSource(current_link_id);

        while (current_node_id) |node_id| {
            const node = self.getNodeById(node_id) orelse return null;
            if (debug) std.debug.print("Checking node ID: {d}\n", .{node_id});

            if (node.object.get("type")) |nodeType| {
                if (nodeType != .string) continue;

                if (std.mem.eql(u8, nodeType.string, "CLIPTextEncode")) {
                    if (node.object.get("widgets_values")) |values| {
                        if (values != .array or values.array.items.len == 0) continue;
                        const prompt = values.array.items[0];
                        if (prompt != .string) continue;
                        return try self.allocator.dupe(u8, prompt.string);
                    }
                    break;
                } else if (std.mem.eql(u8, nodeType.string, "Reroute")) {
                    // Follow reroute node's input
                    if (node.object.get("inputs")) |inputs| {
                        if (inputs != .array or inputs.array.items.len == 0) break;
                        const input = inputs.array.items[0];
                        if (input != .object) break;
                        if (input.object.get("link")) |link| {
                            if (link != .integer) break;
                            current_link_id = link.integer;
                            current_node_id = self.getLinkSource(current_link_id);
                            continue;
                        }
                    }
                } else {
                    // Follow any node's CONDITIONING input
                    if (node.object.get("inputs")) |inputs| {
                        if (inputs != .array or inputs.array.items.len == 0) break;

                        for (inputs.array.items) |input| {
                            if (input != .object) continue;

                            // Check if this input is of type CONDITIONING
                            if (input.object.get("type")) |inputType| {
                                if (inputType != .string) continue;
                                if (!std.mem.eql(u8, inputType.string, "CONDITIONING")) continue;

                                if (input.object.get("link")) |link| {
                                    if (link != .integer) continue;
                                    current_link_id = link.integer;
                                    current_node_id = self.getLinkSource(current_link_id);
                                    if (debug) std.debug.print("Following CONDITIONING input to node: {?}\n", .{current_node_id});
                                    break;
                                }
                            }
                        }
                        continue;
                    }
                }
            }
            break;
        }

        return null;
    }
};

test "parse ComfyUI workflow" {
    const testing = std.testing;

    // Open and read the workflow file
    const workflow_path = "test-artifacts/workflow.json";
    const file = try std.fs.cwd().openFile(workflow_path, .{});
    defer file.close();

    // Read the entire file content
    const workflow_json = try file.readToEndAlloc(testing.allocator, 1024 * 1024);
    defer testing.allocator.free(workflow_json);

    // Create parser and test
    var parser = ComfyParser.init(testing.allocator);
    const prompt = try parser.parseWorkflow(workflow_json);
    defer if (prompt) |p| testing.allocator.free(p);

    // Add assertions based on expected content
    try testing.expect(prompt != null);
    if (prompt) |p| {
        // output the prompt for debugging
        if (debug) std.debug.print("prompt: {s}\n", .{p});
        try testing.expectFmt("this is the prompt text! it has lots of cool stuff in it", "{s}", .{p});
    }
}
