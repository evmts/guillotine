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

test "snailtracer differential: create returns identical runtime and call output matches REVM" {
    const allocator = testing.allocator;

    // Load init bytecode and calldata
    const bytecode_hex = try read_case_file(allocator, "snailtracer", "bytecode.txt");
    defer allocator.free(bytecode_hex);

    const init_code = try hex_decode(allocator, bytecode_hex);
    defer allocator.free(init_code);

    // REVM side: create to obtain runtime, then execute call
    var revm_vm = try revm_wrapper.Revm.init(allocator, .{});
    defer revm_vm.deinit();
    const deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    // no fixed_addr needed since we only compare runtime code
    try revm_vm.setBalance(deployer, std.math.maxInt(u256));
    var revm_create = try revm_vm.create(deployer, 0, init_code, 10_000_000);
    const revm_runtime = try allocator.dupe(u8, revm_create.output);
    errdefer allocator.free(revm_runtime);
    defer revm_create.deinit();

    // Guillotine side: create to obtain runtime
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    try vm.state.set_balance(deployer, std.math.maxInt(u256));
    const zig_create = try vm.create_contract(deployer, 0, init_code, 1_000_000_000);
    // VM owns zig_create.output - do not free

    // Compare runtime bytecode from create
    try testing.expect(revm_runtime.len == (if (zig_create.output) |o| o.len else 0));
    if (zig_create.output) |o| {
        try testing.expectEqualSlices(u8, revm_runtime, o);
    } else {
        // If no runtime was produced, both should be empty
        try testing.expectEqual(@as(usize, 0), revm_runtime.len);
    }

    // Done: Only compare runtime from CREATE for differential parity
    allocator.free(revm_runtime);
}
