const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");

// Import interpret2 components
const interpret2 = evm.interpret2;

test {
    std.testing.log_level = .warn;
}

// MARK: - POP Tests

test "interpret2: POP happy path" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x42,  // PUSH1 0x42
        0x60, 0x99,  // PUSH1 0x99
        0x50,        // POP (remove 0x99)
        0x00,        // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    // Should have only 0x42 left on stack (0x99 was popped)
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    try testing.expectEqual(@as(u256, 0x42), try frame.stack.pop());
}

test "interpret2: POP stack underflow" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x50,  // POP with empty stack
        0x00,  // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.StackUnderflow, result);
}

// MARK: - MLOAD Tests

test "interpret2: MLOAD happy path" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x00,  // PUSH1 0x00 (offset)
        0x51,        // MLOAD
        0x00,        // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    // Should have loaded 0 from uninitialized memory
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "interpret2: MLOAD with offset beyond max" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x7F,  // PUSH32 max_u256
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x51,  // MLOAD (should fail)
        0x00,  // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.OutOfOffset, result);
}

// MARK: - MSTORE Tests

test "interpret2: MSTORE happy path" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x42,  // PUSH1 0x42 (value)
        0x60, 0x00,  // PUSH1 0x00 (offset)
        0x52,        // MSTORE
        0x60, 0x00,  // PUSH1 0x00 (offset)
        0x51,        // MLOAD (load it back)
        0x00,        // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    // Should have stored and loaded back 0x42
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    try testing.expectEqual(@as(u256, 0x42), try frame.stack.pop());
}

test "interpret2: MSTORE with high offset" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x42,  // PUSH1 0x42 (value)
        0x61, 0x03, 0x20,  // PUSH2 0x320 (offset 800)
        0x52,        // MSTORE
        0x61, 0x03, 0x20,  // PUSH2 0x320 (offset 800)
        0x51,        // MLOAD (load it back)
        0x00,        // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    // Should have stored and loaded back 0x42 at offset 800
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    try testing.expectEqual(@as(u256, 0x42), try frame.stack.pop());
}

// MARK: - MSTORE8 Tests

test "interpret2: MSTORE8 happy path" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x61, 0x01, 0x23,  // PUSH2 0x123 (value with high bits)
        0x60, 0x00,        // PUSH1 0x00 (offset)
        0x53,              // MSTORE8 (store only LSB: 0x23)
        0x60, 0x00,        // PUSH1 0x00 (offset)
        0x51,              // MLOAD (load full word)
        0x00,              // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    // Should have stored only 0x23 (LSB) at first byte position
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    const loaded = try frame.stack.pop();
    // First byte should be 0x23, rest should be 0
    try testing.expectEqual(@as(u256, 0x23) << 248, loaded);
}

test "interpret2: MSTORE8 multiple bytes" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0xAA,  // PUSH1 0xAA
        0x60, 0x00,  // PUSH1 0x00 (offset)
        0x53,        // MSTORE8
        0x60, 0xBB,  // PUSH1 0xBB
        0x60, 0x01,  // PUSH1 0x01 (offset)
        0x53,        // MSTORE8
        0x60, 0x00,  // PUSH1 0x00 (offset)
        0x51,        // MLOAD (load full word)
        0x00,        // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    // Should have stored 0xAA at offset 0 and 0xBB at offset 1
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    const loaded = try frame.stack.pop();
    // First two bytes should be 0xAABB, rest should be 0
    const expected = (@as(u256, 0xAA) << 248) | (@as(u256, 0xBB) << 240);
    try testing.expectEqual(expected, loaded);
}

// MARK: - MSIZE Tests

test "interpret2: MSIZE initial size" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x59,  // MSIZE
        0x00,  // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    // Initial memory size should be 0
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "interpret2: MSIZE after memory expansion" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x42,  // PUSH1 0x42
        0x60, 0x40,  // PUSH1 0x40 (offset 64)
        0x52,        // MSTORE (expands memory to 96 bytes)
        0x59,        // MSIZE
        0x00,        // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    // Memory size should be 96 (64 + 32), aligned to 32-byte words
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    try testing.expectEqual(@as(u256, 96), try frame.stack.pop());
}

// MARK: - DUP Tests

test "interpret2: DUP1 happy path" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x42,  // PUSH1 0x42
        0x80,        // DUP1
        0x00,        // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    // Should have two copies of 0x42
    try testing.expectEqual(@as(usize, 2), frame.stack.size());
    try testing.expectEqual(@as(u256, 0x42), try frame.stack.pop());
    try testing.expectEqual(@as(u256, 0x42), try frame.stack.pop());
}

test "interpret2: DUP2 operation" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x11,  // PUSH1 0x11
        0x60, 0x22,  // PUSH1 0x22
        0x81,        // DUP2 (duplicate second item: 0x11)
        0x00,        // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    // Stack should be [0x11, 0x22, 0x11] (top to bottom)
    try testing.expectEqual(@as(usize, 3), frame.stack.size());
    try testing.expectEqual(@as(u256, 0x11), try frame.stack.pop()); // DUP2 result
    try testing.expectEqual(@as(u256, 0x22), try frame.stack.pop()); // Second item
    try testing.expectEqual(@as(u256, 0x11), try frame.stack.pop()); // First item
}

test "interpret2: DUP8 operation" {
    const allocator = testing.allocator;
    
    // Build code that pushes 8 values then duplicates the 8th
    var code = std.ArrayList(u8).init(allocator);
    defer code.deinit();
    
    // Push values 1-8
    var i: u8 = 1;
    while (i <= 8) : (i += 1) {
        try code.append(0x60); // PUSH1
        try code.append(i);
    }
    
    try code.append(0x87); // DUP8
    try code.append(0x00); // STOP
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, code.items, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, code.items);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    // Should have 9 items on stack, top should be 1 (8th from top duplicated)
    try testing.expectEqual(@as(usize, 9), frame.stack.size());
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop()); // DUP8 result
}

test "interpret2: DUP16 operation" {
    const allocator = testing.allocator;
    
    // Build code that pushes 16 values then duplicates the 16th
    var code = std.ArrayList(u8).init(allocator);
    defer code.deinit();
    
    // Push values 1-16
    var i: u8 = 1;
    while (i <= 16) : (i += 1) {
        try code.append(0x60); // PUSH1
        try code.append(i);
    }
    
    try code.append(0x8F); // DUP16
    try code.append(0x00); // STOP
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, code.items, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, code.items);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    // Should have 17 items on stack, top should be 1 (16th from top duplicated)
    try testing.expectEqual(@as(usize, 17), frame.stack.size());
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop()); // DUP16 result
}

test "interpret2: DUP1 stack underflow" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x80,  // DUP1 with empty stack
        0x00,  // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.StackUnderflow, result);
}

test "interpret2: DUP2 insufficient stack depth" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x42,  // PUSH1 0x42 (only 1 item)
        0x81,        // DUP2 (needs 2 items)
        0x00,        // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.StackUnderflow, result);
}

// MARK: - SWAP Tests

test "interpret2: SWAP1 happy path" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x11,  // PUSH1 0x11
        0x60, 0x22,  // PUSH1 0x22
        0x90,        // SWAP1
        0x00,        // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    // After SWAP1: [0x11, 0x22] becomes [0x22, 0x11]
    try testing.expectEqual(@as(usize, 2), frame.stack.size());
    try testing.expectEqual(@as(u256, 0x11), try frame.stack.pop()); // Was second, now first
    try testing.expectEqual(@as(u256, 0x22), try frame.stack.pop()); // Was first, now second
}

test "interpret2: SWAP2 operation" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x11,  // PUSH1 0x11
        0x60, 0x22,  // PUSH1 0x22
        0x60, 0x33,  // PUSH1 0x33
        0x91,        // SWAP2 (swap 1st and 3rd)
        0x00,        // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    // After SWAP2: [0x11, 0x22, 0x33] becomes [0x33, 0x22, 0x11]
    try testing.expectEqual(@as(usize, 3), frame.stack.size());
    try testing.expectEqual(@as(u256, 0x11), try frame.stack.pop()); // Was third, now first
    try testing.expectEqual(@as(u256, 0x22), try frame.stack.pop()); // Unchanged
    try testing.expectEqual(@as(u256, 0x33), try frame.stack.pop()); // Was first, now third
}

test "interpret2: SWAP8 operation" {
    const allocator = testing.allocator;
    
    // Build code that pushes 9 values then swaps 1st with 9th
    var code = std.ArrayList(u8).init(allocator);
    defer code.deinit();
    
    // Push values 1-9
    var i: u8 = 1;
    while (i <= 9) : (i += 1) {
        try code.append(0x60); // PUSH1
        try code.append(i);
    }
    
    try code.append(0x97); // SWAP8
    try code.append(0x00); // STOP
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, code.items, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, code.items);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    // Top should now be 1 (was 9th from top), and item at position 8 should be 9
    try testing.expectEqual(@as(usize, 9), frame.stack.size());
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop()); // Was 9th, now top
}

test "interpret2: SWAP16 operation" {
    const allocator = testing.allocator;
    
    // Build code that pushes 17 values then swaps 1st with 17th
    var code = std.ArrayList(u8).init(allocator);
    defer code.deinit();
    
    // Push values 1-17
    var i: u8 = 1;
    while (i <= 17) : (i += 1) {
        try code.append(0x60); // PUSH1
        try code.append(i);
    }
    
    try code.append(0x9F); // SWAP16
    try code.append(0x00); // STOP
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, code.items, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, code.items);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    // Top should now be 1 (was 17th from top)
    try testing.expectEqual(@as(usize, 17), frame.stack.size());
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop()); // Was 17th, now top
}

test "interpret2: SWAP1 insufficient stack depth" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x42,  // PUSH1 0x42 (only 1 item)
        0x90,        // SWAP1 (needs 2 items)
        0x00,        // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.StackUnderflow, result);
}

// MARK: - PUSH Tests

test "interpret2: PUSH0 operation" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x5F,  // PUSH0
        0x00,  // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "interpret2: PUSH1 operation" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0xFF,  // PUSH1 0xFF
        0x00,        // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    try testing.expectEqual(@as(u256, 0xFF), try frame.stack.pop());
}

test "interpret2: PUSH16 operation" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x6F,  // PUSH16
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
        0x00,  // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    const expected: u256 = 0x0102030405060708090A0B0C0D0E0F10;
    try testing.expectEqual(expected, try frame.stack.pop());
}

test "interpret2: PUSH32 operation" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x7F,  // PUSH32
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20,
        0x00,  // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    const expected: u256 = 0x0102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F20;
    try testing.expectEqual(expected, try frame.stack.pop());
}

// MARK: - Complex Stack/Memory Interaction Tests

test "interpret2: complex stack and memory interaction" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x11,  // PUSH1 0x11
        0x60, 0x22,  // PUSH1 0x22
        0x60, 0x33,  // PUSH1 0x33  Stack: [0x11, 0x22, 0x33]
        0x82,        // DUP3        Stack: [0x11, 0x22, 0x33, 0x11]
        0x60, 0x00,  // PUSH1 0x00  Stack: [0x11, 0x22, 0x33, 0x11, 0x00]
        0x52,        // MSTORE      Stack: [0x11, 0x22, 0x33] (store 0x11 at offset 0)
        0x91,        // SWAP2       Stack: [0x33, 0x22, 0x11]
        0x60, 0x20,  // PUSH1 0x20  Stack: [0x33, 0x22, 0x11, 0x20]
        0x52,        // MSTORE      Stack: [0x33, 0x22] (store 0x11 at offset 32)
        0x60, 0x00,  // PUSH1 0x00  Stack: [0x33, 0x22, 0x00]
        0x51,        // MLOAD       Stack: [0x33, 0x22, 0x11] (load from offset 0)
        0x01,        // ADD         Stack: [0x33, 0x33] (0x22 + 0x11)
        0x01,        // ADD         Stack: [0x66] (0x33 + 0x33)
        0x00,        // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    // Final result should be 0x66 (0x33 + 0x33)
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    try testing.expectEqual(@as(u256, 0x66), try frame.stack.pop());
}

test "interpret2: memory expansion cost" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0xFF,        // PUSH1 0xFF
        0x61, 0x10, 0x00,  // PUSH2 0x1000 (offset 4096)
        0x52,              // MSTORE (should expand memory significantly)
        0x59,              // MSIZE
        0x00,              // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    // Memory should be expanded to cover offset 4096 + 32 = 4128, aligned to 32-byte words
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    const memory_size = try frame.stack.pop();
    try testing.expect(memory_size >= 4128);
    try testing.expect(memory_size % 32 == 0); // Should be word-aligned
}