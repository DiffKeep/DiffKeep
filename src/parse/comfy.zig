const std = @import("std");

pub const ParseResult = struct {
    positive_prompt: ?[]const u8 = null,
    negative_prompt: ?[]const u8 = null,
    model: ?[]const u8 = null,
    cfg: ?f64 = null,
    steps: ?i64 = null,
    seed: ?i64 = null,
    sampler: ?[]const u8 = null,
    scheduler: ?[]const u8 = null,
    loras: ?[]const []const u8 = null,

    pub fn deinit(self: *ParseResult, allocator: std.mem.Allocator) void {
        if (self.positive_prompt) |p| allocator.free(p);
        if (self.negative_prompt) |p| allocator.free(p);
        if (self.model) |m| allocator.free(m);
        if (self.sampler) |s| allocator.free(s);
        if (self.scheduler) |s| allocator.free(s);
        if (self.loras) |loras| {
            for (loras) |lora| allocator.free(lora);
            allocator.free(loras);
        }
    }
};

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

    fn getLinkSource(self: *ComfyParser, link_id: i64) ?i64 {
        for (self.links.items) |link| {
            if (link != .array or link.array.items.len < 2) continue;
            const id = link.array.items[0];
            if (id != .integer or id.integer != link_id) continue;
            const src = link.array.items[1];
            if (src != .integer) continue;
            return src.integer;
        }
        return null;
    }

    fn getNodeById(self: *ComfyParser, id: i64) ?std.json.Value {
        for (self.nodes.items) |node| {
            if (node != .object) continue;
            const node_id = node.object.get("id") orelse continue;
            if (node_id != .integer or node_id.integer != id) continue;
            return node;
        }
        return null;
    }

    fn getInputLink(node: std.json.Value, input_name: []const u8) ?i64 {
        if (node != .object) return null;
        const inputs = node.object.get("inputs") orelse return null;
        if (inputs != .array) return null;
        for (inputs.array.items) |inp| {
            if (inp != .object) continue;
            const name = inp.object.get("name") orelse continue;
            if (name != .string or !std.mem.eql(u8, name.string, input_name)) continue;
            const link = inp.object.get("link") orelse return null;
            if (link != .integer) return null;
            return link.integer;
        }
        return null;
    }

    fn isActiveSamplerNode(node: std.json.Value) bool {
        if (node != .object) return false;
        if (node.object.get("mode")) |mode| {
            if (mode == .integer and mode.integer != 0) return false;
        }
        const t_val = node.object.get("type") orelse return false;
        if (t_val != .string) return false;
        const t = t_val.string;
        return std.mem.startsWith(u8, t, "KSampler") or
            std.mem.eql(u8, t, "KSamplerAdvanced") or
            std.mem.eql(u8, t, "SamplerCustomNoise") or
            std.mem.eql(u8, t, "SamplerCustom") or
            std.mem.eql(u8, t, "SamplerCustomAdvanced");
    }

    // Follow a conditioning link to find the text prompt. Returns a newly allocated string or null.
    fn followToText(self: *ComfyParser, link_id: i64, depth: u8) !?[]const u8 {
        if (depth > 15) return null;
        const src_id = self.getLinkSource(link_id) orelse return null;
        const node = self.getNodeById(src_id) orelse return null;
        if (node != .object) return null;
        const t_val = node.object.get("type") orelse return null;
        if (t_val != .string) return null;
        const t = t_val.string;

        // Direct text encoders: wv[0] is the text
        if (std.mem.indexOf(u8, t, "CLIPTextEncode") != null or
            std.mem.indexOf(u8, t, "T5TextEncode") != null)
        {
            const wv = node.object.get("widgets_values") orelse return null;
            if (wv != .array or wv.array.items.len == 0) return null;
            const p = wv.array.items[0];
            if (p != .string) return null;
            return try self.allocator.dupe(u8, p.string);
        }

        // Prompt Generator: try wv[4] (generated output, may be string or integer seed),
        // fall back to wv[3] (user-provided base text)
        if (std.mem.indexOf(u8, t, "Prompt Generator") != null) {
            const wv = node.object.get("widgets_values") orelse return null;
            if (wv != .array) return null;
            const items = wv.array.items;
            if (items.len > 4 and items[4] == .string and items[4].string.len > 0) {
                return try self.allocator.dupe(u8, items[4].string);
            }
            if (items.len > 3 and items[3] == .string and items[3].string.len > 0) {
                return try self.allocator.dupe(u8, items[3].string);
            }
            return null;
        }

        // Any node with exactly one * typed input is a pass-through (Reroute, Sleep, ImpactSleep, etc.)
        if (node.object.get("inputs")) |inputs| {
            if (inputs == .array and inputs.array.items.len == 1) {
                const inp = inputs.array.items[0];
                if (inp == .object) {
                    if (inp.object.get("type")) |tp| {
                        if (tp == .string and std.mem.eql(u8, tp.string, "*")) {
                            if (inp.object.get("link")) |lnk| {
                                if (lnk == .integer) return self.followToText(lnk.integer, depth + 1);
                            }
                        }
                    }
                }
            }
        }

        // Nodes that pass conditioning through a "conditioning" or "positive" named input
        for ([_][]const u8{ "conditioning", "positive" }) |name| {
            if (getInputLink(node, name)) |pass_link| {
                return self.followToText(pass_link, depth + 1);
            }
        }

        // If node has exactly one CONDITIONING-type input with a link, follow it
        if (node.object.get("inputs")) |inputs| {
            if (inputs == .array) {
                var found_link: ?i64 = null;
                var cond_count: usize = 0;
                for (inputs.array.items) |inp| {
                    if (inp != .object) continue;
                    const tp = inp.object.get("type") orelse continue;
                    if (tp != .string or !std.mem.eql(u8, tp.string, "CONDITIONING")) continue;
                    cond_count += 1;
                    if (inp.object.get("link")) |lnk| {
                        if (lnk == .integer) found_link = lnk.integer;
                    }
                }
                if (cond_count == 1) {
                    if (found_link) |lnk| return self.followToText(lnk, depth + 1);
                }
            }
        }

        return null;
    }

    // Follow a model link, collecting LoRA names along the way, until we reach a checkpoint loader.
    fn followToModel(self: *ComfyParser, link_id: i64, loras: *std.ArrayList([]const u8), depth: u8) !?[]const u8 {
        if (depth > 20) return null;
        const src_id = self.getLinkSource(link_id) orelse return null;
        const node = self.getNodeById(src_id) orelse return null;
        if (node != .object) return null;
        const t_val = node.object.get("type") orelse return null;
        if (t_val != .string) return null;
        const t = t_val.string;

        // Checkpoint / model loaders: wv[0] is model filename
        if (std.mem.indexOf(u8, t, "CheckpointLoader") != null or
            std.mem.indexOf(u8, t, "UnetLoader") != null or
            std.mem.eql(u8, t, "PixArtCheckpointLoader"))
        {
            const wv = node.object.get("widgets_values") orelse return null;
            if (wv != .array or wv.array.items.len == 0) return null;
            if (wv.array.items[0] != .string) return null;
            return try self.allocator.dupe(u8, wv.array.items[0].string);
        }

        // Efficient Loader (SDXL): wv[0] is checkpoint name
        if (std.mem.indexOf(u8, t, "Eff. Loader") != null) {
            const wv = node.object.get("widgets_values") orelse return null;
            if (wv != .array or wv.array.items.len == 0) return null;
            if (wv.array.items[0] != .string) return null;
            return try self.allocator.dupe(u8, wv.array.items[0].string);
        }

        // LoRA loader: collect lora name (wv[0]) and follow model input up the chain
        if (std.mem.indexOf(u8, t, "LoraLoader") != null or std.mem.eql(u8, t, "LoRA Loader")) {
            if (node.object.get("widgets_values")) |wv| {
                if (wv == .array and wv.array.items.len > 0 and wv.array.items[0] == .string) {
                    const duped = try self.allocator.dupe(u8, wv.array.items[0].string);
                    try loras.append(self.allocator, duped);
                }
            }
            if (getInputLink(node, "model")) |model_link| {
                return self.followToModel(model_link, loras, depth + 1);
            }
            return null;
        }

        // Reroute: follow its single input
        if (std.mem.eql(u8, t, "Reroute")) {
            if (node.object.get("inputs")) |inputs| {
                if (inputs == .array and inputs.array.items.len > 0) {
                    const inp = inputs.array.items[0];
                    if (inp == .object) {
                        if (inp.object.get("link")) |lnk| {
                            if (lnk == .integer) return self.followToModel(lnk.integer, loras, depth + 1);
                        }
                    }
                }
            }
            return null;
        }

        // Passthrough model nodes (Automatic CFG, FreeU, DynamicThresholding, etc.)
        if (getInputLink(node, "model")) |model_link| {
            return self.followToModel(model_link, loras, depth + 1);
        }

        return null;
    }

    // Extract seed/steps/cfg/sampler/scheduler from a sampler node's widgets_values.
    fn extractSamplerWidgets(self: *ComfyParser, node: std.json.Value, result: *ParseResult) !void {
        if (node != .object) return;
        const t_val = node.object.get("type") orelse return;
        if (t_val != .string) return;
        const t = t_val.string;
        const wv_val = node.object.get("widgets_values") orelse return;
        if (wv_val != .array) return;
        const items = wv_val.array.items;

        // KSamplerAdvanced: [add_noise, seed, control, steps, cfg, sampler, sched, ...]
        if (std.mem.eql(u8, t, "KSamplerAdvanced") or std.mem.eql(u8, t, "KSampler Advanced")) {
            if (items.len > 1 and items[1] == .integer and items[1].integer >= 0)
                result.seed = items[1].integer;
            if (items.len > 3 and items[3] == .integer)
                result.steps = items[3].integer;
            if (items.len > 4)
                result.cfg = floatFromValue(items[4]);
            if (items.len > 5 and items[5] == .string and result.sampler == null)
                result.sampler = try self.allocator.dupe(u8, items[5].string);
            if (items.len > 6 and items[6] == .string and result.scheduler == null)
                result.scheduler = try self.allocator.dupe(u8, items[6].string);
            return;
        }

        // SamplerCustomNoise: [add_noise, return_leftover, noise_type, seed, control, ...]
        if (std.mem.eql(u8, t, "SamplerCustomNoise") or std.mem.eql(u8, t, "SamplerCustom")) {
            if (items.len > 3 and items[3] == .integer and items[3].integer >= 0)
                result.seed = items[3].integer;
            return;
        }

        // Standard KSampler family: [seed, control, steps, cfg, sampler, sched, ...]
        if (items.len > 0 and items[0] == .integer and items[0].integer >= 0)
            result.seed = items[0].integer;
        if (items.len > 2 and items[2] == .integer)
            result.steps = items[2].integer;
        if (items.len > 3)
            result.cfg = floatFromValue(items[3]);
        if (items.len > 4 and items[4] == .string and result.sampler == null)
            result.sampler = try self.allocator.dupe(u8, items[4].string);
        if (items.len > 5 and items[5] == .string and result.scheduler == null)
            result.scheduler = try self.allocator.dupe(u8, items[5].string);
    }

    fn floatFromValue(val: std.json.Value) ?f64 {
        return switch (val) {
            .float => |f| f,
            .integer => |i| @as(f64, @floatFromInt(i)),
            else => null,
        };
    }

    // For SDXL tuple-based samplers, extract text from the Efficient Loader node.
    fn sdxlLoaderField(self: *ComfyParser, sdxl_link: i64, index: usize) !?[]const u8 {
        const src_id = self.getLinkSource(sdxl_link) orelse return null;
        const node = self.getNodeById(src_id) orelse return null;
        if (node != .object) return null;
        const t_val = node.object.get("type") orelse return null;
        if (t_val != .string or std.mem.indexOf(u8, t_val.string, "Eff. Loader") == null) return null;
        const wv = node.object.get("widgets_values") orelse return null;
        if (wv != .array or wv.array.items.len <= index) return null;
        const p = wv.array.items[index];
        if (p != .string) return null;
        return try self.allocator.dupe(u8, p.string);
    }

    pub fn parseWorkflow(self: *ComfyParser, workflow_json: []const u8) !?ParseResult {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, workflow_json, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return null;

        const nodes_val = root.object.get("nodes") orelse return null;
        if (nodes_val != .array) return null;
        self.nodes = nodes_val.array;

        const links_val = root.object.get("links") orelse return null;
        if (links_val != .array) return null;
        self.links = links_val.array;

        var result = ParseResult{};
        var loras_list = std.ArrayList([]const u8).empty;

        errdefer {
            result.deinit(self.allocator);
            for (loras_list.items) |l| self.allocator.free(l);
            loras_list.deinit(self.allocator);
        }

        for (self.nodes.items) |node| {
            if (!isActiveSamplerNode(node)) continue;
            if (result.positive_prompt != null) break;

            // SDXL tuple path: KSampler SDXL (Eff.) takes sdxl_tuple instead of
            // separate positive/negative/model inputs.
            if (getInputLink(node, "sdxl_tuple")) |sdxl_link| {
                // wv[7]=positive, wv[8]=negative, wv[0]=model in Eff. Loader SDXL
                result.positive_prompt = try self.sdxlLoaderField(sdxl_link, 7);
                result.negative_prompt = try self.sdxlLoaderField(sdxl_link, 8);
                result.model = try self.sdxlLoaderField(sdxl_link, 0);
                if (result.positive_prompt != null) {
                    try self.extractSamplerWidgets(node, &result);
                    break;
                }
            }

            // Standard path: follow named positive/negative/model inputs
            if (getInputLink(node, "positive")) |pos_link| {
                result.positive_prompt = try self.followToText(pos_link, 0);
            }

            // SamplerCustomAdvanced: conditioning/model/cfg are in the guider node
            if (result.positive_prompt == null) {
                if (getInputLink(node, "guider")) |guider_link| {
                    const guider_src = self.getLinkSource(guider_link) orelse continue;
                    const guider_node = self.getNodeById(guider_src) orelse continue;
                    if (getInputLink(guider_node, "positive")) |pos_link| {
                        result.positive_prompt = try self.followToText(pos_link, 0);
                    }
                    if (result.positive_prompt != null) {
                        if (getInputLink(guider_node, "negative")) |neg_link| {
                            result.negative_prompt = try self.followToText(neg_link, 0);
                        }
                        if (getInputLink(guider_node, "model")) |model_link| {
                            result.model = try self.followToModel(model_link, &loras_list, 0);
                        }
                        if (guider_node.object.get("widgets_values")) |wv| {
                            if (wv == .array and wv.array.items.len > 0)
                                result.cfg = floatFromValue(wv.array.items[0]);
                        }
                    }
                }
            }

            if (result.positive_prompt == null) continue;

            if (result.negative_prompt == null) {
                if (getInputLink(node, "negative")) |neg_link| {
                    result.negative_prompt = try self.followToText(neg_link, 0);
                }
            }
            if (result.model == null) {
                if (getInputLink(node, "model")) |model_link| {
                    result.model = try self.followToModel(model_link, &loras_list, 0);
                }
            }
            try self.extractSamplerWidgets(node, &result);

            // SamplerCustomAdvanced: seed is in the RandomNoise node's widgets_values[0]
            if (result.seed == null) {
                if (getInputLink(node, "noise")) |noise_link| {
                    if (self.getLinkSource(noise_link)) |noise_src| {
                        if (self.getNodeById(noise_src)) |noise_node| {
                            if (noise_node.object.get("widgets_values")) |wv| {
                                if (wv == .array and wv.array.items.len > 0 and wv.array.items[0] == .integer)
                                    result.seed = wv.array.items[0].integer;
                            }
                        }
                    }
                }
            }
        }

        if (result.positive_prompt == null) {
            result.deinit(self.allocator);
            for (loras_list.items) |l| self.allocator.free(l);
            loras_list.deinit(self.allocator);
            return null;
        }

        if (loras_list.items.len > 0) {
            result.loras = try loras_list.toOwnedSlice(self.allocator);
        } else {
            loras_list.deinit(self.allocator);
        }

        return result;
    }

    // Parse the ComfyUI "prompt" chunk (execution graph with resolved inputs).
    // Format: {"node_id": {"class_type": "...", "inputs": {"key": value_or_[node_id,slot]}}}
    // This is more reliable than parseWorkflow for workflows with AI-generated text
    // or complex group nodes.
    pub fn parsePromptChunk(self: *ComfyParser, prompt_json: []const u8) !?ParseResult {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, prompt_json, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return null;

        var result = ParseResult{};
        var loras_list = std.ArrayList([]const u8).empty;

        errdefer {
            result.deinit(self.allocator);
            for (loras_list.items) |l| self.allocator.free(l);
            loras_list.deinit(self.allocator);
        }

        var iter = root.object.iterator();
        while (iter.next()) |entry| {
            if (result.positive_prompt != null) break;
            const node = entry.value_ptr.*;
            if (node != .object) continue;

            const ct_val = node.object.get("class_type") orelse continue;
            if (ct_val != .string) continue;
            const ct = ct_val.string;
            if (!promptIsKSampler(ct)) continue;

            const inputs = node.object.get("inputs") orelse continue;
            if (inputs != .object) continue;

            // Extract scalar sampler params (already resolved in prompt chunk)
            promptExtractSamplerInputs(inputs.object, &result);
            if (result.sampler == null) {
                if (inputs.object.get("sampler_name")) |v| {
                    if (v == .string) result.sampler = try self.allocator.dupe(u8, v.string);
                }
            }
            if (result.scheduler == null) {
                if (inputs.object.get("scheduler")) |v| {
                    if (v == .string) result.scheduler = try self.allocator.dupe(u8, v.string);
                }
            }

            // Follow positive conditioning link
            if (inputs.object.get("positive")) |pos_val| {
                result.positive_prompt = try self.followPromptToText(root.object, pos_val, 0);
            }

            // SamplerCustomAdvanced: conditioning/model/cfg are in the guider node
            if (result.positive_prompt == null) {
                if (inputs.object.get("guider")) |guider_val| {
                    if (guider_val == .array and guider_val.array.items.len >= 1 and
                        guider_val.array.items[0] == .string)
                    {
                        const guider_id = guider_val.array.items[0].string;
                        if (root.object.get(guider_id)) |guider_node| {
                            if (guider_node == .object) {
                                if (guider_node.object.get("inputs")) |g_inp| {
                                    if (g_inp == .object) {
                                        if (g_inp.object.get("positive")) |pos_val| {
                                            result.positive_prompt = try self.followPromptToText(root.object, pos_val, 0);
                                        }
                                        if (result.positive_prompt != null) {
                                            if (g_inp.object.get("negative")) |neg_val| {
                                                result.negative_prompt = try self.followPromptToText(root.object, neg_val, 0);
                                            }
                                            if (g_inp.object.get("model")) |model_val| {
                                                result.model = try self.followPromptToModel(root.object, model_val, &loras_list, 0);
                                            }
                                            if (g_inp.object.get("cfg")) |cfg_val| {
                                                result.cfg = switch (cfg_val) {
                                                    .float => |f| f,
                                                    .integer => |i| @as(f64, @floatFromInt(i)),
                                                    else => null,
                                                };
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if (result.positive_prompt == null) continue;

            // Follow negative/model links (standard path; guider path already sets these)
            if (result.negative_prompt == null) {
                if (inputs.object.get("negative")) |neg_val| {
                    result.negative_prompt = try self.followPromptToText(root.object, neg_val, 0);
                }
            }
            if (result.model == null) {
                if (inputs.object.get("model")) |model_val| {
                    result.model = try self.followPromptToModel(root.object, model_val, &loras_list, 0);
                }
            }

            // SamplerCustomAdvanced: seed is in the noise node (noise_seed input)
            if (result.seed == null) {
                if (inputs.object.get("noise")) |noise_val| {
                    if (noise_val == .array and noise_val.array.items.len >= 1 and
                        noise_val.array.items[0] == .string)
                    {
                        const noise_id = noise_val.array.items[0].string;
                        if (root.object.get(noise_id)) |noise_node| {
                            if (noise_node == .object) {
                                if (noise_node.object.get("inputs")) |n_inp| {
                                    if (n_inp == .object) {
                                        if (n_inp.object.get("noise_seed")) |seed_val| {
                                            if (seed_val == .integer) result.seed = seed_val.integer;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        if (result.positive_prompt == null) {
            result.deinit(self.allocator);
            for (loras_list.items) |l| self.allocator.free(l);
            loras_list.deinit(self.allocator);
            return null;
        }

        if (loras_list.items.len > 0) {
            result.loras = try loras_list.toOwnedSlice(self.allocator);
        } else {
            loras_list.deinit(self.allocator);
        }

        return result;
    }

    // Follow a link value [node_id_str, slot] through the prompt chunk graph to find text.
    fn followPromptToText(self: *ComfyParser, nodes: std.json.ObjectMap, val: std.json.Value, depth: u8) !?[]const u8 {
        if (depth > 20) return null;

        // Literal string value
        if (val == .string) {
            if (val.string.len > 0) return try self.allocator.dupe(u8, val.string);
            return null;
        }

        // Link: ["node_id", slot]
        if (val != .array or val.array.items.len < 1) return null;
        const node_id_val = val.array.items[0];
        const node_id = switch (node_id_val) {
            .string => |s| s,
            else => return null,
        };
        const node = nodes.get(node_id) orelse return null;
        if (node != .object) return null;
        const ct_val = node.object.get("class_type") orelse return null;
        if (ct_val != .string) return null;
        const ct = ct_val.string;
        const inputs = node.object.get("inputs") orelse return null;
        if (inputs != .object) return null;
        const inp = inputs.object;

        // Direct text encoders
        if (std.mem.indexOf(u8, ct, "CLIPTextEncode") != null or
            std.mem.indexOf(u8, ct, "T5TextEncode") != null)
        {
            if (inp.get("text")) |text_val| {
                return self.followPromptToText(nodes, text_val, depth + 1);
            }
            return null;
        }

        // Static text nodes
        if (std.mem.eql(u8, ct, "Text Multiline") or
            std.mem.eql(u8, ct, "TextMultiline") or
            std.mem.eql(u8, ct, "CLIPTextEncodeFlux") or
            std.mem.eql(u8, ct, "String Literal") or
            std.mem.eql(u8, ct, "StringLiteral"))
        {
            if (inp.get("text")) |text_val| {
                if (text_val == .string and text_val.string.len > 0)
                    return try self.allocator.dupe(u8, text_val.string);
            }
            return null;
        }

        // Pass-through conditioning nodes (Sleep, Reroute, FluxGuidance, etc.)
        // Try well-known pass-through input names in priority order
        for ([_][]const u8{ "input", "conditioning", "positive" }) |pt| {
            if (inp.get(pt)) |pt_val| {
                if (pt_val == .array) {
                    if (try self.followPromptToText(nodes, pt_val, depth + 1)) |text| return text;
                }
            }
        }

        // For concatenation/combining nodes: try text inputs in order, return first found
        for ([_][]const u8{ "text", "text_a", "text_b", "text_c", "prompt", "prefix", "postfix", "string" }) |name| {
            if (inp.get(name)) |name_val| {
                if (name_val == .string and name_val.string.len > 0) {
                    return try self.allocator.dupe(u8, name_val.string);
                }
                if (name_val == .array) {
                    if (try self.followPromptToText(nodes, name_val, depth + 1)) |text| return text;
                }
            }
        }

        return null;
    }

    // Follow a model link in the prompt chunk, collecting loras, to find checkpoint name.
    fn followPromptToModel(self: *ComfyParser, nodes: std.json.ObjectMap, val: std.json.Value, loras: *std.ArrayList([]const u8), depth: u8) !?[]const u8 {
        if (depth > 20) return null;
        if (val != .array or val.array.items.len < 1) return null;
        const node_id_val = val.array.items[0];
        const node_id = switch (node_id_val) {
            .string => |s| s,
            else => return null,
        };
        const node = nodes.get(node_id) orelse return null;
        if (node != .object) return null;
        const ct_val = node.object.get("class_type") orelse return null;
        if (ct_val != .string) return null;
        const ct = ct_val.string;
        const inputs_val = node.object.get("inputs") orelse return null;
        if (inputs_val != .object) return null;
        const inp = inputs_val.object;

        // Checkpoint loaders: ckpt_name or unet_name is the widget
        if (std.mem.indexOf(u8, ct, "CheckpointLoader") != null or
            std.mem.indexOf(u8, ct, "UnetLoader") != null)
        {
            for ([_][]const u8{ "ckpt_name", "unet_name" }) |key| {
                if (inp.get(key)) |name_val| {
                    if (name_val == .string) return try self.allocator.dupe(u8, name_val.string);
                }
            }
            return null;
        }

        // LoRA loaders: collect lora_name and follow model input
        if (std.mem.indexOf(u8, ct, "LoraLoader") != null) {
            if (inp.get("lora_name")) |lora_val| {
                if (lora_val == .string and lora_val.string.len > 0) {
                    const duped = try self.allocator.dupe(u8, lora_val.string);
                    try loras.append(self.allocator, duped);
                }
            }
            if (inp.get("model")) |model_val| {
                return self.followPromptToModel(nodes, model_val, loras, depth + 1);
            }
            return null;
        }

        // Passthrough (Automatic CFG, FreeU, etc.): follow model input
        if (inp.get("model")) |model_val| {
            return self.followPromptToModel(nodes, model_val, loras, depth + 1);
        }

        return null;
    }

    // Parse A1111-style parameters text (from PNG iTXt "parameters" chunk).
    // Format:
    //   <positive prompt>
    //   Negative prompt: <negative prompt>
    //   Steps: N, Sampler: X, CFG scale: F, Seed: N, ...
    pub fn parseA1111Parameters(self: *ComfyParser, text: []const u8) !?ParseResult {
        var result = ParseResult{};
        errdefer result.deinit(self.allocator);

        // Find the settings line: a line that starts with a known A1111 parameter key
        var settings_line_start: ?usize = null;
        {
            var pos: usize = 0;
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "Steps:") or
                    std.mem.startsWith(u8, line, "Sampler:") or
                    std.mem.startsWith(u8, line, "CFG scale:"))
                {
                    settings_line_start = pos;
                    break;
                }
                pos += line.len + 1;
            }
        }

        // Find "Negative prompt:" line (must come before settings)
        var neg_content_start: ?usize = null;
        var neg_line_start: ?usize = null;
        {
            var pos: usize = 0;
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| {
                if (settings_line_start) |sls| {
                    if (pos >= sls) break;
                }
                if (std.mem.startsWith(u8, line, "Negative prompt:")) {
                    neg_line_start = pos;
                    neg_content_start = pos + "Negative prompt:".len;
                    if (neg_content_start.? < text.len and text[neg_content_start.?] == ' ')
                        neg_content_start.? += 1;
                }
                pos += line.len + 1;
            }
        }

        // Positive prompt: everything before neg line or settings line
        const pos_end = neg_line_start orelse settings_line_start orelse text.len;
        const pos_text = std.mem.trimEnd(u8, text[0..pos_end], " \t\r\n");
        if (pos_text.len > 0)
            result.positive_prompt = try self.allocator.dupe(u8, pos_text);

        // Negative prompt: from neg_content_start to settings line
        if (neg_content_start) |ncs| {
            const neg_end = settings_line_start orelse text.len;
            const neg_text = std.mem.trimEnd(u8, text[ncs..neg_end], " \t\r\n");
            if (neg_text.len > 0)
                result.negative_prompt = try self.allocator.dupe(u8, neg_text);
        }

        // Settings line: "Steps: N, Sampler: X, CFG scale: F, Seed: N, ..."
        if (settings_line_start) |sls| {
            const line_end = std.mem.indexOfScalarPos(u8, text, sls, '\n') orelse text.len;
            try parseA1111Settings(self.allocator, text[sls..line_end], &result);
        }

        if (result.positive_prompt == null) {
            result.deinit(self.allocator);
            return null;
        }
        return result;
    }
};

// Parse "Steps: N, Sampler: X, CFG scale: F, Seed: N, ..." key-value line.
// Values containing commas must be inside {} or [] brackets (e.g. Hashes: {...}).
fn parseA1111Settings(allocator: std.mem.Allocator, line: []const u8, result: *ParseResult) !void {
    var i: usize = 0;
    while (i < line.len) {
        const colon = std.mem.indexOfPos(u8, line, i, ": ") orelse break;
        const key = std.mem.trim(u8, line[i..colon], " ");
        var j: usize = colon + 2;
        var depth: usize = 0;
        var value_end: usize = line.len;
        while (j < line.len) {
            switch (line[j]) {
                '{', '[' => depth += 1,
                '}', ']' => if (depth > 0) { depth -= 1; },
                ',' => if (depth == 0 and j + 1 < line.len and line[j + 1] == ' ') {
                    value_end = j;
                    break;
                },
                else => {},
            }
            j += 1;
        }
        const value = std.mem.trim(u8, line[colon + 2 .. value_end], " ");
        i = if (value_end + 2 <= line.len) value_end + 2 else line.len;

        if (std.mem.eql(u8, key, "Steps")) {
            if (result.steps == null) result.steps = std.fmt.parseInt(i64, value, 10) catch null;
        } else if (std.mem.eql(u8, key, "Sampler")) {
            if (result.sampler == null and value.len > 0)
                result.sampler = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "Scheduler")) {
            if (result.scheduler == null and value.len > 0)
                result.scheduler = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "CFG scale")) {
            if (result.cfg == null) result.cfg = std.fmt.parseFloat(f64, value) catch null;
        } else if (std.mem.eql(u8, key, "Seed")) {
            if (result.seed == null) result.seed = std.fmt.parseInt(i64, value, 10) catch null;
        } else if (std.mem.eql(u8, key, "Model")) {
            if (result.model == null and value.len > 0)
                result.model = try allocator.dupe(u8, value);
        }
    }
}

fn promptIsKSampler(class_type: []const u8) bool {
    return std.mem.startsWith(u8, class_type, "KSampler") or
        std.mem.eql(u8, class_type, "KSamplerAdvanced") or
        std.mem.eql(u8, class_type, "SamplerCustomNoise") or
        std.mem.eql(u8, class_type, "SamplerCustom") or
        std.mem.eql(u8, class_type, "SamplerCustomAdvanced");
}

fn promptExtractSamplerInputs(inp: std.json.ObjectMap, result: *ParseResult) void {
    // In the prompt chunk, sampler values are explicit named inputs (not widgets_values).
    // Only set numeric fields here — string fields must be duped by the caller.
    if (inp.get("seed")) |v| {
        if (v == .integer and v.integer >= 0) result.seed = v.integer;
    }
    if (inp.get("steps")) |v| {
        if (v == .integer) result.steps = v.integer;
    }
    if (inp.get("cfg")) |v| {
        result.cfg = switch (v) {
            .float => |f| f,
            .integer => |i| @as(f64, @floatFromInt(i)),
            else => null,
        };
    }
}

test "parse ComfyUI workflow" {
    const testing = std.testing;
    const io = testing.io;

    var workflows_dir = try std.Io.Dir.cwd().openDir(io, "test-artifacts/workflows", .{ .iterate = true });
    defer workflows_dir.close(io);

    var dir_iter = workflows_dir.iterate();
    while (try dir_iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const workflow_path = try std.fmt.allocPrint(testing.allocator, "test-artifacts/workflows/{s}", .{entry.name});
        defer testing.allocator.free(workflow_path);

        const file = try std.Io.Dir.cwd().openFile(io, workflow_path, .{});
        defer file.close(io);

        const file_size = try file.length(io);
        const workflow_json = try testing.allocator.alloc(u8, file_size);
        defer testing.allocator.free(workflow_json);
        _ = try file.readPositionalAll(io, workflow_json, 0);

        var parser = ComfyParser.init(testing.allocator);
        var maybe_result = try parser.parseWorkflow(workflow_json);

        try testing.expect(maybe_result != null);

        if (maybe_result) |*result| {
            defer result.deinit(testing.allocator);
            try testing.expect(result.positive_prompt != null);
        }
    }
}
