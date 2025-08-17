const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");

// Import interpret2 components
const interpret2 = evm.interpret2;

//
// COMPARISON OPCODES TESTS
//

test "interpret2: LT happy path" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x05,  // PUSH1 5
        0x60, 0x03,  // PUSH1 3
        0x10,        // LT
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
    
    // 3 < 5 = true (1)
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "interpret2: LT false case" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x03,  // PUSH1 3
        0x60, 0x05,  // PUSH1 5
        0x10,        // LT
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
    
    // 5 < 3 = false (0)
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "interpret2: LT equal values" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x05,  // PUSH1 5
        0x60, 0x05,  // PUSH1 5
        0x10,        // LT
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
    
    // 5 < 5 = false (0)
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "interpret2: GT happy path" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x03,  // PUSH1 3
        0x60, 0x05,  // PUSH1 5
        0x11,        // GT
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
    
    // 5 > 3 = true (1)
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "interpret2: SLT signed comparison" {
    const allocator = testing.allocator;
    
    // Test negative vs positive: -1 < 1
    const code = [_]u8{
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,  // PUSH32 0xffffffff...
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x60, 0x01,  // PUSH1 1
        0x12,        // SLT
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
    
    // 1 < -1 = false (0) in signed comparison
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "interpret2: SGT signed comparison" {
    const allocator = testing.allocator;
    
    // Test positive vs negative: 1 > -1
    const code = [_]u8{
        0x60, 0x01,  // PUSH1 1
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,  // PUSH32 0xffffffff... (-1)
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x13,        // SGT
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
    
    // -1 > 1 = false (0) in signed comparison
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "interpret2: EQ equal values" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x05,  // PUSH1 5
        0x60, 0x05,  // PUSH1 5
        0x14,        // EQ
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
    
    // 5 == 5 = true (1)
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "interpret2: EQ unequal values" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x05,  // PUSH1 5
        0x60, 0x03,  // PUSH1 3
        0x14,        // EQ
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
    
    // 3 == 5 = false (0)
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "interpret2: ISZERO zero value" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x00,  // PUSH1 0
        0x15,        // ISZERO
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
    
    // 0 == 0 = true (1)
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "interpret2: ISZERO non-zero value" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x05,  // PUSH1 5
        0x15,        // ISZERO
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
    
    // 5 == 0 = false (0)
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

//
// BITWISE OPCODES TESTS
//

test "interpret2: AND operation" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x0F,  // PUSH1 0x0F (15)
        0x60, 0x0A,  // PUSH1 0x0A (10)
        0x16,        // AND
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
    
    // 0x0A & 0x0F = 0x0A (10)
    try testing.expectEqual(@as(u256, 0x0A), try frame.stack.pop());
}

test "interpret2: OR operation" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x0F,  // PUSH1 0x0F (15)
        0x60, 0x0A,  // PUSH1 0x0A (10)
        0x17,        // OR
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
    
    // 0x0A | 0x0F = 0x0F (15)
    try testing.expectEqual(@as(u256, 0x0F), try frame.stack.pop());
}

test "interpret2: XOR operation" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x0F,  // PUSH1 0x0F (15)
        0x60, 0x0A,  // PUSH1 0x0A (10)
        0x18,        // XOR
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
    
    // 0x0A ^ 0x0F = 0x05 (5)
    try testing.expectEqual(@as(u256, 0x05), try frame.stack.pop());
}

test "interpret2: NOT operation" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x0A,  // PUSH1 0x0A (10)
        0x19,        // NOT
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
    
    // ~0x0A = 0xFFF...FF5 (bitwise complement)
    const expected = ~@as(u256, 0x0A);
    try testing.expectEqual(expected, try frame.stack.pop());
}

test "interpret2: BYTE valid index" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x00,  // PUSH1 0 (index 0 - most significant byte)
        0x61, 0x12, 0x34,  // PUSH2 0x1234
        0x1A,        // BYTE
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
    
    // byte 0 of 0x1234 = 0x00 (since 0x1234 is padded to 32 bytes)
    try testing.expectEqual(@as(u256, 0x00), try frame.stack.pop());
}

test "interpret2: BYTE index 30" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x1E,  // PUSH1 30 (index 30)
        0x61, 0x12, 0x34,  // PUSH2 0x1234
        0x1A,        // BYTE
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
    
    // byte 30 of 0x1234 = 0x12
    try testing.expectEqual(@as(u256, 0x12), try frame.stack.pop());
}

test "interpret2: BYTE index 31" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x1F,  // PUSH1 31 (index 31)
        0x61, 0x12, 0x34,  // PUSH2 0x1234
        0x1A,        // BYTE
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
    
    // byte 31 of 0x1234 = 0x34 (least significant byte)
    try testing.expectEqual(@as(u256, 0x34), try frame.stack.pop());
}

test "interpret2: BYTE out of bounds index" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x20,  // PUSH1 32 (index 32 - out of bounds)
        0x61, 0x12, 0x34,  // PUSH2 0x1234
        0x1A,        // BYTE
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
    
    // byte at index >= 32 returns 0
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "interpret2: SHL shift left" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x02,  // PUSH1 2 (shift amount)
        0x60, 0x05,  // PUSH1 5 (value)
        0x1B,        // SHL
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
    
    // 5 << 2 = 20
    try testing.expectEqual(@as(u256, 20), try frame.stack.pop());
}

test "interpret2: SHL shift by zero" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x00,  // PUSH1 0 (shift amount)
        0x60, 0x05,  // PUSH1 5 (value)
        0x1B,        // SHL
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
    
    // 5 << 0 = 5
    try testing.expectEqual(@as(u256, 5), try frame.stack.pop());
}

test "interpret2: SHL shift overflow" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x62, 0x01, 0x00, 0x00,  // PUSH3 256 (shift amount >= 256)
        0x60, 0x05,  // PUSH1 5 (value)
        0x1B,        // SHL
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
    
    // 5 << 256 = 0 (overflow)
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "interpret2: SHR shift right" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x02,  // PUSH1 2 (shift amount)
        0x60, 0x14,  // PUSH1 20 (value)
        0x1C,        // SHR
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
    
    // 20 >> 2 = 5
    try testing.expectEqual(@as(u256, 5), try frame.stack.pop());
}

test "interpret2: SHR shift by zero" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x00,  // PUSH1 0 (shift amount)
        0x60, 0x14,  // PUSH1 20 (value)
        0x1C,        // SHR
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
    
    // 20 >> 0 = 20
    try testing.expectEqual(@as(u256, 20), try frame.stack.pop());
}

test "interpret2: SHR shift overflow" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x62, 0x01, 0x00, 0x00,  // PUSH3 256 (shift amount >= 256)
        0x60, 0x14,  // PUSH1 20 (value)
        0x1C,        // SHR
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
    
    // 20 >> 256 = 0 (overflow)
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "interpret2: SAR arithmetic shift right positive" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x02,  // PUSH1 2 (shift amount)
        0x60, 0x14,  // PUSH1 20 (value)
        0x1D,        // SAR
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
    
    // 20 >>> 2 = 5 (for positive numbers, same as logical shift)
    try testing.expectEqual(@as(u256, 5), try frame.stack.pop());
}

test "interpret2: SAR arithmetic shift right negative" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x02,  // PUSH1 2 (shift amount)
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,  // PUSH32 0xffffffff...FFFFFFFF (-1)
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x1D,        // SAR
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
    
    // -1 >>> 2 = -1 (sign extension keeps all bits as 1)
    try testing.expectEqual(@as(u256, std.math.maxInt(u256)), try frame.stack.pop());
}

test "interpret2: SAR shift overflow positive" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x62, 0x01, 0x00, 0x00,  // PUSH3 256 (shift amount >= 256)
        0x60, 0x14,  // PUSH1 20 (positive value)
        0x1D,        // SAR
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
    
    // positive number >>> 256 = 0
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "interpret2: SAR shift overflow negative" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x62, 0x01, 0x00, 0x00,  // PUSH3 256 (shift amount >= 256)
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,  // PUSH32 0xffffffff...FFFFFFFF (-1)
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x1D,        // SAR
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
    
    // negative number >>> 256 = MAX_U256 (all bits set)
    try testing.expectEqual(@as(u256, std.math.maxInt(u256)), try frame.stack.pop());
}

//
// EDGE CASES AND CORNER CASES
//

test "interpret2: comparison with max values" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,  // PUSH32 MAX_U256
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x60, 0x00,  // PUSH1 0
        0x10,        // LT
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
    
    // 0 < MAX_U256 = true (1)
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "interpret2: signed comparison edge cases" {
    const allocator = testing.allocator;
    
    // Test two's complement boundary: -1 vs 1
    const code = [_]u8{
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,  // PUSH32 -1
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x60, 0x01,  // PUSH1 1
        0x12,        // SLT (signed less than)
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
    
    // 1 < -1 = false (0) in signed comparison
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}