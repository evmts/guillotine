const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const CallParams = evm.CallParams;
const CallResult = evm.CallResult;

// Updated to new API - migration in progress, tests not run yet

test "Simple bytecode works with block execution" {
    std.testing.log_level = .warn;
    const allocator = std.testing.allocator;

    std.log.info("=== TEST: Starting Simple bytecode block execution test ===", .{});

    // Bytecode that's large enough to trigger block execution (>= 32 bytes)
    // This pushes a value, stores it in memory, and returns it
    const bytecode = &[_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0x00
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x00, // PUSH1 0x00
        0xf3, // RETURN
        // Padding to make it >= 32 bytes
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
    };

    std.log.info("TEST: Bytecode is PUSH-MSTORE-RETURN with padding (len={})", .{bytecode.len});

    // Initialize database with normal allocator (EVM will handle internal arena allocation)
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Set up caller account
    const caller_address = try primitives.Address.from_hex("0x1000000000000000000000000000000000000001");
    const contract_address = try primitives.Address.from_hex("0x2000000000000000000000000000000000000002");
    try vm.state.set_balance(caller_address, std.math.maxInt(u256));

    // Set contract code directly
    try vm.state.set_code(contract_address, bytecode);

    // Execute using new call API
    std.log.info("TEST: Starting execution with new call API", .{});
    const call_params = CallParams{ .call = .{
        .caller = caller_address,
        .to = contract_address,
        .value = 0,
        .input = &.{},
        .gas = 1_000_000,
    } };

    const result = try vm.call(call_params);
    std.log.info("TEST: Call execution completed, success={}", .{result.success});

    // Verify success
    try std.testing.expect(result.success);

    if (result.output) |_| {
        
        std.log.info("Simple execution output size: {}", .{output.len});
    }
}
