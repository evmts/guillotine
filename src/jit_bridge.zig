//! Adapter for a per-EVM native-code cache and the frame's pooled buffers.
//! Call before interpretation, with tracing disabled and calldata owned
//! independently of the frame's active memory.

const std = @import("std");
const jit = @import("jit/root.zig");
const log = @import("log.zig");

pub const Outcome = enum {
    stop,
    return_ok,
    revert,
    out_of_gas,
    stack_underflow,
    stack_overflow,
    invalid_jump,
    invalid_opcode,
    out_of_bounds,
};

pub fn Bridge(comptime EvmType: type, comptime FrameType: type) type {
    return struct {
        cache: jit.JitCache,

        const Self = @This();
        const Stack = @FieldType(FrameType, "stack");
        const Memory = @FieldType(FrameType, "memory");
        const runtime: jit.RuntimeHelpers = blk: {
            var helpers = jit.default_helpers;
            helpers.memory_grow = &resizeMemory;
            helpers.memory_resize = &resizeMemory;
            helpers.memory_free = &releaseMemory;
            helpers.ret = &returnData;
            helpers.keccak256 = &keccak;
            break :blk helpers;
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            const fork = FrameType.config.hardfork;
            return .{ .cache = .{
                .allocator = allocator,
                .config = .{ .options = .{
                    .shifts = fork.isAtLeast(.CONSTANTINOPLE),
                    .revert = fork.isAtLeast(.BYZANTIUM),
                    .push0 = fork.isAtLeast(.SHANGHAI),
                    .mcopy = fork.isAtLeast(.CANCUN),
                    .clz = fork.isAtLeast(.OSAKA),
                    .replay_exceptional_halts = true,
                } },
            } };
        }

        pub fn deinit(self: *Self) void {
            self.cache.deinit();
        }

        /// Returns null with the original frame state on a cold or ineligible
        /// program, an unavailable backend, or an interpreter retry.
        /// Exceptional halts consume all gas at the EVM boundary. The two
        /// engines can choose different internal reasons or leave different
        /// partial state due to block gas charging and opcode fusion. The
        /// cached program requests interpreter replay on these exits.
        pub fn tryRun(self: *Self, evm: *EvmType, frame: *FrameType, code: []const u8, code_hash: [32]u8) ?Outcome {
            if (comptime !jit.compiler.native_supported or Stack.WordType != u256 or
                Stack.stack_capacity != jit.stack_capacity or FrameType.config.disable_gas_checks) return null;
            if (frame.memory.pool_allocator == null) return null;

            const program = self.cache.lookup(&code_hash, code) catch |err| {
                log.debug("Native compilation unavailable: {s}", .{@errorName(err)});
                return null;
            } orelse return null;
            return run(program, self.cache.allocator, evm, frame) catch |err| {
                log.debug("Native execution requested interpreter replay: {s}", .{@errorName(err)});
                return null;
            };
        }

        fn run(program: *const jit.Program, allocator: std.mem.Allocator, evm: *EvmType, frame: *FrameType) !Outcome {
            const memory = &frame.memory;
            const buffer = memory.buffer_ptr;
            const checkpoint: usize = memory.checkpoint;
            if (checkpoint > buffer.items.len or checkpoint > Memory.MEMORY_LIMIT) return error.InvalidContext;

            // At the normal frame entry both snapshots are empty, so skip heap
            // allocation entirely. Retain live state for other pooled callers.
            const stack = frame.stack.get_slice();
            const live_memory = buffer.items[checkpoint..];
            const saved_stack: []const u256 = if (stack.len > 0) try allocator.dupe(u256, stack) else &.{};
            defer if (saved_stack.len > 0) allocator.free(saved_stack);
            const saved_memory: []const u8 = if (live_memory.len > 0) try allocator.dupe(u8, live_memory) else &.{};
            defer if (saved_memory.len > 0) allocator.free(saved_memory);
            const saved_words = memory.cached_words;
            const saved_cost = memory.cached_cost;
            errdefer {
                if (saved_stack.len > 0) @memcpy(frame.stack.stack_ptr[0..saved_stack.len], saved_stack);
                buffer.items.len = checkpoint + saved_memory.len;
                if (saved_memory.len > 0) @memcpy(buffer.items[checkpoint..], saved_memory);
                memory.cached_words = saved_words;
                memory.cached_cost = saved_cost;
            }

            const words = saved_memory.len / 32;
            var ctx = jit.JitContext{
                .stack_ptr = frame.stack.stack_ptr,
                .stack_base = frame.stack.buf_ptr + jit.stack_capacity,
                .stack_limit = frame.stack.buf_ptr,
                .gas_remaining = frame.gas_remaining,
                .memory_ptr = if (buffer.capacity > checkpoint) buffer.items.ptr + checkpoint else null,
                .memory_len = saved_memory.len,
                .memory_cap = buffer.capacity - checkpoint,
                .memory_limit = @intCast(Memory.MEMORY_LIMIT - checkpoint),
                .memory_cost = if (words == saved_words) saved_cost else @intCast(jit.helpers.memoryCost(words)),
                .calldata_ptr = frame.calldata_slice.ptr,
                .calldata_len = frame.calldata_slice.len,
                .output_offset = 0,
                .output_len = 0,
                .exit_code = 0,
                .helpers = &runtime,
                .host_ctx = memory,
            };

            const outcome: Outcome = switch (try program.run(&ctx)) {
                .stop => .stop,
                .return_ok => .return_ok,
                .revert => .revert,
                .out_of_gas => .out_of_gas,
                .stack_underflow => .stack_underflow,
                .stack_overflow => .stack_overflow,
                .invalid_jump => .invalid_jump,
                .invalid_opcode => .invalid_opcode,
                .out_of_bounds => .out_of_bounds,
                .fallback => return error.InterpreterReplay,
            };
            if (outcome == .return_ok or outcome == .revert) {
                frame.output_data = if (ctx.output_len == 0) &.{} else blk: {
                    const data = try memory.get_slice(@intCast(ctx.output_offset), @intCast(ctx.output_len));
                    break :blk try evm.getCallArenaAllocator().dupe(u8, data);
                };
            }
            frame.stack.stack_ptr = ctx.stack_ptr;
            frame.gas_remaining = @intCast(ctx.gas_remaining);
            return outcome;
        }

        fn resizeMemory(ctx: *jit.JitContext, len: usize) callconv(.c) u32 {
            const memory: *Memory = @ptrCast(@alignCast(ctx.host_ctx.?));
            const allocator = memory.pool_allocator orelse return @intFromEnum(jit.ExitCode.fallback);
            // Memory owns zeroing, rounding, the allocation and the gas cache.
            // The JIT already charged the expansion delta before calling us.
            memory.ensure_capacity(allocator, @intCast(len)) catch |err| return switch (err) {
                error.MemoryOverflow, error.OutOfBounds => @intFromEnum(jit.ExitCode.out_of_bounds),
                error.OutOfMemory => @intFromEnum(jit.ExitCode.fallback),
            };
            const buffer = memory.buffer_ptr;
            ctx.memory_ptr = buffer.items.ptr + memory.checkpoint;
            ctx.memory_cap = buffer.capacity - memory.checkpoint;
            ctx.memory_len = memory.size();
            return 0;
        }

        fn releaseMemory(_: *jit.JitContext) callconv(.c) void {
            // The EVM pool owns the allocation for the lifetime of the EVM.
        }

        fn returnData(ctx: *jit.JitContext, revert: u32) callconv(.c) u32 {
            const offset = ctx.stack_ptr[0];
            const size = ctx.stack_ptr[1];
            const limit = std.math.maxInt(u24);
            if (offset > limit or size > limit or offset + size > limit) {
                return @intFromEnum(jit.ExitCode.out_of_bounds);
            }
            // The frame's RETURN/REVERT handlers expand to offset + size,
            // including when size is zero.
            if (size == 0) {
                const result = jit.helpers.expand(ctx, 0, offset);
                if (result != 0) return result;
            }
            return jit.helpers.ret(ctx, revert);
        }

        fn keccak(ctx: *jit.JitContext) callconv(.c) u32 {
            // The frame validates offset even for the empty-input fast path.
            if (ctx.stack_ptr[0] > std.math.maxInt(usize)) return @intFromEnum(jit.ExitCode.out_of_bounds);
            return jit.helpers.keccak256(ctx);
        }
    };
}

test "pooled JIT frame matches interpreter memory, gas, stack and detached output" {
    const allocator = std.testing.allocator;
    const Stack = @import("stack/stack.zig").Stack(.{ .stack_size = 1024, .WordType = u256 });
    const Memory = @import("memory/memory.zig").Memory(.{ .initial_capacity = 100, .memory_limit = 512 });
    const MockEvm = struct {
        arena: std.heap.ArenaAllocator,

        pub fn getCallArenaAllocator(self: *@This()) std.mem.Allocator {
            return self.arena.allocator();
        }
    };
    const MockFrame = struct {
        stack: Stack,
        memory: Memory,
        gas_remaining: i32 = 1_000,
        calldata_slice: []const u8 = "abc",
        output_data: []const u8 = &.{},

        pub const config = .{ .hardfork = TestHardfork.OSAKA, .disable_gas_checks = false };
    };

    var evm = MockEvm{ .arena = .init(allocator) };
    defer evm.arena.deinit();
    var bridge = Bridge(MockEvm, MockFrame).init(allocator);
    defer bridge.deinit();
    var native_stack: [1024]u256 align(64) = undefined;
    var ref_stack: [1024]u256 align(64) = undefined;
    var native_buffer: std.ArrayList(u8) = .empty;
    defer native_buffer.deinit(allocator);
    if (comptime !jit.compiler.native_supported) {
        var frame = MockFrame{
            .stack = Stack.initBorrowed(&native_stack, null),
            .memory = Memory.init_pooled(&native_buffer, allocator),
        };
        const hash = [_]u8{1} ** 32;
        try std.testing.expectEqual(null, bridge.tryRun(&evm, &frame, &.{0}, hash));
        try std.testing.expectEqual(null, bridge.tryRun(&evm, &frame, &.{0}, hash));
        try std.testing.expectEqual(@as(usize, 0), bridge.cache.len());
        return;
    }
    var ref_buffer: std.ArrayList(u8) = .empty;
    defer ref_buffer.deinit(allocator);
    try native_buffer.ensureTotalCapacityPrecise(allocator, 100);
    try ref_buffer.ensureTotalCapacityPrecise(allocator, 100);

    var code = [_]u8{
        0x60, 0x01, 0x35, // CALLDATALOAD, partial word
        0x60, 0x1f, 0x52, // MSTORE, grows within the reserved capacity
        0x59, // MSIZE
        0x60, 0x1f, 0x51, // MLOAD
        0x60, 0x03, 0x35, // CALLDATALOAD at the end
        0x60, 0x20, 0x60, 0x1f, 0x61, 0x01, 0x00, 0x5e, // MCOPY, reallocates
        0x59, // MSIZE
        0x60,
        0x02,
        0x61,
        0x01,
        0x00,
        0xf3,
    };
    for ([_]u8{ 0xf3, 0xfd }) |opcode| {
        var native = MockFrame{
            .stack = Stack.initBorrowed(&native_stack, null),
            .memory = Memory.init_pooled(&native_buffer, allocator),
        };
        var reference = MockFrame{
            .stack = Stack.initBorrowed(&ref_stack, null),
            .memory = Memory.init_pooled(&ref_buffer, allocator),
        };
        // A checkpoint hides the prefix from the active frame.
        try native_buffer.appendSlice(allocator, "old");
        try ref_buffer.appendSlice(allocator, "old");
        native.memory.checkpoint = 3;
        reference.memory.checkpoint = 3;
        native.stack.stack_ptr -= 1;
        native.stack.stack_ptr[0] = 0x99;
        try native.memory.ensure_capacity(allocator, 32);
        try reference.memory.ensure_capacity(allocator, 32);
        native.memory.set_byte_unchecked(12, 0x42);
        reference.memory.set_byte_unchecked(12, 0x42);

        const word = @as(u256, 0x6263) << 240;
        reference.gas_remaining -= 46; // Static gas for the bytecode above.
        reference.gas_remaining -= @intCast(reference.memory.get_expansion_cost(63));
        try reference.memory.ensure_capacity(allocator, 63);
        reference.memory.set_u256_unchecked(31, word);
        const first_size = reference.memory.size();
        const loaded = reference.memory.get_u256_unchecked(31);
        reference.gas_remaining -= 3 + @as(i32, @intCast(reference.memory.get_expansion_cost(288)));
        try reference.memory.ensure_capacity(allocator, 288);
        reference.memory.copy_within(256, 31, 32);
        reference.stack.stack_ptr -= 5;
        reference.stack.stack_ptr[0..5].* = .{ reference.memory.size(), 0, loaded, first_size, 0x99 };
        reference.output_data = try reference.memory.get_slice(256, 2);

        code[code.len - 1] = opcode;
        const hash = [_]u8{opcode} ** 32;
        try std.testing.expectEqual(null, bridge.tryRun(&evm, &native, &code, hash));
        const expected: Outcome = if (opcode == 0xf3) .return_ok else .revert;
        try std.testing.expectEqual(expected, bridge.tryRun(&evm, &native, &code, hash).?);
        try std.testing.expectEqual(reference.gas_remaining, native.gas_remaining);
        try std.testing.expectEqualSlices(u256, reference.stack.get_slice(), native.stack.get_slice());
        try std.testing.expectEqualSlices(u8, ref_buffer.items, native_buffer.items);
        try std.testing.expectEqual(reference.memory.cached_words, native.memory.cached_words);
        try std.testing.expectEqual(reference.memory.cached_cost, native.memory.cached_cost);
        native.memory.set_byte_unchecked(256, 0);
        try std.testing.expectEqualSlices(u8, reference.output_data, native.output_data);
    }

    var frame = MockFrame{
        .stack = Stack.initBorrowed(&native_stack, null),
        .memory = Memory.init_pooled(&native_buffer, allocator),
    };
    const empty_return = [_]u8{ 0x5f, 0x60, 33, 0xf3 };
    const empty_hash = [_]u8{1} ** 32;
    try std.testing.expectEqual(null, bridge.tryRun(&evm, &frame, &empty_return, empty_hash));
    try std.testing.expectEqual(Outcome.return_ok, bridge.tryRun(&evm, &frame, &empty_return, empty_hash).?);
    try std.testing.expectEqual(@as(usize, 64), frame.memory.size());
    try std.testing.expectEqual(@as(i32, 989), frame.gas_remaining);
    try std.testing.expectEqual(@as(usize, 0), frame.output_data.len);

    // Mutate the live stack and both overwrite and expand memory before a fault.
    frame.stack.stack_ptr -= 1;
    frame.stack.stack_ptr[0] = 7;
    frame.memory.set_byte_unchecked(0, 0x11);
    const fault = [_]u8{ 0x60, 2, 0x01, 0x60, 0xaa, 0x5f, 0x53, 0x60, 0xbb, 0x60, 80, 0x53, 0xfe };
    const fault_hash = [_]u8{2} ** 32;
    try std.testing.expectEqual(null, bridge.tryRun(&evm, &frame, &fault, fault_hash));
    try std.testing.expectEqual(null, bridge.tryRun(&evm, &frame, &fault, fault_hash));
    try std.testing.expectEqual(@as(usize, 4), bridge.cache.compiled_count);
    try std.testing.expectEqualSlices(u256, &.{7}, frame.stack.get_slice());
    try std.testing.expectEqual(@as(usize, 64), frame.memory.size());
    try std.testing.expectEqual(@as(u8, 0x11), native_buffer.items[0]);
    try std.testing.expectEqual(@as(usize, 2), frame.memory.cached_words);
    try std.testing.expectEqual(@as(u64, 6), frame.memory.cached_cost);
    try std.testing.expectEqual(@as(i32, 989), frame.gas_remaining);

    // A refused pool allocation must replay without publishing any state.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    const failing_allocator = failing.allocator();
    var empty_buffer: std.ArrayList(u8) = .empty;
    defer empty_buffer.deinit(failing_allocator);
    frame.memory = Memory.init_pooled(&empty_buffer, failing_allocator);
    try std.testing.expectEqual(null, bridge.tryRun(&evm, &frame, &empty_return, empty_hash));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqualSlices(u256, &.{7}, frame.stack.get_slice());
    try std.testing.expectEqual(@as(usize, 0), frame.memory.size());
    try std.testing.expectEqual(@as(u64, 0), frame.memory.cached_cost);
    try std.testing.expectEqual(@as(i32, 989), frame.gas_remaining);
}

const TestHardfork = enum {
    BYZANTIUM,
    CONSTANTINOPLE,
    SHANGHAI,
    CANCUN,
    OSAKA,

    fn isAtLeast(self: @This(), fork: @This()) bool {
        return @intFromEnum(self) >= @intFromEnum(fork);
    }
};

// Requires the EVM build modules. The pooled-frame test above also runs with
// plain zig test and a filter, without loading the EVM module graph.
test "EVM module graph: native bridge matches the real dispatch frame" {
    if (comptime !jit.compiler.native_supported) return;
    const allocator = std.testing.allocator;
    const Evm = @import("evm.zig").Evm(.{
        .enable_beacon_roots = false,
        .enable_historical_block_hashes = false,
        .enable_validator_deposits = false,
        .enable_validator_withdrawals = false,
    });
    const Address = @import("voltaire").Address;
    const BlockInfo = @import("block/block_info.zig").BlockInfo(.{});
    var db = @import("storage/database.zig").Database.init(allocator);
    defer db.deinit();
    var evm = try Evm.init(allocator, &db, BlockInfo.init(), .{
        .gas_limit = 30_000_000,
        .coinbase = Address.ZERO_ADDRESS,
        .chain_id = 1,
    }, 0, Address.ZERO_ADDRESS);
    defer evm.deinit();
    var bridge = Bridge(Evm, Evm.Frame).init(allocator);
    defer bridge.deinit();
    var native_stack: [1024]u256 align(64) = undefined;
    var ref_stack: [1024]u256 align(64) = undefined;
    var native_buffer: std.ArrayList(u8) = .empty;
    defer native_buffer.deinit(allocator);
    var ref_buffer: std.ArrayList(u8) = .empty;
    defer ref_buffer.deinit(allocator);

    const cases = [_]struct { code: []const u8, outcome: Outcome, termination: Evm.Frame.Error }{
        .{
            .code = &.{
                0x5f, 0x60, 0xff, 0x57, // False static JUMPI with an invalid target.
                0x5a, 0x5f, 0x35, // GAS and CALLDATALOAD.
                0x61, 0x10, 0x00, 0x52, // MSTORE across the quadratic gas threshold.
                0x59, 0x60, 0x20, 0x61,
                0x10, 0x00, 0xf3,
            },
            .outcome = .return_ok,
            .termination = error.Return,
        },
        .{ .code = &.{ 0x5f, 0x60, 33, 0xfd }, .outcome = .revert, .termination = error.REVERT },
        .{ .code = &.{ 0x5f, 0x5f, 0x20, 0x00 }, .outcome = .stop, .termination = error.Stop },
    };
    for (cases, 0..) |case, index| {
        var native = try Evm.Frame.initPooled(&native_stack, &native_buffer, allocator, 10_000, Address.ZERO_ADDRESS, 0, "abc", &evm);
        defer native.deinitPooled();
        var reference = try Evm.Frame.initPooled(&ref_stack, &ref_buffer, allocator, 10_000, Address.ZERO_ADDRESS, 0, "abc", &evm);
        defer reference.deinitPooled();
        var bytecode = try Evm.Bytecode.init(allocator, case.code);
        defer bytecode.deinit();
        var analysis = try Evm.Frame.Dispatch.DispatchSchedule.initWithJumpTable(allocator, bytecode, &Evm.Frame.opcode_handlers, null);
        defer analysis.jump_table.deinit(allocator);
        defer analysis.schedule.deinit();
        try std.testing.expectError(case.termination, reference.interpret(&analysis.schedule, &analysis.jump_table, case.code));
        const hash = [_]u8{@intCast(index)} ** 32;
        try std.testing.expectEqual(null, bridge.tryRun(&evm, &native, case.code, hash));
        try std.testing.expectEqual(case.outcome, bridge.tryRun(&evm, &native, case.code, hash).?);
        try std.testing.expectEqual(reference.gas_remaining, native.gas_remaining);
        try std.testing.expectEqualSlices(u256, reference.stack.get_slice(), native.stack.get_slice());
        try std.testing.expectEqualSlices(u8, ref_buffer.items, native_buffer.items);
        try std.testing.expectEqualSlices(u8, reference.output_data, native.output_data);
    }
}
