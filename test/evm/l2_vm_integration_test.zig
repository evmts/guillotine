const std = @import("std");
const Evm = @import("evm");
const Address = @import("Address");
const primitives = @import("primitives");

test "VM executes Arbitrum precompile calls" {
    const allocator = std.testing.allocator;
    
    // Create a memory database
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    
    // Initialize VM with Arbitrum chain type
    var vm = try Evm.Evm.init_with_hardfork_and_chain(allocator, db_interface, .CANCUN, .ARBITRUM);
    defer vm.deinit();
    
    // Create a contract that calls ArbSys.arbBlockNumber()
    // PUSH20 <ArbSys address>
    // PUSH1 0x00  // value
    // PUSH1 0x20  // output size
    // PUSH1 0x00  // output offset
    // PUSH1 0x04  // input size
    // PUSH1 0x00  // input offset
    // PUSH2 0x1000 // gas
    // STATICCALL
    // PUSH1 0x00  // return data offset
    // MLOAD       // load result
    const bytecode = [_]u8{
        // PUSH20 ArbSys address (0x64)
        0x73, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x64,
        // PUSH1 0x00 (value)
        0x60, 0x00,
        // PUSH1 0x20 (output size)
        0x60, 0x20,
        // PUSH1 0x00 (output offset)
        0x60, 0x00,
        // PUSH1 0x04 (input size)
        0x60, 0x04,
        // PUSH1 0x00 (input offset)
        0x60, 0x00,
        // PUSH2 0x1000 (gas)
        0x61, 0x10, 0x00,
        // STATICCALL
        0xFA,
        // PUSH1 0x00
        0x60, 0x00,
        // MLOAD
        0x51,
    };
    
    // First store the function selector in memory
    // arbBlockNumber() = 0xa3b1b31d
    const caller = Address.from_hex("0x1234567890123456789012345678901234567890") catch unreachable;
    var contract = try Evm.Contract.init(allocator, bytecode[0..], .{
        .address = caller,
        .gas = 100000,
    });
    defer contract.deinit(allocator, null);
    
    var frame = try Evm.Frame.init(allocator, &vm, 100000, contract, caller, &.{});
    defer frame.deinit();
    
    // Store function selector in memory
    const selector_bytes = [_]u8{ 0xa3, 0xb1, 0xb3, 0x1d };
    try frame.memory.store(0, &selector_bytes);
    
    // Execute the bytecode
    const interpreter_ptr: *Evm.Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Evm.Operation.State = @ptrCast(&frame);
    
    // Execute each instruction
    var pc: usize = 0;
    while (pc < bytecode.len) {
        const op = bytecode[pc];
        const result = try vm.table.execute(0, interpreter_ptr, state_ptr, op);
        
        if (result.action == .STOP or result.action == .RETURN) {
            break;
        }
        
        pc = switch (result.action) {
            .CONTINUE => pc + result.pc_offset,
            .JUMP => result.new_pc,
            else => unreachable,
        };
    }
    
    // Check that we got the expected block number (42) on the stack
    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(primitives.U256, 42), result);
}

test "VM rejects L2 precompiles on Ethereum mainnet" {
    const allocator = std.testing.allocator;
    
    // Create a memory database
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    
    // Initialize VM with Ethereum chain type (default)
    var vm = try Evm.Evm.init_with_hardfork(allocator, db_interface, .CANCUN);
    defer vm.deinit();
    
    // Try to call ArbSys on Ethereum - should fail
    const arb_sys_address = Address.from_hex("0x0000000000000000000000000000000000000064") catch unreachable;
    const input = &[_]u8{ 0xa3, 0xb1, 0xb3, 0x1d }; // arbBlockNumber selector
    var output: [32]u8 = undefined;
    
    const result = Evm.Precompiles.execute_precompile(arb_sys_address, input, &output, 1000, vm.chain_rules);
    
    // Should fail because ArbSys is not available on Ethereum
    try std.testing.expect(result.is_failure());
}