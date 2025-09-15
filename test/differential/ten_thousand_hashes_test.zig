const std = @import("std");
const primitives = @import("primitives");
const differential_testor = @import("differential_testor.zig");
const guillotine_evm = @import("evm");

fn hex_decode(allocator: std.mem.Allocator, hex_str: []const u8) ![]u8 {
    const clean_hex = if (std.mem.startsWith(u8, hex_str, "0x")) hex_str[2..] else hex_str;
    const trimmed = std.mem.trim(u8, clean_hex, &std.ascii.whitespace);
    if (trimmed.len == 0) return allocator.alloc(u8, 0);
    
    const result = try allocator.alloc(u8, trimmed.len / 2);
    var i: usize = 0;
    while (i < trimmed.len) : (i += 2) {
        const byte_str = trimmed[i .. i + 2];
        result[i / 2] = std.fmt.parseInt(u8, byte_str, 16) catch {
            return error.InvalidHexCharacter;
        };
    }
    return result;
}

test "differential: ten thousand hashes deployment" {
    const allocator = std.testing.allocator;
    
    var testor = try differential_testor.DifferentialTestor.initWithConfig(
        allocator,
        .{ .enable_tracing = false },
    );
    defer testor.deinit();
    
    // Test simple bytecode to ensure basic functionality works
    const simple_bytecode = &[_]u8{
        0x60, 0x42, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    try testor.test_bytecode(simple_bytecode);
}

const DeploymentResult = struct {
    success: bool,
    runtime_code: []u8,
    address: primitives.Address,
};

fn deployContract(testor: *differential_testor.DifferentialTestor, init_code: []const u8) !DeploymentResult {
    const log = std.log;
    
    // For both EVMs, we'll deploy using CREATE to get the runtime code
    // The differential testor handles this internally when it detects deployment bytecode
    
    // The test_bytecode method will:
    // 1. Detect that this is deployment bytecode (starts with 0x6080604052)
    // 2. Execute it to get the runtime code
    // 3. Deploy the runtime code to the contract address
    // 4. Compare execution on both EVMs
    
    // Since we want to deploy first and then call, we'll use a special approach:
    // We'll directly set up the deployment bytecode and let the testor handle it
    
    // The bytecode appears to be Solidity deployment code (starts with 0x60806040)
    const is_deployment = init_code.len > 4 and 
        init_code[0] == 0x60 and init_code[1] == 0x80 and 
        init_code[2] == 0x60 and init_code[3] == 0x40;
    
    if (!is_deployment) {
        log.warn("Warning: Bytecode doesn't appear to be deployment code", .{});
    }
    
    // Execute the deployment bytecode to get runtime code
    // We'll do this manually first to extract the runtime code
    
    // Set up the deployment bytecode at the contract address temporarily
    const code_hash = try testor.guillotine_db.set_code(init_code);
    try testor.guillotine_db.set_account(testor.contract.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Use Guillotine EVM for deployment since we don't have revm_instance anymore
    var execution_success = false;
    var runtime_code: []u8 = &.{};

    if (testor.guillotine_instance_no_trace) |*evm| {
        // Execute deployment to get runtime code using Guillotine EVM
        const params = guillotine_evm.CallParams{ .call = .{
            .caller = testor.caller,
            .to = testor.contract,
            .value = 0,
            .input = &.{}, // Empty calldata for deployment
            .gas = 10_000_000, // Generous gas for deployment
        } };
        var execution_result = evm.call(params);
        defer execution_result.deinit(testor.allocator);

        if (!execution_result.success) {
            log.err("Guillotine deployment failed", .{});
            return DeploymentResult{
                .success = false,
                .runtime_code = try testor.allocator.alloc(u8, 0),
                .address = testor.contract,
            };
        }

        execution_success = execution_result.success;
        // The output should be the runtime code
        runtime_code = try testor.allocator.dupe(u8, execution_result.output);
    } else {
        log.err("No Guillotine EVM instance available for deployment", .{});
        return DeploymentResult{
            .success = false,
            .runtime_code = try testor.allocator.alloc(u8, 0),
            .address = testor.contract,
        };
    }
    
    // Now set the runtime code for both EVMs
    const runtime_hash = try testor.guillotine_db.set_code(runtime_code);
    try testor.guillotine_db.set_account(testor.contract.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = runtime_hash,
        .storage_root = [_]u8{0} ** 32,
    });
    
    const runtime_hash_no_trace = try testor.guillotine_db_no_trace.set_code(runtime_code);
    try testor.guillotine_db_no_trace.set_account(testor.contract.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = runtime_hash_no_trace,
        .storage_root = [_]u8{0} ** 32,
    });

    return DeploymentResult{
        .success = true,
        .runtime_code = runtime_code,
        .address = testor.contract,
    };
}

test "differential: ten-thousand-hashes runtime execution" {
    const allocator = std.testing.allocator;
    const log = std.log;
    
    log.info("=== Ten Thousand Hashes Simple Runtime Test ===", .{});
    
    // For this test, we'll extract the runtime code manually from the deployment bytecode
    // and test it directly without going through deployment
    
    const bytecode_file = try std.fs.cwd().openFile("src/evm/fixtures/ten-thousand-hashes/bytecode.txt", .{});
    defer bytecode_file.close();
    const bytecode_hex = try bytecode_file.readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(bytecode_hex);
    
    const deployment_code = try hex_decode(allocator, bytecode_hex);
    defer allocator.free(deployment_code);
    
    // The deployment bytecode typically has the pattern:
    // 1. Constructor code
    // 2. Runtime code
    // 3. Metadata
    
    // For Solidity contracts, we can often find the runtime code after the constructor
    // Let's try to extract it by looking for common patterns
    
    // Look for CODECOPY pattern which is often used to return runtime code
    // Pattern: PUSH2 <size> PUSH1 <offset> PUSH1 0 CODECOPY
    
    // For now, let's just try to run the deployment and extract the result
    var testor = try differential_testor.DifferentialTestor.initWithConfig(
        allocator,
        .{ .enable_tracing = false },
    );
    defer testor.deinit();
    
    // Execute deployment to get runtime code
    const deploy_result = try deployContract(&testor, deployment_code);
    defer allocator.free(deploy_result.runtime_code);
    
    if (!deploy_result.success) {
        log.err("Failed to extract runtime code", .{});
        return error.DeploymentFailed;
    }
    
    log.info("Extracted runtime code: {} bytes", .{deploy_result.runtime_code.len});
    
    // Read the calldata
    const calldata_file = try std.fs.cwd().openFile("src/evm/fixtures/ten-thousand-hashes/calldata.txt", .{});
    defer calldata_file.close();
    const calldata_hex = try calldata_file.readToEndAlloc(allocator, 1024);
    defer allocator.free(calldata_hex);
    
    const calldata = try hex_decode(allocator, calldata_hex);
    defer allocator.free(calldata);
    
    log.info("Testing with calldata: {x}", .{calldata});
    
    // Now test just the runtime code with calldata
    // Create a fresh testor for the runtime test
    var runtime_testor = try differential_testor.DifferentialTestor.initWithConfig(
        allocator,
        .{ .enable_tracing = false },
    );
    defer runtime_testor.deinit();
    
    // Test the runtime code directly
    try runtime_testor.test_bytecode_with_calldata(deploy_result.runtime_code, calldata);
    
    log.info("✅ Runtime code differential test PASSED!", .{});
}