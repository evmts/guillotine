const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const revm = @import("../utils/revm/revm.zig");
const Address = @import("Address");
const Vm = @import("evm").Vm;
const Contract = @import("evm").Contract;
const Frame = @import("evm").Frame;
const MemoryDatabase = @import("evm").MemoryDatabase;
const Operation = @import("evm").Operation;
const u256 = @import("primitives").u256;

test "CREATE opcode with insufficient balance fails" {
    const allocator = testing.allocator;

    // Initialize REVM
    var revm_vm = try revm.init(allocator);
    defer revm_vm.deinit();

    const deployer = Address.ZERO;
    const value = u256{ .limbs = .{ 0, 0, 0, 1 } }; // 1 << 192, very high value

    // Contract bytecode that attempts CREATE with value
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // value (1 << 192)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (size)
        0xf0, // CREATE
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    const revm_contract_address = try revm_vm.deploy(deployer, &bytecode, 1000000);

    // Execute with REVM
    var revm_result = try revm_vm.call(deployer, revm_contract_address, &[_]u8{}, 1000000);
    defer allocator.free(revm_result.output);

    // Initialize Guillotine
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm_instance = try Vm.init(allocator, db_interface, null, null);
    defer vm_instance.deinit();

    // Deploy contract in Guillotine
    var contract = try Contract.init(allocator, &bytecode, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);

    const call_params = Vm.CallParams{
        .origin = deployer,
        .source = deployer,
        .destination = contract.target.address,
        .value = 0,
        .data = &[_]u8{},
        .gas_limit = 1000000,
        .depth = 0,
        .is_static = false,
    };

    // Execute using mini EVM
    const mini_result = try vm_instance.call_mini(call_params);
    defer if (mini_result.output) |output| allocator.free(output);

    // Execute using regular Guillotine
    const result = try vm_instance.call(call_params);
    defer if (result.output) |output| allocator.free(output);

    // All should return 0 (CREATE failed due to insufficient balance)
    const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
    try testing.expectEqual(@as(u256, 0), revm_value);

    const mini_value = std.mem.readInt(u256, mini_result.output.?[0..32], .big);
    try testing.expectEqual(revm_value, mini_value);

    const value_result = std.mem.readInt(u256, result.output.?[0..32], .big);
    try testing.expectEqual(revm_value, value_result);
}

test "CREATE2 with same salt and init code produces same address" {
    const allocator = testing.allocator;

    // Initialize REVM
    var revm_vm = try revm.init(allocator);
    defer revm_vm.deinit();

    const deployer = Address.ZERO;

    // Contract bytecode that does CREATE2 twice with same parameters
    const bytecode = [_]u8{
        // First CREATE2
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x00, // PUSH1 0 (offset - empty init code)
        0x60, 0x00, // PUSH1 0 (size - empty init code)
        0x60, 0x42, // PUSH1 0x42 (salt)
        0xf5, // CREATE2
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        
        // Second CREATE2 with same parameters (should fail)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (size)
        0x60, 0x42, // PUSH1 0x42 (same salt)
        0xf5, // CREATE2
        0x60, 0x20, // PUSH1 32
        0x52, // MSTORE
        
        0x60, 0x40, // PUSH1 64
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    const revm_contract_address = try revm_vm.deploy(deployer, &bytecode, 1000000);

    // Execute with REVM
    var revm_result = try revm_vm.call(deployer, revm_contract_address, &[_]u8{}, 1000000);
    defer allocator.free(revm_result.output);

    // Initialize Guillotine
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm_instance = try Vm.init(allocator, db_interface, null, null);
    defer vm_instance.deinit();

    // Deploy contract in Guillotine
    var contract = try Contract.init(allocator, &bytecode, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);

    const call_params = Vm.CallParams{
        .origin = deployer,
        .source = deployer,
        .destination = contract.target.address,
        .value = 0,
        .data = &[_]u8{},
        .gas_limit = 1000000,
        .depth = 0,
        .is_static = false,
    };

    // Execute using mini EVM
    const mini_result = try vm_instance.call_mini(call_params);
    defer if (mini_result.output) |output| allocator.free(output);

    // Execute using regular Guillotine
    const result = try vm_instance.call(call_params);
    defer if (result.output) |output| allocator.free(output);

    // First CREATE2 should succeed (non-zero address), second should fail (zero)
    const revm_addr1 = std.mem.readInt(u256, revm_result.output[0..32], .big);
    const revm_addr2 = std.mem.readInt(u256, revm_result.output[32..64], .big);
    try testing.expect(revm_addr1 != 0); // First CREATE2 succeeded
    try testing.expectEqual(@as(u256, 0), revm_addr2); // Second CREATE2 failed

    const mini_addr1 = std.mem.readInt(u256, mini_result.output.?[0..32], .big);
    const mini_addr2 = std.mem.readInt(u256, mini_result.output.?[32..64], .big);
    try testing.expectEqual(revm_addr1, mini_addr1);
    try testing.expectEqual(revm_addr2, mini_addr2);

    const addr1 = std.mem.readInt(u256, result.output.?[0..32], .big);
    const addr2 = std.mem.readInt(u256, result.output.?[32..64], .big);
    try testing.expectEqual(revm_addr1, addr1);
    try testing.expectEqual(revm_addr2, addr2);
}

test "CREATE in static call fails with WriteProtection" {
    const allocator = testing.allocator;

    // Initialize REVM
    var revm_vm = try revm.init(allocator);
    defer revm_vm.deinit();

    const deployer = Address.ZERO;

    // Contract bytecode that attempts CREATE
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (size)
        0xf0, // CREATE
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    const revm_contract_address = try revm_vm.deploy(deployer, &bytecode, 1000000);

    // Execute with REVM using staticcall (read-only context)
    var revm_result = try revm_vm.staticcall(deployer, revm_contract_address, &[_]u8{}, 1000000);
    defer allocator.free(revm_result.output);

    // Initialize Guillotine
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm_instance = try Vm.init(allocator, db_interface, null, null);
    defer vm_instance.deinit();

    // Deploy contract in Guillotine
    var contract = try Contract.init(allocator, &bytecode, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);

    const call_params = Vm.CallParams{
        .origin = deployer,
        .source = deployer,
        .destination = contract.target.address,
        .value = 0,
        .data = &[_]u8{},
        .gas_limit = 1000000,
        .depth = 0,
        .is_static = true, // Static call
    };

    // Execute using mini EVM
    const mini_result = try vm_instance.call_mini(call_params);
    defer if (mini_result.output) |output| allocator.free(output);

    // Execute using regular Guillotine
    const result = try vm_instance.call(call_params);
    defer if (result.output) |output| allocator.free(output);

    // All should fail (return empty output due to WriteProtection)
    try testing.expectEqual(@as(usize, 0), revm_result.output.len);
    try testing.expectEqual(@as(?[]u8, null), mini_result.output);
    try testing.expectEqual(@as(?[]u8, null), result.output);
}

test "CREATE at max call depth fails" {
    const allocator = testing.allocator;

    // Initialize REVM
    var revm_vm = try revm.init(allocator);
    defer revm_vm.deinit();

    const deployer = Address.ZERO;

    // Contract bytecode that attempts CREATE
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (size)
        0xf0, // CREATE
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    const revm_contract_address = try revm_vm.deploy(deployer, &bytecode, 1000000);

    // Execute with REVM at max depth (1024)
    var revm_result = try revm_vm.call_with_depth(deployer, revm_contract_address, &[_]u8{}, 1000000, 1024);
    defer allocator.free(revm_result.output);

    // Initialize Guillotine
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm_instance = try Vm.init(allocator, db_interface, null, null);
    defer vm_instance.deinit();

    // Deploy contract in Guillotine
    var contract = try Contract.init(allocator, &bytecode, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);

    const call_params = Vm.CallParams{
        .origin = deployer,
        .source = deployer,
        .destination = contract.target.address,
        .value = 0,
        .data = &[_]u8{},
        .gas_limit = 1000000,
        .depth = 1024, // Max depth
        .is_static = false,
    };

    // Execute using mini EVM
    const mini_result = try vm_instance.call_mini(call_params);
    defer if (mini_result.output) |output| allocator.free(output);

    // Execute using regular Guillotine
    const result = try vm_instance.call(call_params);
    defer if (result.output) |output| allocator.free(output);

    // All should return 0 (CREATE failed due to max depth)
    const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
    try testing.expectEqual(@as(u256, 0), revm_value);

    const mini_value = std.mem.readInt(u256, mini_result.output.?[0..32], .big);
    try testing.expectEqual(revm_value, mini_value);

    const value_result = std.mem.readInt(u256, result.output.?[0..32], .big);
    try testing.expectEqual(revm_value, value_result);
}

test "CREATE2 with large init code" {
    const allocator = testing.allocator;

    // Initialize REVM
    var revm_vm = try revm.init(allocator);
    defer revm_vm.deinit();

    const deployer = Address.ZERO;

    // Contract bytecode that does CREATE2 with large init code
    // First, store large data in memory, then CREATE2 with it
    const bytecode = [_]u8{
        // Store 256 bytes of 0xFF in memory
        0x7f, // PUSH32
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x7f, // PUSH32
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x60, 0x20, // PUSH1 32
        0x52, // MSTORE
        
        // CREATE2 with 64 bytes init code
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x40, // PUSH1 64 (size)
        0x60, 0x42, // PUSH1 0x42 (salt)
        0xf5, // CREATE2
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    const revm_contract_address = try revm_vm.deploy(deployer, &bytecode, 1000000);

    // Execute with REVM
    var revm_result = try revm_vm.call(deployer, revm_contract_address, &[_]u8{}, 1000000);
    defer allocator.free(revm_result.output);

    // Initialize Guillotine
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm_instance = try Vm.init(allocator, db_interface, null, null);
    defer vm_instance.deinit();

    // Deploy contract in Guillotine
    var contract = try Contract.init(allocator, &bytecode, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);

    const call_params = Vm.CallParams{
        .origin = deployer,
        .source = deployer,
        .destination = contract.target.address,
        .value = 0,
        .data = &[_]u8{},
        .gas_limit = 1000000,
        .depth = 0,
        .is_static = false,
    };

    // Execute using mini EVM
    const mini_result = try vm_instance.call_mini(call_params);
    defer if (mini_result.output) |output| allocator.free(output);

    // Execute using regular Guillotine
    const result = try vm_instance.call(call_params);
    defer if (result.output) |output| allocator.free(output);

    // All should return non-zero address (CREATE2 succeeded)
    const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
    try testing.expect(revm_value != 0);

    const mini_value = std.mem.readInt(u256, mini_result.output.?[0..32], .big);
    try testing.expectEqual(revm_value, mini_value);

    const value_result = std.mem.readInt(u256, result.output.?[0..32], .big);
    try testing.expectEqual(revm_value, value_result);
}

test "CREATE with init code that reverts" {
    const allocator = testing.allocator;

    // Initialize REVM
    var revm_vm = try revm.init(allocator);
    defer revm_vm.deinit();

    const deployer = Address.ZERO;

    // Contract bytecode that does CREATE with init code that reverts
    const bytecode = [_]u8{
        // Store init code in memory: PUSH1 0, PUSH1 0, REVERT
        0x60, 0x60, // PUSH1 0x60 (PUSH1 opcode)
        0x60, 0x00, // PUSH1 0
        0x53, // MSTORE8
        0x60, 0x00, // PUSH1 0x00 (0 value)
        0x60, 0x01, // PUSH1 1
        0x53, // MSTORE8
        0x60, 0x60, // PUSH1 0x60 (PUSH1 opcode)
        0x60, 0x02, // PUSH1 2
        0x53, // MSTORE8
        0x60, 0x00, // PUSH1 0x00 (0 value)
        0x60, 0x03, // PUSH1 3
        0x53, // MSTORE8
        0x60, 0xfd, // PUSH1 0xfd (REVERT opcode)
        0x60, 0x04, // PUSH1 4
        0x53, // MSTORE8
        
        // CREATE with reverting init code
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x05, // PUSH1 5 (size)
        0xf0, // CREATE
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    const revm_contract_address = try revm_vm.deploy(deployer, &bytecode, 1000000);

    // Execute with REVM
    var revm_result = try revm_vm.call(deployer, revm_contract_address, &[_]u8{}, 1000000);
    defer allocator.free(revm_result.output);

    // Initialize Guillotine
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm_instance = try Vm.init(allocator, db_interface, null, null);
    defer vm_instance.deinit();

    // Deploy contract in Guillotine
    var contract = try Contract.init(allocator, &bytecode, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);

    const call_params = Vm.CallParams{
        .origin = deployer,
        .source = deployer,
        .destination = contract.target.address,
        .value = 0,
        .data = &[_]u8{},
        .gas_limit = 1000000,
        .depth = 0,
        .is_static = false,
    };

    // Execute using mini EVM
    const mini_result = try vm_instance.call_mini(call_params);
    defer if (mini_result.output) |output| allocator.free(output);

    // Execute using regular Guillotine
    const result = try vm_instance.call(call_params);
    defer if (result.output) |output| allocator.free(output);

    // All should return 0 (CREATE failed due to revert)
    const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
    try testing.expectEqual(@as(u256, 0), revm_value);

    const mini_value = std.mem.readInt(u256, mini_result.output.?[0..32], .big);
    try testing.expectEqual(revm_value, mini_value);

    const value_result = std.mem.readInt(u256, result.output.?[0..32], .big);
    try testing.expectEqual(revm_value, value_result);
}