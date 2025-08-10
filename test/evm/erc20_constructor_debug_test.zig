const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const Address = @import("Address").Address;

test "debug: minimal ERC20 constructor execution" {
    const allocator = testing.allocator;

    // Minimal Solidity constructor that should work:
    // constructor() {
    //     // Store name "Token" at slot 0
    //     // Store symbol "TKN" at slot 1
    //     // Store decimals 18 at slot 2
    //     // Store totalSupply 0 at slot 3
    // }

    // Let's start with something even simpler - just STOP
    const simple_constructor = "\x00"; // STOP opcode

    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var vm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer vm.deinit();

    const caller = Address.from_u256(0x1000000000000000000000000000000000000001);
    try vm.state.set_balance(caller, std.math.maxInt(u256));

    std.log.debug("=== Testing simple STOP constructor ===", .{});
    const create_result = try vm.create_contract(caller, 0, simple_constructor, 1_000_000);
    defer if (create_result.output) |output| allocator.free(output);

    std.log.debug("Simple constructor result: success={}, gas_left={}", .{ create_result.success, create_result.gas_left });

    try testing.expect(create_result.success);
}

test "debug: minimal storage constructor" {
    const allocator = testing.allocator;

    // Constructor that stores a single value:
    // PUSH1 0x42  ; value to store
    // PUSH1 0x00  ; storage slot 0
    // SSTORE      ; store value
    // STOP        ; return empty runtime code
    const storage_constructor = "\x60\x42\x60\x00\x55\x00";

    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var vm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer vm.deinit();

    const caller = Address.from_u256(0x1000000000000000000000000000000000000001);
    try vm.state.set_balance(caller, std.math.maxInt(u256));

    std.log.debug("=== Testing storage constructor ===", .{});
    const create_result = try vm.create_contract(caller, 0, storage_constructor, 1_000_000);
    defer if (create_result.output) |output| allocator.free(output);

    std.log.debug("Storage constructor result: success={}, gas_left={}", .{ create_result.success, create_result.gas_left });

    try testing.expect(create_result.success);

    // Verify the value was stored
    const stored_value = vm.state.get_storage(create_result.address, 0);
    try testing.expectEqual(@as(u256, 0x42), stored_value);
}

test "debug: analyze ERC20 constructor bytecode" {
    const allocator = testing.allocator;

    // Read the actual ERC20 bytecode
    const file_content = try std.fs.cwd().readFileAlloc(allocator, "test/evm/erc20_mint.hex", 1024 * 1024);
    defer allocator.free(file_content);

    const hex_str = std.mem.trim(u8, file_content, " \n\r\t");
    const bytecode = try allocator.alloc(u8, hex_str.len / 2);
    defer allocator.free(bytecode);
    _ = try std.fmt.hexToBytes(bytecode, hex_str);

    std.log.debug("=== Analyzing ERC20 bytecode ===", .{});
    std.log.debug("Total bytecode length: {}", .{bytecode.len});

    // The bytecode contains both constructor and runtime code
    // Let's look at the first few opcodes
    std.log.debug("First 20 bytes: {x}", .{bytecode[0..20]});

    // Look for CODECOPY pattern which separates constructor from runtime
    var i: usize = 0;
    while (i < bytecode.len and i < 200) : (i += 1) {
        if (bytecode[i] == 0x39) { // CODECOPY opcode
            std.log.debug("Found CODECOPY at position {}", .{i});
            if (i >= 6) {
                std.log.debug("Context around CODECOPY: {x}", .{bytecode[i - 6 .. @min(i + 10, bytecode.len)]});
            }
        }
        if (bytecode[i] == 0xfd) { // REVERT opcode
            std.log.debug("Found REVERT at position {}", .{i});
            if (i >= 6) {
                std.log.debug("Context around REVERT: {x}", .{bytecode[i - 6 .. @min(i + 10, bytecode.len)]});
            }
        }
    }
}
