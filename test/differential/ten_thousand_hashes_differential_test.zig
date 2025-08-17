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

test "ten-thousand-hashes differential: runtime and output match REVM" {
    const allocator = testing.allocator;

    // Load init bytecode and calldata
    const bytecode_hex = try read_case_file(allocator, "ten-thousand-hashes", "bytecode.txt");
    defer allocator.free(bytecode_hex);
    
    const calldata_hex = try read_case_file(allocator, "ten-thousand-hashes", "calldata.txt");
    defer allocator.free(calldata_hex);

    const init_code = try hex_decode(allocator, bytecode_hex);
    defer allocator.free(init_code);
    
    const calldata = try hex_decode(allocator, calldata_hex);
    defer allocator.free(calldata);

    const deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    const contract_addr = try Address.from_hex("0x5FbDB2315678afecb367f032d93F642f64180aa3");

    // REVM create + call
    var revm_vm = try revm_wrapper.Revm.init(allocator, .{});
    defer revm_vm.deinit();
    try revm_vm.setBalance(deployer, std.math.maxInt(u256));
    
    // Deploy with REVM
    var revm_create = try revm_vm.create(deployer, 0, init_code, 10_000_000);
    defer revm_create.deinit();
    const revm_runtime = try allocator.dupe(u8, revm_create.output);
    defer allocator.free(revm_runtime);
    
    // Set up contract and call with REVM
    try revm_vm.setCode(contract_addr, revm_runtime);
    var revm_result = try revm_vm.call(deployer, contract_addr, 0, calldata, 10_000_000);
    defer revm_result.deinit();
    
    const revm_success = revm_result.success;
    const revm_output = try allocator.dupe(u8, revm_result.output);
    defer allocator.free(revm_output);

    // Guillotine create + call
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    try vm.state.set_balance(deployer, std.math.maxInt(u256));
    
    // Deploy with Guillotine
    const zig_create = try vm.create_contract(deployer, 0, init_code, 10_000_000);
    try testing.expect(zig_create.output != null);
    const zig_runtime = try allocator.dupe(u8, zig_create.output.?);
    defer allocator.free(zig_runtime);
    
    // Verify runtime matches
    try testing.expectEqualSlices(u8, revm_runtime, zig_runtime);
    
    // Set up contract and call with Guillotine using call2
    try vm.state.set_code(contract_addr, zig_runtime);
    
    const call_params = evm.CallParams{ .call = .{
        .caller = deployer,
        .to = contract_addr,
        .value = 0,
        .input = calldata,
        .gas = 10_000_000,
    } };
    
    // This should reproduce the interpret2 panic
    const call2_result = try vm.call2(call_params);
    
    // Verify results match REVM
    try testing.expectEqual(revm_success, call2_result.success);
    try testing.expectEqualSlices(u8, revm_output, call2_result.output orelse &.{});
}
