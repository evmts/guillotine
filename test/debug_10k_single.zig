const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");

// Force debug logging for this test
pub fn main() !void {
    // Set up allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();


    // Read bytecode and calldata
    const bytecode_path = "/Users/williamcory/Guillotine/bench/official/cases/ten-thousand-hashes/bytecode.txt";
    const calldata_path = "/Users/williamcory/Guillotine/bench/official/cases/ten-thousand-hashes/calldata.txt";

    const bytecode_file = try std.fs.openFileAbsolute(bytecode_path, .{});
    defer bytecode_file.close();
    const bytecode_hex = try bytecode_file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(bytecode_hex);

    const calldata_file = try std.fs.openFileAbsolute(calldata_path, .{});
    defer calldata_file.close();
    const calldata_hex = try calldata_file.readToEndAlloc(allocator, 1024);
    defer allocator.free(calldata_hex);

    // Trim and decode
    const bytecode_trimmed = std.mem.trim(u8, bytecode_hex, " \t\n\r");
    const calldata_trimmed = std.mem.trim(u8, calldata_hex, " \t\n\r");

    const bytecode = try hexDecode(allocator, bytecode_trimmed);
    defer allocator.free(bytecode);
    const calldata = try hexDecode(allocator, calldata_trimmed);
    defer allocator.free(calldata);


    // Set up VM with debug tracing to stderr
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    const stderr = std.io.getStdErr().writer();
    var vm = try evm.Evm.init(
        allocator,
        db_interface,
        null, // table
        null, // chain_rules
        null, // context
        0,    // depth
        false, // read_only
        stderr.any(), // tracer - this enables debug output
    );
    defer vm.deinit();

    // Set up caller
    const caller = primitives.Address.from_u256(0x1000000000000000000000000000000000000001);
    try vm.state.set_balance(caller, std.math.maxInt(u256));

    // Deploy contract
    const deploy_result = try vm.create_contract(caller, 0, bytecode, 10_000_000);
    
    
    if (deploy_result.output) |_| {
    }

    if (!deploy_result.success) {
        return;
    }

    // Call contract
    const contract_address = deploy_result.address;
    const call_params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_address,
        .value = 0,
        .input = calldata,
        .gas = 10_000_000,
    } };

    const call_result = try vm.call(call_params);
    
    
    if (call_result.output) |_| {
    }
}

fn hexDecode(allocator: std.mem.Allocator, hex_str: []const u8) ![]u8 {
    const clean_hex = if (std.mem.startsWith(u8, hex_str, "0x")) hex_str[2..] else hex_str;
    const result = try allocator.alloc(u8, clean_hex.len / 2);
    _ = try std.fmt.hexToBytes(result, clean_hex);
    return result;
}