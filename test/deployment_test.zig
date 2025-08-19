const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");

const Address = primitives.Address.Address;
const CallParams = evm.CallParams;
const CallResult = evm.CallResult;

test "deploy ERC20 contract using CREATE" {
    const allocator = std.testing.allocator;
    
    // Initialize EVM database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    // Create EVM instance
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
    
    // Setup deployer account with ETH balance
    const deployer = try primitives.Address.from_hex("0x1000000000000000000000000000000000000001");
    try vm.state.set_balance(deployer, std.math.maxInt(u256));
    
    // Simple contract deployment bytecode that returns runtime code
    // This simulates a minimal ERC20 constructor
    // Constructor: stores initial supply and returns runtime code
    const deployment_bytecode = [_]u8{
        // Constructor logic (simplified)
        0x60, 0x40, // PUSH1 0x40 (free memory pointer)
        0x52,       // MSTORE
        
        // Return runtime code (simplified - just returns empty code for now)
        0x60, 0x20, // PUSH1 0x20 (size of runtime code)
        0x60, 0x00, // PUSH1 0x00 (offset in memory)
        0xf3,       // RETURN
        
        // Runtime code that would be returned (example)
        0x60, 0x00, // PUSH1 0x00
        0x60, 0x00, // PUSH1 0x00
        0x52,       // MSTORE
        0x60, 0x01, // PUSH1 0x01
        0x60, 0x1f, // PUSH1 0x1f
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x00, // PUSH1 0x00
        0xf3,       // RETURN
    };
    
    // Deploy contract using CREATE
    const create_params = CallParams{ .create = .{
        .caller = deployer,
        .value = 0,
        .init_code = &deployment_bytecode,
        .gas = 1_000_000,
    } };
    
    const deploy_result = try vm.call(create_params);
    
    // Check deployment succeeded
    try std.testing.expect(deploy_result.success);
    try std.testing.expect(deploy_result.output != null);
    
    // Output should be the deployed contract address (20 bytes)
    try std.testing.expectEqual(@as(usize, 20), deploy_result.output.?.len);
    
    // Extract deployed address
    var deployed_address: Address = undefined;
    @memcpy(&deployed_address, deploy_result.output.?[0..20]);
    
    // Verify contract exists at deployed address
    const deployed_code = vm.state.get_code(deployed_address);
    try std.testing.expect(deployed_code.len > 0);
    
    
    // Free the output
    if (deploy_result.output) |_| {
        allocator.free(output);
    }
}

test "deploy and call simple storage contract" {
    const allocator = std.testing.allocator;
    
    // Initialize EVM database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    // Create EVM instance
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
    
    // Setup deployer account
    const deployer = try primitives.Address.from_hex("0x1000000000000000000000000000000000000001");
    try vm.state.set_balance(deployer, std.math.maxInt(u256));
    
    // Deployment bytecode that returns a simple storage contract
    // Runtime code: stores value at slot 0 and returns it
    const runtime_code = [_]u8{
        // Function selector check (simplified - accept any call)
        0x60, 0x00, // PUSH1 0x00
        0x54,       // SLOAD (load from storage slot 0)
        0x60, 0x00, // PUSH1 0x00
        0x52,       // MSTORE (store in memory)
        0x60, 0x20, // PUSH1 0x20 (return 32 bytes)
        0x60, 0x00, // PUSH1 0x00 (from memory position 0)
        0xf3,       // RETURN
    };
    
    // Deployment bytecode: constructor that returns runtime code
    var deployment_bytecode = std.ArrayList(u8).init(allocator);
    defer deployment_bytecode.deinit();
    
    // Constructor: return the runtime code
    try deployment_bytecode.appendSlice(&[_]u8{
        // Store initial value in storage slot 0
        0x60, 0x42, // PUSH1 0x42 (initial value)
        0x60, 0x00, // PUSH1 0x00 (storage slot)
        0x55,       // SSTORE
        
        // Copy runtime code to memory
        0x60, @intCast(runtime_code.len), // PUSH1 runtime_code_size
        0x80,                              // DUP1
        0x60, 0x0d,                        // PUSH1 0x0d (offset to runtime code in bytecode)
        0x60, 0x00,                        // PUSH1 0x00 (destination in memory)
        0x39,                              // CODECOPY
        
        // Return runtime code
        0x60, 0x00, // PUSH1 0x00 (memory offset)
        0xf3,       // RETURN
    });
    try deployment_bytecode.appendSlice(&runtime_code);
    
    // Deploy the contract
    const create_params = CallParams{ .create = .{
        .caller = deployer,
        .value = 0,
        .init_code = deployment_bytecode.items,
        .gas = 1_000_000,
    } };
    
    const deploy_result = try vm.call(create_params);
    try std.testing.expect(deploy_result.success);
    try std.testing.expect(deploy_result.output != null);
    try std.testing.expectEqual(@as(usize, 20), deploy_result.output.?.len);
    
    // Extract deployed address
    var deployed_address: Address = undefined;
    @memcpy(&deployed_address, deploy_result.output.?[0..20]);
    
    // Free deployment output
    if (deploy_result.output) |_| {
        allocator.free(output);
    }
    
    // Call the deployed contract
    const call_params = CallParams{ .call = .{
        .caller = deployer,
        .to = deployed_address,
        .value = 0,
        .input = &[_]u8{}, // Empty calldata
        .gas = 100_000,
    } };
    
    const call_result = try vm.call(call_params);
    try std.testing.expect(call_result.success);
    try std.testing.expect(call_result.output != null);
    try std.testing.expectEqual(@as(usize, 32), call_result.output.?.len);
    
    // Check the returned value (should be 0x42)
    const returned_value = call_result.output.?[31];
    try std.testing.expectEqual(@as(u8, 0x42), returned_value);
    
    // Free call output
    if (call_result.output) |_| {
        allocator.free(output);
    }
}