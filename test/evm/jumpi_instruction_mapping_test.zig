const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const MemoryDatabase = evm.MemoryDatabase;
const CallParams = evm.CallParams;
const Evm = evm.Evm;

// Enable debug logging for all tests
test {
    std.testing.log_level = .warn;
}

test "JUMPI instruction mapping - verify correct PUSH value after jump" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Bytecode that demonstrates the issue:
    // We'll create a pattern where we can verify which PUSH is executed
    // 0x00: PUSH1 0x01 (condition for JUMPI)
    // 0x02: PUSH1 0x0A (destination for JUMPI = 10 decimal)
    // 0x04: JUMPI      (should jump to 0x0A)
    // 0x05: PUSH1 0xFF (should be skipped)
    // 0x07: PUSH1 0xEE (should be skipped) 
    // 0x09: STOP       (should be skipped)
    // 0x0A: JUMPDEST   (at position 10)
    // 0x0B: PUSH1 0xAA (should execute this)
    // 0x0D: PUSH1 0x00 (offset for MSTORE)
    // 0x0F: MSTORE     
    // 0x10: PUSH1 0x20 (size for RETURN)
    // 0x12: PUSH1 0x00 (offset for RETURN)
    // 0x14: RETURN
    const bytecode = &[_]u8{
        0x60, 0x01, // PUSH1 0x01
        0x60, 0x0A, // PUSH1 0x0A (jump to position 10)
        0x57,       // JUMPI
        0x60, 0xFF, // PUSH1 0xFF (should skip)
        0x60, 0xEE, // PUSH1 0xEE (should skip)
        0x00,       // STOP (should skip)
        0x5B,       // JUMPDEST at position 0x0A
        0x60, 0xAA, // PUSH1 0xAA (should execute)
        0x60, 0x00, // PUSH1 0x00
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x00, // PUSH1 0x00
        0xF3,       // RETURN
    };

    const contract_addr = Address.from_u256(0x2000);
    try vm.state.set_code(contract_addr, bytecode);

    const caller = Address.from_u256(0x1000);
    try vm.state.set_balance(caller, std.math.maxInt(u256));

    const call_params = CallParams{
        .call = .{
            .caller = caller,
            .to = contract_addr,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    };

    std.log.warn("=== Executing JUMPI instruction mapping test ===", .{});
    std.log.warn("Expected: Jump to 0x0A, push 0xAA, store it, and return", .{});
    
    const result = try vm.call(call_params);
    
    // Should succeed
    try testing.expect(result.success);
    
    // Should return 32 bytes
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // The returned value should be 0xAA, not 0xFF or 0xEE
    const returned_value = std.mem.readInt(u256, output[0..32], .big);
    std.log.warn("Returned value: 0x{x}", .{returned_value});
    
    // This test will fail if the wrong PUSH instruction is executed
    try testing.expectEqual(@as(u256, 0xAA), returned_value);
}