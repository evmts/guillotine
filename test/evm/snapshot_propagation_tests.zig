//! Tests for snapshot id propagation in nested calls and reverts
//! These tests verify that journal entries are recorded to the correct snapshot
//! and that revert operations apply to the correct scope

const std = @import("std");
const evm = @import("evm");
const Frame = evm.Frame;
const EvmType = evm.Evm(.{});
const MemoryDatabase = evm.MemoryDatabase;
const Account = evm.Account;
const Hardfork = evm.Hardfork;
const primitives = @import("voltaire");
const Address = primitives.Address.Address;
const address_utils = primitives.Address;
const ZERO_ADDRESS = primitives.ZERO_ADDRESS;

fn to_address(n: u32) Address {
    var addr = ZERO_ADDRESS;
    std.mem.writeInt(u32, addr[16..20], n, .big);
    return addr;
}

fn to_u256(addr: Address) u256 {
    return address_utils.to_u256(addr);
}

// Helper to create test EVM
const TestEvm = struct {
    evm: *EvmType,
    memory_db: *MemoryDatabase,
};

fn createTestEvm(allocator: std.mem.Allocator) !TestEvm {
    var memory_db = try allocator.create(MemoryDatabase);
    memory_db.* = MemoryDatabase.init(allocator);
    
    const db_interface = memory_db.to_database_interface();
    const block_info = evm.BlockInfo.init();
    const tx_context = evm.TransactionContext{
        .gas_limit = 30_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };
    const gas_price: u256 = 0;
    const origin = ZERO_ADDRESS;
    const hardfork = Hardfork.CANCUN;
    const evm = try allocator.create(EvmType);
    evm.* = try EvmType.init(allocator, db_interface, block_info, tx_context, gas_price, origin, hardfork);
    
    return TestEvm{ .evm = evm, .memory_db = memory_db };
}

// Contract that stores a value and then calls another contract
const STORE_AND_CALL_CONTRACT = [_]u8{
    // Store value 100 at slot 0
    0x60, 0x64, // PUSH1 100
    0x60, 0x00, // PUSH1 0 (slot)
    0x55,       // SSTORE
    
    // Load target address from calldata (first 32 bytes)
    0x60, 0x00, // PUSH1 0
    0x35,       // CALLDATALOAD
    
    // Make a CALL with value 50
    0x60, 0x00, // PUSH1 0 (output size)
    0x60, 0x00, // PUSH1 0 (output offset)  
    0x60, 0x00, // PUSH1 0 (input size)
    0x60, 0x00, // PUSH1 0 (input offset)
    0x60, 0x32, // PUSH1 50 (value)
    0x83,       // DUP4 (address from calldata)
    0x5A,       // GAS
    0xF1,       // CALL
    
    // Store result at slot 1
    0x60, 0x01, // PUSH1 1 (slot)
    0x55,       // SSTORE
    
    // Return success
    0x60, 0x01, // PUSH1 1
    0x60, 0x00, // PUSH1 0
    0x52,       // MSTORE
    0x60, 0x20, // PUSH1 32
    0x60, 0x00, // PUSH1 0
    0xF3,       // RETURN
};

// Contract that stores a value and then reverts
const STORE_AND_REVERT_CONTRACT = [_]u8{
    // Store value 200 at slot 0
    0x60, 0xC8, // PUSH1 200
    0x60, 0x00, // PUSH1 0 (slot)
    0x55,       // SSTORE
    
    // Store value 300 at slot 1
    0x61, 0x01, 0x2C, // PUSH2 300
    0x60, 0x01, // PUSH1 1 (slot)
    0x55,       // SSTORE
    
    // Revert with empty data
    0x60, 0x00, // PUSH1 0 (size)
    0x60, 0x00, // PUSH1 0 (offset)
    0xFD,       // REVERT
};

// Contract that stores a value and returns success
const STORE_AND_SUCCESS_CONTRACT = [_]u8{
    // Store value 400 at slot 0
    0x61, 0x01, 0x90, // PUSH2 400
    0x60, 0x00, // PUSH1 0 (slot)
    0x55,       // SSTORE
    
    // Return success
    0x60, 0x01, // PUSH1 1
    0x60, 0x00, // PUSH1 0
    0x52,       // MSTORE
    0x60, 0x20, // PUSH1 32
    0x60, 0x00, // PUSH1 0
    0xF3,       // RETURN
};


