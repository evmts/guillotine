const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");

const print = std.debug.print;
const Address = primitives.Address.Address;
const CallParams = evm.CallParams;
const CallResult = evm.CallResult;

const CALLER_ADDRESS = "0x1000000000000000000000000000000000000001";

// Updated to new API - migration in progress, tests not run yet

pub const std_options: std.Options = .{
    .log_level = .err,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();

    // Use normal allocator (EVM will handle internal arena allocation)
    const allocator = gpa_allocator;

    // Parse command line arguments (use GPA for args, not EVM allocator)
    const args = try std.process.argsAlloc(gpa_allocator);
    defer std.process.argsFree(gpa_allocator, args);

    if (args.len < 5) {
        std.debug.print("Usage: {s} --contract-code-path <path> --calldata <hex> [--num-runs <n>] [--next]\n", .{args[0]});
        std.debug.print("Example: {s} --contract-code-path bytecode.txt --calldata 0x12345678\n", .{args[0]});
        std.debug.print("Options:\n", .{});
        std.debug.print("  --next    Use block-based execution (new optimized interpreter)\n", .{});
        std.process.exit(1);
    }

    var contract_code_path: ?[]const u8 = null;
    var calldata_hex: ?[]const u8 = null;
    var num_runs: u8 = 1;
    var use_block_execution = false;

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
            num_runs = std.fmt.parseInt(u8, args[i + 1], 10) catch {
                std.debug.print("Error: --num-runs must be a number\n", .{});
                std.process.exit(1);
            };
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--next")) {
            use_block_execution = true;
        } else {
            std.debug.print("Error: Unknown argument {s}\n", .{args[i]});
            std.process.exit(1);
        }
    }

    if (contract_code_path == null or calldata_hex == null) {
        std.debug.print("Error: --contract-code-path and --calldata are required\n", .{});
        std.process.exit(1);
    }

    // Read contract bytecode from file
    const contract_code_file = std.fs.cwd().openFile(contract_code_path.?, .{}) catch |err| {
        std.debug.print("Error reading contract code file: {}\n", .{err});
        std.process.exit(1);
    };
    defer contract_code_file.close();

    const contract_code_hex = try contract_code_file.readToEndAlloc(gpa_allocator, 10 * 1024 * 1024); // 10MB max
    defer gpa_allocator.free(contract_code_hex);

    // Trim whitespace
    const trimmed_code = std.mem.trim(u8, contract_code_hex, " \t\n\r");

    // Decode hex to bytes
    const contract_code = try hexToBytes(gpa_allocator, trimmed_code);
    defer gpa_allocator.free(contract_code);

    // Decode calldata
    const trimmed_calldata = std.mem.trim(u8, calldata_hex.?, " \t\n\r");
    const calldata = try hexToBytes(gpa_allocator, trimmed_calldata);
    defer gpa_allocator.free(calldata);

    // Parse caller address
    const caller_address = try primitives.Address.from_hex(CALLER_ADDRESS);

    // Initialize EVM database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance using new API
    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(
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

    // Set up caller account with max balance
    try vm.state.set_balance(caller_address, std.math.maxInt(u256));

    // Check if this is deployment bytecode (starts with 0x6080604052)
    const is_deployment = contract_code.len >= 4 and 
                         contract_code[0] == 0x60 and 
                         contract_code[1] == 0x80 and 
                         contract_code[2] == 0x60 and 
                         contract_code[3] == 0x40;
    
    const contract_address = try primitives.Address.from_hex("0x5FbDB2315678afecb367f032d93F642f64180aa3");
    
    if (is_deployment) {
        // Execute constructor to get runtime code
        const deploy_params = evm.CallParams{ .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = &[_]u8{}, // Empty constructor args
            .gas = 10_000_000,
        } };
        
        // First set the deployment code
        try vm.state.set_code(contract_address, contract_code);
        
        // Execute constructor
        const deploy_result = vm.call(deploy_params) catch {
            // If constructor fails, just use the whole bytecode
            try vm.state.set_code(contract_address, contract_code);
            return;
        };
        
        if (deploy_result.output) |output| {
            defer allocator.free(output);
            // Constructor should return runtime code
            if (output.len > 0) {
                try vm.state.set_code(contract_address, output);
            }
        }
    } else {
        // Already runtime code
        try vm.state.set_code(contract_address, contract_code);
    }
    
    // Removed debug output for cleaner benchmark results
    
    // Run benchmarks
    var run: u8 = 0;
    while (run < num_runs) : (run += 1) {
        const start_time = std.time.nanoTimestamp();
        
        // Execute the contract call
        const call_params = evm.CallParams{ .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = calldata,
            .gas = 10_000_000, // Plenty of gas
        } };
        
        const result = vm.call(call_params) catch {
            // On error, just return with exit code 1 to signal failure to the orchestrator
            std.process.exit(1);
        };
        
        if (result.output) |output| {
            allocator.free(output);
        }
        
        const end_time = std.time.nanoTimestamp();
        const duration_ns: u64 = @intCast(end_time - start_time);
        const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
        
        // Output timing in milliseconds (one per line as expected by orchestrator)
        print("{d:.6}\n", .{duration_ms});
    }
}


fn deployContract(allocator: std.mem.Allocator, vm: *evm.Evm, caller: Address, bytecode: []const u8) !Address {
    
    // Use CREATE to deploy the contract
    const create_params = evm.CallParams{ .create = .{
        .caller = caller,
        .value = 0,
        .init_code = bytecode,
        .gas = 10_000_000, // Plenty of gas for deployment
    } };
    
    const result = try vm.call(create_params);
    
    if (!result.success) {
        return error.DeploymentFailed;
    }
    
    // Extract deployed address from output
    if (result.output) |output| {
        defer allocator.free(output);
        if (output.len >= 20) {
            var addr: Address = undefined;
            @memcpy(&addr, output[0..20]);
            return addr;
        }
    }
    
    return error.NoDeployedAddress;
}

fn hexToBytes(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    // Remove 0x prefix if present
    const clean_hex = if (std.mem.startsWith(u8, hex, "0x"))
        hex[2..]
    else
        hex;

    // Ensure even number of characters
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
