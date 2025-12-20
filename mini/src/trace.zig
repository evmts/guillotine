const std = @import("std");

/// EIP-3155 compatible trace entry
pub const TraceEntry = struct {
    pc: u64,
    op: u8,
    gas: u64,
    gasCost: u64,
    memory: ?[]const u8,
    memSize: usize,
    stack: []const u256,
    returnData: ?[]const u8,
    depth: usize,
    refund: i64,
    opName: []const u8,
    error_msg: ?[]const u8 = null,

    pub fn toJson(self: *const TraceEntry, allocator: std.mem.Allocator) !std.json.Value {
        var obj = std.StringArrayHashMap(std.json.Value).init(allocator);

        try obj.put("pc", .{ .integer = @intCast(self.pc) });
        try obj.put("op", .{ .integer = @intCast(self.op) });

        // Format gas as hex string
        var gas_buf: [32]u8 = undefined;
        const gas_str = try std.fmt.bufPrint(&gas_buf, "0x{x}", .{self.gas});
        try obj.put("gas", .{ .string = try allocator.dupe(u8, gas_str) });

        var gas_cost_buf: [32]u8 = undefined;
        const gas_cost_str = try std.fmt.bufPrint(&gas_cost_buf, "0x{x}", .{self.gasCost});
        try obj.put("gasCost", .{ .string = try allocator.dupe(u8, gas_cost_str) });

        // Memory as hex string if present
        if (self.memory) |mem| {
            const hex_mem = try allocator.alloc(u8, mem.len * 2 + 2);
            hex_mem[0] = '0';
            hex_mem[1] = 'x';
            for (mem, 0..) |byte, i| {
                _ = try std.fmt.bufPrint(hex_mem[2 + i * 2 ..][0..2], "{x:0>2}", .{byte});
            }
            try obj.put("memory", .{ .string = hex_mem });
        } else {
            try obj.put("memory", .null);
        }

        try obj.put("memSize", .{ .integer = @intCast(self.memSize) });

        // Stack as array of hex strings
        var stack_arr = std.ArrayList(std.json.Value){};
        for (self.stack) |val| {
            var val_buf: [66]u8 = undefined;
            const val_str = try std.fmt.bufPrint(&val_buf, "0x{x}", .{val});
            try stack_arr.append(allocator, .{ .string = try allocator.dupe(u8, val_str) });
        }
        try obj.put("stack", .{ .array = stack_arr });

        // Return data as hex string if present
        if (self.returnData) |data| {
            const hex_data = try allocator.alloc(u8, data.len * 2 + 2);
            hex_data[0] = '0';
            hex_data[1] = 'x';
            for (data, 0..) |byte, i| {
                _ = try std.fmt.bufPrint(hex_data[2 + i * 2 ..][0..2], "{x:0>2}", .{byte});
            }
            try obj.put("returnData", .{ .string = hex_data });
        } else {
            try obj.put("returnData", .null);
        }

        try obj.put("depth", .{ .integer = @intCast(self.depth) });
        try obj.put("refund", .{ .integer = @intCast(self.refund) });
        try obj.put("opName", .{ .string = try allocator.dupe(u8, self.opName) });

        if (self.error_msg) |err| {
            try obj.put("error", .{ .string = try allocator.dupe(u8, err) });
        }

        return .{ .object = obj };
    }
};

/// Tracer that captures EIP-3155 compatible traces
pub const Tracer = struct {
    entries: std.ArrayList(TraceEntry),
    allocator: std.mem.Allocator,
    enabled: bool = false,

    pub fn init(allocator: std.mem.Allocator) Tracer {
        return .{
            .entries = std.ArrayList(TraceEntry){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Tracer) void {
        // Free allocated memory in entries
        for (self.entries.items) |entry| {
            if (entry.memory) |mem| {
                self.allocator.free(mem);
            }
            if (entry.returnData) |data| {
                self.allocator.free(data);
            }
            self.allocator.free(entry.stack);
            self.allocator.free(entry.opName);
            if (entry.error_msg) |msg| {
                self.allocator.free(msg);
            }
        }
        self.entries.deinit(self.allocator);
    }

    pub fn enable(self: *Tracer) void {
        self.enabled = true;
    }

    pub fn disable(self: *Tracer) void {
        self.enabled = false;
    }

    pub fn captureState(
        self: *Tracer,
        pc: u64,
        op: u8,
        gas: u64,
        gas_cost: u64,
        memory: ?[]const u8,
        stack: []const u256,
        return_data: ?[]const u8,
        depth: usize,
        refund: i64,
        op_name: []const u8,
    ) !void {
        if (!self.enabled) return;

        // Duplicate dynamic data
        const mem_copy = if (memory) |m| try self.allocator.dupe(u8, m) else null;
        const stack_copy = try self.allocator.dupe(u256, stack);
        const return_copy = if (return_data) |r| try self.allocator.dupe(u8, r) else null;
        const op_name_copy = try self.allocator.dupe(u8, op_name);

        const entry = TraceEntry{
            .pc = pc,
            .op = op,
            .gas = gas,
            .gasCost = gas_cost,
            .memory = mem_copy,
            .memSize = if (memory) |m| m.len else 0,
            .stack = stack_copy,
            .returnData = return_copy,
            .depth = depth,
            .refund = refund,
            .opName = op_name_copy,
        };

        try self.entries.append(self.allocator, entry);
    }

    pub fn toJson(self: *const Tracer) !std.json.Value {
        var arr = std.ArrayList(std.json.Value){};

        for (self.entries.items) |*entry| {
            const entry_json = try entry.toJson(self.allocator);
            try arr.append(self.allocator, entry_json);
        }

        return .{ .array = arr };
    }

    pub fn writeToFile(self: *const Tracer, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        var json = std.ArrayList(u8){};
        defer json.deinit(self.allocator);

        const writer = json.writer(self.allocator);

        try writer.writeAll("[\n");

        for (self.entries.items, 0..) |entry, i| {
            if (i > 0) try writer.writeAll(",\n");
            try writer.writeAll("  {\n");
            try writer.print("    \"pc\": {d},\n", .{entry.pc});
            try writer.print("    \"op\": {d},\n", .{entry.op});
            try writer.print("    \"gas\": \"0x{x}\",\n", .{entry.gas});
            try writer.print("    \"gasCost\": \"0x{x}\",\n", .{entry.gasCost});

            if (entry.memory) |mem| {
                try writer.writeAll("    \"memory\": \"0x");
                for (mem) |b| {
                    try writer.print("{x:0>2}", .{b});
                }
                try writer.writeAll("\",\n");
            } else {
                try writer.writeAll("    \"memory\": null,\n");
            }

            try writer.print("    \"memSize\": {d},\n", .{entry.memSize});
            try writer.writeAll("    \"stack\": [");
            for (entry.stack, 0..) |val, j| {
                if (j > 0) try writer.writeAll(", ");
                try writer.print("\"0x{x}\"", .{val});
            }
            try writer.writeAll("],\n");

            if (entry.returnData) |data| {
                try writer.writeAll("    \"returnData\": \"0x");
                for (data) |b| {
                    try writer.print("{x:0>2}", .{b});
                }
                try writer.writeAll("\",\n");
            } else {
                try writer.writeAll("    \"returnData\": null,\n");
            }

            try writer.print("    \"depth\": {d},\n", .{entry.depth});
            try writer.print("    \"refund\": {d},\n", .{entry.refund});
            try writer.print("    \"opName\": \"{s}\"\n", .{entry.opName});
            try writer.writeAll("  }");
        }

        try writer.writeAll("\n]\n");
        try file.writeAll(json.items);
    }
};

/// Compare two traces and find the first divergence
pub const TraceDiff = struct {
    divergence_index: ?usize,
    our_entry: ?TraceEntry,
    ref_entry: ?TraceEntry,
    diff_field: ?[]const u8,

    pub fn compare(allocator: std.mem.Allocator, our_trace: *const Tracer, ref_trace: *const Tracer) !TraceDiff {
        const min_len = @min(our_trace.entries.items.len, ref_trace.entries.items.len);

        for (0..min_len) |i| {
            const our = &our_trace.entries.items[i];
            const ref = &ref_trace.entries.items[i];

            if (our.pc != ref.pc) {
                return TraceDiff{
                    .divergence_index = i,
                    .our_entry = our.*,
                    .ref_entry = ref.*,
                    .diff_field = try allocator.dupe(u8, "pc"),
                };
            }

            if (our.op != ref.op) {
                return TraceDiff{
                    .divergence_index = i,
                    .our_entry = our.*,
                    .ref_entry = ref.*,
                    .diff_field = try allocator.dupe(u8, "op"),
                };
            }

            if (our.gas != ref.gas) {
                return TraceDiff{
                    .divergence_index = i,
                    .our_entry = our.*,
                    .ref_entry = ref.*,
                    .diff_field = try allocator.dupe(u8, "gas"),
                };
            }

            // Check stack
            if (our.stack.len != ref.stack.len) {
                return TraceDiff{
                    .divergence_index = i,
                    .our_entry = our.*,
                    .ref_entry = ref.*,
                    .diff_field = try allocator.dupe(u8, "stack_length"),
                };
            }

            for (our.stack, ref.stack) |our_val, ref_val| {
                if (our_val != ref_val) {
                    return TraceDiff{
                        .divergence_index = i,
                        .our_entry = our.*,
                        .ref_entry = ref.*,
                        .diff_field = try allocator.dupe(u8, "stack_value"),
                    };
                }
            }
        }

        // Check if one trace is longer
        if (our_trace.entries.items.len != ref_trace.entries.items.len) {
            return TraceDiff{
                .divergence_index = min_len,
                .our_entry = if (our_trace.entries.items.len > min_len) our_trace.entries.items[min_len] else null,
                .ref_entry = if (ref_trace.entries.items.len > min_len) ref_trace.entries.items[min_len] else null,
                .diff_field = try allocator.dupe(u8, "trace_length"),
            };
        }

        return TraceDiff{
            .divergence_index = null,
            .our_entry = null,
            .ref_entry = null,
            .diff_field = null,
        };
    }

    pub fn printDiff(self: *const TraceDiff, writer: anytype) !void {
        if (self.divergence_index == null) {
            try writer.print("✓ Traces match perfectly!\n", .{});
            return;
        }

        try writer.print("\n{s}⚠ Trace Divergence at step {d}{s}\n", .{
            "\x1b[33m", // Yellow
            self.divergence_index.?,
            "\x1b[0m", // Reset
        });

        if (self.diff_field) |field| {
            try writer.print("{s}Difference in: {s}{s}\n\n", .{
                "\x1b[1m", // Bold
                field,
                "\x1b[0m", // Reset
            });
        }

        if (self.our_entry) |our| {
            try writer.print("{s}Our EVM:{s}\n", .{ "\x1b[36m", "\x1b[0m" }); // Cyan
            try writer.print("  PC: 0x{x}  Op: 0x{x:0>2} ({s})  Gas: {d}\n", .{
                our.pc,
                our.op,
                our.opName,
                our.gas,
            });
            try writer.print("  Stack depth: {d}\n", .{our.stack.len});
        }

        if (self.ref_entry) |ref| {
            try writer.print("\n{s}Reference:{s}\n", .{ "\x1b[35m", "\x1b[0m" }); // Magenta
            try writer.print("  PC: 0x{x}  Op: 0x{x:0>2} ({s})  Gas: {d}\n", .{
                ref.pc,
                ref.op,
                ref.opName,
                ref.gas,
            });
            try writer.print("  Stack depth: {d}\n", .{ref.stack.len});
        }
    }
};
