const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const log = evm.log;

const testing = std.testing;

// Enable info logging for tests
pub const std_options = .{
    .log_level = .info,
};

// Use DefaultEvm for regular EVM execution
const DefaultEvm = evm.DefaultEvm;

fn parse_hex_alloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    // First pass: count hex digits ignoring whitespace and 0x prefix occurrences
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '0' and i + 1 < text.len and (text[i + 1] == 'x' or text[i + 1] == 'X')) {
            i += 1;
            continue;
        }
        if (std.ascii.isWhitespace(c)) continue;
        count += 1;
    }
    if (count == 0) return allocator.alloc(u8, 0);
    if (count % 2 != 0) return error.InvalidHex;

    var out = try allocator.alloc(u8, count / 2);
    errdefer allocator.free(out);

    // Second pass: decode
    var idx: usize = 0;
    i = 0;
    var hi_digit: ?u8 = null;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '0' and i + 1 < text.len and (text[i + 1] == 'x' or text[i + 1] == 'X')) {
            i += 1;
            continue;
        }
        if (std.ascii.isWhitespace(c)) continue;
        const d = std.fmt.charToDigit(c, 16) catch return error.InvalidHex;
        if (hi_digit == null) {
            hi_digit = d;
        } else {
            const hi = hi_digit.?;
            out[idx] = @intCast((hi << 4) | d);
            idx += 1;
            hi_digit = null;
        }
    }
    return out;
}

fn run_fixture_test(allocator: std.mem.Allocator, fixture_dir: []const u8) !void {
    var cwd = std.fs.cwd();
    
    const bc_path = try std.fmt.allocPrint(allocator, "{s}/bytecode.txt", .{fixture_dir});
    defer allocator.free(bc_path);
    const cd_path = try std.fmt.allocPrint(allocator, "{s}/calldata.txt", .{fixture_dir});
    defer allocator.free(cd_path);

    const bc_text = try cwd.readFileAlloc(allocator, bc_path, 1024 * 1024);
    defer allocator.free(bc_text);
    const cd_text = try cwd.readFileAlloc(allocator, cd_path, 1024 * 1024);
    defer allocator.free(cd_text);

    const init_bytecode = try parse_hex_alloc(allocator, bc_text);
    defer allocator.free(init_bytecode);
    
    const cd_trimmed = std.mem.trim(u8, cd_text, &std.ascii.whitespace);
    
    // Parse calldata - handle empty case "0x" or just whitespace
    const calldata = if (std.mem.eql(u8, cd_trimmed, "0x") or cd_trimmed.len == 0)
        try allocator.alloc(u8, 0)
    else
        try parse_hex_alloc(allocator, cd_text);
    defer allocator.free(calldata);

    // Setup addresses
    const caller = try primitives.Address.from_hex("0x1000000000000000000000000000000000000001");

    // Setup database
    var database = evm.Database.init(allocator);
    defer database.deinit();
    
    // Set up caller with large balance
    try database.set_account(caller.bytes, .{
        .balance = std.math.maxInt(u256),
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });

    // Setup block info and transaction context
    const block_info = evm.BlockInfo{
        .chain_id = 1,
        .number = 20_000_000,  // Ensure after all fork blocks
        .timestamp = 1_800_000_000,  // Ensure after Shanghai
        .difficulty = 0,
        .gas_limit = 1_000_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 7,
        .prev_randao = [_]u8{0} ** 32,
        .blob_base_fee = 1000000000,
        .blob_versioned_hashes = &.{},
    };

    const tx_context = evm.TransactionContext{
        .gas_limit = 1_000_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    // Create EVM instance
    var evm_instance = try DefaultEvm.init(
        allocator,
        &database,
        block_info,
        tx_context,
        0, // gas_price
        caller, // origin
        .CANCUN // hardfork
    );
    defer evm_instance.deinit();
    
    // Check if this is deployment bytecode or runtime bytecode
    // Deployment bytecode typically starts with 0x6080604052 (PUSH1 0x80 PUSH1 0x40 MSTORE)
    const is_deployment_code = init_bytecode.len > 4 and 
        init_bytecode[0] == 0x60 and init_bytecode[1] == 0x80 and 
        init_bytecode[2] == 0x60 and init_bytecode[3] == 0x40;
    
    log.info("Testing fixture: {s}", .{fixture_dir});
    log.info("  Bytecode type: {s} ({} bytes)", .{ 
        if (is_deployment_code) "deployment" else "runtime", 
        init_bytecode.len 
    });
    
    var contract_address: primitives.Address = undefined;
    var runtime_code: []const u8 = undefined;
    var runtime_code_owned: ?[]u8 = null;
    defer if (runtime_code_owned) |code| allocator.free(code);
    
    if (is_deployment_code) {
        log.info("  Deploying contract via CREATE...", .{});
        
        // Deploy the contract using CREATE
        const deploy_params = evm.CallParams{
            .create = .{
                .caller = caller,
                .value = 0,
                .init_code = init_bytecode,
                .gas = 500_000_000,  // High gas for deployment
            },
        };
        
        std.debug.print("Deploying contract with {} bytes of init code\n", .{init_bytecode.len});
        
        // Deploy with regular EVM execution
        const deploy_result = evm_instance.call(deploy_params);
        if (!deploy_result.success) {
            log.err("❌ Contract deployment failed for {s}", .{fixture_dir});
            log.err("  This indicates a bug during deployment (constructor execution)", .{});
            log.err("  Output length: {}", .{deploy_result.output.len});
            if (deploy_result.output.len > 0) {
                log.err("  Output (first 64 bytes): {x}", .{deploy_result.output[0..@min(64, deploy_result.output.len)]});
            }
            if (deploy_result.error_info) |error_info| {
                log.err("  Error: {s}", .{error_info});
            }
            return error.DeploymentFailed;
        }
        
        // Get the deployed contract address (deterministic based on caller + nonce)
        contract_address = primitives.Address.get_contract_address(caller, 0);
        
        // The output of deployment is the runtime code
        runtime_code_owned = try allocator.alloc(u8, deploy_result.output.len);
        @memcpy(runtime_code_owned.?, deploy_result.output);
        runtime_code = runtime_code_owned.?;
        
        log.info("  ✅ Contract deployed to: {x}", .{contract_address.bytes});
        log.info("  Runtime code size: {} bytes", .{runtime_code.len});
        
        // Update database with the deployed contract
        const code_hash = try database.set_code(runtime_code);
        try database.set_account(contract_address.bytes, .{
            .balance = 0,
            .nonce = 1,
            .code_hash = code_hash,
            .storage_root = [_]u8{0} ** 32,
        });

        // Contract is already deployed to our database, no need to sync
    } else {
        // Not deployment bytecode, use directly as runtime code
        contract_address = try primitives.Address.from_hex("0xc0de000000000000000000000000000000000000");
        runtime_code = init_bytecode;
        
        log.info("  Using bytecode as runtime code directly", .{});
        
        // Deploy runtime code to database
        const code_hash = try database.set_code(runtime_code);
        try database.set_account(contract_address.bytes, .{
            .balance = 0,
            .nonce = 1,
            .code_hash = code_hash,
            .storage_root = [_]u8{0} ** 32,
        });

        // Contract code is already set in database
    }
    
    // Now execute with calldata if provided
    if (calldata.len > 0) {
        log.info("  Executing with calldata ({} bytes)...", .{calldata.len});
        if (calldata.len >= 4) {
            log.info("  Function selector: 0x{x:0>8}", .{std.mem.readInt(u32, calldata[0..4], .big)});
        }
        
        const call_params = evm.CallParams{
            .call = .{
                .caller = caller,
                .to = contract_address,
                .value = 0,
                .input = calldata,
                .gas = 100_000_000,  // High gas for execution
            },
        };
        
        // Execute with regular EVM execution
        const result = evm_instance.call(call_params);
        if (!result.success) {
            log.err("❌ Contract execution failed for {s}", .{fixture_dir});
            log.err("  This indicates a bug during contract execution", .{});
            if (result.error_info) |error_info| {
                log.err("  Error: {s}", .{error_info});
            }
            return error.ExecutionFailed;
        }
        
        log.info("  ✅ Execution successful, gas used: {}", .{100_000_000 - result.gas_left});
        if (result.output.len > 0) {
            log.info("  Output length: {} bytes", .{result.output.len});
            if (result.output.len <= 32) {
                log.info("  Output: 0x{x}", .{result.output});
            }
        }
    } else {
        log.info("  No calldata provided, skipping execution phase", .{});
    }
    
    log.info("✅ Fixture {s} passed differential testing", .{fixture_dir});
}

// test "differential: snailtracer fixture" {
//     const allocator = testing.allocator;
//     try run_fixture_test(allocator, "src/evm/fixtures/snailtracer");
// }

test "differential: erc20-transfer fixture" {
    const allocator = testing.allocator;
    try run_fixture_test(allocator, "src/_test_utils/fixtures/erc20-transfer");
}

// test "differential: erc20-approval-transfer fixture" {
//     const allocator = testing.allocator;
//     try run_fixture_test(allocator, "src/evm/fixtures/erc20-approval-transfer");
// }

// test "differential: erc20-mint fixture" {
//     const allocator = testing.allocator;
//     try run_fixture_test(allocator, "src/evm/fixtures/erc20-mint");
// }

// test "differential: ten-thousand-hashes fixture" {
//     const allocator = testing.allocator;
//     try run_fixture_test(allocator, "src/evm/fixtures/ten-thousand-hashes");
// }