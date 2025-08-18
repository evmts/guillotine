const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const revm_wrapper = @import("revm");

test {
    std.testing.log_level = .warn;
}

fn hex_decode(allocator: std.mem.Allocator, hex_str: []const u8) ![]u8 {
    const clean_hex = if (std.mem.startsWith(u8, hex_str, "0x")) hex_str[2..] else hex_str;
    const result = try allocator.alloc(u8, clean_hex.len / 2);
    _ = try std.fmt.hexToBytes(result, clean_hex);
    return result;
}

fn read_case_file(allocator: std.mem.Allocator, comptime case_name: []const u8, comptime file_name: []const u8) ![]u8 {
    const path = "/Users/williamcory/Guillotine/bench/official/cases/" ++ case_name ++ "/" ++ file_name;
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 16 * 1024 * 1024);
    const trimmed = std.mem.trim(u8, content, " \t\n\r");
    if (trimmed.ptr == content.ptr and trimmed.len == content.len) {
        return content;
    }
    defer allocator.free(content);
    const result = try allocator.alloc(u8, trimmed.len);
    @memcpy(result, trimmed);
    return result;
}

test "call2 differential: ERC20 transfer with REVM, call, call, and call2" {
    const allocator = testing.allocator;

    // Load bytecode and calldata
    const bytecode_hex = try read_case_file(allocator, "erc20-transfer", "bytecode.txt");
    defer allocator.free(bytecode_hex);
    
    const calldata_hex = try read_case_file(allocator, "erc20-transfer", "calldata.txt");
    defer allocator.free(calldata_hex);

    const init_code = try hex_decode(allocator, bytecode_hex);
    defer allocator.free(init_code);
    
    const calldata = try hex_decode(allocator, calldata_hex);
    defer allocator.free(calldata);

    const deployer = try Address.from_hex("0x1000000000000000000000000000000000000001");
    const contract_addr = try Address.from_hex("0x5FbDB2315678afecb367f032d93F642f64180aa3");

    // === REVM Reference Implementation ===
    var revm_vm = try revm_wrapper.Revm.init(allocator, .{});
    defer revm_vm.deinit();
    
    try revm_vm.setBalance(deployer, std.math.maxInt(u256));
    
    // Deploy contract with REVM
    var revm_create = try revm_vm.create(deployer, 0, init_code, 10_000_000);
    defer revm_create.deinit();
    const revm_runtime = try allocator.dupe(u8, revm_create.output);
    defer allocator.free(revm_runtime);
    
    // Set up ERC20 state for REVM
    try revm_vm.setCode(contract_addr, revm_runtime);
    
    // Give tokens to the deployer (slot calculation for balanceOf mapping)
    var caller_slot_data: [64]u8 = undefined;
    @memset(&caller_slot_data, 0);
    @memcpy(caller_slot_data[12..32], &deployer);
    @memset(caller_slot_data[32..64], 0);
    
    var caller_slot_hash: [32]u8 = undefined;
    const Keccak256 = std.crypto.hash.sha3.Keccak256;
    Keccak256.hash(&caller_slot_data, &caller_slot_hash, .{});
    const slot_key = std.mem.readInt(u256, &caller_slot_hash, .big);
    
    const balance: u256 = 10_000_000 * std.math.pow(u256, 10, 18);
    try revm_vm.setStorage(contract_addr, slot_key, balance);
    try revm_vm.setStorage(contract_addr, 2, balance); // total supply
    
    // Call with REVM
    var revm_result = try revm_vm.call(deployer, contract_addr, 0, calldata, 10_000_000);
    defer revm_result.deinit();
    
    const revm_success = revm_result.success;
    const revm_output = try allocator.dupe(u8, revm_result.output);
    defer allocator.free(revm_output);
    const revm_gas_used = revm_result.gas_used;

    std.log.debug("REVM: success={}, gas_used={}, output_len={}", .{ revm_success, revm_gas_used, revm_output.len });

    // === Guillotine - Standard call ===
    {
        var memory_db = evm.MemoryDatabase.init(allocator);
        defer memory_db.deinit();
        var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
        defer vm.deinit();
        
        try vm.state.set_balance(deployer, std.math.maxInt(u256));
        
        // Deploy and get runtime
        const zig_create = try vm.create_contract(deployer, 0, init_code, 10_000_000);
        try testing.expect(zig_create.output != null);
        const zig_runtime = try allocator.dupe(u8, zig_create.output.?);
        defer allocator.free(zig_runtime);
        
        // Set up contract and ERC20 state
        try vm.state.set_code(contract_addr, zig_runtime);
        try vm.state.set_storage(contract_addr, slot_key, balance);
        try vm.state.set_storage(contract_addr, 2, balance);
        
        // Call with standard interpreter
        const call_params = evm.CallParams{ .call = .{
            .caller = deployer,
            .to = contract_addr,
            .value = 0,
            .input = calldata,
            .gas = 10_000_000,
        } };
        
        const call_result = try vm.call(call_params);
        const call_gas_used = 10_000_000 - call_result.gas_left;
        
        std.log.debug("call: success={}, gas_used={}, output_len={}", .{ call_result.success, call_gas_used, if (call_result.output) |o| o.len else 0 });
        
        // Verify against REVM
        try testing.expectEqual(revm_success, call_result.success);
        try testing.expectEqualSlices(u8, revm_output, call_result.output orelse &.{});
        
        // Don't free output - it's VM-owned memory per CallResult documentation
    }

    // === Guillotine - call ===
    {
        var memory_db = evm.MemoryDatabase.init(allocator);
        defer memory_db.deinit();
        var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
        defer vm.deinit();
        
        try vm.state.set_balance(deployer, std.math.maxInt(u256));
        
        // Deploy and get runtime
        const zig_create = try vm.create_contract(deployer, 0, init_code, 10_000_000);
        try testing.expect(zig_create.output != null);
        const zig_runtime = try allocator.dupe(u8, zig_create.output.?);
        defer allocator.free(zig_runtime);
        
        // Set up contract and ERC20 state
        try vm.state.set_code(contract_addr, zig_runtime);
        try vm.state.set_storage(contract_addr, slot_key, balance);
        try vm.state.set_storage(contract_addr, 2, balance);
        
        // Call with call interpreter
        const call_params = evm.CallParams{ .call = .{
            .caller = deployer,
            .to = contract_addr,
            .value = 0,
            .input = calldata,
            .gas = 10_000_000,
        } };
        
        const call_result = try vm.call(call_params);
        const call_gas_used = 10_000_000 - call_result.gas_left;
        
        std.log.debug("call: success={}, gas_used={}, output_len={}", .{ call_result.success, call_gas_used, if (call_result.output) |o| o.len else 0 });
        
        // Verify against REVM
        try testing.expectEqual(revm_success, call_result.success);
        try testing.expectEqualSlices(u8, revm_output, call_result.output orelse &.{});
        
        // Don't free output - it's VM-owned memory per CallResult documentation
    }

    // === Guillotine - call2 with interpret2 ===
    {
        var memory_db = evm.MemoryDatabase.init(allocator);
        defer memory_db.deinit();
        var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
        defer vm.deinit();
        
        try vm.state.set_balance(deployer, std.math.maxInt(u256));
        
        // Deploy and get runtime
        const zig_create = try vm.create_contract(deployer, 0, init_code, 10_000_000);
        try testing.expect(zig_create.output != null);
        const zig_runtime = try allocator.dupe(u8, zig_create.output.?);
        defer allocator.free(zig_runtime);
        
        // Set up contract and ERC20 state
        try vm.state.set_code(contract_addr, zig_runtime);
        try vm.state.set_storage(contract_addr, slot_key, balance);
        try vm.state.set_storage(contract_addr, 2, balance);
        
        // Call with call2/interpret2
        const call_params = evm.CallParams{ .call = .{
            .caller = deployer,
            .to = contract_addr,
            .value = 0,
            .input = calldata,
            .gas = 10_000_000,
        } };
        
        const call2_result = try vm.call2(call_params);
        const call2_gas_used = 10_000_000 - call2_result.gas_left;
        
        std.log.debug("call2: success={}, gas_used={}, output_len={}", .{ call2_result.success, call2_gas_used, if (call2_result.output) |o| o.len else 0 });
        
        // Verify against REVM
        try testing.expectEqual(revm_success, call2_result.success);
        try testing.expectEqualSlices(u8, revm_output, call2_result.output orelse &.{});
        
        // Don't free output - it's VM-owned memory per CallResult documentation
    }
}

test "call2 differential: ten-thousand-hashes with REVM, call, call, and call2" {
    const allocator = testing.allocator;

    // Load bytecode and calldata
    const bytecode_hex = try read_case_file(allocator, "ten-thousand-hashes", "bytecode.txt");
    defer allocator.free(bytecode_hex);
    
    const calldata_hex = try read_case_file(allocator, "ten-thousand-hashes", "calldata.txt");
    defer allocator.free(calldata_hex);

    const init_code = try hex_decode(allocator, bytecode_hex);
    defer allocator.free(init_code);
    
    const calldata = try hex_decode(allocator, calldata_hex);
    defer allocator.free(calldata);

    const deployer = try Address.from_hex("0x1000000000000000000000000000000000000001");
    const contract_addr = try Address.from_hex("0x5FbDB2315678afecb367f032d93F642f64180aa3");

    // === REVM Reference Implementation ===
    var revm_vm = try revm_wrapper.Revm.init(allocator, .{});
    defer revm_vm.deinit();
    
    try revm_vm.setBalance(deployer, std.math.maxInt(u256));
    
    // Deploy contract with REVM
    var revm_create = try revm_vm.create(deployer, 0, init_code, 10_000_000);
    defer revm_create.deinit();
    const revm_runtime = try allocator.dupe(u8, revm_create.output);
    defer allocator.free(revm_runtime);
    
    // Set up contract
    try revm_vm.setCode(contract_addr, revm_runtime);
    
    // Call with REVM
    var revm_result = try revm_vm.call(deployer, contract_addr, 0, calldata, 10_000_000);
    defer revm_result.deinit();
    
    const revm_success = revm_result.success;
    const revm_output = try allocator.dupe(u8, revm_result.output);
    defer allocator.free(revm_output);
    const revm_gas_used = revm_result.gas_used;

    std.log.debug("REVM: success={}, gas_used={}, output_len={}", .{ revm_success, revm_gas_used, revm_output.len });

    // === Guillotine - Standard call ===
    {
        var memory_db = evm.MemoryDatabase.init(allocator);
        defer memory_db.deinit();
        var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
        defer vm.deinit();
        
        try vm.state.set_balance(deployer, std.math.maxInt(u256));
        
        // Deploy and get runtime
        const zig_create = try vm.create_contract(deployer, 0, init_code, 10_000_000);
        try testing.expect(zig_create.output != null);
        const zig_runtime = try allocator.dupe(u8, zig_create.output.?);
        defer allocator.free(zig_runtime);
        
        // Set up contract
        try vm.state.set_code(contract_addr, zig_runtime);
        
        // Call with standard interpreter
        const call_params = evm.CallParams{ .call = .{
            .caller = deployer,
            .to = contract_addr,
            .value = 0,
            .input = calldata,
            .gas = 10_000_000,
        } };
        
        const call_result = try vm.call(call_params);
        const call_gas_used = 10_000_000 - call_result.gas_left;
        
        std.log.debug("call: success={}, gas_used={}, output_len={}", .{ call_result.success, call_gas_used, if (call_result.output) |o| o.len else 0 });
        
        // Verify against REVM
        try testing.expectEqual(revm_success, call_result.success);
        try testing.expectEqualSlices(u8, revm_output, call_result.output orelse &.{});
        
        // Don't free output - it's VM-owned memory per CallResult documentation
    }

    // === Guillotine - call ===
    {
        var memory_db = evm.MemoryDatabase.init(allocator);
        defer memory_db.deinit();
        var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
        defer vm.deinit();
        
        try vm.state.set_balance(deployer, std.math.maxInt(u256));
        
        // Deploy and get runtime
        const zig_create = try vm.create_contract(deployer, 0, init_code, 10_000_000);
        try testing.expect(zig_create.output != null);
        const zig_runtime = try allocator.dupe(u8, zig_create.output.?);
        defer allocator.free(zig_runtime);
        
        // Set up contract
        try vm.state.set_code(contract_addr, zig_runtime);
        
        // Call with call interpreter
        const call_params = evm.CallParams{ .call = .{
            .caller = deployer,
            .to = contract_addr,
            .value = 0,
            .input = calldata,
            .gas = 10_000_000,
        } };
        
        const call_result = try vm.call(call_params);
        const call_gas_used = 10_000_000 - call_result.gas_left;
        
        std.log.debug("call: success={}, gas_used={}, output_len={}", .{ call_result.success, call_gas_used, if (call_result.output) |o| o.len else 0 });
        
        // Verify against REVM
        try testing.expectEqual(revm_success, call_result.success);
        try testing.expectEqualSlices(u8, revm_output, call_result.output orelse &.{});
        
        // Don't free output - it's VM-owned memory per CallResult documentation
    }

    // === Guillotine - call2 with interpret2 ===
    {
        var memory_db = evm.MemoryDatabase.init(allocator);
        defer memory_db.deinit();
        var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
        defer vm.deinit();
        
        try vm.state.set_balance(deployer, std.math.maxInt(u256));
        
        // Deploy and get runtime
        const zig_create = try vm.create_contract(deployer, 0, init_code, 10_000_000);
        try testing.expect(zig_create.output != null);
        const zig_runtime = try allocator.dupe(u8, zig_create.output.?);
        defer allocator.free(zig_runtime);
        
        // Set up contract
        try vm.state.set_code(contract_addr, zig_runtime);
        
        // Call with call2/interpret2
        const call_params = evm.CallParams{ .call = .{
            .caller = deployer,
            .to = contract_addr,
            .value = 0,
            .input = calldata,
            .gas = 10_000_000,
        } };
        
        const call2_result = try vm.call2(call_params);
        const call2_gas_used = 10_000_000 - call2_result.gas_left;
        
        std.log.debug("call2: success={}, gas_used={}, output_len={}", .{ call2_result.success, call2_gas_used, if (call2_result.output) |o| o.len else 0 });
        
        // Verify against REVM
        try testing.expectEqual(revm_success, call2_result.success);
        try testing.expectEqualSlices(u8, revm_output, call2_result.output orelse &.{});
        
        // Don't free output - it's VM-owned memory per CallResult documentation
    }
}