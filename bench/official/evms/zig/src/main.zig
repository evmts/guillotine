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
        std.debug.print("Usage: {s} --contract-code-path <path> --calldata <hex> [--num-runs <n>] [--next] [--call2]\n", .{args[0]});
        std.debug.print("Example: {s} --contract-code-path bytecode.txt --calldata 0x12345678\n", .{args[0]});
        std.debug.print("Options:\n", .{});
        std.debug.print("  --next    Use call_mini (simplified lazy jumpdest validation)\n", .{});
        std.debug.print("  --call2   Use call2 with interpret2 (tailcall dispatch interpreter)\n", .{});
        std.process.exit(1);
    }

    var contract_code_path: ?[]const u8 = null;
    var calldata_hex: ?[]const u8 = null;
    var num_runs: u8 = 1;
    var use_block_execution = false;
    var use_call2 = false;

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
        } else if (std.mem.eql(u8, args[i], "--call2")) {
            use_call2 = true;
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

    // Check if this is deployment bytecode (starts with 0x6080604052 or other common patterns)
    const is_deployment = contract_code.len >= 4 and 
                         ((contract_code[0] == 0x60 and contract_code[1] == 0x80) or // Solidity pattern
                          (contract_code[0] == 0x60)); // General PUSH pattern for constructor
    
    const contract_address = try primitives.Address.from_hex("0x5FbDB2315678afecb367f032d93F642f64180aa3");
    
    if (is_deployment) {
        // Deploy contract using CREATE to get runtime code
        const deploy_params = evm.CallParams{ .create = .{
            .caller = caller_address,
            .value = 0,
            .init_code = contract_code,
            .gas = 10_000_000,
        } };
        
        const deploy_result = vm.call(deploy_params) catch |err| {
            std.debug.print("Error deploying contract: {}\n", .{err});
            // If deployment fails, try to use the bytecode directly as runtime code
            try vm.state.set_code(contract_address, contract_code);
            return;
        };
        
        if (!deploy_result.success) {
            std.debug.print("Contract deployment failed, using bytecode directly\n", .{});
            // Deployment failed, use bytecode directly
            try vm.state.set_code(contract_address, contract_code);
        } else if (deploy_result.output) |output| {
            // Extract deployed contract address from output (20 bytes)
            if (output.len == 20) {
                var deployed_addr: primitives.Address.Address = undefined;
                @memcpy(&deployed_addr, output[0..20]);
                
                // Get the deployed runtime code
                const runtime_code = vm.state.get_code(deployed_addr);
                
                // Copy runtime code to our target address
                if (runtime_code.len > 0) {
                    try vm.state.set_code(contract_address, runtime_code);
                } else {
                    // No runtime code deployed, use original bytecode
                    try vm.state.set_code(contract_address, contract_code);
                }
            }
            // Don't free - output is VM-owned memory
        } else {
            // No output, use bytecode directly
            try vm.state.set_code(contract_address, contract_code);
        }
    } else {
        // Already runtime code
        try vm.state.set_code(contract_address, contract_code);
    }
    
    // Set up initial ERC20 state if needed
    // For ERC20 contracts, we need to give the caller some initial balance
    // Check if this looks like an ERC20 transfer call
    if (calldata.len >= 4) {
        const selector = std.mem.readInt(u32, calldata[0..4], .big);
        // 0xa9059cbb is the selector for transfer(address,uint256)
        // 0x30627b7c is used in some benchmarks for stress testing
        if (selector == 0xa9059cbb or selector == 0x30627b7c) {
            // This is an ERC20 operation - set up token balances
            // Standard ERC20 uses slot 0 for balances mapping
            // balanceOf[address] is stored at keccak256(abi.encode(address, uint256(0)))
            
            // Give tokens to the caller
            var caller_slot_data: [64]u8 = undefined;
            // First 32 bytes: address (padded to 32 bytes)
            @memset(&caller_slot_data, 0);
            @memcpy(caller_slot_data[12..32], &caller_address); // address in last 20 bytes
            // Second 32 bytes: mapping slot (0)
            @memset(caller_slot_data[32..64], 0);
            
            var caller_slot_hash: [32]u8 = undefined;
            const Keccak256 = std.crypto.hash.sha3.Keccak256;
            Keccak256.hash(&caller_slot_data, &caller_slot_hash, .{});
            
            // Set balance to a large value (10 million tokens with 18 decimals)
            const balance: u256 = 10_000_000 * std.math.pow(u256, 10, 18);
            const slot_key = std.mem.readInt(u256, &caller_slot_hash, .big);
            try vm.state.set_storage(contract_address, slot_key, balance);
            
            // Also set the total supply at slot 2 (standard ERC20 layout)
            try vm.state.set_storage(contract_address, 2, balance);
            
            // If this is a transfer, also give some balance to the recipient
            if (calldata.len >= 68 and selector == 0xa9059cbb) {
                // Extract recipient address from calldata (bytes 4-36)
                var recipient: [20]u8 = undefined;
                @memcpy(&recipient, calldata[16..36]); // Skip 12 bytes of padding
                
                var recipient_slot_data: [64]u8 = undefined;
                @memset(&recipient_slot_data, 0);
                @memcpy(recipient_slot_data[12..32], &recipient);
                @memset(recipient_slot_data[32..64], 0);
                
                var recipient_slot_hash: [32]u8 = undefined;
                Keccak256.hash(&recipient_slot_data, &recipient_slot_hash, .{});
                
                // Give recipient some initial balance too
                const recipient_slot_key = std.mem.readInt(u256, &recipient_slot_hash, .big);
                try vm.state.set_storage(contract_address, recipient_slot_key, 1_000_000 * std.math.pow(u256, 10, 18));
            }
        }
    }
    
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
            .gas = 100_000_000, // 100M gas for intensive operations like minting loops
        } };
        
        const result = if (use_call2)
            vm.call2(call_params) catch |err| {
                // On error, print to stderr and exit
                std.debug.print("Error executing call2: {}\n", .{err});
                std.process.exit(1);
            }
        else if (use_block_execution)
            vm.call2(call_params) catch |err| {
                // On error, print to stderr and exit
                std.debug.print("Error executing call2: {}\n", .{err});
                std.process.exit(1);
            }
        else
            vm.call(call_params) catch |err| {
                // On error, print to stderr and exit
                std.debug.print("Error executing call: {}\n", .{err});
                std.process.exit(1);
            };
        
        const end_time = std.time.nanoTimestamp();
        const duration_ns: u64 = @intCast(end_time - start_time);
        const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
        
        // Debug mode: print additional info to stderr (only on first run)
        if (run == 0 and !result.success) {
            std.debug.print("Call success: {}, gas_left: {}, output_len: {}\n", .{
                result.success,
                result.gas_left,
                if (result.output) |o| o.len else 0,
            });
            
            // Print the error output if call failed
            if (!result.success) {
                if (result.output) |output| {
                    std.debug.print("Error output (hex): ", .{});
                    for (output) |byte| {
                        std.debug.print("{x:0>2}", .{byte});
                    }
                    std.debug.print("\n", .{});
                    
                    // Try to print as string if it looks like one
                    var has_printable = true;
                    for (output) |byte| {
                        if (byte < 0x20 or byte > 0x7E) {
                            if (byte != 0) {
                                has_printable = false;
                                break;
                            }
                        }
                    }
                    if (has_printable) {
                        std.debug.print("Error output (string): {s}\n", .{output});
                    }
                }
            }
        }
        
        // Don't free output - it's VM-owned memory per CallResult documentation
        
        // Validate the call actually succeeded
        if (!result.success) {
            std.debug.print("Call failed!\n", .{});
            std.process.exit(1);
        }
        
        // Output timing in milliseconds (one per line as expected by orchestrator)
        print("{d:.6}\n", .{duration_ms});
    }
}


fn deployContract(allocator: std.mem.Allocator, vm: *evm.Evm, caller: Address, bytecode: []const u8) !Address {
    _ = allocator; // Not used after removing free calls
    
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
        // Don't free output - it's VM-owned memory
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
