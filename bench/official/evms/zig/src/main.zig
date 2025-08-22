const std = @import("std");
const print = std.debug.print;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address.Address;

pub const std_options: std.Options = .{
    .log_level = .err,
};

fn hex_decode(allocator: std.mem.Allocator, hex_str: []const u8) ![]u8 {
    const clean_hex = if (std.mem.startsWith(u8, hex_str, "0x")) hex_str[2..] else hex_str;
    const result = try allocator.alloc(u8, clean_hex.len / 2);
    var i: usize = 0;
    while (i < clean_hex.len) : (i += 2) {
        const byte_str = clean_hex[i .. i + 2];
        result[i / 2] = std.fmt.parseInt(u8, byte_str, 16) catch {
            return error.InvalidHexCharacter;
        };
    }
    return result;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 5) {
        std.debug.print("Usage: {s} --contract-code-path <path> --calldata <hex> [--num-runs <n>]\n", .{args[0]});
        std.process.exit(1);
    }

    var contract_code_path: ?[]const u8 = null;
    var calldata_hex: ?[]const u8 = null;
    var num_runs: u32 = 1;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--contract-code-path")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --contract-code-path requires a value\n", .{});
                std.process.exit(1);
            }
            contract_code_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--calldata")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --calldata requires a value\n", .{});
                std.process.exit(1);
            }
            calldata_hex = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--num-runs")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --num-runs requires a value\n", .{});
                std.process.exit(1);
            }
            num_runs = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                std.debug.print("Error: --num-runs must be a number\n", .{});
                std.process.exit(1);
            };
            i += 1;
        } else {
            std.debug.print("Error: Unknown argument {s}\n", .{args[i]});
            std.process.exit(1);
        }
    }

    if (contract_code_path == null or calldata_hex == null) {
        std.debug.print("Error: --contract-code-path and --calldata are required\n", .{});
        std.process.exit(1);
    }

    // Read init bytecode from file
    const init_code_file = try std.fs.cwd().openFile(contract_code_path.?, .{});
    defer init_code_file.close();
    const init_code_hex = try init_code_file.readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(init_code_hex);
    const trimmed_init_hex = std.mem.trim(u8, init_code_hex, " \t\n\r");
    const init_code = try hex_decode(allocator, trimmed_init_hex);
    defer allocator.free(init_code);

    // Decode calldata
    const trimmed_calldata = std.mem.trim(u8, calldata_hex.?, " \t\n\r");
    const calldata = try hex_decode(allocator, trimmed_calldata);
    defer allocator.free(calldata);

    // Fixed addresses
    const deployer = try primitives.Address.from_hex("0x1000000000000000000000000000000000000001");
    const contract_addr = try primitives.Address.from_hex("0x5FbDB2315678afecb367f032d93F642f64180aa3");

    // Run benchmarks
    for (0..num_runs) |_| {
        var memory_db = evm.MemoryDatabase.init(allocator);
        defer memory_db.deinit();

        var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
        defer vm.deinit();

        // Set deployer balance
        try vm.state.set_balance(deployer, std.math.maxInt(u256));

        // Step 1: Deploy contract using call2 CREATE
        const create_params = evm.CallParams{ .create = .{
            .caller = deployer,
            .value = 0,
            .init_code = init_code,
            .gas = 10_000_000,
        } };

        const create_result = vm.call2(create_params) catch |err| {
            std.debug.print("Error calling vm.call2 for CREATE: {}\n", .{err});
            std.process.exit(1);
        };

        if (!create_result.success) {
            std.debug.print("Contract deployment failed\n", .{});
            std.process.exit(1);
        }

        // Debug: confirm CREATE succeeded
        // std.debug.print("CREATE succeeded, gas_left={}\n", .{create_result.gas_left});

        const runtime_code = create_result.output orelse {
            std.debug.print("No runtime code returned\n", .{});
            std.process.exit(1);
        };

        // Set the runtime code at the contract address
        try vm.state.set_code(contract_addr, runtime_code);

        // Set up ERC20 state if this looks like an ERC20 operation
        if (calldata.len >= 4) {
            const selector = std.mem.readInt(u32, calldata[0..4], .big);
            // 0xa9059cbb is transfer(address,uint256), 0x30627b7c is used in benchmarks
            if (selector == 0xa9059cbb or selector == 0x30627b7c) {
                // Give tokens to the deployer
                var caller_slot_data: [64]u8 = undefined;
                @memset(&caller_slot_data, 0);
                @memcpy(caller_slot_data[12..32], &deployer);
                @memset(caller_slot_data[32..64], 0);

                var caller_slot_hash: [32]u8 = undefined;
                const Keccak256 = std.crypto.hash.sha3.Keccak256;
                Keccak256.hash(&caller_slot_data, &caller_slot_hash, .{});
                const slot_key = std.mem.readInt(u256, &caller_slot_hash, .big);

                const balance: u256 = 10_000_000 * std.math.pow(u256, 10, 18);
                try vm.state.set_storage(contract_addr, slot_key, balance);
                try vm.state.set_storage(contract_addr, 2, balance); // total supply
            }
        }

        // Step 2: Call contract using call2 CALL
        // std.debug.print("Starting CALL to contract...\n", .{});
        const call_params = evm.CallParams{ .call = .{
            .caller = deployer,
            .to = contract_addr,
            .value = 0,
            .input = calldata,
            .gas = 100_000_000,
        } };

        const start_time = std.time.nanoTimestamp();
        const call_result = vm.call2(call_params) catch |err| {
            std.debug.print("Error calling vm.call2 for CALL: {}\n", .{err});
            std.process.exit(1);
        };
        const end_time = std.time.nanoTimestamp();
        // std.debug.print("CALL completed, success={}\n", .{call_result.success});

        if (!call_result.success) {
            std.debug.print("Contract call failed\n", .{});
            std.process.exit(1);
        }
        
        const elapsed_ns = @as(u64, @intCast(end_time - start_time));
        const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
        print("{d:.6}\n", .{elapsed_ms});
    }
}