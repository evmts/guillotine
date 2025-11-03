/// Tests for context instruction implementations
/// Phase 2.3 - Test execution context operations
const std = @import("std");
const testing = std.testing;
const Frame = @import("Frame.zig");
const context = @import("context.zig");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const Hardfork = primitives.Hardfork;

// Test helper to create a frame with full context
fn makeFrameWithContext(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    caller: Address,
    address: Address,
    value: u256,
    calldata: []const u8,
) !Frame {
    return try Frame.initFull(
        allocator,
        bytecode,
        1000000, // gas
        caller,
        address,
        value,
        calldata,
        .CANCUN,
    );
}

// ADDRESS opcode (0x30)
test "ADDRESS: returns current contract address" {
    const allocator = testing.allocator;
    const addr = try Address.fromString("0x1234567890123456789012345678901234567890");
    var frame = try makeFrameWithContext(allocator, &[_]u8{}, Address.zero(), addr, 0, &[_]u8{});
    defer frame.deinit(allocator);

    try context.AddressInstruction(Frame).run(&frame);

    const result = try frame.stack.pop();
    const expected = primitives.Address.toU256(addr);
    try testing.expectEqual(expected, result);
}

// CALLER opcode (0x33)
test "CALLER: returns caller address" {
    const allocator = testing.allocator;
    const caller = try Address.fromString("0xabcdefabcdefabcdefabcdefabcdefabcdefabcd");
    var frame = try makeFrameWithContext(allocator, &[_]u8{}, caller, Address.zero(), 0, &[_]u8{});
    defer frame.deinit(allocator);

    try context.CallerInstruction(Frame).run(&frame);

    const result = try frame.stack.pop();
    const expected = primitives.Address.toU256(caller);
    try testing.expectEqual(expected, result);
}

// CALLVALUE opcode (0x34)
test "CALLVALUE: returns call value" {
    const allocator = testing.allocator;
    const value: u256 = 123456789;
    var frame = try makeFrameWithContext(allocator, &[_]u8{}, Address.zero(), Address.zero(), value, &[_]u8{});
    defer frame.deinit(allocator);

    try context.CallvalueInstruction(Frame).run(&frame);

    const result = try frame.stack.pop();
    try testing.expectEqual(value, result);
}

// CALLDATALOAD opcode (0x35)
test "CALLDATALOAD: loads 32 bytes from calldata" {
    const allocator = testing.allocator;
    const calldata = [_]u8{0x01} ++ [_]u8{0x00} ** 31; // 0x0100...00
    var frame = try makeFrameWithContext(allocator, &[_]u8{}, Address.zero(), Address.zero(), 0, &calldata);
    defer frame.deinit(allocator);

    // Load from offset 0
    try frame.stack.push(0);
    try context.CalldataloadInstruction(Frame).run(&frame);

    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0x01) << 248, result); // First byte in MSB position
}

test "CALLDATALOAD: pads with zeros if calldata is short" {
    const allocator = testing.allocator;
    const calldata = [_]u8{0xff, 0xee};
    var frame = try makeFrameWithContext(allocator, &[_]u8{}, Address.zero(), Address.zero(), 0, &calldata);
    defer frame.deinit(allocator);

    // Load from offset 0
    try frame.stack.push(0);
    try context.CalldataloadInstruction(Frame).run(&frame);

    const result = try frame.stack.pop();
    // 0xffee followed by 30 zero bytes
    const expected = (@as(u256, 0xff) << 248) | (@as(u256, 0xee) << 240);
    try testing.expectEqual(expected, result);
}

test "CALLDATALOAD: returns zero if offset >= calldata length" {
    const allocator = testing.allocator;
    const calldata = [_]u8{0xff};
    var frame = try makeFrameWithContext(allocator, &[_]u8{}, Address.zero(), Address.zero(), 0, &calldata);
    defer frame.deinit(allocator);

    // Load from offset beyond calldata
    try frame.stack.push(100);
    try context.CalldataloadInstruction(Frame).run(&frame);

    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result);
}

// CALLDATASIZE opcode (0x36)
test "CALLDATASIZE: returns size of calldata" {
    const allocator = testing.allocator;
    const calldata = [_]u8{0x01, 0x02, 0x03, 0x04, 0x05};
    var frame = try makeFrameWithContext(allocator, &[_]u8{}, Address.zero(), Address.zero(), 0, &calldata);
    defer frame.deinit(allocator);

    try context.CalldasizeInstruction(Frame).run(&frame);

    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 5), result);
}

test "CALLDATASIZE: returns zero for empty calldata" {
    const allocator = testing.allocator;
    var frame = try makeFrameWithContext(allocator, &[_]u8{}, Address.zero(), Address.zero(), 0, &[_]u8{});
    defer frame.deinit(allocator);

    try context.CalldasizeInstruction(Frame).run(&frame);

    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result);
}

// CALLDATACOPY opcode (0x37)
test "CALLDATACOPY: copies calldata to memory" {
    const allocator = testing.allocator;
    const calldata = [_]u8{ 0xaa, 0xbb, 0xcc, 0xdd };
    var frame = try makeFrameWithContext(allocator, &[_]u8{}, Address.zero(), Address.zero(), 0, &calldata);
    defer frame.deinit(allocator);

    // Copy 4 bytes from calldata[0] to memory[0]
    try frame.stack.push(4); // length
    try frame.stack.push(0); // calldata offset
    try frame.stack.push(0); // memory dest offset
    try context.CalldatacopyInstruction(Frame).run(&frame);

    // Verify memory contents
    try testing.expectEqual(@as(u8, 0xaa), frame.readMemory(0));
    try testing.expectEqual(@as(u8, 0xbb), frame.readMemory(1));
    try testing.expectEqual(@as(u8, 0xcc), frame.readMemory(2));
    try testing.expectEqual(@as(u8, 0xdd), frame.readMemory(3));
}

test "CALLDATACOPY: pads with zeros if reading beyond calldata" {
    const allocator = testing.allocator;
    const calldata = [_]u8{0xff};
    var frame = try makeFrameWithContext(allocator, &[_]u8{}, Address.zero(), Address.zero(), 0, &calldata);
    defer frame.deinit(allocator);

    // Copy 4 bytes from calldata[0] to memory[0] (only 1 byte exists)
    try frame.stack.push(4); // length
    try frame.stack.push(0); // calldata offset
    try frame.stack.push(0); // memory dest offset
    try context.CalldatacopyInstruction(Frame).run(&frame);

    // Verify memory: 0xff followed by zeros
    try testing.expectEqual(@as(u8, 0xff), frame.readMemory(0));
    try testing.expectEqual(@as(u8, 0x00), frame.readMemory(1));
    try testing.expectEqual(@as(u8, 0x00), frame.readMemory(2));
    try testing.expectEqual(@as(u8, 0x00), frame.readMemory(3));
}

// CODESIZE opcode (0x38)
test "CODESIZE: returns size of bytecode" {
    const allocator = testing.allocator;
    const bytecode = [_]u8{ 0x60, 0x42, 0x60, 0x10, 0x01 }; // PUSH1 0x42 PUSH1 0x10 ADD
    var frame = try makeFrameWithContext(allocator, &bytecode, Address.zero(), Address.zero(), 0, &[_]u8{});
    defer frame.deinit(allocator);

    try context.CodesizeInstruction(Frame).run(&frame);

    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 5), result);
}

// CODECOPY opcode (0x39)
test "CODECOPY: copies bytecode to memory" {
    const allocator = testing.allocator;
    const bytecode = [_]u8{ 0x60, 0x42, 0x60, 0x10, 0x01 };
    var frame = try makeFrameWithContext(allocator, &bytecode, Address.zero(), Address.zero(), 0, &[_]u8{});
    defer frame.deinit(allocator);

    // Copy 3 bytes from bytecode[1] to memory[0]
    try frame.stack.push(3); // length
    try frame.stack.push(1); // code offset
    try frame.stack.push(0); // memory dest offset
    try context.CodecopyInstruction(Frame).run(&frame);

    // Verify memory: 0x42, 0x60, 0x10
    try testing.expectEqual(@as(u8, 0x42), frame.readMemory(0));
    try testing.expectEqual(@as(u8, 0x60), frame.readMemory(1));
    try testing.expectEqual(@as(u8, 0x10), frame.readMemory(2));
}

test "CODECOPY: pads with zeros if reading beyond bytecode" {
    const allocator = testing.allocator;
    const bytecode = [_]u8{0x60};
    var frame = try makeFrameWithContext(allocator, &bytecode, Address.zero(), Address.zero(), 0, &[_]u8{});
    defer frame.deinit(allocator);

    // Copy 4 bytes from bytecode[0] to memory[0] (only 1 byte exists)
    try frame.stack.push(4); // length
    try frame.stack.push(0); // code offset
    try frame.stack.push(0); // memory dest offset
    try context.CodecopyInstruction(Frame).run(&frame);

    // Verify memory: 0x60 followed by zeros
    try testing.expectEqual(@as(u8, 0x60), frame.readMemory(0));
    try testing.expectEqual(@as(u8, 0x00), frame.readMemory(1));
    try testing.expectEqual(@as(u8, 0x00), frame.readMemory(2));
    try testing.expectEqual(@as(u8, 0x00), frame.readMemory(3));
}

// RETURNDATASIZE opcode (0x3d)
test "RETURNDATASIZE: returns size of return data" {
    const allocator = testing.allocator;
    var frame = try makeFrameWithContext(allocator, &[_]u8{}, Address.zero(), Address.zero(), 0, &[_]u8{});
    defer frame.deinit(allocator);

    // Set return data
    frame.return_data = &[_]u8{ 0x01, 0x02, 0x03 };

    try context.ReturndatasizeInstruction(Frame).run(&frame);

    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 3), result);
}

// RETURNDATACOPY opcode (0x3e)
test "RETURNDATACOPY: copies return data to memory" {
    const allocator = testing.allocator;
    var frame = try makeFrameWithContext(allocator, &[_]u8{}, Address.zero(), Address.zero(), 0, &[_]u8{});
    defer frame.deinit(allocator);

    // Set return data
    frame.return_data = &[_]u8{ 0xaa, 0xbb, 0xcc, 0xdd };

    // Copy 3 bytes from return_data[1] to memory[0]
    try frame.stack.push(3); // length
    try frame.stack.push(1); // return data offset
    try frame.stack.push(0); // memory dest offset
    try context.ReturndatacopyInstruction(Frame).run(&frame);

    // Verify memory: 0xbb, 0xcc, 0xdd
    try testing.expectEqual(@as(u8, 0xbb), frame.readMemory(0));
    try testing.expectEqual(@as(u8, 0xcc), frame.readMemory(1));
    try testing.expectEqual(@as(u8, 0xdd), frame.readMemory(2));
}

test "RETURNDATACOPY: fails if reading beyond return data" {
    const allocator = testing.allocator;
    var frame = try makeFrameWithContext(allocator, &[_]u8{}, Address.zero(), Address.zero(), 0, &[_]u8{});
    defer frame.deinit(allocator);

    // Set return data
    frame.return_data = &[_]u8{ 0xaa, 0xbb };

    // Try to copy 4 bytes from return_data[0] (only 2 bytes exist)
    try frame.stack.push(4); // length
    try frame.stack.push(0); // return data offset
    try frame.stack.push(0); // memory dest offset

    const result = context.ReturndatacopyInstruction(Frame).run(&frame);
    try testing.expectError(error.ReturnDataOutOfBounds, result);
}

// GAS opcode (0x5a)
test "GAS: returns remaining gas" {
    const allocator = testing.allocator;
    var frame = try makeFrameWithContext(allocator, &[_]u8{}, Address.zero(), Address.zero(), 0, &[_]u8{});
    defer frame.deinit(allocator);

    // Initial gas is 1000000
    try context.GasInstruction(Frame).run(&frame);

    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1000000), result);
}

test "GAS: returns 0 if gas is negative" {
    const allocator = testing.allocator;
    var frame = try makeFrameWithContext(allocator, &[_]u8{}, Address.zero(), Address.zero(), 0, &[_]u8{});
    defer frame.deinit(allocator);

    // Set negative gas
    frame.gas_remaining = -100;

    try context.GasInstruction(Frame).run(&frame);

    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result);
}

// Integration test: Mixed context operations
test "Context: mixed operations sequence" {
    const allocator = testing.allocator;
    const caller_addr = try Address.fromString("0x1111111111111111111111111111111111111111");
    const contract_addr = try Address.fromString("0x2222222222222222222222222222222222222222");
    const call_value: u256 = 42;
    const calldata = [_]u8{ 0xaa, 0xbb, 0xcc };

    var frame = try makeFrameWithContext(allocator, &[_]u8{}, caller_addr, contract_addr, call_value, &calldata);
    defer frame.deinit(allocator);

    // Get CALLER
    try context.CallerInstruction(Frame).run(&frame);
    const caller_result = try frame.stack.pop();
    try testing.expectEqual(primitives.Address.toU256(caller_addr), caller_result);

    // Get ADDRESS
    try context.AddressInstruction(Frame).run(&frame);
    const address_result = try frame.stack.pop();
    try testing.expectEqual(primitives.Address.toU256(contract_addr), address_result);

    // Get CALLVALUE
    try context.CallvalueInstruction(Frame).run(&frame);
    const value_result = try frame.stack.pop();
    try testing.expectEqual(call_value, value_result);

    // Get CALLDATASIZE
    try context.CalldasizeInstruction(Frame).run(&frame);
    const size_result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 3), size_result);
}
