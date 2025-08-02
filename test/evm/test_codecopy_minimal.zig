const std = @import("std");
const testing = std.testing;

test {
    std.testing.log_level = .debug;
}

const Evm = @import("evm");
const primitives = @import("primitives");

test "CODECOPY minimal execution" {
    const allocator = testing.allocator;
    
    // Set up EVM
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);
    
    var vm = try builder.build();
    defer vm.deinit();
    
    // Minimal CODECOPY test - copy 5 bytes of code to memory
    const bytecode = &[_]u8{
        0x60, 0x05, // PUSH1 5 (size)
        0x60, 0x00, // PUSH1 0 (code offset)
        0x60, 0x00, // PUSH1 0 (dest offset)
        0x39,       // CODECOPY
        0x60, 0x05, // PUSH1 5 (size for RETURN)
        0x60, 0x00, // PUSH1 0 (offset for RETURN)
        0xf3,       // RETURN
    };
    
    // For now, just use zeros as code hash - it's not used in the test
    const code_hash = [_]u8{0} ** 32;
    
    const contract = Evm.Contract.init(
        primitives.Address.ZERO, // caller
        primitives.Address.ZERO, // address
        0, // value
        1000000, // gas
        bytecode,
        code_hash,
        &.{}, // input
        false, // is_static
    );
    
    var contract_mut = contract;
    const result = try vm.interpret(&contract_mut, &.{}, false);
    defer if (result.output) |output| allocator.free(output);
    
    // Should have succeeded
    try testing.expectEqual(Evm.RunResult.Status.Success, result.status);
    
    // Output should be first 5 bytes of bytecode
    try testing.expect(result.output != null);
    try testing.expectEqual(@as(usize, 5), result.output.?.len);
    try testing.expectEqualSlices(u8, bytecode[0..5], result.output.?);
}