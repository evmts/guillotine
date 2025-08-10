const std = @import("std");
const primitives = @import("primitives");
const Stack = @import("evm").Stack;
const Memory = @import("evm").Memory;

/// Debug state capture for EVM execution steps
pub const DebugState = struct {
    pc: usize,
    opcode: u8,
    opcode_name: []const u8,
    gas_remaining: u64,
    depth: u32,
    is_static: bool,
    stack_size: usize,
    memory_size: usize,
    has_error: bool,
    error_name: ?[]const u8,

    pub fn capture(
        pc: usize,
        opcode: u8,
        gas_remaining: u64,
        depth: u32,
        is_static: bool,
        stack: *const Stack,
        memory: *const Memory,
        err: ?anyerror,
    ) DebugState {
        return DebugState{
            .pc = pc,
            .opcode = opcode,
            .opcode_name = opcodeToString(opcode),
            .gas_remaining = gas_remaining,
            .depth = depth,
            .is_static = is_static,
            .stack_size = stack.size,
            .memory_size = memory.size(),
            .has_error = err != null,
            .error_name = if (err) |e| @errorName(e) else null,
        };
    }
};

/// Storage entry for JSON serialization
pub const StorageEntry = struct {
    key: []const u8,
    value: []const u8,
};

/// Simple JSON-serializable state for the frontend
pub const EvmStateJson = struct {
    pc: usize,
    opcode: []const u8,
    gasLeft: u64,
    depth: u32,
    stack: [][]const u8,
    memory: []const u8,
    storage: []StorageEntry,
    logs: [][]const u8,
    returnData: []const u8,
};

/// Convert opcode byte to human-readable string
pub fn opcodeToString(opcode: u8) []const u8 {
    return switch (opcode) {
        0x00 => "STOP",
        0x01 => "ADD",
        0x02 => "MUL",
        0x03 => "SUB",
        0x04 => "DIV",
        0x05 => "SDIV",
        0x06 => "MOD",
        0x07 => "SMOD",
        0x08 => "ADDMOD",
        0x09 => "MULMOD",
        0x0a => "EXP",
        0x0b => "SIGNEXTEND",
        0x10 => "LT",
        0x11 => "GT",
        0x12 => "SLT",
        0x13 => "SGT",
        0x14 => "EQ",
        0x15 => "ISZERO",
        0x16 => "AND",
        0x17 => "OR",
        0x18 => "XOR",
        0x19 => "NOT",
        0x1a => "BYTE",
        0x1b => "SHL",
        0x1c => "SHR",
        0x1d => "SAR",
        0x20 => "KECCAK256",
        0x30 => "ADDRESS",
        0x31 => "BALANCE",
        0x32 => "ORIGIN",
        0x33 => "CALLER",
        0x34 => "CALLVALUE",
        0x35 => "CALLDATALOAD",
        0x36 => "CALLDATASIZE",
        0x37 => "CALLDATACOPY",
        0x38 => "CODESIZE",
        0x39 => "CODECOPY",
        0x3a => "GASPRICE",
        0x3b => "EXTCODESIZE",
        0x3c => "EXTCODECOPY",
        0x3d => "RETURNDATASIZE",
        0x3e => "RETURNDATACOPY",
        0x3f => "EXTCODEHASH",
        0x40 => "BLOCKHASH",
        0x41 => "COINBASE",
        0x42 => "TIMESTAMP",
        0x43 => "NUMBER",
        0x44 => "PREVRANDAO",
        0x45 => "GASLIMIT",
        0x46 => "CHAINID",
        0x47 => "SELFBALANCE",
        0x48 => "BASEFEE",
        0x50 => "POP",
        0x51 => "MLOAD",
        0x52 => "MSTORE",
        0x53 => "MSTORE8",
        0x54 => "SLOAD",
        0x55 => "SSTORE",
        0x56 => "JUMP",
        0x57 => "JUMPI",
        0x58 => "PC",
        0x59 => "MSIZE",
        0x5a => "GAS",
        0x5b => "JUMPDEST",
        0x5f => "PUSH0",
        0x60 => "PUSH1",
        0x61 => "PUSH2",
        0x62 => "PUSH3",
        0x63 => "PUSH4",
        0x64 => "PUSH5",
        0x65 => "PUSH6",
        0x66 => "PUSH7",
        0x67 => "PUSH8",
        0x68 => "PUSH9",
        0x69 => "PUSH10",
        0x6a => "PUSH11",
        0x6b => "PUSH12",
        0x6c => "PUSH13",
        0x6d => "PUSH14",
        0x6e => "PUSH15",
        0x6f => "PUSH16",
        0x70 => "PUSH17",
        0x71 => "PUSH18",
        0x72 => "PUSH19",
        0x73 => "PUSH20",
        0x74 => "PUSH21",
        0x75 => "PUSH22",
        0x76 => "PUSH23",
        0x77 => "PUSH24",
        0x78 => "PUSH25",
        0x79 => "PUSH26",
        0x7a => "PUSH27",
        0x7b => "PUSH28",
        0x7c => "PUSH29",
        0x7d => "PUSH30",
        0x7e => "PUSH31",
        0x7f => "PUSH32",
        0x80 => "DUP1",
        0x81 => "DUP2",
        0x82 => "DUP3",
        0x83 => "DUP4",
        0x84 => "DUP5",
        0x85 => "DUP6",
        0x86 => "DUP7",
        0x87 => "DUP8",
        0x88 => "DUP9",
        0x89 => "DUP10",
        0x8a => "DUP11",
        0x8b => "DUP12",
        0x8c => "DUP13",
        0x8d => "DUP14",
        0x8e => "DUP15",
        0x8f => "DUP16",
        0x90 => "SWAP1",
        0x91 => "SWAP2",
        0x92 => "SWAP3",
        0x93 => "SWAP4",
        0x94 => "SWAP5",
        0x95 => "SWAP6",
        0x96 => "SWAP7",
        0x97 => "SWAP8",
        0x98 => "SWAP9",
        0x99 => "SWAP10",
        0x9a => "SWAP11",
        0x9b => "SWAP12",
        0x9c => "SWAP13",
        0x9d => "SWAP14",
        0x9e => "SWAP15",
        0x9f => "SWAP16",
        0xa0 => "LOG0",
        0xa1 => "LOG1",
        0xa2 => "LOG2",
        0xa3 => "LOG3",
        0xa4 => "LOG4",
        0xf0 => "CREATE",
        0xf1 => "CALL",
        0xf2 => "CALLCODE",
        0xf3 => "RETURN",
        0xf4 => "DELEGATECALL",
        0xf5 => "CREATE2",
        0xfa => "STATICCALL",
        0xfd => "REVERT",
        0xfe => "INVALID",
        0xff => "SELFDESTRUCT",
        else => "UNKNOWN",
    };
}

/// Format a u256 value as hex string
pub fn formatU256Hex(allocator: std.mem.Allocator, value: u256) ![]u8 {
    return try std.fmt.allocPrint(allocator, "0x{x}", .{value});
}

/// Format bytes as hex string
pub fn formatBytesHex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (bytes.len == 0) return try allocator.dupe(u8, "0x");
    return try std.fmt.allocPrint(allocator, "0x{}", .{std.fmt.fmtSliceHexLower(bytes)});
}

/// Serialize stack contents to hex string array
pub fn serializeStack(allocator: std.mem.Allocator, stack: *const Stack) ![][]const u8 {
    var stack_array = std.ArrayList([]const u8).init(allocator);
    defer stack_array.deinit();

    // Get stack items (top to bottom for debugging visibility)
    var i: usize = 0;
    while (i < stack.size) {
        const idx = i; // peek_n(0) is top, peek_n(1) is second from top, etc.
        const value = stack.peek_n(idx) catch break;
        const hex_str = try formatU256Hex(allocator, value);
        try stack_array.append(hex_str);
        i += 1;
    }

    return try stack_array.toOwnedSlice();
}

/// Serialize memory contents to hex string
pub fn serializeMemory(allocator: std.mem.Allocator, memory: *const Memory) ![]u8 {
    const memory_size = memory.size();
    if (memory_size == 0) {
        return try allocator.dupe(u8, "0x");
    }

    // Read memory contents
    const memory_read = @import("evm").memory.read;
    const memory_data = try memory_read.get_slice(memory, 0, memory_size);
    return try formatBytesHex(allocator, memory_data);
}

/// Create empty EVM state JSON for initial state
pub fn createEmptyEvmStateJson(allocator: std.mem.Allocator) !EvmStateJson {
    var empty_stack = std.ArrayList([]const u8).init(allocator);
    defer empty_stack.deinit();

    var empty_storage = std.ArrayList(StorageEntry).init(allocator);
    defer empty_storage.deinit();

    var empty_logs = std.ArrayList([]const u8).init(allocator);
    defer empty_logs.deinit();

    return EvmStateJson{
        .pc = 0,
        .opcode = try allocator.dupe(u8, "-"),
        .gasLeft = 0,
        .depth = 0,
        .stack = try empty_stack.toOwnedSlice(),
        .memory = try allocator.dupe(u8, "0x"),
        .storage = try empty_storage.toOwnedSlice(),
        .logs = try empty_logs.toOwnedSlice(),
        .returnData = try allocator.dupe(u8, "0x"),
    };
}

/// Free allocated memory from EvmStateJson
pub fn freeEvmStateJson(allocator: std.mem.Allocator, state: EvmStateJson) void {
    allocator.free(state.opcode);

    for (state.stack) |stack_item| {
        allocator.free(stack_item);
    }
    allocator.free(state.stack);

    allocator.free(state.memory);

    // Free storage entries
    for (state.storage) |entry| {
        allocator.free(entry.key);
        allocator.free(entry.value);
    }
    allocator.free(state.storage);

    for (state.logs) |log_item| {
        allocator.free(log_item);
    }
    allocator.free(state.logs);

    allocator.free(state.returnData);
}

test "DebugState.capture works correctly" {
    const testing = std.testing;
    // const Evm = @import("evm");

    // Create minimal stack and memory for testing
    var stack = Stack{};
    try stack.append(42);
    try stack.append(100);

    var memory = try Memory.init_default(testing.allocator);
    defer memory.deinit();

    const debug_state = DebugState.capture(
        10, // pc
        0x01, // ADD opcode
        50000, // gas
        1, // depth
        false, // not static
        &stack,
        &memory,
        null, // no error
    );

    try testing.expectEqual(@as(usize, 10), debug_state.pc);
    try testing.expectEqual(@as(u8, 0x01), debug_state.opcode);
    try testing.expectEqualStrings("ADD", debug_state.opcode_name);
    try testing.expectEqual(@as(u64, 50000), debug_state.gas_remaining);
    try testing.expectEqual(@as(u32, 1), debug_state.depth);
    try testing.expectEqual(false, debug_state.is_static);
    try testing.expectEqual(@as(usize, 2), debug_state.stack_size);
    try testing.expectEqual(false, debug_state.has_error);
    try testing.expect(debug_state.error_name == null);
}

test "opcodeToString returns correct names" {
    const testing = std.testing;

    try testing.expectEqualStrings("STOP", opcodeToString(0x00));
    try testing.expectEqualStrings("ADD", opcodeToString(0x01));
    try testing.expectEqualStrings("PUSH1", opcodeToString(0x60));
    try testing.expectEqualStrings("RETURN", opcodeToString(0xf3));
    try testing.expectEqualStrings("UNKNOWN", opcodeToString(0xaa));
}

test "formatU256Hex works correctly" {
    const testing = std.testing;

    const hex1 = try formatU256Hex(testing.allocator, 0);
    defer testing.allocator.free(hex1);
    try testing.expectEqualStrings("0x0", hex1);

    const hex2 = try formatU256Hex(testing.allocator, 255);
    defer testing.allocator.free(hex2);
    try testing.expectEqualStrings("0xff", hex2);

    const hex3 = try formatU256Hex(testing.allocator, 42);
    defer testing.allocator.free(hex3);
    try testing.expectEqualStrings("0x2a", hex3);
}

test "formatBytesHex works correctly" {
    const testing = std.testing;

    const hex1 = try formatBytesHex(testing.allocator, &[_]u8{});
    defer testing.allocator.free(hex1);
    try testing.expectEqualStrings("0x", hex1);

    const hex2 = try formatBytesHex(testing.allocator, &[_]u8{ 0x12, 0x34, 0xab });
    defer testing.allocator.free(hex2);
    try testing.expectEqualStrings("0x1234ab", hex2);
}

test "serializeStack works correctly" {
    const testing = std.testing;

    // Test empty stack
    var empty_stack = Stack{};
    const empty_result = try serializeStack(testing.allocator, &empty_stack);
    defer {
        for (empty_result) |item| testing.allocator.free(item);
        testing.allocator.free(empty_result);
    }
    try testing.expectEqual(@as(usize, 0), empty_result.len);

    // Test stack with values
    var stack = Stack{};
    try stack.append(42);
    try stack.append(255);
    try stack.append(1000);

    const result = try serializeStack(testing.allocator, &stack);
    defer {
        for (result) |item| testing.allocator.free(item);
        testing.allocator.free(result);
    }

    try testing.expectEqual(@as(usize, 3), result.len);
    // Stack should be serialized top-first
    try testing.expectEqualStrings("0x3e8", result[0]); // 1000
    try testing.expectEqualStrings("0xff", result[1]); // 255
    try testing.expectEqualStrings("0x2a", result[2]); // 42
}

test "serializeMemory works correctly" {
    const testing = std.testing;
    // const Evm = @import("evm");

    // Test empty memory
    var empty_memory = try Memory.init_default(testing.allocator);
    defer empty_memory.deinit();

    const empty_result = try serializeMemory(testing.allocator, &empty_memory);
    defer testing.allocator.free(empty_result);
    try testing.expectEqualStrings("0x", empty_result);

    // Test memory with data
    var memory = try Memory.init_default(testing.allocator);
    defer memory.deinit();

    const test_data = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    const memory_write = @import("evm").memory.write;
    try memory_write.set_data_bounded(&memory, 0, &test_data, 0, test_data.len);

    const result = try serializeMemory(testing.allocator, &memory);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("0x12345678", result);
}

test "createEmptyEvmStateJson works correctly" {
    const testing = std.testing;

    const empty_state = try createEmptyEvmStateJson(testing.allocator);
    defer freeEvmStateJson(testing.allocator, empty_state);

    try testing.expectEqual(@as(usize, 0), empty_state.pc);
    try testing.expectEqualStrings("-", empty_state.opcode);
    try testing.expectEqual(@as(u64, 0), empty_state.gasLeft);
    try testing.expectEqual(@as(u32, 0), empty_state.depth);
    try testing.expectEqual(@as(usize, 0), empty_state.stack.len);
    try testing.expectEqualStrings("0x", empty_state.memory);
    try testing.expectEqual(@as(usize, 0), empty_state.storage.len);
    try testing.expectEqual(@as(usize, 0), empty_state.logs.len);
    try testing.expectEqualStrings("0x", empty_state.returnData);
}
