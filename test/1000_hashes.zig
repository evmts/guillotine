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

test "ten-thousand-hashes benchmark executes successfully" {
    const allocator = std.testing.allocator;

    // Load bytecode and calldata from official case
    const bytecode_hex = try readCaseFile(allocator, "ten-thousand-hashes", "bytecode.txt");
    defer allocator.free(bytecode_hex);
    const calldata_hex = try readCaseFile(allocator, "ten-thousand-hashes", "calldata.txt");
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

test "hexDecode handles various hex formats" {
    const allocator = std.testing.allocator;
    
    // Test with 0x prefix
    const hex1 = "0x68656c6c6f";
    const bytes1 = try hexDecode(allocator, hex1);
    defer allocator.free(bytes1);
    try std.testing.expectEqualStrings("hello", bytes1);
    
    // Test without 0x prefix
    const hex2 = "776f726c64";
    const bytes2 = try hexDecode(allocator, hex2);
    defer allocator.free(bytes2);
    try std.testing.expectEqualStrings("world", bytes2);
    
    // Test empty string
    const hex3 = "";
    const bytes3 = try hexDecode(allocator, hex3);
    defer allocator.free(bytes3);
    try std.testing.expectEqual(@as(usize, 0), bytes3.len);
}

test "deploy function creates contract successfully" {
    const allocator = std.testing.allocator;
    
    // Set up VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = primitives.Address.from_u256(0x1000000000000000000000000000000000000001);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Simple bytecode that returns 42
    const bytecode = &[_]u8{0x60, 0x2a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3};
    
    const contract_address = try deploy(&vm, allocator, caller, bytecode);
    
    // Verify contract was deployed
    const code = vm.state.get_code(contract_address);
    try std.testing.expect(code.len > 0);
}

test "deploy function handles deployment failure" {
    const allocator = std.testing.allocator;
    
    // Set up VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = primitives.Address.from_u256(0x1000000000000000000000000000000000000001);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Invalid bytecode that will fail deployment (REVERT immediately)
    const bytecode = &[_]u8{0xfd};
    
    const result = deploy(&vm, allocator, caller, bytecode);
    try std.testing.expectError(error.DeploymentFailed, result);
}

test "ten-thousand-hashes benchmark gas consumption" {
    const allocator = std.testing.allocator;
    
    // Load bytecode and calldata
    const bytecode_hex = try readCaseFile(allocator, "ten-thousand-hashes", "bytecode.txt");
    defer allocator.free(bytecode_hex);
    const calldata_hex = try readCaseFile(allocator, "ten-thousand-hashes", "calldata.txt");
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
    
    // Deploy and call with limited gas
    const contract_address = try deploy(&vm, allocator, caller, bytecode);
    const initial_gas: u64 = 10_000_000;
    const params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_address,
        .value = 0,
        .input = calldata,
        .gas = initial_gas,
    } };
    const call_result = try vm.call(params);
    
    try std.testing.expect(call_result.success);
    
    // Verify significant gas was consumed (10,000 hashes should use substantial gas)
    const gas_used = initial_gas - call_result.gas_left;
    try std.testing.expect(gas_used > 100_000); // Should use at least 100k gas
    
    if (call_result.output) |output| {
        if (output.len > 0) allocator.free(output);
    }
}

test "readCaseFile reads and trims files correctly" {
    const allocator = std.testing.allocator;
    
    // Read a known file
    const content = try readCaseFile(allocator, "ten-thousand-hashes", "calldata.txt");
    defer allocator.free(content);
    
    // Verify content was read and trimmed
    try std.testing.expect(content.len > 0);
    
    // Verify no leading/trailing whitespace
    try std.testing.expect(content[0] != ' ' and content[0] != '\t' and content[0] != '\n');
    try std.testing.expect(content[content.len - 1] != ' ' and content[content.len - 1] != '\t' and content[content.len - 1] != '\n');
}
