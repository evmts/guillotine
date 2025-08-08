// Auto-generated opcode comparison tests
const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const Address = @import("Address").Address;
const CallParams = Evm.Host.CallParams;
const CallResult = Evm.CallResult;
// Updated to new API - migration in progress, tests not run yet

test "REVM comparison: ADD 5 + 10 = 15" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x05, 0x60, 0x0a, 0x01, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 15
    try testing.expectEqual(@as(u256, 15), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21024), gas_used);
}

test "REVM comparison: ADD overflow MAX + 1 = 0" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0x60, 0x01, 0x01, 0x60, 0x00, 0x52, 0x60, 
        0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: SUB 100 - 58 = 42" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x64, 0x60, 0x3a, 0x03, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 115792089237316195423570985008687907853269984665640564039457584007913129639894
    try testing.expectEqual(@as(u256, 115792089237316195423570985008687907853269984665640564039457584007913129639894), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21024), gas_used);
}

test "REVM comparison: SUB underflow 5 - 10" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x05, 0x60, 0x0a, 0x03, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 5
    try testing.expectEqual(@as(u256, 5), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21024), gas_used);
}

test "REVM comparison: MUL 7 * 6 = 42" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x07, 0x60, 0x06, 0x02, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 42
    try testing.expectEqual(@as(u256, 42), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21026), gas_used);
}

test "REVM comparison: DIV 84 / 2 = 42" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x54, 0x60, 0x02, 0x04, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21026), gas_used);
}

test "REVM comparison: DIV by zero 10 / 0 = 0" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x0a, 0x60, 0x00, 0x04, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21026), gas_used);
}

test "REVM comparison: MOD 17 % 5 = 2" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x11, 0x60, 0x05, 0x06, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 5
    try testing.expectEqual(@as(u256, 5), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21026), gas_used);
}

test "REVM comparison: MOD by zero 10 % 0 = 0" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x0a, 0x60, 0x00, 0x06, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21026), gas_used);
}

test "REVM comparison: SDIV -10 / 3 = -3" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xf6, 0x60, 0x03, 0x05, 0x60, 0x00, 0x52, 0x60, 
        0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21026), gas_used);
}

test "REVM comparison: SDIV by zero -10 / 0 = 0" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xf6, 0x60, 0x00, 0x05, 0x60, 0x00, 0x52, 0x60, 
        0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21026), gas_used);
}

test "REVM comparison: SMOD -10 % 3 = -1" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xf6, 0x60, 0x03, 0x07, 0x60, 0x00, 0x52, 0x60, 
        0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 3
    try testing.expectEqual(@as(u256, 3), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21026), gas_used);
}

test "REVM comparison: SMOD by zero -10 % 0 = 0" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xf6, 0x60, 0x00, 0x07, 0x60, 0x00, 0x52, 0x60, 
        0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21026), gas_used);
}

test "REVM comparison: SDIV MIN_INT256 / -1 overflow" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x7f, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 
        0x00, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0x05, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21026), gas_used);
}

test "REVM comparison: ADDMOD (10 + 10) % 8 = 4" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x0a, 0x60, 0x0a, 0x60, 0x08, 0x08, 0x60, 
        0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 8
    try testing.expectEqual(@as(u256, 8), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21029), gas_used);
}

test "REVM comparison: ADDMOD (10 + 10) % 0 = 0" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x0a, 0x60, 0x0a, 0x60, 0x00, 0x08, 0x60, 
        0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21029), gas_used);
}

test "REVM comparison: ADDMOD MAX + MAX % 10" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0x60, 0x0a, 0x08, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 10
    try testing.expectEqual(@as(u256, 10), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21029), gas_used);
}

test "REVM comparison: MULMOD (10 * 10) % 8 = 4" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x0a, 0x60, 0x0a, 0x60, 0x08, 0x09, 0x60, 
        0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21029), gas_used);
}

test "REVM comparison: EXP 2 ** 3 = 8" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x02, 0x60, 0x03, 0x0a, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 9
    try testing.expectEqual(@as(u256, 9), result_value);
}

test "REVM comparison: SIGNEXTEND 0xFF from byte 0" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0xff, 0x0b, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21026), gas_used);
}

test "REVM comparison: LT 5 < 10 = 1" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x05, 0x60, 0x0a, 0x10, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21024), gas_used);
}

test "REVM comparison: GT 10 > 5 = 1" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x05, 0x60, 0x0a, 0x11, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1
    try testing.expectEqual(@as(u256, 1), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21024), gas_used);
}

test "REVM comparison: EQ 42 == 42 = 1" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x2a, 0x60, 0x2a, 0x14, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1
    try testing.expectEqual(@as(u256, 1), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21024), gas_used);
}

test "REVM comparison: ISZERO 0 = 1" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x15, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1
    try testing.expectEqual(@as(u256, 1), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21023), gas_used);
}

test "REVM comparison: SLT -1 < 1 = 1" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0x60, 0x01, 0x12, 0x60, 0x00, 0x52, 0x60, 
        0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21024), gas_used);
}

test "REVM comparison: SGT 1 > -1 = 1" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0x60, 0x01, 0x13, 0x60, 0x00, 0x52, 0x60, 
        0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1
    try testing.expectEqual(@as(u256, 1), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21024), gas_used);
}

test "REVM comparison: BYTE extracts byte at index" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x1f, 0x60, 0xff, 0x1a, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: AND 0xFF & 0x0F = 0x0F" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0xff, 0x60, 0x0f, 0x16, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 15
    try testing.expectEqual(@as(u256, 15), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21024), gas_used);
}

test "REVM comparison: OR 0xF0 | 0x0F = 0xFF" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0xf0, 0x60, 0x0f, 0x17, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 255
    try testing.expectEqual(@as(u256, 255), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21024), gas_used);
}

test "REVM comparison: XOR 0xFF ^ 0xF0 = 0x0F" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0xff, 0x60, 0xf0, 0x18, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 15
    try testing.expectEqual(@as(u256, 15), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21024), gas_used);
}

test "REVM comparison: NOT ~0 = MAX" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x19, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 115792089237316195423570985008687907853269984665640564039457584007913129639935
    try testing.expectEqual(@as(u256, 115792089237316195423570985008687907853269984665640564039457584007913129639935), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21023), gas_used);
}

test "REVM comparison: SHL 1 << 4 = 16" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x04, 0x60, 0x01, 0x1b, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 8
    try testing.expectEqual(@as(u256, 8), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21024), gas_used);
}

test "REVM comparison: SHR 16 >> 4 = 1" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x04, 0x60, 0x10, 0x1c, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21024), gas_used);
}

test "REVM comparison: SAR -16 >> 4 = -1" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x04, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xf0, 0x1d, 0x60, 0x00, 0x52, 0x60, 
        0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21024), gas_used);
}

test "REVM comparison: POP removes top stack item" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x42, 0x60, 0x10, 0x50, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 66
    try testing.expectEqual(@as(u256, 66), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21020), gas_used);
}

test "REVM comparison: MLOAD loads from memory" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x42, 0x60, 0x00, 0x52, 0x60, 0x00, 0x51, 
        0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 66
    try testing.expectEqual(@as(u256, 66), result_value);
}

test "REVM comparison: MSTORE stores to memory" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x42, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 
        0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 66
    try testing.expectEqual(@as(u256, 66), result_value);
}

test "REVM comparison: MSTORE8 stores single byte" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0xff, 0x60, 0x1f, 0x53, 0x60, 0x00, 0x51, 
        0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 255
    try testing.expectEqual(@as(u256, 255), result_value);
}

test "REVM comparison: MSIZE returns memory size" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x42, 0x60, 0x00, 0x52, 0x59, 0x60, 0x00, 
        0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 32
    try testing.expectEqual(@as(u256, 32), result_value);
}

test "REVM comparison: SLOAD loads from storage" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x54, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: SSTORE in call context" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x42, 0x60, 0x00, 0x55, 0x60, 0x01, 0x60, 
        0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1
    try testing.expectEqual(@as(u256, 1), result_value);
}

test "REVM comparison: JUMP to valid destination" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x05, 0x56, 0x00, 0x00, 0x5b, 0x60, 0x42, 
        0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 66
    try testing.expectEqual(@as(u256, 66), result_value);
}

test "REVM comparison: JUMPI jump taken" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x01, 0x60, 0x08, 0x57, 0x60, 0x00, 0x00, 
        0x00, 0x00, 0x5b, 0x60, 0x42, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    // REVM failed with error, we should fail too
    // REVM error: Halted: InvalidJump
    try testing.expect(!result.success);
    // Should fail with invalid jump
}

test "REVM comparison: PC returns program counter" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x58, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: GAS returns remaining gas" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x5a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 978998
    try testing.expectEqual(@as(u256, 978998), result_value);
}

test "REVM comparison: PUSH0" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x5f, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: PUSH1" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 
        0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: PUSH2" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x61, 0x00, 0x01, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1
    try testing.expectEqual(@as(u256, 1), result_value);
}

test "REVM comparison: PUSH3" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x62, 0x00, 0x01, 0x02, 0x60, 0x00, 0x52, 0x60, 
        0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 258
    try testing.expectEqual(@as(u256, 258), result_value);
}

test "REVM comparison: PUSH4" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x63, 0x00, 0x01, 0x02, 0x03, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 66051
    try testing.expectEqual(@as(u256, 66051), result_value);
}

test "REVM comparison: PUSH5" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x64, 0x00, 0x01, 0x02, 0x03, 0x04, 0x60, 0x00, 
        0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 16909060
    try testing.expectEqual(@as(u256, 16909060), result_value);
}

test "REVM comparison: PUSH6" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x65, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x60, 
        0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 4328719365
    try testing.expectEqual(@as(u256, 4328719365), result_value);
}

test "REVM comparison: PUSH7" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x66, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 
        0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1108152157446
    try testing.expectEqual(@as(u256, 1108152157446), result_value);
}

test "REVM comparison: PUSH8" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x67, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 
        0x07, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 283686952306183
    try testing.expectEqual(@as(u256, 283686952306183), result_value);
}

test "REVM comparison: PUSH9" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x68, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 
        0x07, 0x08, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 
        0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 72623859790382856
    try testing.expectEqual(@as(u256, 72623859790382856), result_value);
}

test "REVM comparison: PUSH10" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x69, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 
        0x07, 0x08, 0x09, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 18591708106338011145
    try testing.expectEqual(@as(u256, 18591708106338011145), result_value);
}

test "REVM comparison: PUSH11" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x6a, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 
        0x07, 0x08, 0x09, 0x0a, 0x60, 0x00, 0x52, 0x60, 
        0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 4759477275222530853130
    try testing.expectEqual(@as(u256, 4759477275222530853130), result_value);
}

test "REVM comparison: PUSH12" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x6b, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 
        0x07, 0x08, 0x09, 0x0a, 0x0b, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1218426182456967898401291
    try testing.expectEqual(@as(u256, 1218426182456967898401291), result_value);
}

test "REVM comparison: PUSH13" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x6c, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 
        0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x60, 0x00, 
        0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 311917102708983781990730508
    try testing.expectEqual(@as(u256, 311917102708983781990730508), result_value);
}

test "REVM comparison: PUSH14" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x6d, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 
        0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x60, 
        0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 79850778293499848189627010061
    try testing.expectEqual(@as(u256, 79850778293499848189627010061), result_value);
}

test "REVM comparison: PUSH15" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x6e, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 
        0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 
        0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 20441799243135961136544514575630
    try testing.expectEqual(@as(u256, 20441799243135961136544514575630), result_value);
}

test "REVM comparison: PUSH16" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x6f, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 
        0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 
        0x0f, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 5233100606242806050955395731361295
    try testing.expectEqual(@as(u256, 5233100606242806050955395731361295), result_value);
}

test "REVM comparison: PUSH17" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x70, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 
        0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 
        0x0f, 0x10, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 
        0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1339673755198158349044581307228491536
    try testing.expectEqual(@as(u256, 1339673755198158349044581307228491536), result_value);
}

test "REVM comparison: PUSH18" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x71, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 
        0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 
        0x0f, 0x10, 0x11, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 342956481330728537355412814650493833233
    try testing.expectEqual(@as(u256, 342956481330728537355412814650493833233), result_value);
}

test "REVM comparison: PUSH19" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x72, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 
        0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 
        0x0f, 0x10, 0x11, 0x12, 0x60, 0x00, 0x52, 0x60, 
        0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 87796859220666505562985680550526421307666
    try testing.expectEqual(@as(u256, 87796859220666505562985680550526421307666), result_value);
}

test "REVM comparison: PUSH20" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x73, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 
        0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 
        0x0f, 0x10, 0x11, 0x12, 0x13, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 22475995960490625424124334220934763854762515
    try testing.expectEqual(@as(u256, 22475995960490625424124334220934763854762515), result_value);
}

test "REVM comparison: PUSH21" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x74, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 
        0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 
        0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x60, 0x00, 
        0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 5753854965885600108575829560559299546819203860
    try testing.expectEqual(@as(u256, 5753854965885600108575829560559299546819203860), result_value);
}

test "REVM comparison: PUSH22" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x75, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 
        0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 
        0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x60, 
        0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1472986871266713627795412367503180683985716188181
    try testing.expectEqual(@as(u256, 1472986871266713627795412367503180683985716188181), result_value);
}

test "REVM comparison: PUSH23" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x76, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 
        0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 
        0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 
        0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 377084639044278688715625566080814255100343344174358
    try testing.expectEqual(@as(u256, 377084639044278688715625566080814255100343344174358), result_value);
}

test "REVM comparison: PUSH24" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x77, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 
        0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 
        0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 
        0x17, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 96533667595335344311200144916688449305687896108635671
    try testing.expectEqual(@as(u256, 96533667595335344311200144916688449305687896108635671), result_value);
}

test "REVM comparison: PUSH25" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x78, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 
        0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 
        0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 
        0x17, 0x18, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 
        0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 24712618904405848143667237098672243022256101403810731800
    try testing.expectEqual(@as(u256, 24712618904405848143667237098672243022256101403810731800), result_value);
}

test "REVM comparison: PUSH26" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x79, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 
        0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 
        0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 
        0x17, 0x18, 0x19, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 6326430439527897124778812697260094213697561959375547340825
    try testing.expectEqual(@as(u256, 6326430439527897124778812697260094213697561959375547340825), result_value);
}

test "REVM comparison: PUSH27" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x7a, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 
        0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 
        0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 
        0x17, 0x18, 0x19, 0x1a, 0x60, 0x00, 0x52, 0x60, 
        0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1619566192519141663943376050498584118706575861600140119251226
    try testing.expectEqual(@as(u256, 1619566192519141663943376050498584118706575861600140119251226), result_value);
}

test "REVM comparison: PUSH28" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x7b, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 
        0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 
        0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 
        0x17, 0x18, 0x19, 0x1a, 0x1b, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 414608945284900265969504268927637534388883420569635870528313883
    try testing.expectEqual(@as(u256, 414608945284900265969504268927637534388883420569635870528313883), result_value);
}

test "REVM comparison: PUSH29" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x7c, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 
        0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 
        0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 
        0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x60, 0x00, 
        0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 106139889992934468088193092845475208803554155665826782855248354076
    try testing.expectEqual(@as(u256, 106139889992934468088193092845475208803554155665826782855248354076), result_value);
}

test "REVM comparison: PUSH30" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x7d, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 
        0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 
        0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 
        0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x60, 
        0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 27171811838191223830577431768441653453709863850451656410943578643485
    try testing.expectEqual(@as(u256, 27171811838191223830577431768441653453709863850451656410943578643485), result_value);
}

test "REVM comparison: PUSH31" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x7e, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 
        0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 
        0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 
        0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 
        0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 6955983830576953300627822532721063284149725145715624041201556132732190
    try testing.expectEqual(@as(u256, 6955983830576953300627822532721063284149725145715624041201556132732190), result_value);
}

test "REVM comparison: PUSH32" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x7f, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 
        0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 
        0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 
        0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 
        0x1f, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1780731860627700044960722568376592200742329637303199754547598369979440671
    try testing.expectEqual(@as(u256, 1780731860627700044960722568376592200742329637303199754547598369979440671), result_value);
}

test "REVM comparison: DUP1" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x01, 0x80, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1
    try testing.expectEqual(@as(u256, 1), result_value);
}

test "REVM comparison: DUP2" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x02, 0x60, 0x01, 0x81, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 2
    try testing.expectEqual(@as(u256, 2), result_value);
}

test "REVM comparison: DUP3" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x03, 0x60, 0x02, 0x60, 0x01, 0x82, 0x60, 
        0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 3
    try testing.expectEqual(@as(u256, 3), result_value);
}

test "REVM comparison: DUP4" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x04, 0x60, 0x03, 0x60, 0x02, 0x60, 0x01, 
        0x83, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 4
    try testing.expectEqual(@as(u256, 4), result_value);
}

test "REVM comparison: DUP5" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x05, 0x60, 0x04, 0x60, 0x03, 0x60, 0x02, 
        0x60, 0x01, 0x84, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 5
    try testing.expectEqual(@as(u256, 5), result_value);
}

test "REVM comparison: DUP6" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x06, 0x60, 0x05, 0x60, 0x04, 0x60, 0x03, 
        0x60, 0x02, 0x60, 0x01, 0x85, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 6
    try testing.expectEqual(@as(u256, 6), result_value);
}

test "REVM comparison: DUP7" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x07, 0x60, 0x06, 0x60, 0x05, 0x60, 0x04, 
        0x60, 0x03, 0x60, 0x02, 0x60, 0x01, 0x86, 0x60, 
        0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 7
    try testing.expectEqual(@as(u256, 7), result_value);
}

test "REVM comparison: DUP8" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x08, 0x60, 0x07, 0x60, 0x06, 0x60, 0x05, 
        0x60, 0x04, 0x60, 0x03, 0x60, 0x02, 0x60, 0x01, 
        0x87, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 8
    try testing.expectEqual(@as(u256, 8), result_value);
}

test "REVM comparison: DUP9" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x09, 0x60, 0x08, 0x60, 0x07, 0x60, 0x06, 
        0x60, 0x05, 0x60, 0x04, 0x60, 0x03, 0x60, 0x02, 
        0x60, 0x01, 0x88, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 9
    try testing.expectEqual(@as(u256, 9), result_value);
}

test "REVM comparison: DUP10" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x0a, 0x60, 0x09, 0x60, 0x08, 0x60, 0x07, 
        0x60, 0x06, 0x60, 0x05, 0x60, 0x04, 0x60, 0x03, 
        0x60, 0x02, 0x60, 0x01, 0x89, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 10
    try testing.expectEqual(@as(u256, 10), result_value);
}

test "REVM comparison: DUP11" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x0b, 0x60, 0x0a, 0x60, 0x09, 0x60, 0x08, 
        0x60, 0x07, 0x60, 0x06, 0x60, 0x05, 0x60, 0x04, 
        0x60, 0x03, 0x60, 0x02, 0x60, 0x01, 0x8a, 0x60, 
        0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 11
    try testing.expectEqual(@as(u256, 11), result_value);
}

test "REVM comparison: DUP12" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x0c, 0x60, 0x0b, 0x60, 0x0a, 0x60, 0x09, 
        0x60, 0x08, 0x60, 0x07, 0x60, 0x06, 0x60, 0x05, 
        0x60, 0x04, 0x60, 0x03, 0x60, 0x02, 0x60, 0x01, 
        0x8b, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 12
    try testing.expectEqual(@as(u256, 12), result_value);
}

test "REVM comparison: DUP13" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x0d, 0x60, 0x0c, 0x60, 0x0b, 0x60, 0x0a, 
        0x60, 0x09, 0x60, 0x08, 0x60, 0x07, 0x60, 0x06, 
        0x60, 0x05, 0x60, 0x04, 0x60, 0x03, 0x60, 0x02, 
        0x60, 0x01, 0x8c, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 13
    try testing.expectEqual(@as(u256, 13), result_value);
}

test "REVM comparison: DUP14" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x0e, 0x60, 0x0d, 0x60, 0x0c, 0x60, 0x0b, 
        0x60, 0x0a, 0x60, 0x09, 0x60, 0x08, 0x60, 0x07, 
        0x60, 0x06, 0x60, 0x05, 0x60, 0x04, 0x60, 0x03, 
        0x60, 0x02, 0x60, 0x01, 0x8d, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 14
    try testing.expectEqual(@as(u256, 14), result_value);
}

test "REVM comparison: DUP15" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x0f, 0x60, 0x0e, 0x60, 0x0d, 0x60, 0x0c, 
        0x60, 0x0b, 0x60, 0x0a, 0x60, 0x09, 0x60, 0x08, 
        0x60, 0x07, 0x60, 0x06, 0x60, 0x05, 0x60, 0x04, 
        0x60, 0x03, 0x60, 0x02, 0x60, 0x01, 0x8e, 0x60, 
        0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 15
    try testing.expectEqual(@as(u256, 15), result_value);
}

test "REVM comparison: DUP16" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x10, 0x60, 0x0f, 0x60, 0x0e, 0x60, 0x0d, 
        0x60, 0x0c, 0x60, 0x0b, 0x60, 0x0a, 0x60, 0x09, 
        0x60, 0x08, 0x60, 0x07, 0x60, 0x06, 0x60, 0x05, 
        0x60, 0x04, 0x60, 0x03, 0x60, 0x02, 0x60, 0x01, 
        0x8f, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 16
    try testing.expectEqual(@as(u256, 16), result_value);
}

test "REVM comparison: SWAP1" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x01, 0x90, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: SWAP2" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x01, 0x60, 0x02, 0x91, 0x60, 
        0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: SWAP3" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x01, 0x60, 0x02, 0x60, 0x03, 
        0x92, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: SWAP4" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x01, 0x60, 0x02, 0x60, 0x03, 
        0x60, 0x04, 0x93, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: SWAP5" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x01, 0x60, 0x02, 0x60, 0x03, 
        0x60, 0x04, 0x60, 0x05, 0x94, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: SWAP6" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x01, 0x60, 0x02, 0x60, 0x03, 
        0x60, 0x04, 0x60, 0x05, 0x60, 0x06, 0x95, 0x60, 
        0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: SWAP7" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x01, 0x60, 0x02, 0x60, 0x03, 
        0x60, 0x04, 0x60, 0x05, 0x60, 0x06, 0x60, 0x07, 
        0x96, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: SWAP8" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x01, 0x60, 0x02, 0x60, 0x03, 
        0x60, 0x04, 0x60, 0x05, 0x60, 0x06, 0x60, 0x07, 
        0x60, 0x08, 0x97, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: SWAP9" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x01, 0x60, 0x02, 0x60, 0x03, 
        0x60, 0x04, 0x60, 0x05, 0x60, 0x06, 0x60, 0x07, 
        0x60, 0x08, 0x60, 0x09, 0x98, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: SWAP10" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x01, 0x60, 0x02, 0x60, 0x03, 
        0x60, 0x04, 0x60, 0x05, 0x60, 0x06, 0x60, 0x07, 
        0x60, 0x08, 0x60, 0x09, 0x60, 0x0a, 0x99, 0x60, 
        0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: SWAP11" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x01, 0x60, 0x02, 0x60, 0x03, 
        0x60, 0x04, 0x60, 0x05, 0x60, 0x06, 0x60, 0x07, 
        0x60, 0x08, 0x60, 0x09, 0x60, 0x0a, 0x60, 0x0b, 
        0x9a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: SWAP12" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x01, 0x60, 0x02, 0x60, 0x03, 
        0x60, 0x04, 0x60, 0x05, 0x60, 0x06, 0x60, 0x07, 
        0x60, 0x08, 0x60, 0x09, 0x60, 0x0a, 0x60, 0x0b, 
        0x60, 0x0c, 0x9b, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: SWAP13" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x01, 0x60, 0x02, 0x60, 0x03, 
        0x60, 0x04, 0x60, 0x05, 0x60, 0x06, 0x60, 0x07, 
        0x60, 0x08, 0x60, 0x09, 0x60, 0x0a, 0x60, 0x0b, 
        0x60, 0x0c, 0x60, 0x0d, 0x9c, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: SWAP14" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x01, 0x60, 0x02, 0x60, 0x03, 
        0x60, 0x04, 0x60, 0x05, 0x60, 0x06, 0x60, 0x07, 
        0x60, 0x08, 0x60, 0x09, 0x60, 0x0a, 0x60, 0x0b, 
        0x60, 0x0c, 0x60, 0x0d, 0x60, 0x0e, 0x9d, 0x60, 
        0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: SWAP15" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x01, 0x60, 0x02, 0x60, 0x03, 
        0x60, 0x04, 0x60, 0x05, 0x60, 0x06, 0x60, 0x07, 
        0x60, 0x08, 0x60, 0x09, 0x60, 0x0a, 0x60, 0x0b, 
        0x60, 0x0c, 0x60, 0x0d, 0x60, 0x0e, 0x60, 0x0f, 
        0x9e, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: SWAP16" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x01, 0x60, 0x02, 0x60, 0x03, 
        0x60, 0x04, 0x60, 0x05, 0x60, 0x06, 0x60, 0x07, 
        0x60, 0x08, 0x60, 0x09, 0x60, 0x0a, 0x60, 0x0b, 
        0x60, 0x0c, 0x60, 0x0d, 0x60, 0x0e, 0x60, 0x0f, 
        0x60, 0x10, 0x9f, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: LOG0" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x42, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 
        0x00, 0xa0, 0x60, 0x01, 0x60, 0x00, 0x52, 0x60, 
        0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1
    try testing.expectEqual(@as(u256, 1), result_value);
}

test "REVM comparison: LOG1" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x42, 0x60, 0x00, 0x52, 0x60, 0xaa, 0x60, 
        0x20, 0x60, 0x00, 0xa1, 0x60, 0x01, 0x60, 0x00, 
        0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1
    try testing.expectEqual(@as(u256, 1), result_value);
}

test "REVM comparison: LOG2" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x42, 0x60, 0x00, 0x52, 0x60, 0xaa, 0x60, 
        0xaa, 0x60, 0x20, 0x60, 0x00, 0xa2, 0x60, 0x01, 
        0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1
    try testing.expectEqual(@as(u256, 1), result_value);
}

test "REVM comparison: LOG3" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x42, 0x60, 0x00, 0x52, 0x60, 0xaa, 0x60, 
        0xaa, 0x60, 0xaa, 0x60, 0x20, 0x60, 0x00, 0xa3, 
        0x60, 0x01, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 
        0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1
    try testing.expectEqual(@as(u256, 1), result_value);
}

test "REVM comparison: LOG4" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x42, 0x60, 0x00, 0x52, 0x60, 0xaa, 0x60, 
        0xaa, 0x60, 0xaa, 0x60, 0xaa, 0x60, 0x20, 0x60, 
        0x00, 0xa4, 0x60, 0x01, 0x60, 0x00, 0x52, 0x60, 
        0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1
    try testing.expectEqual(@as(u256, 1), result_value);
}

test "REVM comparison: RETURN" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x42, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 
        0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 66
    try testing.expectEqual(@as(u256, 66), result_value);
}

test "REVM comparison: REVERT" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x00, 0xfd, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    // REVM failed with error, we should fail too
    // REVM error: Reverted: 0x
    try testing.expect(!result.success);
    try testing.expect(result.is_revert);
}

test "REVM comparison: CODECOPY copies code to memory" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x03, 0x60, 0x00, 0x60, 0x00, 0x39, 0x60, 
        0x00, 0x51, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 
        0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 43427996572837200330951463007322972794967162007767166728780254423896786206720
    try testing.expectEqual(@as(u256, 43427996572837200330951463007322972794967162007767166728780254423896786206720), result_value);
}

test "REVM comparison: ADDRESS" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x30, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 292300327466180583640736966543256603931186508595
    try testing.expectEqual(@as(u256, 292300327466180583640736966543256603931186508595), result_value);
}

test "REVM comparison: CALLER" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x33, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 97433442488726861213578988847752201310395502865
    try testing.expectEqual(@as(u256, 97433442488726861213578988847752201310395502865), result_value);
}

test "REVM comparison: CALLVALUE" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x34, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: CALLDATASIZE" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x36, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: CODESIZE" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x38, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 9
    try testing.expectEqual(@as(u256, 9), result_value);
}

test "REVM comparison: GASPRICE" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x3a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: BLOCKHASH" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x40, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: COINBASE" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x41, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: TIMESTAMP" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x42, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1
    try testing.expectEqual(@as(u256, 1), result_value);
}

test "REVM comparison: NUMBER" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x43, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: DIFFICULTY" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x44, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: GASLIMIT" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x45, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 115792089237316195423570985008687907853269984665640564039457584007913129639935
    try testing.expectEqual(@as(u256, 115792089237316195423570985008687907853269984665640564039457584007913129639935), result_value);
}

test "REVM comparison: CHAINID" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x46, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1
    try testing.expectEqual(@as(u256, 1), result_value);
}

test "REVM comparison: SELFBALANCE" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x47, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: BASEFEE" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x48, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: KECCAK256 empty" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x00, 0x20, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 89477152217924674838424037953991966239322087453347756267410168184682657981552
    try testing.expectEqual(@as(u256, 89477152217924674838424037953991966239322087453347756267410168184682657981552), result_value);
}

test "REVM comparison: KECCAK256 hello" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x68, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x00, 0x00, 
        0x00, 0x00, 0x60, 0x00, 0x52, 0x60, 0x05, 0x60, 
        0x00, 0x20, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 
        0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 88691373886691830474546593511551865147992741123997168990340854445980345442540
    try testing.expectEqual(@as(u256, 88691373886691830474546593511551865147992741123997168990340854445980345442540), result_value);
}

test "REVM comparison: CALL basic" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 
        0x60, 0x00, 0x60, 0x00, 0x5a, 0xf1, 0x60, 0x00, 
        0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1
    try testing.expectEqual(@as(u256, 1), result_value);
}

test "REVM comparison: DELEGATECALL" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 
        0x60, 0x00, 0x5a, 0xf4, 0x60, 0x00, 0x52, 0x60, 
        0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1
    try testing.expectEqual(@as(u256, 1), result_value);
}

test "REVM comparison: STATICCALL" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 
        0x60, 0x00, 0x5a, 0xfa, 0x60, 0x00, 0x52, 0x60, 
        0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1
    try testing.expectEqual(@as(u256, 1), result_value);
}

test "REVM comparison: CALLCODE" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 
        0x60, 0x00, 0x60, 0x00, 0x5a, 0xf2, 0x60, 0x00, 
        0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1
    try testing.expectEqual(@as(u256, 1), result_value);
}

test "REVM comparison: CREATE" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x42, 0x60, 0x00, 0x52, 0x60, 0x0a, 0x60, 
        0x16, 0x52, 0x60, 0x00, 0x60, 0x16, 0x60, 0x0a, 
        0xf0, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: CREATE2" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 
        0xf5, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 519858980732727385752209233171042092800462541852
    try testing.expectEqual(@as(u256, 519858980732727385752209233171042092800462541852), result_value);
}

test "REVM comparison: CALLDATALOAD" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x35, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: CALLDATACOPY" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x20, 0x60, 0x00, 0x60, 0x00, 0x37, 0x60, 
        0x00, 0x51, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 
        0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: RETURNDATASIZE" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x3d, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: RETURNDATACOPY empty" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x3e, 0x60, 
        0x01, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1
    try testing.expectEqual(@as(u256, 1), result_value);
}

test "REVM comparison: EXTCODESIZE" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x3b, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: EXTCODECOPY" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 
        0x3c, 0x60, 0x01, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1
    try testing.expectEqual(@as(u256, 1), result_value);
}

test "REVM comparison: EXTCODEHASH" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x3f, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: BALANCE" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x31, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: ORIGIN" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x32, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 97433442488726861213578988847752201310395502865
    try testing.expectEqual(@as(u256, 97433442488726861213578988847752201310395502865), result_value);
}

test "REVM comparison: MCOPY" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x42, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 
        0x00, 0x60, 0x20, 0x5e, 0x60, 0x20, 0x51, 0x60, 
        0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 66
    try testing.expectEqual(@as(u256, 66), result_value);
}

test "REVM comparison: TLOAD" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x5c, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: TSTORE" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x42, 0x60, 0x00, 0x5d, 0x60, 0x00, 0x5c, 
        0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 66
    try testing.expectEqual(@as(u256, 66), result_value);
}

test "REVM comparison: BLOBHASH" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x49, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: BLOBBASEFEE" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x4a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1
    try testing.expectEqual(@as(u256, 1), result_value);
}

test "REVM comparison: STOP" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x42, 0x60, 0x00, 0x52, 0x00, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
}

test "REVM comparison: INVALID" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0xfe, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    // REVM failed with error, we should fail too
    // REVM error: Halted: InvalidFEOpcode
    try testing.expect(!result.success);
    // Should fail with invalid opcode
}

test "REVM comparison: JUMPDEST" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x5b, 0x60, 0x42, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 66
    try testing.expectEqual(@as(u256, 66), result_value);
}

test "REVM comparison: SELFDESTRUCT" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0xff, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
}

test "REVM comparison: Precompile ecrecover" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x80, 0x60, 0x00, 0x60, 0x20, 0x60, 0x00, 
        0x60, 0x00, 0x60, 0x01, 0x5a, 0xf1, 0x60, 0x00, 
        0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1
    try testing.expectEqual(@as(u256, 1), result_value);
}

test "REVM comparison: Precompile SHA256" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x00, 0x60, 0x20, 0x60, 0x00, 
        0x60, 0x00, 0x60, 0x02, 0x5a, 0xf1, 0x60, 0x00, 
        0x51, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: Precompile RIPEMD160" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x00, 0x60, 0x20, 0x60, 0x00, 
        0x60, 0x00, 0x60, 0x03, 0x5a, 0xf1, 0x60, 0x00, 
        0x51, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: Precompile identity" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x42, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 
        0x00, 0x60, 0x20, 0x60, 0x20, 0x60, 0x00, 0x60, 
        0x04, 0x5a, 0xf1, 0x60, 0x20, 0x51, 0x60, 0x00, 
        0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: Precompile modexp" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x01, 0x60, 0x00, 0x52, 0x60, 0x01, 0x60, 
        0x20, 0x52, 0x60, 0x01, 0x60, 0x40, 0x52, 0x60, 
        0x02, 0x60, 0x60, 0x52, 0x60, 0x03, 0x60, 0x80, 
        0x52, 0x60, 0x05, 0x60, 0xa0, 0x52, 0x60, 0x20, 
        0x60, 0xc0, 0x60, 0xc0, 0x60, 0x00, 0x60, 0x00, 
        0x60, 0x05, 0x5a, 0xf1, 0x60, 0xc0, 0x51, 0x60, 
        0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: Precompile ecAdd" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x80, 0x60, 0x00, 0x60, 0x40, 0x60, 0x00, 
        0x60, 0x00, 0x60, 0x06, 0x5a, 0xf1, 0x60, 0x00, 
        0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1
    try testing.expectEqual(@as(u256, 1), result_value);
}

test "REVM comparison: Precompile ecMul" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x60, 0x60, 0x00, 0x60, 0x40, 0x60, 0x00, 
        0x60, 0x00, 0x60, 0x07, 0x5a, 0xf1, 0x60, 0x00, 
        0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1
    try testing.expectEqual(@as(u256, 1), result_value);
}

test "REVM comparison: Precompile ecPairing" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x00, 0x60, 0x20, 0x60, 0x00, 
        0x60, 0x00, 0x60, 0x08, 0x5a, 0xf1, 0x60, 0x00, 
        0x51, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: Precompile blake2f" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x01, 0x60, 0x03, 0x53, 0x61, 0x00, 0xd5, 
        0x60, 0x00, 0x60, 0x40, 0x61, 0x01, 0x00, 0x60, 
        0x00, 0x60, 0x09, 0x5a, 0xf1, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: MULMOD 10 * 10 % 0" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x0a, 0x60, 0x0a, 0x60, 0x00, 0x09, 0x60, 
        0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
    
    // Check gas usage
    const gas_used = 1_000_000 - result.gas_left;
    try testing.expectEqual(@as(u64, 21029), gas_used);
}

test "REVM comparison: MULMOD MAX * 2 % 3" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0x60, 0x02, 0x60, 0x03, 0x09, 0x60, 0x00, 
        0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 6
    try testing.expectEqual(@as(u256, 6), result_value);
}

test "REVM comparison: EXP 2 ** 256" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x02, 0x61, 0x01, 0x00, 0x0a, 0x60, 0x00, 
        0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 65536
    try testing.expectEqual(@as(u256, 65536), result_value);
}

test "REVM comparison: EXP 0 ** 0" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x00, 0x0a, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1
    try testing.expectEqual(@as(u256, 1), result_value);
}

test "REVM comparison: BYTE index 32" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x20, 0x60, 0xff, 0x1a, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: SIGNEXTEND byte 31" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x1f, 0x7f, 0x80, 0x00, 0x00, 0x00, 0x00, 
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 
        0x00, 0x00, 0x00, 0x0b, 0x60, 0x00, 0x52, 0x60, 
        0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 31
    try testing.expectEqual(@as(u256, 31), result_value);
}

test "REVM comparison: MLOAD at large offset" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x61, 0xff, 0xff, 0x51, 0x60, 0x00, 0x52, 0x60, 
        0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: ADD with empty stack" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x01, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    // REVM failed with error, we should fail too
    // REVM error: Halted: StackUnderflow
    try testing.expect(!result.success);
    // Should halt execution
}

test "REVM comparison: Stack depth 1024" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 
        0x60, 0x01, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    // REVM failed with error, we should fail too
    // REVM error: Halted: StackOverflow
    try testing.expect(!result.success);
    // Should halt execution
}

test "REVM comparison: JUMP to non-JUMPDEST" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x04, 0x56, 0x60, 0x42, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    // REVM failed with error, we should fail too
    // REVM error: Halted: InvalidJump
    try testing.expect(!result.success);
    // Should fail with invalid jump
}

test "REVM comparison: JUMPI with MAX condition" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x07, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0x57, 0x00, 0x5b, 0x60, 0x42, 
        0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    // REVM failed with error, we should fail too
    // REVM error: Halted: InvalidJump
    try testing.expect(!result.success);
    // Should fail with invalid jump
}

test "REVM comparison: CALLDATACOPY beyond data" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x20, 0x60, 0x10, 0x60, 0x00, 0x37, 0x60, 
        0x00, 0x51, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 
        0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: RETURNDATACOPY no data" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x01, 0x60, 0x00, 0x60, 0x00, 0x3e, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    // REVM failed with error, we should fail too
    // REVM error: Halted: OutOfOffset
    try testing.expect(!result.success);
    // Should halt execution
}

test "REVM comparison: CREATE2 address calc" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x42, 
        0xf5, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 
        0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: EXTCODEHASH empty" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x3f, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: BLOCKHASH future block" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x61, 0xff, 0xff, 0x40, 0x60, 0x00, 0x52, 0x60, 
        0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: SHL shift > 256" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x01, 0x61, 0x01, 0x00, 0x1b, 0x60, 0x00, 
        0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: SHR shift > 256" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0x61, 0x01, 0x00, 0x1c, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: SAR shift > 256 negative" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0x61, 0x01, 0x00, 0x1d, 0x60, 0x00, 0x52, 
        0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 115792089237316195423570985008687907853269984665640564039457584007913129639935
    try testing.expectEqual(@as(u256, 115792089237316195423570985008687907853269984665640564039457584007913129639935), result_value);
}

test "REVM comparison: ECRECOVER invalid sig" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0x60, 0x00, 0x52, 0x60, 0x80, 0x60, 
        0x00, 0x60, 0x20, 0x60, 0x80, 0x60, 0x00, 0x60, 
        0x01, 0x5a, 0xf1, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 1
    try testing.expectEqual(@as(u256, 1), result_value);
}

test "REVM comparison: MSTORE8 at odd offset" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0xff, 0x60, 0x13, 0x53, 0x60, 0x00, 0x51, 
        0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 20203181441137406086353707335680
    try testing.expectEqual(@as(u256, 20203181441137406086353707335680), result_value);
}

test "REVM comparison: ADDMOD MAX + MAX % MAX" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0x08, 0x60, 0x00, 0x52, 0x60, 
        0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: CODECOPY beyond code" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x20, 0x61, 0xff, 0xff, 0x60, 0x00, 0x39, 
        0x60, 0x00, 0x51, 0x60, 0x00, 0x52, 0x60, 0x20, 
        0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: EXTCODECOPY non-existent" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x20, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 
        0x3c, 0x60, 0x00, 0x51, 0x60, 0x00, 0x52, 0x60, 
        0x20, 0x60, 0x00, 0xf3, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.success);
    
    // Check output
    try testing.expect(result.output != null);
    const output = result.output.?;
    try testing.expectEqual(@as(usize, 32), output.len);
    
    // Convert output to u256
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, output[0..32]);
    const result_value = std.mem.readInt(u256, &bytes, .big);
    
    // REVM produced: 0
    try testing.expectEqual(@as(u256, 0), result_value);
}

test "REVM comparison: RETURNDATALOAD no data" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x60, 0x00, 0xf7, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    // REVM failed with error, we should fail too
    // REVM error: Halted: OpcodeNotFound
    try testing.expect(!result.success);
    // Should halt execution
}

test "REVM comparison: Insufficient gas for MSTORE" {
    const allocator = testing.allocator;
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    const bytecode = &[_]u8{
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0x60, 0x42, 0x81, 0x52, 
    };
    
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    // REVM failed with error, we should fail too
    // REVM error: Halted: OutOfGas(InvalidOperand)
    try testing.expect(!result.success);
    // Should fail with invalid opcode
}

