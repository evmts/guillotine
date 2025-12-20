//! Test helpers for Frame integration tests
//! Provides utilities to create real EVM instances for testing Frame operations

const std = @import("std");
const Evm = @import("evm").DefaultEvm;
const MemoryDatabase = @import("evm").MemoryDatabase;
const Address = @import("voltaire").Address.Address;
const primitives = @import("voltaire");
const BlockInfo = @import("evm").BlockInfo;
const TransactionContext = @import("evm").TransactionContext;
const Hardfork = @import("evm").Hardfork;
const Account = @import("evm").Account;

/// Result of creating a test EVM
pub const TestEvm = struct {
    evm: *Evm,
    memory_db: *MemoryDatabase,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TestEvm) void {
        self.evm.deinit();
        self.allocator.destroy(self.evm);
        self.memory_db.deinit();
        self.allocator.destroy(self.memory_db);
    }
};

/// Create a configured EVM instance for testing
pub fn createTestEvm(allocator: std.mem.Allocator) !TestEvm {
    const memory_db = try allocator.create(MemoryDatabase);
    errdefer allocator.destroy(memory_db);
    
    memory_db.* = MemoryDatabase.init(allocator);
    errdefer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    
    const block_info = BlockInfo.init();
    const tx_context = TransactionContext{
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    const gas_price = 0;
    const origin = primitives.ZERO_ADDRESS;
    const hardfork = Hardfork.CANCUN;
    
    const evm = try allocator.create(Evm);
    errdefer allocator.destroy(evm);
    
    evm.* = try Evm.init(allocator, db_interface, block_info, tx_context, gas_price, origin, hardfork);
    
    return TestEvm{
        .evm = evm,
        .memory_db = memory_db,
        .allocator = allocator,
    };
}

/// Convert a number to an Address
pub fn toAddress(value: u256) Address {
    var addr: Address = [_]u8{0} ** 20;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        addr[19 - i] = @truncate(value >> @intCast(i * 8));
    }
    return addr;
}

/// Convert an Address to u256
pub fn addressToU256(addr: Address) u256 {
    var result: u256 = 0;
    for (addr, 0..) |byte, i| {
        result |= @as(u256, byte) << @intCast((19 - i) * 8);
    }
    return result;
}

/// Set up an account with code and balance
pub fn setupAccount(test_evm: *TestEvm, address: Address, balance: u256, code: []const u8) !void {
    var account = Account.zero();
    account.balance = balance;
    
    if (code.len > 0) {
        const code_hash = try test_evm.evm.database.set_code(code);
        account.code_hash = code_hash;
    }
    
    try test_evm.evm.database.set_account(address, account);
}

/// Deploy a contract that returns success
pub fn deploySuccessContract(test_evm: *TestEvm, address: Address) !void {
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE (store 1 at memory offset 0)
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN (return 32 bytes from offset 0)
    };
    try setupAccount(test_evm, address, 0, &bytecode);
}

/// Deploy a contract that reverts
pub fn deployRevertContract(test_evm: *TestEvm, address: Address) !void {
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0xFD,       // REVERT
    };
    try setupAccount(test_evm, address, 0, &bytecode);
}

/// Deploy a contract that tries to modify storage (for STATICCALL tests)
pub fn deployStorageModifierContract(test_evm: *TestEvm, address: Address) !void {
    const bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE (try to store 0x42 at slot 0)
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    try setupAccount(test_evm, address, 0, &bytecode);
}

/// Deploy a contract that reads caller and value (for DELEGATECALL tests)
pub fn deployContextReaderContract(test_evm: *TestEvm, address: Address) !void {
    const bytecode = [_]u8{
        0x33,       // CALLER
        0x34,       // CALLVALUE
        0x01,       // ADD (combine them)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    try setupAccount(test_evm, address, 0, &bytecode);
}

/// Get init code for a simple contract deployment
pub fn getSimpleInitCode() [22]u8 {
    return [_]u8{
        // Constructor: return a simple contract that stores 42
        0x60, 0x0A, // PUSH1 10 (size of runtime code)
        0x60, 0x0C, // PUSH1 12 (offset of runtime code)
        0x60, 0x00, // PUSH1 0 (destination in memory)
        0x39,       // CODECOPY
        0x60, 0x0A, // PUSH1 10 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xF3,       // RETURN
        // Runtime code (10 bytes):
        0x60, 0x2A, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
}