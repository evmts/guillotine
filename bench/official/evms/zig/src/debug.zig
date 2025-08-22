const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");

const print = std.debug.print;
const Address = primitives.Address.Address;

const CALLER_ADDRESS = "0x1000000000000000000000000000000000000001";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 5) {
        print("Usage: {s} --contract-code-path <path> --calldata <hex>\n", .{args[0]});
        std.process.exit(1);
    }

    var contract_code_path: ?[]const u8 = null;
    var calldata_hex: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--contract-code-path")) {
            contract_code_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--calldata")) {
            calldata_hex = args[i + 1];
            i += 1;
        }
    }

    // Read contract bytecode
    const contract_code_file = try std.fs.cwd().openFile(contract_code_path.?, .{});
    defer contract_code_file.close();

    const contract_code_hex = try contract_code_file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(contract_code_hex);

    const contract_code = try hexToBytes(allocator, std.mem.trim(u8, contract_code_hex, " \t\n\r"));
    defer allocator.free(contract_code);

    const calldata = try hexToBytes(allocator, std.mem.trim(u8, calldata_hex.?, " \t\n\r"));
    defer allocator.free(calldata);

    print("Contract code length: {}\n", .{contract_code.len});
    print("Calldata length: {}\n", .{calldata.len});
    print("First 4 bytes of calldata (selector): ", .{});
    for (calldata[0..@min(4, calldata.len)]) |b| {
        print("{x:0>2}", .{b});
    }
    print("\n", .{});

    // Initialize EVM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(
        allocator,
        db_interface,
        null, // table
        null, // chain_rules
        null, // context
        null, // tracer
    );
    defer vm.deinit();

    const caller_address = try primitives.Address.from_hex(CALLER_ADDRESS);
    try vm.state.set_balance(caller_address, std.math.maxInt(u256));

    const contract_address = try primitives.Address.from_hex("0x5FbDB2315678afecb367f032d93F642f64180aa3");
    
    // Check if deployment bytecode
    const is_deployment = contract_code.len >= 4 and 
                         contract_code[0] == 0x60 and 
                         contract_code[1] == 0x80 and 
                         contract_code[2] == 0x60 and 
                         contract_code[3] == 0x40;
    
    print("Is deployment bytecode: {}\n", .{is_deployment});
    
    if (is_deployment) {
        // Deploy contract
        const deploy_params = evm.CallParams{ .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = &[_]u8{},
            .gas = 10_000_000,
        } };
        
        try vm.state.set_code(contract_address, contract_code);
        
        print("Executing constructor...\n", .{});
        const deploy_result = vm.call(deploy_params) catch |err| {
            print("Constructor failed: {}\n", .{err});
            return err;
        };
        
        print("Constructor success: {}\n", .{deploy_result.success});
        print("Gas left: {}\n", .{deploy_result.gas_left});
        
        if (deploy_result.output) |output| {
            defer allocator.free(output);
            print("Constructor output length: {}\n", .{output.len});
            if (output.len > 0) {
                try vm.state.set_code(contract_address, output);
                print("Set runtime code, length: {}\n", .{output.len});
            }
        }
    } else {
        try vm.state.set_code(contract_address, contract_code);
    }
    
    // Execute the contract call
    print("\nExecuting contract call...\n", .{});
    const call_params = evm.CallParams{ .call = .{
        .caller = caller_address,
        .to = contract_address,
        .value = 0,
        .input = calldata,
        .gas = 10_000_000,
    } };
    
    const result = vm.call(call_params) catch |err| {
        print("Call failed: {}\n", .{err});
        return err;
    };
    
    print("Call success: {}\n", .{result.success});
    print("Gas left: {}\n", .{result.gas_left});
    
    if (result.output) |output| {
        defer allocator.free(output);
        print("Output length: {}\n", .{output.len});
        if (output.len > 0 and output.len <= 32) {
            print("Output: 0x", .{});
            for (output) |b| {
                print("{x:0>2}", .{b});
            }
            print("\n", .{});
        }
    }
}

fn hexToBytes(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    const clean_hex = if (std.mem.startsWith(u8, hex, "0x"))
        hex[2..]
    else
        hex;

    if (clean_hex.len % 2 != 0) {
        return error.InvalidHexLength;
    }

    const bytes = try allocator.alloc(u8, clean_hex.len / 2);
    errdefer allocator.free(bytes);

    var i: usize = 0;
    while (i < clean_hex.len) : (i += 2) {
        const byte_str = clean_hex[i .. i + 2];
        bytes[i / 2] = std.fmt.parseInt(u8, byte_str, 16) catch {
            return error.InvalidHexCharacter;
        };
    }

    return bytes;
}