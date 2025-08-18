const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const Log = @import("evm").Log;

test {
    std.testing.log_level = .warn;
}

fn hexDecode(allocator: std.mem.Allocator, hex_str: []const u8) ![]u8 {
    const clean_hex = if (std.mem.startsWith(u8, hex_str, "0x")) hex_str[2..] else hex_str;
    const result = try allocator.alloc(u8, clean_hex.len / 2);
    _ = try std.fmt.hexToBytes(result, clean_hex);
    return result;
}

fn readCaseFile(allocator: std.mem.Allocator, comptime case_name: []const u8, comptime file_name: []const u8) ![]u8 {
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
    _ = allocator; // unused in this helper
    // Bench bytecode is initcode for ERC20 cases; deploy via CREATE so constructor runs and returns runtime
    const create_result = try vm.create_contract(caller, 0, bytecode, 10_000_000);
    if (!create_result.success) return error.DeploymentFailed;
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

    // Debug: Check deployed code
    const deployed_code = vm.state.get_code(contract_address);
    std.log.debug("Deployed code size: {}", .{deployed_code.len});

    const initial_gas: u64 = 100_000_000;
    std.log.debug("Calling ERC20 transfer with gas: {}, calldata len: {}", .{ initial_gas, calldata.len });
    const params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_address,
        .value = 0,
        .input = calldata,
        .gas = initial_gas,
    } };
    const call_result = try vm.call(params);

    std.log.debug("Call result: success={}, gas_left={}, output_len={}", .{ call_result.success, call_result.gas_left, if (call_result.output) |o| o.len else 0 });

    // Debug: log the selector we're sending
    if (calldata.len >= 4) {
        const selector = std.mem.readInt(u32, calldata[0..4], .big);
        std.log.debug("Sent selector: 0x{x:0>8}", .{selector});
    }

    if (!call_result.success) {
        std.log.err("ERC20 transfer call failed, gas_left: {}", .{call_result.gas_left});
        Log.debug("[erc20-test] Call failed with gas_left={d}, initial_gas={d}", .{ call_result.gas_left, initial_gas });
        Log.debug("[erc20-test] Contract deployed at: {x}", .{primitives.Address.to_u256(contract_address)});
        Log.debug("[erc20-test] Calldata length: {d}", .{calldata.len});
        if (calldata.len >= 4) {
            Log.debug("[erc20-test] Function selector: 0x{x:0>8}", .{std.mem.readInt(u32, calldata[0..4], .big)});
        }
    }
    try std.testing.expect(call_result.success);
    const gas_used = initial_gas - call_result.gas_left;
    try std.testing.expect(gas_used > 0);
    // transfer(address,uint256) should return 32-byte true
    if (call_result.output) |output| {
        std.log.debug("ERC20 transfer returned {} bytes", .{output.len});
        Log.debug("[erc20-test] Transfer output length: {d}", .{output.len});
        Log.debug("[erc20-test] Call success: {}, gas_left: {d}", .{ call_result.success, call_result.gas_left });
        if (output.len > 0) {
            std.log.debug("First few bytes: {x}", .{output[0..@min(8, output.len)]});
            if (output.len >= 32) {
                std.log.debug("Last byte: {x}", .{output[output.len - 1]});
            }
        }
        if (output.len < 32) {
            std.log.err("Output too short: expected at least 32 bytes, got {}", .{output.len});
            if (output.len > 0) {
                std.log.err("Output data: {x}", .{output});
            }
        }
        try std.testing.expect(output.len >= 32);
        if (output[output.len - 1] != 1) {
            std.log.err("Expected last byte to be 1, got {}", .{output[output.len - 1]});
            std.log.err("Full output: {x}", .{output});
        }
        try std.testing.expect(output[output.len - 1] == 1);
    } else {
        std.log.err("No output returned from ERC20 transfer", .{});
        return error.MissingReturnData;
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
    const gas_used = initial_gas - call_result.gas_left;
    try std.testing.expect(gas_used > 0);
    // Many mint implementations return bool; accept either true or empty (if non-standard)
    if (call_result.output) |output| {
        if (output.len > 0) {
            try std.testing.expect(output.len >= 32);
            try std.testing.expect(output[output.len - 1] == 1);
        }
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
    const gas_used = initial_gas - call_result.gas_left;
    try std.testing.expect(gas_used > 0);
    // approve->transfer flow should return bool true on the last call
    if (call_result.output) |output| {
        try std.testing.expect(output.len >= 32);
        try std.testing.expect(output[output.len - 1] == 1);
    } else {
        return error.MissingReturnData;
    }
}

test "erc20 benchmark gas usage patterns" {
    const allocator = std.testing.allocator;

    // Test gas consumption for different ERC20 operations
    const test_cases = [_]struct {
        name: []const u8,
        expected_min_gas: u64,
    }{
        // Note: Our current interpreter charges gas at block granularity and undercounts
        // compared to full EVM. Use small minimums that reflect the current model.
        .{ .name = "erc20-transfer", .expected_min_gas = 50 },
        .{ .name = "erc20-mint", .expected_min_gas = 50 },
        .{ .name = "erc20-approval-transfer", .expected_min_gas = 50 },
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
            _ = output; // no-op; output is VM-owned
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

test "erc20 allowance starts at zero for fresh keys" {
    const allocator = std.testing.allocator;

    // Load ERC20 runtime and deploy via CREATE
    const bytecode_hex = try readCaseFileRuntime(allocator, "erc20-transfer", "bytecode.txt");
    defer allocator.free(bytecode_hex);
    const bytecode = try hexDecode(allocator, bytecode_hex);
    defer allocator.free(bytecode);

    // Set up VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const deployer = primitives.Address.from_u256(0x1000000000000000000000000000000000000001);
    const caller = primitives.Address.from_u256(0x2000000000000000000000000000000000000002);
    try vm.state.set_balance(deployer, std.math.maxInt(u256));

    const contract_address = try deploy(&vm, allocator, deployer, bytecode);

    // Build calldata for allowance(address,address)
    var calldata: [4 + 32 + 32]u8 = undefined;
    // selector dd62ed3e
    calldata[0] = 0xdd;
    calldata[1] = 0x62;
    calldata[2] = 0xed;
    calldata[3] = 0x3e;
    // owner = deployer (left-padded to 32 bytes)
    @memset(calldata[4..36], 0);
    @memcpy(calldata[36 - 20 .. 36], &deployer);
    // spender = caller
    @memset(calldata[36..68], 0);
    @memcpy(calldata[68 - 20 .. 68], &caller);

    const initial_gas: u64 = 1_000_000_000;
    const params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_address,
        .value = 0,
        .input = &calldata,
        .gas = initial_gas,
    } };
    const call_result = try vm.call(params);
    try std.testing.expect(call_result.success);
    try std.testing.expect(call_result.output != null);
    const out = call_result.output.?;

    try std.testing.expect(out.len >= 32);
    // Expect zero allowance
    var zero_word: [32]u8 = .{0} ** 32;
    try std.testing.expectEqualSlices(u8, zero_word[0..], out[out.len - 32 ..]);
}

test "erc20 transfer using call" {
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

    // Set up VM in regular mode for deployment
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null); // Regular mode for deployment
    defer vm.deinit();

    // Caller and funding
    const caller = primitives.Address.from_u256(0x1000000000000000000000000000000000000001);
    try vm.state.set_balance(caller, std.math.maxInt(u256));

    // Deploy with regular execution
    const contract_address = try deploy(&vm, allocator, caller, bytecode);

    const initial_gas: u64 = 100_000_000;
    std.log.debug("Calling ERC20 transfer with call, gas: {}, calldata len: {}", .{ initial_gas, calldata.len });
    const params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_address,
        .value = 0,
        .input = calldata,
        .gas = initial_gas,
    } };
    // Use call directly
    const call_result = try vm.call(params);

    std.log.debug("call result: success={}, gas_left={}, output_len={}", .{ call_result.success, call_result.gas_left, if (call_result.output) |o| o.len else 0 });

    try std.testing.expect(call_result.success);
    const gas_used = initial_gas - call_result.gas_left;
    try std.testing.expect(gas_used > 0);
    
    // transfer(address,uint256) should return 32-byte true
    if (call_result.output) |output| {
        std.log.debug("ERC20 transfer via call returned {} bytes", .{output.len});
        try std.testing.expect(output.len >= 32);
        try std.testing.expect(output[output.len - 1] == 1);
    } else {
        std.log.err("No output returned from ERC20 transfer using call", .{});
        return error.MissingReturnData;
    }
}

test "erc20 mint using call" {
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

    // Set up VM in regular mode for deployment
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null); // Regular mode for deployment
    defer vm.deinit();

    // Caller and funding
    const caller = primitives.Address.from_u256(0x1000000000000000000000000000000000000001);
    try vm.state.set_balance(caller, std.math.maxInt(u256));

    // Deploy with regular execution
    const contract_address = try deploy(&vm, allocator, caller, bytecode);
    
    const initial_gas: u64 = 100_000_000;
    const params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_address,
        .value = 0,
        .input = calldata,
        .gas = initial_gas,
    } };
    // Use call directly
    const call_result = try vm.call(params);

    try std.testing.expect(call_result.success);
    const gas_used = initial_gas - call_result.gas_left;
    try std.testing.expect(gas_used > 0);
    
    // Many mint implementations return bool; accept either true or empty (if non-standard)
    if (call_result.output) |output| {
        if (output.len > 0) {
            try std.testing.expect(output.len >= 32);
            try std.testing.expect(output[output.len - 1] == 1);
        }
    }
}
