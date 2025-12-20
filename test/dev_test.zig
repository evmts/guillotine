const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("voltaire");
const log = std.log.scoped(.dev_test);

test "simple trace generation" {
    // Enable debug logging for this test
    std.testing.log_level = .err;
    
    const allocator = testing.allocator;
    
    // Simple bytecode: PUSH1 0x42, PUSH1 0x10, ADD, STOP
    const code = [_]u8{ 0x60, 0x42, 0x60, 0x10, 0x01, 0x00 };
    
    // Create database interface
    var database = Evm.MemoryDatabase.init(allocator);
    defer database.deinit();
    const db_interface = database.interface();
    
    // Set up blockchain context
    const block_info = primitives.BlockInfo{
        .coinbase = primitives.Address.zero(),
        .gas_limit = 30_000_000,
        .number = 1,
        .timestamp = 1,
        .basefee = 1,
        .prevrandao = primitives.Hash.zero(),
        .blob_base_fee = null,
    };
    
    // Create transaction context for deployment
    const tx_context = primitives.TransactionContext{
        .origin = primitives.Address.zero(),
        .gas_price = 1,
        .blob_hashes = &.{},
        .authorization_list = null,
    };
    
    // Initialize EVM with tracer
    var evm = try Evm.MainnetEvmWithTracer.init(allocator, db_interface, &block_info, &tx_context);
    defer evm.deinit();
    
    // Deploy the contract
    const deploy_result = try evm.create(
        primitives.Address.zero(), // caller
        0, // value
        &code, // init code
        1000000, // gas limit
    );
    
    std.debug.print("\n=== Simple Deploy Result ===\n", .{});
    std.debug.print("Success: {}\n", .{deploy_result.is_success});
    std.debug.print("Gas used: {}\n", .{deploy_result.gas_used});
    
    // Get the tracer and check if it captured steps
    const tracer = evm.getTracer();
    const steps = tracer.steps.items;
    std.debug.print("Steps captured: {}\n", .{steps.len});
    
    if (steps.len == 0) {
        std.debug.print("ERROR: No steps captured despite tracer being enabled!\n", .{});
        
        // Check if MinimalEvm was initialized
        if (tracer.minimal_evm) |minimal| {
            std.debug.print("MinimalEvm is initialized\n", .{});
            std.debug.print("MinimalEvm PC: {}\n", .{minimal.pc});
            std.debug.print("MinimalEvm stack size: {}\n", .{minimal.stack.items.len});
        } else {
            std.debug.print("ERROR: MinimalEvm is NOT initialized!\n", .{});
        }
    } else {
        // Print first few steps for debugging
        for (steps[0..@min(10, steps.len)], 0..) |step, i| {
            std.debug.print("  Step {}: PC={}, Op={s}, Gas={}\n", .{i, step.pc, @tagName(step.op), step.gas});
        }
    }
    
    // Try to generate JSON trace
    const json_trace = try tracer.toJsonRpcTrace(allocator);
    defer allocator.free(json_trace);
    
    std.debug.print("\nJSON trace length: {} bytes\n", .{json_trace.len});
    if (json_trace.len < 1000) {
        std.debug.print("JSON trace: {s}\n", .{json_trace});
    } else {
        std.debug.print("JSON trace (first 500 chars): {s}...\n", .{json_trace[0..500]});
    }
}

test "trace with dispatch analysis" {
    std.testing.log_level = .err;
    
    const allocator = testing.allocator;
    
    // More complex bytecode with jumps and storage
    // PUSH1 0x05, PUSH1 0x00, SSTORE (store 5 at slot 0)
    // PUSH1 0x00, SLOAD, PUSH1 0x0A, ADD (load slot 0, add 10)
    // PUSH1 0x01, SSTORE, STOP (store result at slot 1)
    const code = [_]u8{ 
        0x60, 0x05, // PUSH1 0x05
        0x60, 0x00, // PUSH1 0x00
        0x55,       // SSTORE
        0x60, 0x00, // PUSH1 0x00
        0x54,       // SLOAD
        0x60, 0x0A, // PUSH1 0x0A
        0x01,       // ADD
        0x60, 0x01, // PUSH1 0x01
        0x55,       // SSTORE
        0x00,       // STOP
    };
    
    log.debug("Analyzing bytecode for dispatch building...", .{});
    
    // First analyze the bytecode to see what dispatch will be built
    const bytecode = try Evm.Bytecode.init(allocator, &code, .{ .enable_fusions = true });
    defer bytecode.deinit();
    
    const pretty = try bytecode.pretty_print(allocator);
    defer allocator.free(pretty);
    
    std.debug.print("\n=== Bytecode Analysis ===\n", .{});
    std.debug.print("Code length: {} bytes\n", .{code.len});
    std.debug.print("Instructions:\n{s}\n", .{pretty});
    
    // Now execute with tracer
    var database = Evm.MemoryDatabase.init(allocator);
    defer database.deinit();
    const db_interface = database.interface();
    
    const block_info = primitives.BlockInfo{
        .coinbase = primitives.Address.zero(),
        .gas_limit = 30_000_000,
        .number = 1,
        .timestamp = 1,
        .basefee = 1,
        .prevrandao = primitives.Hash.zero(),
        .blob_base_fee = null,
    };
    
    const tx_context = primitives.TransactionContext{
        .origin = primitives.Address.zero(),
        .gas_price = 1,
        .blob_hashes = &.{},
        .authorization_list = null,
    };
    
    var evm = try Evm.MainnetEvmWithTracer.init(allocator, db_interface, &block_info, &tx_context);
    defer evm.deinit();
    
    const deploy_result = try evm.create(
        primitives.Address.zero(),
        0,
        &code,
        1000000,
    );
    
    std.debug.print("\n=== Execution Result ===\n", .{});
    std.debug.print("Success: {}\n", .{deploy_result.is_success});
    std.debug.print("Gas used: {}\n", .{deploy_result.gas_used});
    
    const tracer = evm.getTracer();
    const steps = tracer.steps.items;
    std.debug.print("Steps captured: {}\n", .{steps.len});
    
    if (steps.len > 0) {
        std.debug.print("\nExecution trace:\n", .{});
        for (steps, 0..) |step, i| {
            std.debug.print("  Step {}: PC={}, Op={s}, Gas={}, Stack depth={}\n", .{
                i, step.pc, @tagName(step.op), step.gas, step.stack.len
            });
        }
    }
}

test "erc20 mint trace - minimal" {
    std.testing.log_level = .err;
    
    const allocator = testing.allocator;
    
    // ERC20 mint function selector and minimal implementation
    // This simulates a simplified mint(address,uint256) call
    // Function selector for mint: 0x40c10f19
    const mint_calldata = [_]u8{
        0x40, 0xc1, 0x0f, 0x19, // function selector
        // address (32 bytes, padded)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, // address ends with 0x01
        // amount (32 bytes)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xe8, // 1000 tokens
    };
    
    // Minimal ERC20 mint implementation
    // Check function selector, update balance, return success
    const contract_code = [_]u8{
        // Load function selector
        0x60, 0x00, // PUSH1 0x00
        0x35,       // CALLDATALOAD
        0x60, 0xe0, // PUSH1 0xe0
        0x1c,       // SHR (shift right by 224 bits to get 4-byte selector)
        
        // Check if it's mint function (0x40c10f19)
        0x63, 0x40, 0xc1, 0x0f, 0x19, // PUSH4 0x40c10f19
        0x14,       // EQ
        0x60, 0x20, // PUSH1 0x20 (jump dest if equal)
        0x57,       // JUMPI
        
        // Not mint, revert
        0x60, 0x00, // PUSH1 0x00
        0x60, 0x00, // PUSH1 0x00
        0xfd,       // REVERT
        
        // Mint implementation starts at PC 0x20
        0x5b,       // JUMPDEST (PC=0x14)
        
        // Load recipient address from calldata[4:36]
        0x60, 0x04, // PUSH1 0x04
        0x35,       // CALLDATALOAD
        
        // Load amount from calldata[36:68]
        0x60, 0x24, // PUSH1 0x24
        0x35,       // CALLDATALOAD
        
        // Store in balance mapping (simplified - just use address as storage key)
        0x81,       // DUP2 (duplicate address)
        0x54,       // SLOAD (load current balance)
        0x01,       // ADD (add new amount)
        0x82,       // DUP3 (duplicate address)
        0x55,       // SSTORE (store new balance)
        
        // Return success (return 32 bytes of 0x01)
        0x60, 0x01, // PUSH1 0x01
        0x60, 0x00, // PUSH1 0x00
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x00, // PUSH1 0x00
        0xf3,       // RETURN
    };
    
    log.debug("Testing ERC20 mint with tracer", .{});
    
    // Set up database with deployed contract
    var database = Evm.MemoryDatabase.init(allocator);
    defer database.deinit();
    
    const contract_address = try primitives.Address.fromHex("0x5FbDB2315678afecb367f032d93F642f64180aa3");
    
    // Add contract to database
    const account = primitives.Account{
        .nonce = 1,
        .balance = 0,
        .code_hash = primitives.Hash.zero(), // Will be set by database
    };
    try database.setAccount(contract_address, account);
    try database.setCode(contract_address, &contract_code);
    
    const db_interface = database.interface();
    
    const block_info = primitives.BlockInfo{
        .coinbase = primitives.Address.zero(),
        .gas_limit = 30_000_000,
        .number = 1,
        .timestamp = 1,
        .basefee = 1,
        .prevrandao = primitives.Hash.zero(),
        .blob_base_fee = null,
    };
    
    const tx_context = primitives.TransactionContext{
        .origin = primitives.Address.zero(),
        .gas_price = 1,
        .blob_hashes = &.{},
        .authorization_list = null,
    };
    
    var evm = try Evm.MainnetEvmWithTracer.init(allocator, db_interface, &block_info, &tx_context);
    defer evm.deinit();
    
    // Call the mint function
    const call_result = try evm.call(
        primitives.Address.zero(), // caller
        contract_address, // target
        0, // value
        &mint_calldata, // calldata
        1000000, // gas limit
    );
    
    std.debug.print("\n=== ERC20 Mint Result ===\n", .{});
    std.debug.print("Success: {}\n", .{call_result.is_success});
    std.debug.print("Gas used: {}\n", .{call_result.gas_used});
    
    const tracer = evm.getTracer();
    const steps = tracer.steps.items;
    std.debug.print("Steps captured: {}\n", .{steps.len});
    
    // Generate and display JSON trace
    const json_trace = try tracer.toJsonRpcTrace(allocator);
    defer allocator.free(json_trace);
    
    std.debug.print("\nJSON trace ({} bytes):\n", .{json_trace.len});
    std.debug.print("{s}\n", .{json_trace});
}