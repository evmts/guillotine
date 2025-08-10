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

fn readCaseFileRuntime(allocator: std.mem.Allocator, case_name: []const u8, file_name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "/Users/williamcory/guillotine/bench/official/cases/{s}/{s}", .{ case_name, file_name });
    defer allocator.free(path);
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

test "erc20 transfer benchmark executes successfully" {
    const allocator = std.testing.allocator;

    // Load bytecode and calldata from official case (erc20-transfer)
    const bytecode_hex = try readCaseFile(allocator, "erc20-transfer", "bytecode.txt");
    defer allocator.free(bytecode_hex);
    const calldata_hex = try readCaseFile(allocator, "erc20-transfer", "calldata.txt");
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

test "erc20 mint benchmark executes successfully" {
    const allocator = std.testing.allocator;

    // Load bytecode and calldata from official case (erc20-mint)
    const bytecode_hex = try readCaseFile(allocator, "erc20-mint", "bytecode.txt");
    defer allocator.free(bytecode_hex);
    const calldata_hex = try readCaseFile(allocator, "erc20-mint", "calldata.txt");
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

test "erc20 approval-transfer benchmark executes successfully" {
    const allocator = std.testing.allocator;

    // Load bytecode and calldata from official case (erc20-approval-transfer)
    const bytecode_hex = try readCaseFile(allocator, "erc20-approval-transfer", "bytecode.txt");
    defer allocator.free(bytecode_hex);
    const calldata_hex = try readCaseFile(allocator, "erc20-approval-transfer", "calldata.txt");
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

test "erc20 benchmark gas usage patterns" {
    const allocator = std.testing.allocator;

    // Test gas consumption for different ERC20 operations
    const test_cases = [_]struct {
        name: []const u8,
        expected_min_gas: u64,
    }{
        .{ .name = "erc20-transfer", .expected_min_gas = 20_000 },
        .{ .name = "erc20-mint", .expected_min_gas = 20_000 },
        .{ .name = "erc20-approval-transfer", .expected_min_gas = 40_000 },
    };

    for (test_cases) |test_case| {
        // Load bytecode and calldata
        const bytecode_hex = try readCaseFileRuntime(allocator, test_case.name, "bytecode.txt");
        defer allocator.free(bytecode_hex);
        const calldata_hex = try readCaseFileRuntime(allocator, test_case.name, "calldata.txt");
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
        
        const gas_used = initial_gas - call_result.gas_left;
        try std.testing.expect(gas_used >= test_case.expected_min_gas);

        if (call_result.output) |output| {
            if (output.len > 0) allocator.free(output);
        }
    }
}

test "erc20 deployment validates bytecode size" {
    const allocator = std.testing.allocator;

    // Verify ERC20 contracts have reasonable bytecode size
    const test_cases = [_][]const u8{
        "erc20-transfer",
        "erc20-mint",
        "erc20-approval-transfer",
    };

    for (test_cases) |case_name| {
        const bytecode_hex = try readCaseFileRuntime(allocator, case_name, "bytecode.txt");
        defer allocator.free(bytecode_hex);

        const bytecode = try hexDecode(allocator, bytecode_hex);
        defer allocator.free(bytecode);

        // ERC20 bytecode should be substantial but not enormous
        try std.testing.expect(bytecode.len > 100); // At least 100 bytes
        try std.testing.expect(bytecode.len < 50_000); // Less than 50KB
    }
}

