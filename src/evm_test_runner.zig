const std = @import("std");
const Evm = @import("evm");
const Address = @import("primitives").Address;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    if (args.len < 2) {
        std.debug.print("Usage: {s} <bytecode_hex> [calldata_hex]\n", .{args[0]});
        std.process.exit(1);
    }
    
    // Parse bytecode hex
    const bytecode_hex = args[1];
    const bytecode = try hexToBytes(allocator, bytecode_hex);
    defer allocator.free(bytecode);
    
    // Parse calldata hex if provided
    var calldata: []const u8 = &[_]u8{};
    if (args.len > 2) {
        calldata = try hexToBytes(allocator, args[2]);
    }
    defer if (args.len > 2) allocator.free(calldata);
    
    // Set up EVM
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(
        allocator,
        db_interface,
        null, // table
        null, // chain_rules
        null, // context
        0, // depth
        false, // read_only
        null, // tracer
    );
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract_address = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Deploy bytecode
    try vm.state.set_code(contract_address, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    // Call contract
    const result = try vm.call_contract(
        caller,
        contract_address,
        0,
        calldata,
        1_000_000,
        false
    );
    defer if (result.output) |output| allocator.free(output);
    
    // Output results in a parseable format
    std.debug.print("success: {}\n", .{result.success});
    std.debug.print("gas_left: {}\n", .{result.gas_left});
    
    if (result.output) |output| {
        std.debug.print("output: ", .{});
        for (output) |byte| {
            std.debug.print("{x:0>2}", .{byte});
        }
        std.debug.print("\n", .{});
    } else {
        std.debug.print("output: \n", .{});
    }
}

fn hexToBytes(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    var start: usize = 0;
    if (hex.len >= 2 and std.mem.eql(u8, hex[0..2], "0x")) {
        start = 2;
    }
    
    const clean_hex = hex[start..];
    if (clean_hex.len % 2 != 0) {
        return error.OddLength;
    }
    
    const bytes = try allocator.alloc(u8, clean_hex.len / 2);
    
    var i: usize = 0;
    while (i < clean_hex.len) : (i += 2) {
        const byte_str = clean_hex[i..i+2];
        bytes[i/2] = try std.fmt.parseInt(u8, byte_str, 16);
    }
    
    return bytes;
}