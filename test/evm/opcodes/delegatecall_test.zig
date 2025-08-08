const std = @import("std");
const testing = std.testing;

// test {
//     std.testing.log_level = .debug;
// }
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const CallParams = Evm.Host.CallParams;
const CallResult = Evm.CallResult;
// Updated to new API - migration in progress, tests not run yet

// test {
//     std.testing.log_level = .debug;
// }

const Vm = Evm.Evm;
const Contract = Evm.Contract;
const MemoryDatabase = Evm.MemoryDatabase;
const Context = Evm.Context;
const Account = Evm.Account;

test "DELEGATECALL basic functionality" {
    const allocator = testing.allocator;

    // Initialize database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Setup context
    const context = Context.init_with_values(
        primitives.Address.from_u256(0x1111), // tx origin
        1000000000, // gas price
        1, // block number
        1000, // timestamp
        primitives.Address.ZERO_ADDRESS, // coinbase
        0, // difficulty
        10000000, // gas limit
        1, // chain id
        0, // base fee
        &.{}, // blob hashes
        0, // blob base fee
    );
    vm.set_context(context);

    // Deploy callee contract that returns caller address
    // Contract code: CALLER PUSH1 0x00 MSTORE PUSH1 0x20 PUSH1 0x00 RETURN
    // Bytecode: 0x33 0x60 0x00 0x52 0x60 0x20 0x60 0x00 0xf3
    const callee_code = [_]u8{ 0x33, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    const callee_addr = primitives.Address.from_u256(0x2222);
    try vm.state.set_code(callee_addr, &callee_code);

    // Deploy caller contract that uses DELEGATECALL
    // Contract code:
    // PUSH1 0x20    // retSize (32 bytes for the returned address)
    // PUSH1 0x00    // retOffset
    // PUSH1 0x00    // argsSize
    // PUSH1 0x00    // argsOffset
    // PUSH20 <callee_addr>  // address
    // GAS           // gas
    // DELEGATECALL  // execute
    // PUSH1 0x20    // size
    // PUSH1 0x00    // offset
    // RETURN        // return the result
    var caller_code = std.ArrayList(u8).init(allocator);
    defer caller_code.deinit();

    // Build the bytecode
    try caller_code.appendSlice(&[_]u8{
        0x60, 0x20, // PUSH1 0x20 (retSize - 32 bytes)
        0x60, 0x00, // PUSH1 0x00 (retOffset)
        0x60, 0x00, // PUSH1 0x00 (argsSize)
        0x60, 0x00, // PUSH1 0x00 (argsOffset)
        0x73, // PUSH20
    });
    try caller_code.appendSlice(&callee_addr); // Push callee address
    try caller_code.appendSlice(&[_]u8{
        0x5a, // GAS
        0xf4, // DELEGATECALL
        0x60, 0x20, // PUSH1 0x20 (size)
        0x60, 0x00, // PUSH1 0x00 (offset)
        0xf3, // RETURN
    });

    const caller_addr = primitives.Address.from_u256(0x3333);
    try vm.state.set_code(caller_addr, caller_code.items);

    // Execute call from EOA to caller contract
    const eoa_addr = primitives.Address.from_u256(0x4444);
    try vm.state.set_balance(eoa_addr, 1000000);

    var contract = Contract.init_at_address(
        eoa_addr, // caller
        caller_addr, // address
        0, // value
        100000, // gas
        caller_code.items,
        &.{}, // input
        false, // static
    );
    defer contract.deinit(allocator, null);

    const result = try vm.interpret(&contract, &.{}, false);
    defer if (result.output) |out| allocator.free(out);

    // Verify execution succeeded
    try testing.expectEqual(.Success, result.status);

    // Verify the returned data is the EOA address (preserved through DELEGATECALL)
    // In DELEGATECALL, msg.sender is preserved from the original call
    try testing.expect(result.output != null);
    try testing.expectEqual(@as(usize, 32), result.output.?.len);

    // The CALLER opcode in delegated code should return the EOA address (preserved)
    var expected_addr = [_]u8{0} ** 32;
    @memcpy(expected_addr[12..32], &eoa_addr);
    try testing.expectEqualSlices(u8, &expected_addr, result.output.?);
}

test "DELEGATECALL preserves sender and value" {
    const allocator = testing.allocator;

    // Initialize database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Setup context
    const context = Context.init();
    vm.set_context(context);

    // Deploy callee contract that returns CALLER and CALLVALUE
    // Contract code:
    // CALLER PUSH1 0x00 MSTORE
    // CALLVALUE PUSH1 0x20 MSTORE
    // PUSH1 0x00 PUSH1 0x40 RETURN
    const callee_code = [_]u8{
        0x33, 0x60, 0x00, 0x52, // CALLER, PUSH1 0x00, MSTORE
        0x34, 0x60, 0x20, 0x52, // CALLVALUE, PUSH1 0x20, MSTORE
        0x60, 0x40, 0x60, 0x00,
        0xf3, // PUSH1 0x40, PUSH1 0x00, RETURN
    };
    const callee_addr = primitives.Address.from_u256(0x5555);
    try vm.state.set_code(callee_addr, &callee_code);

    // Create caller contract that delegates to callee
    var caller_code = std.ArrayList(u8).init(allocator);
    defer caller_code.deinit();

    try caller_code.appendSlice(&[_]u8{
        0x60, 0x40, // PUSH1 0x40 (retSize - return 64 bytes)
        0x60, 0x00, // PUSH1 0x00 (retOffset)
        0x60, 0x00, // PUSH1 0x00 (argsSize)
        0x60, 0x00, // PUSH1 0x00 (argsOffset)
        0x73, // PUSH20
    });
    try caller_code.appendSlice(&callee_addr);
    try caller_code.appendSlice(&[_]u8{
        0x5a, // GAS
        0xf4, // DELEGATECALL
        0x60, 0x40, // PUSH1 0x40 (size)
        0x60, 0x00, // PUSH1 0x00 (offset)
        0xf3, // RETURN
    });

    const caller_addr = primitives.Address.from_u256(0x6666);
    try vm.state.set_code(caller_addr, caller_code.items);

    // Execute with value
    const eoa_addr = primitives.Address.from_u256(0x7777);
    try vm.state.set_balance(eoa_addr, 1000000);

    var contract = Contract.init_at_address(
        eoa_addr,
        caller_addr,
        12345, // value
        100000, // gas
        caller_code.items,
        &.{}, // input
        false, // static
    );
    defer contract.deinit(allocator, null);

    const result = try vm.interpret(&contract, &.{}, false);
    defer if (result.output) |out| allocator.free(out);

    try testing.expectEqual(.Success, result.status);
    try testing.expect(result.output != null);
    try testing.expectEqual(@as(usize, 64), result.output.?.len);

    // First 32 bytes: CALLER should be the EOA (preserved from original call)
    var expected_caller = [_]u8{0} ** 32;
    @memcpy(expected_caller[12..32], &eoa_addr);
    try testing.expectEqualSlices(u8, expected_caller[0..32], result.output.?[0..32]);

    // Second 32 bytes: CALLVALUE should be 12345
    var expected_value = [_]u8{0} ** 32;
    std.mem.writeInt(u256, &expected_value, 12345, .big);
    try testing.expectEqualSlices(u8, &expected_value, result.output.?[32..64]);
}

test "DELEGATECALL with storage access" {
    const allocator = testing.allocator;

    // Initialize database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Setup context
    const context = Context.init();
    vm.set_context(context);

    // Deploy callee contract that reads and writes storage
    // Contract code:
    // PUSH1 0x42 PUSH1 0x01 SSTORE  // Store 0x42 at slot 1
    // PUSH1 0x01 SLOAD              // Load from slot 1
    // PUSH1 0x00 MSTORE             // Store in memory
    // PUSH1 0x00 PUSH1 0x20 RETURN  // Return 32 bytes
    const callee_code = [_]u8{
        0x60, 0x42, 0x60, 0x01, 0x55, // PUSH1 0x42, PUSH1 0x01, SSTORE
        0x60, 0x01, 0x54, // PUSH1 0x01, SLOAD
        0x60, 0x00, 0x52, // PUSH1 0x00, MSTORE
        0x60, 0x20, 0x60,
        0x00, 0xf3, // PUSH1 0x20, PUSH1 0x00, RETURN
    };
    const callee_addr = primitives.Address.from_u256(0x8888);
    try vm.state.set_code(callee_addr, &callee_code);

    // Create caller contract
    var caller_code = std.ArrayList(u8).init(allocator);
    defer caller_code.deinit();

    try caller_code.appendSlice(&[_]u8{
        0x60, 0x20, // PUSH1 0x20 (retSize)
        0x60, 0x00, // PUSH1 0x00 (retOffset)
        0x60, 0x00, // PUSH1 0x00 (argsSize)
        0x60, 0x00, // PUSH1 0x00 (argsOffset)
        0x73, // PUSH20
    });
    try caller_code.appendSlice(&callee_addr);
    try caller_code.appendSlice(&[_]u8{
        0x5a, // GAS
        0xf4, // DELEGATECALL
        0x60, 0x20, // PUSH1 0x20 (size)
        0x60, 0x00, // PUSH1 0x00 (offset)
        0xf3, // RETURN
    });

    const caller_addr = primitives.Address.from_u256(0x9999);
    try vm.state.set_code(caller_addr, caller_code.items);

    // Execute
    const eoa_addr = primitives.Address.from_u256(0xAAAA);
    var contract = Contract.init_at_address(
        eoa_addr,
        caller_addr,
        0,
        100000,
        caller_code.items,
        &.{},
        false,
    );
    defer contract.deinit(allocator, null);

    const result = try vm.interpret(&contract, &.{}, false);
    defer if (result.output) |out| allocator.free(out);

    try testing.expectEqual(.Success, result.status);

    // Verify storage was written to caller's address, not callee's
    const caller_storage = try db_interface.get_storage(caller_addr, 1);
    try testing.expectEqual(@as(u256, 0x42), caller_storage);

    const callee_storage = try db_interface.get_storage(callee_addr, 1);
    try testing.expectEqual(@as(u256, 0), callee_storage);
}
