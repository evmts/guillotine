const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");

// Import interpret2 components
const interpret2 = evm.interpret2;

// Helper function to create a frame for testing using MockHost
fn create_test_frame(
    allocator: std.mem.Allocator,
    code: []const u8,
    contract_address: primitives.Address.Address,
    caller: primitives.Address.Address,
    value: u256,
) !struct { frame: evm.Frame, analysis: evm.CodeAnalysis, memory_db: evm.MemoryDatabase, mock_host: evm.MockHost } {
    var memory_db = evm.MemoryDatabase.init(allocator);
    
    var mock_host = evm.MockHost.init(allocator);
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, code, &metadata);
    
    const frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        contract_address,
        caller,
        value,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    
    return .{ .frame = frame, .analysis = analysis, .memory_db = memory_db, .mock_host = mock_host };
}

// Environment Opcodes Tests

test "interpret2: ADDRESS opcode returns contract address" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x30,        // ADDRESS
        0x00,        // STOP
    };
    
    const test_address = primitives.Address.from_u256(0x1234567890123456789012345678901234567890);
    
    var test_setup = try create_test_frame(
        allocator,
        &code,
        test_address,
        primitives.Address.ZERO_ADDRESS,
        0,
    );
    defer test_setup.frame.deinit(allocator);
    defer test_setup.analysis.deinit();
    defer test_setup.memory_db.deinit();
    defer test_setup.mock_host.deinit();
    
    const result = interpret2.interpret2(&test_setup.frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    try testing.expectEqual(@as(usize, 1), test_setup.frame.stack.size());
    try testing.expectEqual(@as(u256, 0x1234567890123456789012345678901234567890), try test_setup.frame.stack.pop());
}

test "interpret2: BALANCE opcode returns account balance" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x00,  // PUSH1 0 (simple address)
        0x31,        // BALANCE
        0x00,        // STOP
    };
    
    var test_setup = try create_test_frame(
        allocator,
        &code,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
    );
    defer test_setup.frame.deinit(allocator);
    defer test_setup.analysis.deinit();
    defer test_setup.memory_db.deinit();
    defer test_setup.mock_host.deinit();
    
    const result = interpret2.interpret2(&test_setup.frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    try testing.expectEqual(@as(usize, 1), test_setup.frame.stack.size());
    try testing.expectEqual(@as(u256, 0), try test_setup.frame.stack.pop()); // MemoryDatabase returns 0 for uninitialized balance
}

test "interpret2: CALLER opcode returns caller address" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x33,        // CALLER
        0x00,        // STOP
    };
    
    const caller_address = primitives.Address.from_u256(0x5678901234567890123456789012345678901234);
    
    var test_setup = try create_test_frame(
        allocator,
        &code,
        primitives.Address.ZERO_ADDRESS,
        caller_address,
        0,
    );
    defer test_setup.frame.deinit(allocator);
    defer test_setup.analysis.deinit();
    defer test_setup.memory_db.deinit();
    defer test_setup.mock_host.deinit();
    
    const result = interpret2.interpret2(&test_setup.frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    try testing.expectEqual(@as(usize, 1), test_setup.frame.stack.size());
    try testing.expectEqual(@as(u256, 0x5678901234567890123456789012345678901234), try test_setup.frame.stack.pop());
}

test "interpret2: CALLVALUE opcode returns call value" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x34,        // CALLVALUE
        0x00,        // STOP
    };
    
    const test_value: u256 = 1000000000000000000; // 1 ETH in wei
    
    var test_setup = try create_test_frame(
        allocator,
        &code,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        test_value,
    );
    defer test_setup.frame.deinit(allocator);
    defer test_setup.analysis.deinit();
    defer test_setup.memory_db.deinit();
    defer test_setup.mock_host.deinit();
    
    const result = interpret2.interpret2(&test_setup.frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    try testing.expectEqual(@as(usize, 1), test_setup.frame.stack.size());
    try testing.expectEqual(test_value, try test_setup.frame.stack.pop());
}

test "interpret2: CALLDATASIZE opcode with empty calldata" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x36,        // CALLDATASIZE
        0x00,        // STOP
    };
    
    var test_setup = try create_test_frame(
        allocator,
        &code,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
    );
    defer test_setup.frame.deinit(allocator);
    defer test_setup.analysis.deinit();
    defer test_setup.memory_db.deinit();
    defer test_setup.mock_host.deinit();
    
    const result = interpret2.interpret2(&test_setup.frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    try testing.expectEqual(@as(usize, 1), test_setup.frame.stack.size());
    try testing.expectEqual(@as(u256, 0), try test_setup.frame.stack.pop()); // MockHost returns empty input
}

test "interpret2: CALLDATALOAD opcode with out of bounds offset" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x64,  // PUSH1 100 (offset past end of calldata)
        0x35,        // CALLDATALOAD
        0x00,        // STOP
    };
    
    var test_setup = try create_test_frame(
        allocator,
        &code,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
    );
    defer test_setup.frame.deinit(allocator);
    defer test_setup.analysis.deinit();
    defer test_setup.memory_db.deinit();
    defer test_setup.mock_host.deinit();
    
    const result = interpret2.interpret2(&test_setup.frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    try testing.expectEqual(@as(usize, 1), test_setup.frame.stack.size());
    try testing.expectEqual(@as(u256, 0), try test_setup.frame.stack.pop());
}

test "interpret2: CODESIZE opcode returns code length" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x38,        // CODESIZE
        0x00,        // STOP
    };
    
    var test_setup = try create_test_frame(
        allocator,
        &code,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
    );
    defer test_setup.frame.deinit(allocator);
    defer test_setup.analysis.deinit();
    defer test_setup.memory_db.deinit();
    defer test_setup.mock_host.deinit();
    
    const result = interpret2.interpret2(&test_setup.frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    try testing.expectEqual(@as(usize, 1), test_setup.frame.stack.size());
    try testing.expectEqual(@as(u256, 2), try test_setup.frame.stack.pop()); // 2 bytes: CODESIZE + STOP
}

test "interpret2: CHAINID opcode returns chain ID" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x46,        // CHAINID
        0x00,        // STOP
    };
    
    var test_setup = try create_test_frame(
        allocator,
        &code,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
    );
    defer test_setup.frame.deinit(allocator);
    defer test_setup.analysis.deinit();
    defer test_setup.memory_db.deinit();
    defer test_setup.mock_host.deinit();
    
    const result = interpret2.interpret2(&test_setup.frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    try testing.expectEqual(@as(usize, 1), test_setup.frame.stack.size());
    try testing.expectEqual(@as(u256, 1), try test_setup.frame.stack.pop()); // Mainnet chain ID
}

test "interpret2: SELFBALANCE opcode returns contract balance" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x47,        // SELFBALANCE
        0x00,        // STOP
    };
    
    var test_setup = try create_test_frame(
        allocator,
        &code,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
    );
    defer test_setup.frame.deinit(allocator);
    defer test_setup.analysis.deinit();
    defer test_setup.memory_db.deinit();
    defer test_setup.mock_host.deinit();
    
    const result = interpret2.interpret2(&test_setup.frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    try testing.expectEqual(@as(usize, 1), test_setup.frame.stack.size());
    try testing.expectEqual(@as(u256, 0), try test_setup.frame.stack.pop()); // MemoryDatabase returns 0 for uninitialized balance
}

// Block Information Opcodes Tests

test "interpret2: COINBASE opcode returns block coinbase" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x41,        // COINBASE
        0x00,        // STOP
    };
    
    var test_setup = try create_test_frame(
        allocator,
        &code,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
    );
    defer test_setup.frame.deinit(allocator);
    defer test_setup.analysis.deinit();
    defer test_setup.memory_db.deinit();
    defer test_setup.mock_host.deinit();
    
    const result = interpret2.interpret2(&test_setup.frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    try testing.expectEqual(@as(usize, 1), test_setup.frame.stack.size());
    // MockHost uses ZERO_ADDRESS for coinbase
    try testing.expectEqual(primitives.Address.to_u256(primitives.Address.ZERO_ADDRESS), try test_setup.frame.stack.pop());
}

test "interpret2: TIMESTAMP opcode returns block timestamp" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x42,        // TIMESTAMP
        0x00,        // STOP
    };
    
    var test_setup = try create_test_frame(
        allocator,
        &code,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
    );
    defer test_setup.frame.deinit(allocator);
    defer test_setup.analysis.deinit();
    defer test_setup.memory_db.deinit();
    defer test_setup.mock_host.deinit();
    
    const result = interpret2.interpret2(&test_setup.frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    try testing.expectEqual(@as(usize, 1), test_setup.frame.stack.size());
    try testing.expectEqual(@as(u256, 1000), try test_setup.frame.stack.pop()); // MockHost timestamp
}

test "interpret2: NUMBER opcode returns block number" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x43,        // NUMBER
        0x00,        // STOP
    };
    
    var test_setup = try create_test_frame(
        allocator,
        &code,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
    );
    defer test_setup.frame.deinit(allocator);
    defer test_setup.analysis.deinit();
    defer test_setup.memory_db.deinit();
    defer test_setup.mock_host.deinit();
    
    const result = interpret2.interpret2(&test_setup.frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    try testing.expectEqual(@as(usize, 1), test_setup.frame.stack.size());
    try testing.expectEqual(@as(u256, 1), try test_setup.frame.stack.pop()); // MockHost block number
}

test "interpret2: PREVRANDAO opcode returns difficulty/prevrandao" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x44,        // DIFFICULTY/PREVRANDAO
        0x00,        // STOP
    };
    
    var test_setup = try create_test_frame(
        allocator,
        &code,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
    );
    defer test_setup.frame.deinit(allocator);
    defer test_setup.analysis.deinit();
    defer test_setup.memory_db.deinit();
    defer test_setup.mock_host.deinit();
    
    const result = interpret2.interpret2(&test_setup.frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    try testing.expectEqual(@as(usize, 1), test_setup.frame.stack.size());
    try testing.expectEqual(@as(u256, 100), try test_setup.frame.stack.pop()); // MockHost difficulty
}

test "interpret2: GASLIMIT opcode returns block gas limit" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x45,        // GASLIMIT
        0x00,        // STOP
    };
    
    var test_setup = try create_test_frame(
        allocator,
        &code,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
    );
    defer test_setup.frame.deinit(allocator);
    defer test_setup.analysis.deinit();
    defer test_setup.memory_db.deinit();
    defer test_setup.mock_host.deinit();
    
    const result = interpret2.interpret2(&test_setup.frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    try testing.expectEqual(@as(usize, 1), test_setup.frame.stack.size());
    try testing.expectEqual(@as(u256, 30000000), try test_setup.frame.stack.pop()); // MockHost gas limit
}

test "interpret2: BASEFEE opcode returns block base fee" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x48,        // BASEFEE
        0x00,        // STOP
    };
    
    var test_setup = try create_test_frame(
        allocator,
        &code,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
    );
    defer test_setup.frame.deinit(allocator);
    defer test_setup.analysis.deinit();
    defer test_setup.memory_db.deinit();
    defer test_setup.mock_host.deinit();
    
    const result = interpret2.interpret2(&test_setup.frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    try testing.expectEqual(@as(usize, 1), test_setup.frame.stack.size());
    try testing.expectEqual(@as(u256, 1000000000), try test_setup.frame.stack.pop()); // MockHost base fee (1 gwei)
}