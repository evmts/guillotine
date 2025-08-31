const std = @import("std");
const Opcode = @import("opcode_data.zig").Opcode;
const OpcodeSynthetic = @import("opcode_synthetic.zig").OpcodeSynthetic;
const ArrayList = std.ArrayListAligned;

/// PC mapping entry for tracing
pub fn PCMapEntry(comptime FrameType: type) type {
    return struct {
        dispatch_index: usize,
        pc: FrameType.PcType,
        opcode: u8,
        is_synthetic: bool,
    };
}

/// Build a mapping from dispatch indices to PC values and opcodes for tracing
pub fn buildPCMapping(
    comptime FrameType: type,
    comptime DispatchType: type,
    allocator: std.mem.Allocator,
    schedule: []const DispatchType.Item,
    bytecode: anytype,
) ![]PCMapEntry(FrameType) {
    const Self = DispatchType;
    const PCMapEntryType = PCMapEntry(FrameType);
    const PCMapList = ArrayList(PCMapEntryType, null);
    var pc_map = PCMapList{};
    errdefer pc_map.deinit(allocator);

    // Create iterator to traverse bytecode
    var iter = bytecode.createIterator();
    var dispatch_index: usize = 0;

    // Skip first_block_gas if present
    // First_block_gas is only added if calculateFirstBlockGas(bytecode) > 0
    const first_block_gas = Self.calculateFirstBlockGas(bytecode);
    if (first_block_gas > 0 and schedule.len > 0) {
        dispatch_index = 1;
    }

    while (true) {
        const instr_pc = iter.pc;
        const maybe = iter.next();
        if (maybe == null) break;
        const op_data = maybe.?;

        switch (op_data) {
            .regular => |data| {
                // Map this regular opcode to its dispatch index
                try pc_map.append(allocator, .{
                    .dispatch_index = dispatch_index,
                    .pc = @intCast(instr_pc),
                    .opcode = data.opcode,
                    .is_synthetic = false,
                });
                dispatch_index += 1;

                // PC, CODESIZE, CODECOPY opcodes have additional dispatch items
                if (data.opcode == @intFromEnum(Opcode.PC) or
                    data.opcode == @intFromEnum(Opcode.CODESIZE) or
                    data.opcode == @intFromEnum(Opcode.CODECOPY))
                {
                    dispatch_index += 1; // Account for metadata
                }
            },
            .push => |data| {
                const push_opcode = 0x60 + data.size - 1;
                try pc_map.append(allocator, .{
                    .dispatch_index = dispatch_index,
                    .pc = @intCast(instr_pc),
                    .opcode = push_opcode,
                    .is_synthetic = false,
                });
                dispatch_index += 1;

                // PUSH operations have additional value item
                dispatch_index += 1;
            },
            .jumpdest => |data| {
                _ = data;
                try pc_map.append(allocator, .{
                    .dispatch_index = dispatch_index,
                    .pc = @intCast(instr_pc),
                    .opcode = @intFromEnum(Opcode.JUMPDEST),
                    .is_synthetic = false,
                });
                dispatch_index += 1;

                // JUMPDEST has additional metadata
                dispatch_index += 1;
            },
            // Handle fusion operations
            .push_add_fusion, .push_mul_fusion, .push_sub_fusion, .push_div_fusion, .push_and_fusion, .push_or_fusion, .push_xor_fusion, .push_jump_fusion, .push_jumpi_fusion => |data| {
                _ = data;
                const synthetic_opcode: u8 = switch (op_data) {
                    .push_add_fusion => @intFromEnum(OpcodeSynthetic.PUSH_ADD_INLINE),
                    .push_mul_fusion => @intFromEnum(OpcodeSynthetic.PUSH_MUL_INLINE),
                    .push_sub_fusion => @intFromEnum(OpcodeSynthetic.PUSH_SUB_INLINE),
                    .push_div_fusion => @intFromEnum(OpcodeSynthetic.PUSH_DIV_INLINE),
                    .push_and_fusion => @intFromEnum(OpcodeSynthetic.PUSH_AND_INLINE),
                    .push_or_fusion => @intFromEnum(OpcodeSynthetic.PUSH_OR_INLINE),
                    .push_xor_fusion => @intFromEnum(OpcodeSynthetic.PUSH_XOR_INLINE),
                    .push_jump_fusion => @intFromEnum(OpcodeSynthetic.PUSH_JUMP_INLINE),
                    .push_jumpi_fusion => @intFromEnum(OpcodeSynthetic.PUSH_JUMPI_INLINE),
                    else => unreachable,
                };

                try pc_map.append(allocator, .{
                    .dispatch_index = dispatch_index,
                    .pc = @intCast(instr_pc),
                    .opcode = synthetic_opcode,
                    .is_synthetic = true,
                });
                dispatch_index += 1;

                // Fusion ops may have additional value item
                dispatch_index += 1;
            },
            .stop => {
                try pc_map.append(allocator, .{
                    .dispatch_index = dispatch_index,
                    .pc = @intCast(instr_pc),
                    .opcode = @intFromEnum(Opcode.STOP),
                    .is_synthetic = false,
                });
                dispatch_index += 1;
            },
            .invalid => {
                try pc_map.append(allocator, .{
                    .dispatch_index = dispatch_index,
                    .pc = @intCast(instr_pc),
                    .opcode = @intFromEnum(Opcode.INVALID),
                    .is_synthetic = false,
                });
                dispatch_index += 1;
            },
        }
    }

    return pc_map.toOwnedSlice(allocator);
}

// ============================
// Tests
// ============================

const testing = std.testing;

// Mock types for testing
const TestFrame = struct {
    pub const PcType = u32;
};

const TestItem = struct {
    value: u64,
};

const TestDispatch = struct {
    cursor: [*]const TestItem,
    
    pub const Item = TestItem;
    
    pub fn calculateFirstBlockGas(bytecode: anytype) u64 {
        _ = bytecode;
        return 0; // No first block gas for testing
    }
};

// Mock bytecode for testing
const MockBytecode = struct {
    data: []const u8,
    
    pub const Iterator = struct {
        pc: u32,
        index: usize,
        data: []const u8,
        
        pub const OpData = union(enum) {
            regular: struct { opcode: u8 },
            push: struct { size: u8, value: u256 },
            jumpdest: struct { gas_cost: u32 },
            stop,
            invalid,
            push_add_fusion: struct { value: u64 },
            push_mul_fusion: struct { value: u64 },
            push_sub_fusion: struct { value: u64 },
            push_div_fusion: struct { value: u64 },
            push_and_fusion: struct { value: u64 },
            push_or_fusion: struct { value: u64 },
            push_xor_fusion: struct { value: u64 },
            push_jump_fusion: struct { value: u64 },
            push_jumpi_fusion: struct { value: u64 },
        };
        
        pub fn next(self: *@This()) ?OpData {
            if (self.index >= self.data.len) return null;
            
            const opcode = self.data[self.index];
            self.index += 1;
            
            return switch (opcode) {
                0x00 => OpData{ .stop = {} },
                0x5b => OpData{ .jumpdest = .{ .gas_cost = 1 } },
                0x60...0x7f => |op| OpData{ .push = .{ .size = op - 0x5f, .value = 0 } },
                0x58 => OpData{ .regular = .{ .opcode = @intFromEnum(Opcode.PC) } },
                0x38 => OpData{ .regular = .{ .opcode = @intFromEnum(Opcode.CODESIZE) } },
                0x39 => OpData{ .regular = .{ .opcode = @intFromEnum(Opcode.CODECOPY) } },
                0xfe => OpData{ .invalid = {} },
                else => OpData{ .regular = .{ .opcode = opcode } },
            };
        }
    };
    
    pub fn createIterator(self: @This()) Iterator {
        return .{ .pc = 0, .index = 0, .data = self.data };
    }
};

test "PCMapEntry structure" {
    const Entry = PCMapEntry(TestFrame);
    
    const entry = Entry{
        .dispatch_index = 10,
        .pc = 100,
        .opcode = 0x60,
        .is_synthetic = false,
    };
    
    try testing.expectEqual(@as(usize, 10), entry.dispatch_index);
    try testing.expectEqual(@as(u32, 100), entry.pc);
    try testing.expectEqual(@as(u8, 0x60), entry.opcode);
    try testing.expectEqual(false, entry.is_synthetic);
}

test "buildPCMapping with regular opcodes" {
    const bytecode_data = [_]u8{ 0x01, 0x02, 0x03 }; // ADD, MUL, SUB
    const bytecode = MockBytecode{ .data = &bytecode_data };
    
    const schedule = [_]TestItem{
        .{ .value = 0 }, // ADD
        .{ .value = 1 }, // MUL
        .{ .value = 2 }, // SUB
    };
    
    const pc_map = try buildPCMapping(TestFrame, TestDispatch, testing.allocator, &schedule, bytecode);
    defer testing.allocator.free(pc_map);
    
    try testing.expectEqual(@as(usize, 3), pc_map.len);
    
    // First opcode
    try testing.expectEqual(@as(usize, 0), pc_map[0].dispatch_index);
    try testing.expectEqual(@as(u32, 0), pc_map[0].pc);
    try testing.expectEqual(@as(u8, 0x01), pc_map[0].opcode);
    try testing.expectEqual(false, pc_map[0].is_synthetic);
    
    // Second opcode
    try testing.expectEqual(@as(usize, 1), pc_map[1].dispatch_index);
    try testing.expectEqual(@as(u32, 1), pc_map[1].pc);
    try testing.expectEqual(@as(u8, 0x02), pc_map[1].opcode);
    
    // Third opcode
    try testing.expectEqual(@as(usize, 2), pc_map[2].dispatch_index);
    try testing.expectEqual(@as(u32, 2), pc_map[2].pc);
    try testing.expectEqual(@as(u8, 0x03), pc_map[2].opcode);
}

test "buildPCMapping with metadata opcodes" {
    const bytecode_data = [_]u8{ 0x58, 0x38, 0x39 }; // PC, CODESIZE, CODECOPY
    const bytecode = MockBytecode{ .data = &bytecode_data };
    
    const schedule = [_]TestItem{
        .{ .value = 0 }, // PC handler
        .{ .value = 1 }, // PC metadata
        .{ .value = 2 }, // CODESIZE handler
        .{ .value = 3 }, // CODESIZE metadata
        .{ .value = 4 }, // CODECOPY handler
        .{ .value = 5 }, // CODECOPY metadata
    };
    
    const pc_map = try buildPCMapping(TestFrame, TestDispatch, testing.allocator, &schedule, bytecode);
    defer testing.allocator.free(pc_map);
    
    try testing.expectEqual(@as(usize, 3), pc_map.len);
    
    // PC opcode (dispatch index 0, but next is at 2 due to metadata)
    try testing.expectEqual(@as(usize, 0), pc_map[0].dispatch_index);
    try testing.expectEqual(@intFromEnum(Opcode.PC), pc_map[0].opcode);
    
    // CODESIZE opcode (dispatch index 2, next at 4)
    try testing.expectEqual(@as(usize, 2), pc_map[1].dispatch_index);
    try testing.expectEqual(@intFromEnum(Opcode.CODESIZE), pc_map[1].opcode);
    
    // CODECOPY opcode (dispatch index 4, next at 6)
    try testing.expectEqual(@as(usize, 4), pc_map[2].dispatch_index);
    try testing.expectEqual(@intFromEnum(Opcode.CODECOPY), pc_map[2].opcode);
}

test "buildPCMapping with PUSH operations" {
    const bytecode_data = [_]u8{ 0x60, 0x61 }; // PUSH1, PUSH2
    const bytecode = MockBytecode{ .data = &bytecode_data };
    
    const schedule = [_]TestItem{
        .{ .value = 0 }, // PUSH1 handler
        .{ .value = 1 }, // PUSH1 value
        .{ .value = 2 }, // PUSH2 handler
        .{ .value = 3 }, // PUSH2 value
    };
    
    const pc_map = try buildPCMapping(TestFrame, TestDispatch, testing.allocator, &schedule, bytecode);
    defer testing.allocator.free(pc_map);
    
    try testing.expectEqual(@as(usize, 2), pc_map.len);
    
    // PUSH1
    try testing.expectEqual(@as(usize, 0), pc_map[0].dispatch_index);
    try testing.expectEqual(@as(u8, 0x60), pc_map[0].opcode);
    
    // PUSH2
    try testing.expectEqual(@as(usize, 2), pc_map[1].dispatch_index);
    try testing.expectEqual(@as(u8, 0x61), pc_map[1].opcode);
}

test "buildPCMapping with JUMPDEST" {
    const bytecode_data = [_]u8{ 0x5b, 0x01, 0x5b }; // JUMPDEST, ADD, JUMPDEST
    const bytecode = MockBytecode{ .data = &bytecode_data };
    
    const schedule = [_]TestItem{
        .{ .value = 0 }, // JUMPDEST handler
        .{ .value = 1 }, // JUMPDEST metadata
        .{ .value = 2 }, // ADD handler
        .{ .value = 3 }, // JUMPDEST handler
        .{ .value = 4 }, // JUMPDEST metadata
    };
    
    const pc_map = try buildPCMapping(TestFrame, TestDispatch, testing.allocator, &schedule, bytecode);
    defer testing.allocator.free(pc_map);
    
    try testing.expectEqual(@as(usize, 3), pc_map.len);
    
    // First JUMPDEST
    try testing.expectEqual(@as(usize, 0), pc_map[0].dispatch_index);
    try testing.expectEqual(@intFromEnum(Opcode.JUMPDEST), pc_map[0].opcode);
    
    // ADD
    try testing.expectEqual(@as(usize, 2), pc_map[1].dispatch_index);
    try testing.expectEqual(@as(u8, 0x01), pc_map[1].opcode);
    
    // Second JUMPDEST
    try testing.expectEqual(@as(usize, 3), pc_map[2].dispatch_index);
    try testing.expectEqual(@intFromEnum(Opcode.JUMPDEST), pc_map[2].opcode);
}

test "buildPCMapping with synthetic fusion opcodes" {
    // Mock bytecode that returns fusion operations
    const MockFusionBytecode = struct {
        pub const Iterator = struct {
            index: usize,
            pc: u32,
            
            pub fn next(self: *@This()) ?MockBytecode.Iterator.OpData {
                if (self.index >= 2) return null;
                
                const result = switch (self.index) {
                    0 => MockBytecode.Iterator.OpData{ .push_add_fusion = .{ .value = 100 } },
                    1 => MockBytecode.Iterator.OpData{ .push_mul_fusion = .{ .value = 200 } },
                    else => null,
                };
                
                self.index += 1;
                self.pc += 1;
                return result;
            }
        };
        
        pub fn createIterator(self: @This()) Iterator {
            _ = self;
            return .{ .index = 0, .pc = 0 };
        }
    };
    
    const bytecode = MockFusionBytecode{};
    
    const schedule = [_]TestItem{
        .{ .value = 0 }, // PUSH_ADD handler
        .{ .value = 1 }, // PUSH_ADD value
        .{ .value = 2 }, // PUSH_MUL handler
        .{ .value = 3 }, // PUSH_MUL value
    };
    
    const pc_map = try buildPCMapping(TestFrame, TestDispatch, testing.allocator, &schedule, bytecode);
    defer testing.allocator.free(pc_map);
    
    try testing.expectEqual(@as(usize, 2), pc_map.len);
    
    // PUSH_ADD fusion
    try testing.expectEqual(@as(usize, 0), pc_map[0].dispatch_index);
    try testing.expectEqual(@intFromEnum(OpcodeSynthetic.PUSH_ADD_INLINE), pc_map[0].opcode);
    try testing.expectEqual(true, pc_map[0].is_synthetic);
    
    // PUSH_MUL fusion
    try testing.expectEqual(@as(usize, 2), pc_map[1].dispatch_index);
    try testing.expectEqual(@intFromEnum(OpcodeSynthetic.PUSH_MUL_INLINE), pc_map[1].opcode);
    try testing.expectEqual(true, pc_map[1].is_synthetic);
}