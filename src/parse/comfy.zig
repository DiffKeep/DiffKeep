const std = @import("std");

// enable to output parsing debug statements
var debug = false;

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
            if (debug) std.debug.print("Link ID {d} links to node ID: {d}\n", .{ linkId, source_id.integer });
            return source_id.integer;
        }
        return null;
    }

    fn getSaveImageNodes(self: *ComfyParser) !std.ArrayList(std.json.Value) {
        var saveNodes = std.ArrayList(std.json.Value).init(self.allocator);
        var alternateNodes = std.ArrayList(std.json.Value).init(self.allocator); // Store alternate nodes separately

        for (self.nodes.items) |node| {
            if (node != .object) continue;

            // Check for active status (mode == 0)
            if (node.object.get("mode")) |mode| {
                if (mode != .integer or mode.integer != 0) continue;
            }

            // Check for "save" in type name (case-insensitive)
            if (node.object.get("type")) |nodeType| {
                if (nodeType != .string) continue;
                const typeNameLower = try std.ascii.allocLowerString(self.allocator, nodeType.string);
                defer self.allocator.free(typeNameLower);
                if (debug) std.debug.print("Node type: {s}\n", .{typeNameLower});

                var isAlternate = false; // Flag to track alternate nodes

                if (std.mem.eql(u8, typeNameLower, "previewimage")) {
                    isAlternate = true;
                } else if (std.mem.indexOf(u8, typeNameLower, "save") != null
                    or std.mem.eql(u8, typeNameLower, "vhs_videocombine")
                ) {
                    // Check for IMAGE input type
                    if (node.object.get("inputs")) |inputs| {
                        if (inputs != .array) continue;
                        for (inputs.array.items) |input| {
                            if (input != .object) continue;
                            if (input.object.get("type")) |inputType| {
                                if (inputType != .string or !std.mem.eql(u8, inputType.string, "IMAGE")) continue;
                                try saveNodes.append(node);
                                break;
                            }
                        }
                    }
                }


                if (isAlternate) {
                    // Check for IMAGE input type
                    if (node.object.get("inputs")) |inputs| {
                        if (inputs != .array) continue;
                        for (inputs.array.items) |input| {
                            if (input != .object) continue;
                            if (input.object.get("type")) |inputType| {
                                if (inputType != .string or !std.mem.eql(u8, inputType.string, "IMAGE")) continue;
                                try alternateNodes.append(node); // Append to alternateNodes
                                break;
                            }
                        }
                    }
                }
            }
        }

        // Append alternate nodes after all other save nodes
        for (alternateNodes.items) |alternateNode| {
            try saveNodes.append(alternateNode);
        }
        alternateNodes.deinit(); // Deallocate alternateNodes, as its contents have been moved

        return saveNodes;
    }

    fn getNodeInputsByType(self: *ComfyParser, node: std.json.Value, inputType: []const u8) !std.ArrayList(std.json.Value) {
        var inputsOfType = std.ArrayList(std.json.Value).init(self.allocator);

        if (node != .object) return inputsOfType; // Return empty list if not an object

        if (node.object.get("inputs")) |inputs| {
            if (inputs != .array) return inputsOfType; // Return empty list if inputs is not an array

            for (inputs.array.items) |input| {
                if (input != .object) continue;
                if (input.object.get("type")) |currentInputType| {
                    if (currentInputType != .string) continue;
                    if (std.mem.eql(u8, currentInputType.string, inputType)) {
                        try inputsOfType.append(input);
                    }
                }
            }
        }

        return inputsOfType;
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

        var saveImageNodes = try self.getSaveImageNodes();
        defer saveImageNodes.deinit();

        if (debug) {
            std.debug.print("Save image nodes found: {d}\n", .{saveImageNodes.items.len});
        }

        // Trace back from each save image node to find a node that takes "conditioning" type as input
        for (saveImageNodes.items) |saveNode| {
            // debug out the current node id
            if (debug) {
                const current_node_id = saveNode.object.get("id").?.integer;
                std.debug.print("Save node id: {d} - {s}\n", .{current_node_id, saveNode.object.get("type").?.string});
            }

            if (saveNode.object.get("inputs")) |inputs| {
                if (inputs != .array) continue;

                // find the IMAGE input and follow the link progressivly
                for (inputs.array.items) |input| {
                    if (input != .object) continue;
                    if (input.object.get("type")) |inputType| {
                        if (inputType != .string or !std.mem.eql(u8, inputType.string, "IMAGE")) continue;
                    } else {
                        continue;
                    }
                    if (input.object.get("link")) |link| {
                        if (link != .integer) continue;

                        var next_node_id = self.getLinkSource(link.integer);
                        if (debug) std.debug.print("Following image input to node: {?}\n", .{next_node_id});

                        next: while (next_node_id) |node_id| {
                            const node = self.getNodeById(node_id) orelse {
                                std.debug.print("Failed to find node with ID: {d}\n", .{node_id});
                                return null;
                            };
                            if (debug) std.debug.print("Checking node ID: {d}\n", .{node_id});

                            if (node.object.get("type")) |nodeType| {
                                if (nodeType != .string) break;
                                if (debug) std.debug.print("Node type: {s}\n", .{nodeType.string});

                                // if it's a LoadImage node, use the first widget (image name) value as the prompt
                                if (std.mem.eql(u8, nodeType.string, "LoadImage")) {
                                    if (debug) std.debug.print("Found LoadImage node\n", .{});
                                    if (node.object.get("widgets_values")) |values| {
                                        if (values != .array) break;
                                        if (values.array.items.len > 0) {
                                            // it's an array of strings, get the first one
                                            const firstValue = values.array.items[0];
                                            if (firstValue != .string) break;
                                            return try std.fmt.allocPrint(self.allocator, "IMAGE: {s}", .{firstValue.string});
                                        }
                                    } else {
                                        if (debug) std.debug.print("No widgets_values found\n", .{});
                                    }
                                }

                                // if it's an efficiency loader, it will have the prompt
                                if (std.mem.indexOf(u8, nodeType.string, "Eff. Loader") != null) {
                                    if (debug) std.debug.print("Found efficiency loader\n", .{});
                                    // widgets_values 7 is the prompt
                                    if (node.object.get("widgets_values")) |values| {
                                        if (values != .array) break;
                                        if (values.array.items.len < 7) {
                                            if (debug) std.debug.print("Not enough widgets_values found in eff. loader\n", .{});
                                            return null;
                                        }
                                        const prompt = values.array.items[7];
                                        if (prompt != .string) break;
                                        return try self.allocator.dupe(u8, prompt.string);
                                    }
                                }

                                // Check if this node has a "CONDITIONING" input
                                const conditioningInputs = try self.getNodeInputsByType(node, "CONDITIONING");
                                defer conditioningInputs.deinit();
                                if (conditioningInputs.items.len > 0) {
                                    if (debug) std.debug.print("Found CONDITIONING input\n", .{});
                                    // get the conditioning input with the name "positive"
                                    for (conditioningInputs.items) |conditioningInput| {
                                        if (conditioningInput.object.get("name")) |name| {
                                            if (name != .string) continue;
                                            const nameLower = try std.ascii.allocLowerString(self.allocator, name.string);
                                            defer self.allocator.free(nameLower);
                                            if (!std.mem.eql(u8, nameLower, "positive")) continue;
                                            if (debug) std.debug.print("Found positive conditioning input\n", .{});
                                            // get the link for the positive prompt
                                            if (conditioningInput.object.get("link")) |link2| {
                                                if (link2 != .integer) continue;
                                                next_node_id = self.getLinkSource(link2.integer);
                                                if (debug) std.debug.print("Discovered positive conditioning node id: {?}\n", .{next_node_id});
                                                continue :next;
                                            }
                                        }
                                    }
                                }

                                // Check if this node takes a conditioning input
                                const clip_types = [_][]const u8{ "CLIP", "T5" };
                                for (clip_types) |clip_type| {
                                    if (debug) std.debug.print("Checking for {s} input\n", .{clip_type});
                                    const clipInputs = try self.getNodeInputsByType(node, clip_type);
                                    defer clipInputs.deinit();
                                    if (clipInputs.items.len > 0) {
                                        if (debug) std.debug.print("Found {s} input for node ID {d}\n", .{clip_type, node_id});
                                        if (node.object.get("widgets_values")) |values| {
                                            if (values != .array or values.array.items.len == 0) break;
                                            if (debug) {
                                                std.debug.print("Node ID {d} has {d} values: ", .{ node_id, values.array.items.len });
                                                for (values.array.items) |value| {
                                                    if (value == .string) {
                                                        std.debug.print("{s}, ", .{value.string});
                                                    } else if (value == .integer) {
                                                        std.debug.print("{d}, ", .{value.integer});
                                                    } else if (value == .float) {
                                                        std.debug.print("{d}, ", .{value.float});
                                                    }
                                                }
                                                std.debug.print("\n", .{});
                                            }
                                            // check if this is a prompt generator node
                                            if (debug) std.debug.print("Checking if {s} is a prompt generator node\n", .{nodeType.string});
                                            if (std.mem.eql(u8, nodeType.string, "Prompt Generator")) {
                                                if (debug) {
                                                    std.debug.print("Found prompt generator node\n", .{});
                                                    std.debug.print("Found {d} widgets_values\n", .{values.array.items.len});
                                                }
                                                // the input for prompt generator is index 3 or 4... if 4 is not a string then it's probably 3
                                                if (values.array.items.len < 4) break;
                                                var prompt = values.array.items[4];
                                                if (prompt != .string) {
                                                    prompt = values.array.items[3];
                                                }

                                                if (prompt != .string) {
                                                    if (debug) std.debug.print("Prompt generator widget value is not a string\n", .{});
                                                    return null;
                                                }
                                                return try self.allocator.dupe(u8, prompt.string);
                                            }
                                            const prompt = values.array.items[0];
                                            if (prompt != .string) break;
                                            return try self.allocator.dupe(u8, prompt.string);
                                        }
                                        break;
                                    }
                                }

                                // if the node only takes one input and it's an asterisk, it's a reroute or passthrough node
                                // and we can just follow its input
                                if (node.object.get("inputs")) |node_inputs| {
                                    if (node_inputs != .array or node_inputs.array.items.len == 0) break;
                                    if (node_inputs.array.items.len == 1) {
                                        const first_input = node_inputs.array.items[0];
                                        if (first_input != .object) break;
                                        if (first_input.object.get("type")) |input_type| {
                                            if (input_type != .string) break;
                                            if (std.mem.eql(u8, input_type.string, "*")) {
                                                if (debug) std.debug.print("Found passthrough node\n", .{});
                                                if (first_input.object.get("link")) |node_link| {
                                                    if (node_link != .integer) break;
                                                    next_node_id = self.getLinkSource(node_link.integer);
                                                    if (debug) std.debug.print("Passthrough next node id: {?}\n", .{next_node_id});
                                                    continue :next;
                                                }
                                            }
                                        }
                                    }
                                }
                                // Follow any input, in order of preference
                                const input_types = [_][]const u8{ "SDXL_TUPLE", "CONDITIONING", "IMAGE", "LATENT" };
                                for (input_types) |input_type| {
                                    const inputs2 = try self.getNodeInputsByType(node, input_type);
                                    defer inputs2.deinit();
                                    if (inputs2.items.len > 0) {
                                        if (debug) std.debug.print("Found {s} input for node ID {d}\n", .{ input_type, node_id });
                                        // follow the first link for this input type and try that node next
                                        if (inputs2.items[0].object.get("link")) |link2| {
                                            if (link2 != .integer) break;
                                            next_node_id = self.getLinkSource(link2.integer);
                                            if (debug) std.debug.print("Following link to node ID {?}\n", .{next_node_id});
                                            continue :next;
                                        }
                                    }
                                }
                                if (debug) std.debug.print("No preferred inputs found for node ID {d}\n", .{node_id});
                                break;
                            }
                        }
                        if (debug) std.debug.print("No next node found: {?}\n", .{next_node_id});
                    }
                }
            }
        }
        if (debug) std.debug.print("No prompt found\n", .{});

        return null;
    }
};

test "parse ComfyUI workflow" {
    const testing = std.testing;
    debug = true;

    // Open the workflows directory
    var workflows_dir = try std.fs.cwd().openDir("test-artifacts/workflows", .{
        .iterate = true,
    });
    defer workflows_dir.close();

    // Iterate over each entry in the directory
    var dir_iter = workflows_dir.iterate();
    while (try dir_iter.next()) |entry| {
        if (entry.kind != .file) continue; // Skip directories or other entries
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue; // Only process .json files

        // Construct the full path to the workflow file
        const workflow_path = try std.fmt.allocPrint(testing.allocator, "test-artifacts/workflows/{s}", .{entry.name});
        defer testing.allocator.free(workflow_path);

        std.debug.print("Testing workflow: {s}\n", .{workflow_path}); // Log the workflow being tested

        const file = try std.fs.cwd().openFile(workflow_path, .{});
        defer file.close();

        const workflow_json = try file.readToEndAlloc(testing.allocator, 1024 * 1024);
        defer testing.allocator.free(workflow_json);

        var parser = ComfyParser.init(testing.allocator);
        const prompt = try parser.parseWorkflow(workflow_json);
        defer if (prompt) |p| testing.allocator.free(p);

        try testing.expect(prompt != null);
        if (prompt) |p| {
            // output the prompt for debugging
            if (debug) std.debug.print("prompt: {s}\n", .{p});
            // if the prompt should be an image, it will start with IMAGE:
            if (std.mem.startsWith(u8, p, "IMAGE:")) {
                try testing.expectFmt("IMAGE: image.png", "{s}", .{p});
            } else {
                try testing.expectFmt("this is the prompt text! it has lots of cool stuff in it", "{s}", .{p});
            }
        }
    }
}
