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

test "minimal JUMPI test - debug instruction mapping" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer vm.deinit();

    // Minimal bytecode to test JUMPI:
    // 0x00: PUSH1 0x01 (condition = 1)
    // 0x02: PUSH1 0x06 (destination = 6) 
    // 0x04: JUMPI
    // 0x05: INVALID (should skip)
    // 0x06: JUMPDEST
    // 0x07: PUSH1 0x42
    // 0x09: STOP
    const bytecode = &[_]u8{
        0x60, 0x01, // PUSH1 0x01
        0x60, 0x06, // PUSH1 0x06
        0x57,       // JUMPI
        0xFE,       // INVALID (should skip)
        0x5B,       // JUMPDEST at position 6
        0x60, 0x42, // PUSH1 0x42
        0x00,       // STOP
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

    std.log.warn("=== Executing minimal JUMPI test ===", .{});
    const result = try vm.call(call_params);
    
    // Should succeed (jump over INVALID)
    try testing.expectEqual(true, result.success);
    
    // Stack should have 0x42 on top after execution
    std.log.warn("Result: success={}, gas_used={}", .{ result.success, 100000 - result.gas_left });
}