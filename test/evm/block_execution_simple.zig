const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");

test "Simple bytecode works with block execution" {
    std.testing.log_level = .debug;
    const allocator = std.testing.allocator;
    
    std.log.info("=== TEST: Starting Simple bytecode block execution test ===", .{});
    
    // Bytecode that's large enough to trigger block execution (>= 32 bytes)
    // This pushes a value, stores it in memory, and returns it
    const bytecode = &[_]u8{
        0x60, 0x42,  // PUSH1 0x42
        0x60, 0x00,  // PUSH1 0x00
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 0x20
        0x60, 0x00,  // PUSH1 0x00
        0xf3,        // RETURN
        // Padding to make it >= 32 bytes
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    
    std.log.info("TEST: Bytecode is PUSH-MSTORE-RETURN with padding (len={})", .{bytecode.len});
    
    // Initialize database with normal allocator (EVM will handle internal arena allocation)
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm_builder = evm.EvmBuilder.init(allocator, db_interface);
    var vm = try evm_builder.build();
    defer vm.deinit();
    
    // Set up caller account
    const caller_address = try primitives.Address.from_hex("0x1000000000000000000000000000000000000001");
    const contract_address = try primitives.Address.from_hex("0x2000000000000000000000000000000000000002");
    try vm.state.set_balance(caller_address, std.math.maxInt(u256));
    
    // Set contract code directly
    try vm.state.set_code(contract_address, bytecode);
    
    // Get contract code
    const code = vm.state.get_code(contract_address);
    const code_hash = [_]u8{0} ** 32;
    
    // Create contract
    var contract = evm.Contract.init(
        caller_address, // caller
        contract_address, // address
        0, // value
        1_000_000, // gas
        code, // code
        code_hash, // code_hash
        &.{}, // empty input
        false // is_static
    );
    defer contract.deinit(allocator, null);
    
    // Execute with block interpreter to test
    std.log.info("TEST: Starting block execution with interpret_block", .{});
    const result = try vm.interpret_block(&contract, &.{}, false);
    std.log.info("TEST: Block execution completed, status={}", .{result.status});
    
    // Verify success
    try std.testing.expect(result.status == .Success);
    
    if (result.output) |output| {
        defer allocator.free(output);
        std.log.info("Simple block execution output size: {}", .{output.len});
    }
}