const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");

test {
    std.testing.log_level = .debug;
}

fn hexDecode(allocator: std.mem.Allocator, hex_str: []const u8) ![]u8 {
    const clean_hex = if (std.mem.startsWith(u8, hex_str, "0x")) hex_str[2..] else hex_str;
    const result = try allocator.alloc(u8, clean_hex.len / 2);
    _ = try std.fmt.hexToBytes(result, clean_hex);
    return result;
}

fn readCaseFile(allocator: std.mem.Allocator, comptime case_name: []const u8, comptime file_name: []const u8) ![]u8 {
    const path = "/Users/williamcory/guillotine/bench/official/cases/" ++ case_name ++ "/" ++ file_name;
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

fn deploy(vm: *evm.Evm, allocator: std.mem.Allocator, caller: primitives.Address.Address, bytecode: []const u8) !primitives.Address.Address {
    const create_result = try vm.create_contract(caller, 0, bytecode, 10_000_000);
    if (create_result.output) |out| {
        defer allocator.free(out);
    }
    if (!create_result.success) {
        std.debug.print("TEST FAILURE: deploy failed, success=false, gas_left={}\n", .{create_result.gas_left});
        return error.DeploymentFailed;
    }
    return create_result.address;
}

test "snailtracer benchmark executes successfully" {
    const allocator = std.testing.allocator;

    // Load bytecode and calldata from official case
    const bytecode_hex = try readCaseFile(allocator, "snailtracer", "bytecode.txt");
    defer allocator.free(bytecode_hex);
    const calldata_hex = try readCaseFile(allocator, "snailtracer", "calldata.txt");
    defer allocator.free(calldata_hex);

    const bytecode = try hexDecode(allocator, bytecode_hex);
    defer allocator.free(bytecode);
    const calldata = try hexDecode(allocator, calldata_hex);
    defer allocator.free(calldata);

    // Set up VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Caller and funding
    const caller = primitives.Address.from_u256(0x1000000000000000000000000000000000000001);
    try vm.state.set_balance(caller, std.math.maxInt(u256));

    // Deploy and call
    const contract_address = try deploy(&vm, allocator, caller, bytecode);
    const params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_address,
        .value = 0,
        .input = calldata,
        .gas = 1_000_000_000,
    } };
    const call_result = try vm.call(params);

    try std.testing.expect(call_result.success);
    if (call_result.output) |output| {
        if (output.len > 0) allocator.free(output);
    }
}

test "snailtracer benchmark high gas consumption" {
    const allocator = std.testing.allocator;

    // Load bytecode and calldata
    const bytecode_hex = try readCaseFile(allocator, "snailtracer", "bytecode.txt");
    defer allocator.free(bytecode_hex);
    const calldata_hex = try readCaseFile(allocator, "snailtracer", "calldata.txt");
    defer allocator.free(calldata_hex);

    const bytecode = try hexDecode(allocator, bytecode_hex);
    defer allocator.free(bytecode);
    const calldata = try hexDecode(allocator, calldata_hex);
    defer allocator.free(calldata);

    // Set up VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const caller = primitives.Address.from_u256(0x1000000000000000000000000000000000000001);
    try vm.state.set_balance(caller, std.math.maxInt(u256));

    // Deploy and call with gas tracking
    const contract_address = try deploy(&vm, allocator, caller, bytecode);
    const initial_gas: u64 = 100_000_000;
    const params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_address,
        .value = 0,
        .input = calldata,
        .gas = initial_gas,
    } };
    const call_result = try vm.call(params);

    try std.testing.expect(call_result.success);
    
    // Snailtracer is computationally intensive - should use significant gas
    const gas_used = initial_gas - call_result.gas_left;
    try std.testing.expect(gas_used > 1_000_000); // Should use at least 1M gas

    if (call_result.output) |output| {
        if (output.len > 0) allocator.free(output);
    }
}

test "snailtracer produces expected output format" {
    const allocator = std.testing.allocator;

    // Load bytecode and calldata
    const bytecode_hex = try readCaseFile(allocator, "snailtracer", "bytecode.txt");
    defer allocator.free(bytecode_hex);
    const calldata_hex = try readCaseFile(allocator, "snailtracer", "calldata.txt");
    defer allocator.free(calldata_hex);

    const bytecode = try hexDecode(allocator, bytecode_hex);
    defer allocator.free(bytecode);
    const calldata = try hexDecode(allocator, calldata_hex);
    defer allocator.free(calldata);

    // Set up VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const caller = primitives.Address.from_u256(0x1000000000000000000000000000000000000001);
    try vm.state.set_balance(caller, std.math.maxInt(u256));

    // Deploy and call
    const contract_address = try deploy(&vm, allocator, caller, bytecode);
    const params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_address,
        .value = 0,
        .input = calldata,
        .gas = 1_000_000_000,
    } };
    const call_result = try vm.call(params);

    try std.testing.expect(call_result.success);
    
    // Snailtracer should produce output
    if (call_result.output) |output| {
        try std.testing.expect(output.len > 0);
        allocator.free(output);
    } else {
        return error.NoOutput;
    }
}

test "snailtracer bytecode size validation" {
    const allocator = std.testing.allocator;

    const bytecode_hex = try readCaseFile(allocator, "snailtracer", "bytecode.txt");
    defer allocator.free(bytecode_hex);

    const bytecode = try hexDecode(allocator, bytecode_hex);
    defer allocator.free(bytecode);

    // Snailtracer is a complex contract - should have substantial bytecode
    try std.testing.expect(bytecode.len > 1000); // At least 1KB
    try std.testing.expect(bytecode.len < 100_000); // Less than 100KB
}

test "snailtracer deployment gas requirements" {
    const allocator = std.testing.allocator;

    const bytecode_hex = try readCaseFile(allocator, "snailtracer", "bytecode.txt");
    defer allocator.free(bytecode_hex);

    const bytecode = try hexDecode(allocator, bytecode_hex);
    defer allocator.free(bytecode);

    // Set up VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const caller = primitives.Address.from_u256(0x1000000000000000000000000000000000000001);
    try vm.state.set_balance(caller, std.math.maxInt(u256));

    // Track deployment gas
    const initial_gas: u64 = 10_000_000;
    const create_result = try vm.create_contract(caller, 0, bytecode, initial_gas);
    
    if (create_result.output) |out| {
        defer allocator.free(out);
    }
    
    try std.testing.expect(create_result.success);
    
    // Verify deployment consumed reasonable gas
    const gas_used = initial_gas - create_result.gas_left;
    try std.testing.expect(gas_used > 50_000); // Deployment should use significant gas
    try std.testing.expect(gas_used < initial_gas); // But not all of it
}


