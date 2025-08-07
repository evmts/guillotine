const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");

// Load the ERC20 bytecode that's causing issues
fn loadERC20Bytecode(allocator: std.mem.Allocator) ![]u8 {
    const bytecode_path = "/Users/williamcory/Guillotine/bench/official/cases/erc20-transfer/bytecode.txt";
    const file = try std.fs.openFileAbsolute(bytecode_path, .{});
    defer file.close();
    
    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);
    
    const trimmed = std.mem.trim(u8, content, " \t\n\r");
    const clean_hex = if (std.mem.startsWith(u8, trimmed, "0x"))
        trimmed[2..]
    else
        trimmed;
    
    const bytes = try allocator.alloc(u8, clean_hex.len / 2);
    var i: usize = 0;
    while (i < clean_hex.len) : (i += 2) {
        const byte_str = clean_hex[i .. i + 2];
        bytes[i / 2] = try std.fmt.parseInt(u8, byte_str, 16);
    }
    
    return bytes;
}

test "ERC20 contract deployment hangs - minimal reproduction" {
    std.testing.log_level = .debug;
    const allocator = std.testing.allocator;
    
    std.log.info("=== TEST: Starting ERC20 deployment hang reproduction ===", .{});
    
    // Load the problematic ERC20 bytecode
    const bytecode = try loadERC20Bytecode(allocator);
    defer allocator.free(bytecode);
    std.log.info("TEST: Loaded ERC20 bytecode, size={}", .{bytecode.len});
    
    // Initialize EVM
    // Use normal allocator (EVM will handle internal arena allocation)
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm_builder = evm.EvmBuilder.init(allocator, db_interface);
    var vm = try evm_builder.build();
    defer vm.deinit();
    
    // Set up deployer account
    const deployer = try primitives.Address.from_hex("0x1000000000000000000000000000000000000001");
    try vm.state.set_balance(deployer, std.math.maxInt(u256));
    
    // Attempt to deploy the contract - this should hang
    std.log.info("TEST: About to deploy ERC20 contract with create_contract", .{});
    const result = try vm.create_contract(
        deployer,
        0, // value
        bytecode, // init code
        10_000_000 // gas
    );
    
    std.log.info("TEST: Deployment result: success={}, gas_left={}", .{result.success, result.gas_left});
    
    if (result.success) {
        std.log.info("TEST: Contract deployed at address: {any}", .{result.address});
    } else {
        std.log.info("TEST: Deployment failed", .{});
    }
}

test "Simple contract deployment works" {
    std.testing.log_level = .debug;
    const allocator = std.testing.allocator;
    
    std.log.info("=== TEST: Starting simple contract deployment test ===", .{});
    
    // Simple bytecode that just returns 42
    const simple_bytecode = &[_]u8{
        0x60, 0x2a, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    std.log.info("TEST: Simple bytecode size={}", .{simple_bytecode.len});
    
    // Initialize EVM
    // Use normal allocator (EVM will handle internal arena allocation)
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm_builder = evm.EvmBuilder.init(allocator, db_interface);
    var vm = try evm_builder.build();
    defer vm.deinit();
    
    // Set up deployer account
    const deployer = try primitives.Address.from_hex("0x1000000000000000000000000000000000000001");
    try vm.state.set_balance(deployer, std.math.maxInt(u256));
    
    // Deploy the simple contract
    std.log.info("TEST: About to deploy simple contract", .{});
    const result = try vm.create_contract(
        deployer,
        0, // value
        simple_bytecode, // init code
        10_000_000 // gas
    );
    
    std.log.info("TEST: Deployment result: success={}, gas_left={}", .{result.success, result.gas_left});
    
    try std.testing.expect(result.success);
}