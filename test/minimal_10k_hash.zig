const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");

test "minimal 10k hash test" {
    const allocator = std.testing.allocator;
    
    // The 10k hashes contract runtime code (extracted from full bytecode)
    // This is what gets deployed after the constructor runs
    const runtime_hex = "6080604052348015600e575f5ffd5b50600436106026575f3560e01c806330627b7c14602a575b5f5ffd5b60306032565b005b5f5b614e20811015605e5760408051602081018390520160408051601f19818403019052526001016034565b5056fe";
    
    // Convert hex to bytes
    const runtime_code = blk: {
        var buf: [200]u8 = undefined;
        const len = try std.fmt.hexToBytes(&buf, runtime_hex);
        break :blk buf[0..len];
    };
    
    
    // Set up VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, null);
    defer vm.deinit();
    
    // Set up accounts
    const caller = primitives.Address.from_u256(0x1000000000000000000000000000000000000001);
    const contract_address = primitives.Address.from_u256(0x2000000000000000000000000000000000000002);
    
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Deploy the runtime code directly at the contract address
    try vm.state.set_code(contract_address, runtime_code);
    
    // Call the contract with function selector 0x30627b7c
    const calldata = [_]u8{0x30, 0x62, 0x7b, 0x7c};
    
    const initial_gas: u64 = 50_000_000; // 50M gas should be plenty
    
    const params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_address,
        .value = 0,
        .input = &calldata,
        .gas = initial_gas,
    } };
    
    const result = try vm.call(params);
    
    
    if (!result.success) {
        if (result.output) |_| {
        }
    }
    
    try std.testing.expect(result.success);
    
    const gas_used = initial_gas - result.gas_left;
    
    // Each KECCAK256 costs ~30 gas, so 20k hashes should use ~600k gas minimum
    try std.testing.expect(gas_used > 100_000);
}

test "simple hash operation test" {
    const allocator = std.testing.allocator;
    
    // Simple contract that just does one KECCAK256 and returns
    // PUSH1 0x20, PUSH1 0x00, KECCAK256, STOP
    const simple_hash_code = [_]u8{0x60, 0x20, 0x60, 0x00, 0x20, 0x00};
    
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, null);
    defer vm.deinit();
    
    const caller = primitives.Address.from_u256(0x1000000000000000000000000000000000000001);
    const contract_address = primitives.Address.from_u256(0x2000000000000000000000000000000000000002);
    
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    try vm.state.set_code(contract_address, &simple_hash_code);
    
    const initial_gas: u64 = 100_000;
    const params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = initial_gas,
    } };
    
    const result = try vm.call(params);
    
        result.success,
        initial_gas - result.gas_left,
    });
    
    try std.testing.expect(result.success);
}