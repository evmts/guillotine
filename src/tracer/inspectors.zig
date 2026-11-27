//! Zero-cost comptime execution inspectors (`CallTracer`, `LogCollector`).
//!
//! Configured via `EvmConfig.InspectorType`. When `InspectorType == void` (the
//! default), Guillotine adds zero bytes to `Evm` and emits zero hook instructions.
//! When enabled, `Evm.setInspector(&tracer)` attaches a concrete inspector for
//! structured call trees (`debug_traceTransaction` `callTracer` format) and event
//! analytics without serializing per-opcode `structLogs`.

const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address;

pub const CallKind = enum(u8) {
    CALL,
    CALLCODE,
    DELEGATECALL,
    STATICCALL,
    CREATE,
    CREATE2,

    pub fn name(self: CallKind) []const u8 {
        return @tagName(self);
    }
};

pub const CallRecord = struct {
    depth: u16,
    parent_index: ?usize,
    kind: CallKind,
    from: Address,
    to: ?Address,
    value: u256,
    gas: u64,
    gas_used: u64,
    input: []const u8,
    output: []const u8,
    success: bool,
    created_address: ?Address,
    log_count: u32,
};

/// Records the full nested call tree of a transaction (`callTracer`-compatible).
pub const CallTracer = struct {
    allocator: std.mem.Allocator,
    calls: std.ArrayList(CallRecord) = .empty,
    active_stack: std.ArrayList(usize) = .empty,
    oom: bool = false,

    pub fn init(allocator: std.mem.Allocator) CallTracer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CallTracer) void {
        self.clear();
        self.calls.deinit(self.allocator);
        self.active_stack.deinit(self.allocator);
    }

    pub fn clear(self: *CallTracer) void {
        for (self.calls.items) |rec| {
            if (rec.input.len > 0) self.allocator.free(rec.input);
            if (rec.output.len > 0) self.allocator.free(rec.output);
        }
        self.calls.clearRetainingCapacity();
        self.active_stack.clearRetainingCapacity();
        self.oom = false;
    }

    pub fn onCallEnter(self: *CallTracer, depth: u11, params: anytype) void {
        const info = extractParams(params);
        const input_copy = if (info.input.len > 0)
            self.allocator.dupe(u8, info.input) catch {
                self.oom = true;
                return;
            }
        else
            &[_]u8{};

        const parent: ?usize = if (self.active_stack.items.len > 0)
            self.active_stack.items[self.active_stack.items.len - 1]
        else
            null;
        const idx = self.calls.items.len;
        self.calls.append(self.allocator, .{
            .depth = depth,
            .parent_index = parent,
            .kind = info.kind,
            .from = info.from,
            .to = info.to,
            .value = info.value,
            .gas = info.gas,
            .gas_used = 0,
            .input = input_copy,
            .output = &[_]u8{},
            .success = false,
            .created_address = null,
            .log_count = 0,
        }) catch {
            if (input_copy.len > 0) self.allocator.free(input_copy);
            self.oom = true;
            return;
        };
        self.active_stack.append(self.allocator, idx) catch {
            self.oom = true;
        };
    }

    pub fn onCallExit(self: *CallTracer, _: u11, _: anytype, result: anytype) void {
        if (self.active_stack.items.len == 0) return;
        const idx = self.active_stack.pop() orelse return;
        const rec = &self.calls.items[idx];
        rec.success = result.success;
        rec.gas_used = rec.gas -| result.gas_left;
        rec.created_address = result.created_address;
        if (result.output.len > 0) {
            rec.output = self.allocator.dupe(u8, result.output) catch {
                self.oom = true;
                return;
            };
        }
    }

    pub fn onLog(self: *CallTracer, _: u11, _: Address, _: []const u256, _: []const u8) void {
        if (self.active_stack.items.len == 0) return;
        const idx = self.active_stack.items[self.active_stack.items.len - 1];
        self.calls.items[idx].log_count += 1;
    }

    /// Serialize recorded calls as a compact JSON array (Geth `callTracer`-style fields).
    pub fn toJson(self: *const CallTracer, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        try buf.append(allocator, '[');
        for (self.calls.items, 0..) |rec, idx| {
            if (idx > 0) try buf.append(allocator, ',');
            try appendRecordJson(allocator, &buf, rec);
        }
        try buf.append(allocator, ']');
        return buf.toOwnedSlice(allocator);
    }
};

fn appendHex(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), bytes: []const u8) !void {
    const hex = "0123456789abcdef";
    try buf.appendSlice(allocator, "\"0x");
    for (bytes) |b| {
        try buf.append(allocator, hex[b >> 4]);
        try buf.append(allocator, hex[b & 0x0f]);
    }
    try buf.append(allocator, '"');
}

fn appendRecordJson(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), rec: CallRecord) !void {
    try buf.appendSlice(allocator, "{\"type\":\"");
    try buf.appendSlice(allocator, rec.kind.name());
    try buf.appendSlice(allocator, "\",\"depth\":");
    try appendDecimal(allocator, buf, rec.depth);
    try buf.appendSlice(allocator, ",\"from\":");
    try appendHex(allocator, buf, &rec.from.bytes);
    if (rec.to) |to| {
        try buf.appendSlice(allocator, ",\"to\":");
        try appendHex(allocator, buf, &to.bytes);
    }
    if (rec.created_address) |created| {
        try buf.appendSlice(allocator, ",\"created\":");
        try appendHex(allocator, buf, &created.bytes);
    }
    try buf.appendSlice(allocator, ",\"gas\":");
    try appendDecimal(allocator, buf, rec.gas);
    try buf.appendSlice(allocator, ",\"gasUsed\":");
    try appendDecimal(allocator, buf, rec.gas_used);
    try buf.appendSlice(allocator, ",\"success\":");
    try buf.appendSlice(allocator, if (rec.success) "true" else "false");
    try buf.appendSlice(allocator, ",\"input\":");
    try appendHex(allocator, buf, rec.input);
    try buf.appendSlice(allocator, ",\"output\":");
    try appendHex(allocator, buf, rec.output);
    try buf.appendSlice(allocator, ",\"logs\":");
    try appendDecimal(allocator, buf, rec.log_count);
    try buf.append(allocator, '}');
}

fn appendDecimal(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: u64) !void {
    var tmp: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch return error.OutOfMemory;
    try buf.appendSlice(allocator, text);
}

fn extractParams(params: anytype) struct {
    kind: CallKind,
    from: Address,
    to: ?Address,
    value: u256,
    gas: u64,
    input: []const u8,
} {
    return switch (params) {
        .call => |p| .{
            .kind = .CALL,
            .from = p.caller,
            .to = p.to,
            .value = p.value,
            .gas = p.gas,
            .input = p.input,
        },
        .callcode => |p| .{
            .kind = .CALLCODE,
            .from = p.caller,
            .to = p.to,
            .value = p.value,
            .gas = p.gas,
            .input = p.input,
        },
        .delegatecall => |p| .{
            .kind = .DELEGATECALL,
            .from = p.caller,
            .to = p.to,
            .value = 0,
            .gas = p.gas,
            .input = p.input,
        },
        .staticcall => |p| .{
            .kind = .STATICCALL,
            .from = p.caller,
            .to = p.to,
            .value = 0,
            .gas = p.gas,
            .input = p.input,
        },
        .create => |p| .{
            .kind = .CREATE,
            .from = p.caller,
            .to = null,
            .value = p.value,
            .gas = p.gas,
            .input = p.init_code,
        },
        .create2 => |p| .{
            .kind = .CREATE2,
            .from = p.caller,
            .to = null,
            .value = p.value,
            .gas = p.gas,
            .input = p.init_code,
        },
    };
}

const testing = std.testing;

test "CallTracer tracks parent-child frames and serializes JSON" {
    var tracer = CallTracer.init(testing.allocator);
    defer tracer.deinit();

    const MockParams = union(enum) {
        call: struct { caller: Address, to: Address, value: u256, input: []const u8, gas: u64 },
        callcode: struct { caller: Address, to: Address, value: u256, input: []const u8, gas: u64 },
        delegatecall: struct { caller: Address, to: Address, input: []const u8, gas: u64 },
        staticcall: struct { caller: Address, to: Address, input: []const u8, gas: u64 },
        create: struct { caller: Address, value: u256, init_code: []const u8, gas: u64 },
        create2: struct { caller: Address, value: u256, init_code: []const u8, salt: u256, gas: u64 },
    };
    const MockResult = struct {
        success: bool,
        gas_left: u64,
        output: []const u8,
        created_address: ?Address = null,
    };

    const p0 = MockParams{ .call = .{
        .caller = Address.fromU256(1),
        .to = Address.fromU256(2),
        .value = 0,
        .input = &.{ 0xab, 0xcd },
        .gas = 50_000,
    } };
    const p1 = MockParams{ .staticcall = .{
        .caller = Address.fromU256(2),
        .to = Address.fromU256(3),
        .input = &.{},
        .gas = 10_000,
    } };

    tracer.onCallEnter(0, p0);
    tracer.onCallEnter(1, p1);
    tracer.onLog(1, Address.fromU256(3), &.{}, &.{});
    tracer.onCallExit(1, p1, MockResult{ .success = true, .gas_left = 7_500, .output = &.{0x2a} });
    tracer.onCallExit(0, p0, MockResult{ .success = true, .gas_left = 40_000, .output = &.{0x2a} });

    try testing.expect(!tracer.oom);
    try testing.expectEqual(@as(usize, 2), tracer.calls.items.len);
    try testing.expectEqual(@as(?usize, 0), tracer.calls.items[1].parent_index);
    try testing.expectEqual(@as(u64, 2_500), tracer.calls.items[1].gas_used);
    try testing.expectEqual(@as(u32, 1), tracer.calls.items[1].log_count);

    const json = try tracer.toJson(testing.allocator);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"type\":\"STATICCALL\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"output\":\"0x2a\"") != null);
}
