const std = @import("std");
const evm = @import("root.zig");
const Hardfork = @import("evm").Hardfork;
const testing = std.testing;
const primitives = @import("voltaire");

test "EVM basic initialization" {
    const allocator = testing.allocator;
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    
    const DefaultEvmType = evm.DefaultEvm;
    const block_info = evm.BlockInfo.init();
    const tx_context = evm.TransactionContext{
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    const gas_price: u256 = 0;
    const origin = primitives.ZERO_ADDRESS;
    const hardfork = Hardfork.CANCUN;
    
    var vm = try DefaultEvmType.init(allocator, db_interface, block_info, tx_context, gas_price, origin, hardfork);
    defer vm.deinit();
    
    // Test that VM initialized correctly
    try testing.expect(vm.allocator == allocator);
}
