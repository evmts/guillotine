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

fn read_case_file(allocator: std.mem.Allocator, case_name: []const u8, file_name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "/Users/williamcory/Guillotine/bench/official/cases/{s}/{s}", .{ case_name, file_name });
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

fn run_case(case_name: []const u8) !void {
    const allocator = testing.allocator;

    const bytecode_hex = try read_case_file(allocator, case_name, "bytecode.txt");
    defer allocator.free(bytecode_hex);

    const init_code = try hex_decode(allocator, bytecode_hex);
    defer allocator.free(init_code);

    // REVM: create to get runtime and then call
    var revm_vm = try revm_wrapper.Revm.init(allocator, .{});
    defer revm_vm.deinit();
    const deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    // no fixed_addr needed; we only compare runtimes
    try revm_vm.setBalance(deployer, std.math.maxInt(u256));
    var revm_create = try revm_vm.create(deployer, 0, init_code, 10_000_000);
    const revm_runtime = try allocator.dupe(u8, revm_create.output);
    defer revm_create.deinit();
    // Only compare runtime bytecode; skip calling as ERC20 constructors set storage

    // Guillotine: create and then call
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    try vm.state.set_balance(deployer, std.math.maxInt(u256));
    const zig_create = try vm.create_contract(deployer, 0, init_code, 1_000_000_000);
    // VM owns zig_create.output - do not free
    // Compare runtime lengths/content
    try testing.expect(zig_create.output != null);
    try testing.expectEqual(@as(usize, revm_runtime.len), zig_create.output.?.len);
    try testing.expectEqualSlices(u8, revm_runtime, zig_create.output.?);

    allocator.free(revm_runtime);
}

fn run_case_with_call2(case_name: []const u8) !void {
    const allocator = testing.allocator;

    const bytecode_hex = try read_case_file(allocator, case_name, "bytecode.txt");
    defer allocator.free(bytecode_hex);

    const init_code = try hex_decode(allocator, bytecode_hex);
    defer allocator.free(init_code);

    // Load calldata if available
    const calldata_hex = read_case_file(allocator, case_name, "calldata.txt") catch "";
    defer if (calldata_hex.len > 0) allocator.free(calldata_hex);

    const calldata = if (calldata_hex.len > 0) try hex_decode(allocator, calldata_hex) else &[_]u8{};
    defer if (calldata.len > 0) allocator.free(calldata);

    // REVM: create to get runtime and then call
    var revm_vm = try revm_wrapper.Revm.init(allocator, .{});
    defer revm_vm.deinit();
    const deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    _ = try Address.from_hex("0x5FbDB2315678afecb367f032d93F642f64180aa3");
    try revm_vm.setBalance(deployer, std.math.maxInt(u256));

    // Deploy with REVM
    var revm_create = try revm_vm.create(deployer, 0, init_code, 10_000_000);
    const revm_runtime = try allocator.dupe(u8, revm_create.output);
    defer allocator.free(revm_runtime);
    defer revm_create.deinit();

    // Guillotine: create with call2
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    try vm.state.set_balance(deployer, std.math.maxInt(u256));

    // Use call2 for contract creation
    const create_params = evm.CallParams{ .create = .{
        .caller = deployer,
        .value = 0,
        .init_code = init_code,
        .gas = 10_000_000,
    } };

    const create_result = try vm.call2(create_params);

    // Compare runtime if creation succeeded
    if (create_result.success) {
        if (create_result.output) |output| {
            try testing.expectEqual(@as(usize, revm_runtime.len), output.len);
            try testing.expectEqualSlices(u8, revm_runtime, output);
        } else {
            return error.NoOutputFromCreate;
        }
    } else {
        return error.CreationFailed;
    }

    // Don't free output - it's VM-owned memory per CallResult documentation
    _ = create_result.output;
}

test "erc20 differential: erc20-transfer" {
    try run_case("erc20-transfer");
}
test "erc20 differential: erc20-mint" {
    try run_case("erc20-mint");
}
test "erc20 differential: erc20-approval-transfer" {
    try run_case("erc20-approval-transfer");
}

// Tests with call2
test "erc20 differential with call2: erc20-transfer" {
    try run_case_with_call2("erc20-transfer");
}
test "erc20 differential with call2: erc20-mint" {
    try run_case_with_call2("erc20-mint");
}
test "erc20 differential with call2: erc20-approval-transfer" {
    try run_case_with_call2("erc20-approval-transfer");
}
