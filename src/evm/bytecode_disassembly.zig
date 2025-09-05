const std = @import("std");
const Opcode = @import("opcode.zig").Opcode;
const OpcodeSynthetic = @import("opcode_synthetic.zig").OpcodeSynthetic;
const OPCODE_INFO = @import("opcode_data.zig").OPCODE_INFO;

/// This module provides structured analysis of both original bytecode and optimized dispatch streams.
/// Designed for minimal code addition while maximizing reuse of existing infrastructure.
/// Main bytecode disassembly API
pub const BytecodeDisassembly = struct {
    /// Analysis result for a single bytecode instruction
    pub const Instruction = struct {
        /// Program counter location
        pc: u32,
        /// Raw opcode value (0x00-0xFF)
        opcode_hex: u8,
        /// Opcode name (e.g., "PUSH1", "ADD", "JUMPDEST")
        opcode_name: []const u8,
        /// Static gas cost from OPCODE_INFO
        gas_cost: u16,
        /// Push value if this is a PUSH instruction
        push_value: ?u256 = null,
        /// Stack consumed
        stack_inputs: u8,
        /// Stack produced
        stack_outputs: u8,
    };

    /// Basic block representing a segment of bytecode between control flow changes
    pub const BasicBlock = struct {
        start: u32,
        end: u32,
    };

    /// Complete disassembly result
    pub const Result = struct {
        /// Original bytecode analysis
        bytecode_instructions: []Instruction,
        /// Detected jump destinations
        jumpdests: []u32,
        /// Basic blocks (segments between jumpdests)
        basic_blocks: []BasicBlock,
        /// Statistics
        stats: Stats,

        pub const Stats = struct {
            original_size: usize,
            dispatch_size: usize,
            gas_first_block: u32,
            jumpdest_count: usize,
            basic_block_count: usize,
        };

        pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
            allocator.free(self.bytecode_instructions);
            allocator.free(self.jumpdests);
            allocator.free(self.basic_blocks);
        }
    };

    ///
    /// IMPLEMENTATION STRATEGY:
    /// 1. Reuse bytecode.zig's iterator infrastructure
    /// 2. Leverage dispatch.zig's schedule building
    /// 3. Extract metadata without pretty-printing overhead
    pub fn analyze(
        allocator: std.mem.Allocator,
        bytecode: anytype, // Accepts any bytecode type with createIterator()
        comptime FrameType: type,
    ) !Result {
        // PHASE 1: Bytecode Analysis
        // Reuses: bytecode.createIterator() from bytecode.zig:608
        // Reuses: OPCODE_INFO from opcode_data.zig for gas/stack info
        var instructions = std.ArrayList(Instruction){};
        defer instructions.deinit(allocator);
        
        var jumpdests_list = std.ArrayList(u32){};
        defer jumpdests_list.deinit(allocator);

        // Parse raw bytecode directly without fusion analysis
        const runtime_code = bytecode.runtime_code;
        var pc: u32 = 0;

        while (pc < runtime_code.len) {
            const opcode = runtime_code[pc];

            // Check if valid opcode
            if (std.meta.intToEnum(Opcode, opcode)) |op| {
                const info = OPCODE_INFO[opcode];

                // Handle PUSH instructions specially to extract value
                if (opcode >= 0x60 and opcode <= 0x7f) { // PUSH1 to PUSH32
                    const push_size = opcode - 0x60 + 1;
                    var push_value: u256 = 0;

                    // Extract push value from following bytes
                    const end_pc = @min(pc + 1 + push_size, @as(u32, @intCast(runtime_code.len)));
                    for (pc + 1..end_pc) |i| {
                        push_value = (push_value << 8) | runtime_code[i];
                    }

                    try instructions.append(allocator, .{
                        .pc = pc,
                        .opcode_hex = opcode,
                        .opcode_name = @tagName(op),
                        .gas_cost = info.gas_cost,
                        .push_value = push_value,
                        .stack_inputs = info.stack_inputs,
                        .stack_outputs = info.stack_outputs,
                    });

                    pc = end_pc;
                } else {
                    // Regular opcode
                    if (opcode == @intFromEnum(Opcode.JUMPDEST)) {
                        try jumpdests_list.append(allocator, pc);
                    }

                    try instructions.append(allocator, .{
                        .pc = pc,
                        .opcode_hex = opcode,
                        .opcode_name = @tagName(op),
                        .gas_cost = info.gas_cost,
                        .stack_inputs = info.stack_inputs,
                        .stack_outputs = info.stack_outputs,
                    });

                    pc += 1;
                }
            } else |_| {
                // Invalid opcode
                try instructions.append(allocator, .{
                    .pc = pc,
                    .opcode_hex = opcode,
                    .opcode_name = "INVALID",
                    .gas_cost = 0,
                    .stack_inputs = 0,
                    .stack_outputs = 0,
                });

                pc += 1;
            }
        }

        // PHASE 2: Build Dispatch Schedule
        // Build dispatch schedule to get its size
        const Dispatch = @import("dispatch.zig").Dispatch(FrameType);
        // Get opcode handlers for the frame type
        const frame_handlers = @import("frame_handlers.zig");
        const opcode_handlers = frame_handlers.getOpcodeHandlers(FrameType);
        const schedule = try Dispatch.init(allocator, bytecode, &opcode_handlers);
        defer allocator.free(schedule);

        // Calculate first block gas
        const first_block_gas = Dispatch.calculateFirstBlockGas(bytecode);

        // PHASE 3: Create basic blocks
        // Basic blocks are segments of code between jumpdests
        var blocks = std.ArrayList(BasicBlock){};
        defer blocks.deinit(allocator);

        const sorted_jumpdests = try jumpdests_list.toOwnedSlice(allocator);
        // No defer free - ownership transferred to Result

        // Sort jumpdests for block creation
        std.mem.sort(u32, sorted_jumpdests, {}, std.sort.asc(u32));

        var block_start: u32 = 0;
        for (sorted_jumpdests) |jd| {
            if (jd > block_start) {
                try blocks.append(allocator, .{ .start = block_start, .end = jd });
                block_start = jd;
            }
        }
        // Add final block from last jumpdest to end of bytecode
        if (block_start < runtime_code.len) {
            try blocks.append(allocator, .{ .start = block_start, .end = @intCast(runtime_code.len) });
        }

        // PHASE 4: Return structured result
        return Result{
            .bytecode_instructions = try instructions.toOwnedSlice(allocator),
            .jumpdests = sorted_jumpdests,
            .basic_blocks = try blocks.toOwnedSlice(allocator),
            .stats = .{
                .original_size = bytecode.runtime_code.len,
                .dispatch_size = schedule.len,
                .gas_first_block = @intCast(first_block_gas),
                .jumpdest_count = sorted_jumpdests.len,
                .basic_block_count = blocks.items.len,
            },
        };
    }
};

const testing = std.testing;

// Test configuration - use a real Frame to satisfy handlers
const test_config = @import("frame_config.zig").FrameConfig{
    .stack_size = 1024,
    .WordType = u256,
    .max_bytecode_size = 24576,  // Use standard size to get u16 PcType
    .block_gas_limit = 30_000_000,
    .DatabaseType = @import("database.zig").Database,  // Required field - use the Database type
    .TracerType = null,     // No tracing needed
    .memory_initial_capacity = 4096,
    .memory_limit = 0xFFFFFF,
};

// Use real Frame type
const TestFrame = @import("frame.zig").Frame(test_config);

test "bytecode disassembly - empty bytecode" {
    const allocator = testing.allocator;

    // Create empty bytecode
    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &.{}) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode, TestFrame);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), result.bytecode_instructions.len);
    try testing.expectEqual(@as(usize, 0), result.jumpdests.len);
    try testing.expectEqual(@as(usize, 0), result.basic_blocks.len);
    try testing.expectEqual(@as(usize, 0), result.stats.original_size);
    try testing.expectEqual(@as(u32, 0), result.stats.gas_first_block);
}

test "bytecode disassembly - single ADD instruction" {
    const allocator = testing.allocator;

    const code = [_]u8{@intFromEnum(Opcode.ADD)};

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode, TestFrame);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.bytecode_instructions.len);
    try testing.expectEqual(@as(u32, 0), result.bytecode_instructions[0].pc);
    try testing.expectEqual(@as(u8, @intFromEnum(Opcode.ADD)), result.bytecode_instructions[0].opcode_hex);
    try testing.expectEqualStrings("ADD", result.bytecode_instructions[0].opcode_name);
    try testing.expectEqual(@as(u16, 3), result.bytecode_instructions[0].gas_cost);
    try testing.expectEqual(@as(u8, 2), result.bytecode_instructions[0].stack_inputs);
    try testing.expectEqual(@as(u8, 1), result.bytecode_instructions[0].stack_outputs);

    // Should have one basic block covering entire bytecode
    try testing.expectEqual(@as(usize, 1), result.basic_blocks.len);
    try testing.expectEqual(@as(u32, 0), result.basic_blocks[0].start);
    try testing.expectEqual(@as(u32, 1), result.basic_blocks[0].end);
}

test "bytecode disassembly - PUSH1 with value" {
    const allocator = testing.allocator;

    const code = [_]u8{ @intFromEnum(Opcode.PUSH1), 0x42 };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode, TestFrame);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.bytecode_instructions.len);
    try testing.expectEqual(@as(u32, 0), result.bytecode_instructions[0].pc);
    try testing.expectEqual(@as(u8, @intFromEnum(Opcode.PUSH1)), result.bytecode_instructions[0].opcode_hex);
    try testing.expectEqualStrings("PUSH1", result.bytecode_instructions[0].opcode_name);
    try testing.expectEqual(@as(?u256, 0x42), result.bytecode_instructions[0].push_value);
}

test "bytecode disassembly - multiple PUSH sizes" {
    const allocator = testing.allocator;

    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0xFF,
        @intFromEnum(Opcode.PUSH2), 0x12,
        0x34,                       @intFromEnum(Opcode.PUSH4),
        0xAB,                       0xCD,
        0xEF,                       0x01,
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode, TestFrame);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), result.bytecode_instructions.len);

    // PUSH1
    try testing.expectEqual(@as(u32, 0), result.bytecode_instructions[0].pc);
    try testing.expectEqual(@as(?u256, 0xFF), result.bytecode_instructions[0].push_value);

    // PUSH2
    try testing.expectEqual(@as(u32, 2), result.bytecode_instructions[1].pc);
    try testing.expectEqual(@as(?u256, 0x1234), result.bytecode_instructions[1].push_value);

    // PUSH4
    try testing.expectEqual(@as(u32, 5), result.bytecode_instructions[2].pc);
    try testing.expectEqual(@as(?u256, 0xABCDEF01), result.bytecode_instructions[2].push_value);
}

test "bytecode disassembly - JUMPDEST creates blocks" {
    const allocator = testing.allocator;

    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x04,
        @intFromEnum(Opcode.JUMP),
        @intFromEnum(Opcode.JUMPDEST), // PC = 3
        @intFromEnum(Opcode.PUSH1),
        0x08,
        @intFromEnum(Opcode.JUMPDEST), // PC = 6
        @intFromEnum(Opcode.STOP),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode, TestFrame);
    defer result.deinit(allocator);

    // Check jumpdests detected
    try testing.expectEqual(@as(usize, 2), result.jumpdests.len);
    try testing.expectEqual(@as(u32, 3), result.jumpdests[0]);
    try testing.expectEqual(@as(u32, 6), result.jumpdests[1]);

    // Check basic blocks created
    try testing.expectEqual(@as(usize, 3), result.basic_blocks.len);

    // Block 0: PC 0-3
    try testing.expectEqual(@as(u32, 0), result.basic_blocks[0].start);
    try testing.expectEqual(@as(u32, 3), result.basic_blocks[0].end);

    // Block 1: PC 3-6
    try testing.expectEqual(@as(u32, 3), result.basic_blocks[1].start);
    try testing.expectEqual(@as(u32, 6), result.basic_blocks[1].end);

    // Block 2: PC 6-8
    try testing.expectEqual(@as(u32, 6), result.basic_blocks[2].start);
    try testing.expectEqual(@as(u32, 8), result.basic_blocks[2].end);
}

test "bytecode disassembly - invalid opcode handling" {
    const allocator = testing.allocator;

    const code = [_]u8{0xEF}; // Invalid opcode

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode, TestFrame);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.bytecode_instructions.len);
    try testing.expectEqual(@as(u8, 0xEF), result.bytecode_instructions[0].opcode_hex);
    try testing.expectEqualStrings("INVALID", result.bytecode_instructions[0].opcode_name);
    try testing.expectEqual(@as(u16, 0), result.bytecode_instructions[0].gas_cost);
}

test "bytecode disassembly - truncated PUSH instruction" {
    const allocator = testing.allocator;

    // PUSH2 with only 1 byte of data (truncated)
    const code = [_]u8{ @intFromEnum(Opcode.PUSH2), 0xAB };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode, TestFrame);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.bytecode_instructions.len);
    try testing.expectEqual(@as(u32, 0), result.bytecode_instructions[0].pc);
    try testing.expectEqual(@as(?u256, 0xAB00), result.bytecode_instructions[0].push_value); // Should be padded
}

test "bytecode disassembly - first block gas calculation" {
    const allocator = testing.allocator;

    // PUSH1 (3 gas) + PUSH1 (3 gas) + ADD (3 gas) = 9 gas
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x05,
        @intFromEnum(Opcode.PUSH1), 0x03,
        @intFromEnum(Opcode.ADD),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode, TestFrame);
    defer result.deinit(allocator);

    // First block should have 9 gas total
    try testing.expectEqual(@as(u32, 9), result.stats.gas_first_block);
}

test "bytecode disassembly - complex control flow" {
    const allocator = testing.allocator;

    const code = [_]u8{
        // Block 0
        @intFromEnum(Opcode.PUSH1),    0x0A,
        @intFromEnum(Opcode.PUSH1),    0x05,
        @intFromEnum(Opcode.GT),       @intFromEnum(Opcode.PUSH1),
        0x0C,                          @intFromEnum(Opcode.JUMPI),
        // Block 1 - JUMPDEST at PC 8
        @intFromEnum(Opcode.JUMPDEST), @intFromEnum(Opcode.PUSH1),
        0x01,                          @intFromEnum(Opcode.RETURN),
        // Block 2 - JUMPDEST at PC 12 (0x0C)
        @intFromEnum(Opcode.JUMPDEST), @intFromEnum(Opcode.PUSH1),
        0x00,                          @intFromEnum(Opcode.RETURN),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode, TestFrame);
    defer result.deinit(allocator);

    // Should have 2 jumpdests
    try testing.expectEqual(@as(usize, 2), result.jumpdests.len);
    try testing.expectEqual(@as(u32, 8), result.jumpdests[0]);
    try testing.expectEqual(@as(u32, 12), result.jumpdests[1]);

    // Should have 3 basic blocks
    try testing.expectEqual(@as(usize, 3), result.basic_blocks.len);
}

test "bytecode disassembly - PUSH32 handling" {
    const allocator = testing.allocator;

    const code = [_]u8{@intFromEnum(Opcode.PUSH32)} ++
        [_]u8{0xFF} ** 32; // 32 bytes of 0xFF

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode, TestFrame);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.bytecode_instructions.len);
    try testing.expectEqual(@as(u32, 0), result.bytecode_instructions[0].pc);
    try testing.expectEqualStrings("PUSH32", result.bytecode_instructions[0].opcode_name);

    // Check the push value is max u256
    const expected_value = std.math.maxInt(u256);
    try testing.expectEqual(@as(?u256, expected_value), result.bytecode_instructions[0].push_value);
}

test "bytecode disassembly - dispatch size verification" {
    const allocator = testing.allocator;

    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1),  0x60,
        @intFromEnum(Opcode.PUSH1),  0x40,
        @intFromEnum(Opcode.MSTORE), @intFromEnum(Opcode.STOP),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode, TestFrame);
    defer result.deinit(allocator);

    // Dispatch should be created and have a size > 0
    try testing.expect(result.stats.dispatch_size > 0);
    // Dispatch size should be at least as large as instruction count (usually larger with metadata)
    try testing.expect(result.stats.dispatch_size >= result.bytecode_instructions.len);
}

test "bytecode disassembly - no jumpdests" {
    const allocator = testing.allocator;

    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x01,
        @intFromEnum(Opcode.PUSH1), 0x02,
        @intFromEnum(Opcode.ADD),   @intFromEnum(Opcode.STOP),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode, TestFrame);
    defer result.deinit(allocator);

    // No jumpdests
    try testing.expectEqual(@as(usize, 0), result.jumpdests.len);

    // Should have exactly 1 basic block covering entire bytecode
    try testing.expectEqual(@as(usize, 1), result.basic_blocks.len);
    try testing.expectEqual(@as(u32, 0), result.basic_blocks[0].start);
    try testing.expectEqual(@as(u32, 6), result.basic_blocks[0].end);
}
