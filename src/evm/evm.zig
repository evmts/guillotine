const std = @import("std");
const Contract = @import("frame/contract.zig");
const Stack = @import("stack/stack.zig");
const JumpTable = @import("jump_table/jump_table.zig");
const Frame = @import("frame/frame.zig");
const Operation = @import("opcodes/operation.zig");
const primitives = @import("primitives");
const StoragePool = @import("frame/storage_pool.zig");
const AccessList = @import("access_list/access_list.zig");
const ExecutionError = @import("execution/execution_error.zig");
const Keccak256 = std.crypto.hash.sha3.Keccak256;
const ChainRules = @import("hardforks/chain_rules.zig");
const gas_constants = @import("constants/gas_constants.zig");
const constants = @import("constants/constants.zig");
const Log = @import("log.zig");
const EvmLog = @import("state/evm_log.zig");
const Context = @import("access_list/context.zig");
const EvmState = @import("state/state.zig");
pub const StorageKey = @import("primitives").StorageKey;
pub const CreateResult = @import("evm/create_result.zig").CreateResult;
pub const CallResult = @import("evm/call_result.zig").CallResult;
pub const RunResult = @import("evm/run_result.zig").RunResult;
const Hardfork = @import("hardforks/hardfork.zig").Hardfork;
const precompiles = @import("precompiles/precompiles.zig");

/// Virtual Machine for executing Ethereum bytecode.
///
/// Manages contract execution, gas accounting, state access, and protocol enforcement
/// according to the configured hardfork rules. Supports the full EVM instruction set
/// including contract creation, calls, and state modifications.
const Evm = @This();

// Hot fields (frequently accessed during execution)
/// Memory allocator for VM operations
allocator: std.mem.Allocator,
/// Opcode dispatch table for the configured hardfork
table: JumpTable,
/// Current call depth for overflow protection
depth: u16 = 0,
/// Whether the current context is read-only (STATICCALL)
read_only: bool = false,

// Configuration fields (set at initialization)
/// Protocol rules for the current hardfork
chain_rules: ChainRules,
/// Execution context providing transaction and block information
context: Context,

// Data fields (moderate access frequency)
/// Return data from the most recent operation
return_data: []u8 = &[_]u8{},

// Large state structures (placed last to minimize offset impact)
/// World state including accounts, storage, and code
state: EvmState,
/// Warm/cold access tracking for EIP-2929 gas costs
access_list: AccessList,
/// Legacy stack field (unused in current implementation)
stack: Stack = .{},

/// Initialize VM with a jump table and corresponding chain rules.
///
/// @param allocator Memory allocator for VM operations
/// @param jump_table Optional jump table. If null, uses JumpTable.DEFAULT (latest hardfork)
/// @param chain_rules Optional chain rules. If null, uses ChainRules.DEFAULT (latest hardfork)
/// @return Initialized VM instance
/// @throws std.mem.Allocator.Error if allocation fails
///
/// Example with custom jump table and rules:
/// ```zig
/// const my_table = comptime JumpTable.init_from_hardfork(.BERLIN);
/// const my_rules = ChainRules.for_hardfork(.BERLIN);
/// var vm = try VM.init(allocator, &my_table, &my_rules);
/// ```
///
/// Example with default (latest):
/// ```zig
/// var vm = try VM.init(allocator, null, null);
/// ```
pub fn init(allocator: std.mem.Allocator, database: @import("state/database_interface.zig").DatabaseInterface, jump_table: ?*const JumpTable, chain_rules: ?*const ChainRules) !Evm {
    Log.debug("VM.init: Initializing VM with allocator and database", .{});

    var state = try EvmState.init(allocator, database);
    errdefer state.deinit();

    const context = Context.init();
    var access_list = AccessList.init(allocator, context);
    errdefer access_list.deinit();

    Log.debug("Evm.init: VM initialization complete", .{});
    return Evm{
        .allocator = allocator,
        .table = (jump_table orelse &JumpTable.DEFAULT).*,
        .depth = 0,
        .read_only = false,
        .chain_rules = (chain_rules orelse &ChainRules.DEFAULT).*,
        .context = context,
        .return_data = &[_]u8{},
        .state = state,
        .access_list = access_list,
        .stack = .{},
    };
}

/// Initialize VM with a specific hardfork.
/// Convenience function that creates the jump table at runtime.
/// For production use, consider pre-generating the jump table at compile time.
/// @param allocator Memory allocator for VM operations
/// @param database Database interface for state management
/// @param hardfork Ethereum hardfork to configure for
/// @return Initialized VM instance
/// @throws std.mem.Allocator.Error if allocation fails
pub fn init_with_hardfork(allocator: std.mem.Allocator, database: @import("state/database_interface.zig").DatabaseInterface, hardfork: Hardfork) !Evm {
    const table = JumpTable.init_from_hardfork(hardfork);
    const rules = ChainRules.for_hardfork(hardfork);
    return try init(allocator, database, &table, &rules);
}

/// Free all VM resources.
/// Must be called when finished with the VM to prevent memory leaks.
pub fn deinit(self: *Evm) void {
    self.state.deinit();
    self.access_list.deinit();
    Contract.clear_analysis_cache(self.allocator);
}

pub usingnamespace @import("evm/set_context.zig");
pub usingnamespace @import("evm/interpret.zig");
pub usingnamespace @import("evm/interpret_static.zig");
pub usingnamespace @import("evm/interpret_with_context.zig");
pub usingnamespace @import("evm/create_contract_internal.zig");
pub usingnamespace @import("evm/create_contract.zig");
pub usingnamespace @import("evm/call_contract.zig");
pub usingnamespace @import("evm/execute_precompile_call.zig");
pub usingnamespace @import("evm/create2_contract.zig");
pub usingnamespace @import("evm/callcode_contract.zig");
pub usingnamespace @import("evm/delegatecall_contract.zig");
pub usingnamespace @import("evm/staticcall_contract.zig");
pub usingnamespace @import("evm/emit_log.zig");
pub usingnamespace @import("evm/validate_static_context.zig");
pub usingnamespace @import("evm/set_storage_protected.zig");
pub usingnamespace @import("evm/set_transient_storage_protected.zig");
pub usingnamespace @import("evm/set_balance_protected.zig");
pub usingnamespace @import("evm/set_code_protected.zig");
pub usingnamespace @import("evm/emit_log_protected.zig");
pub usingnamespace @import("evm/create_contract_protected.zig");
pub usingnamespace @import("evm/create2_contract_protected.zig");
pub usingnamespace @import("evm/validate_value_transfer.zig");
pub usingnamespace @import("evm/selfdestruct_protected.zig");

pub const ConsumeGasError = ExecutionError.Error;

const testing = std.testing;
const MemoryDatabase = @import("state/memory_database.zig");

test "Evm.init default configuration" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null);
    defer evm.deinit();
    
    try testing.expect(evm.allocator.ptr == allocator.ptr);
    try testing.expectEqual(@as(usize, 0), evm.return_data.len);
    try testing.expectEqual(@as(usize, 0), evm.stack.size);
    try testing.expectEqual(@as(u16, 0), evm.depth);
    try testing.expectEqual(false, evm.read_only);
}

test "Evm.init custom jump table and chain rules" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    const custom_table = JumpTable.init_from_hardfork(.BERLIN);
    const custom_rules = ChainRules.for_hardfork(.BERLIN);
    
    var evm = try Evm.init(allocator, db_interface, &custom_table, &custom_rules);
    defer evm.deinit();
    
    try testing.expect(evm.allocator.ptr == allocator.ptr);
    try testing.expectEqual(@as(usize, 0), evm.return_data.len);
    try testing.expectEqual(@as(u16, 0), evm.depth);
    try testing.expectEqual(false, evm.read_only);
}

test "Evm.init_with_hardfork" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init_with_hardfork(allocator, db_interface, .LONDON);
    defer evm.deinit();
    
    try testing.expect(evm.allocator.ptr == allocator.ptr);
    try testing.expectEqual(@as(usize, 0), evm.return_data.len);
    try testing.expectEqual(@as(u16, 0), evm.depth);
    try testing.expectEqual(false, evm.read_only);
}

test "Evm.deinit proper cleanup" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null);
    
    evm.deinit();
}

test "Evm.init state initialization" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null);
    defer evm.deinit();
    
    const test_addr = [_]u8{0x42} ** 20;
    const initial_balance = try evm.state.get_balance(test_addr);
    try testing.expectEqual(@as(u256, 0), initial_balance);
}

test "Evm.init access list initialization" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null);
    defer evm.deinit();
    
    const test_addr = [_]u8{0x42} ** 20;
    const is_warm = evm.access_list.is_address_warm(test_addr);
    try testing.expectEqual(false, is_warm);
}

test "Evm.init context initialization" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null);
    defer evm.deinit();
    
    try testing.expectEqual(@as(u256, 0), evm.context.block.number);
    try testing.expectEqual(@as(u64, 0), evm.context.block.timestamp);
    try testing.expectEqual(@as(u256, 0), evm.context.block.gas_limit);
    try testing.expectEqual(@as(u256, 0), evm.context.block.base_fee);
}

test "Evm multiple VM instances" {
    const allocator = testing.allocator;
    
    var memory_db1 = MemoryDatabase.init(allocator);
    defer memory_db1.deinit();
    var memory_db2 = MemoryDatabase.init(allocator);
    defer memory_db2.deinit();
    
    const db_interface1 = memory_db1.to_database_interface();
    const db_interface2 = memory_db2.to_database_interface();
    
    var evm1 = try Evm.init(allocator, db_interface1, null, null);
    defer evm1.deinit();
    var evm2 = try Evm.init(allocator, db_interface2, null, null);
    defer evm2.deinit();
    
    evm1.depth = 5;
    evm2.depth = 10;
    
    try testing.expectEqual(@as(u16, 5), evm1.depth);
    try testing.expectEqual(@as(u16, 10), evm2.depth);
}

test "Evm initialization with different hardforks" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    
    const hardforks = [_]Hardfork{ .FRONTIER, .HOMESTEAD, .BYZANTIUM, .CONSTANTINOPLE, .ISTANBUL, .BERLIN, .LONDON, .MERGE };
    
    for (hardforks) |hardfork| {
        var evm = try Evm.init_with_hardfork(allocator, db_interface, hardfork);
        defer evm.deinit();
        
        try testing.expect(evm.allocator.ptr == allocator.ptr);
        try testing.expectEqual(@as(u16, 0), evm.depth);
        try testing.expectEqual(false, evm.read_only);
    }
}

test "Evm initialization memory invariants" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null);
    defer evm.deinit();
    
    try testing.expectEqual(@as(usize, 0), evm.return_data.len);
    try testing.expectEqual(@as(usize, 0), evm.stack.size);
    try testing.expectEqual(@as(u16, 0), evm.depth);
    try testing.expectEqual(false, evm.read_only);
    
    for (evm.stack.data) |value| {
        try testing.expectEqual(@as(u256, 0), value);
    }
}

test "Evm depth tracking" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null);
    defer evm.deinit();
    
    try testing.expectEqual(@as(u16, 0), evm.depth);
    
    evm.depth = 1024;
    try testing.expectEqual(@as(u16, 1024), evm.depth);
    
    evm.depth = 0;
    try testing.expectEqual(@as(u16, 0), evm.depth);
}

test "Evm read-only flag" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null);
    defer evm.deinit();
    
    try testing.expectEqual(false, evm.read_only);
    
    evm.read_only = true;
    try testing.expectEqual(true, evm.read_only);
    
    evm.read_only = false;
    try testing.expectEqual(false, evm.read_only);
}

test "Evm return data management" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null);
    defer evm.deinit();
    
    try testing.expectEqual(@as(usize, 0), evm.return_data.len);
    
    const test_data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const allocated_data = try allocator.dupe(u8, &test_data);
    defer allocator.free(allocated_data);
    
    evm.return_data = allocated_data;
    try testing.expectEqual(@as(usize, 4), evm.return_data.len);
    try testing.expectEqualSlices(u8, &test_data, evm.return_data);
}

test "Evm state access" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null);
    defer evm.deinit();
    
    const test_addr = [_]u8{0x42} ** 20;
    const test_balance: u256 = 1000000;
    
    try evm.state.set_balance(test_addr, test_balance);
    const retrieved_balance = try evm.state.get_balance(test_addr);
    try testing.expectEqual(test_balance, retrieved_balance);
}

test "Evm access list operations" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null);
    defer evm.deinit();
    
    const test_addr = [_]u8{0x42} ** 20;
    
    try testing.expectEqual(false, evm.access_list.is_address_warm(test_addr));
    
    try evm.access_list.warm_address(test_addr);
    try testing.expectEqual(true, evm.access_list.is_address_warm(test_addr));
}

test "Evm stack operations via stack field" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null);
    defer evm.deinit();
    
    try testing.expectEqual(@as(usize, 0), evm.stack.size);
    
    try evm.stack.append(42);
    try testing.expectEqual(@as(usize, 1), evm.stack.size);
    
    const value = try evm.stack.pop();
    try testing.expectEqual(@as(u256, 42), value);
    try testing.expectEqual(@as(usize, 0), evm.stack.size);
}

test "Evm jump table access" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null);
    defer evm.deinit();
    
    const add_opcode: u8 = 0x01;
    const operation = evm.table.get(add_opcode);
    try testing.expect(operation != null);
}

test "Evm chain rules access" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null);
    defer evm.deinit();
    
    const test_addr = [_]u8{0x42} ** 20;
    const is_precompile = evm.chain_rules.is_precompile(test_addr);
    try testing.expectEqual(false, is_precompile);
}

test "Evm reinitialization behavior" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    
    var evm = try Evm.init(allocator, db_interface, null, null);
    evm.depth = 5;
    evm.read_only = true;
    evm.deinit();
    
    evm = try Evm.init(allocator, db_interface, null, null);
    defer evm.deinit();
    
    try testing.expectEqual(@as(u16, 0), evm.depth);
    try testing.expectEqual(false, evm.read_only);
}

test "Evm edge case: maximum depth" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null);
    defer evm.deinit();
    
    evm.depth = std.math.maxInt(u16);
    try testing.expectEqual(std.math.maxInt(u16), evm.depth);
}

test "Evm fuzz: initialization with random hardforks" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    
    const hardforks = [_]Hardfork{ .FRONTIER, .HOMESTEAD, .BYZANTIUM, .CONSTANTINOPLE, .ISTANBUL, .BERLIN, .LONDON, .MERGE };
    
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const hardfork = hardforks[random.intRangeAtMost(usize, 0, hardforks.len - 1)];
        var evm = try Evm.init_with_hardfork(allocator, db_interface, hardfork);
        defer evm.deinit();
        
        try testing.expect(evm.allocator.ptr == allocator.ptr);
        try testing.expectEqual(@as(u16, 0), evm.depth);
        try testing.expectEqual(false, evm.read_only);
    }
}

test "Evm fuzz: random depth and read_only values" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null);
    defer evm.deinit();
    
    var prng = std.Random.DefaultPrng.init(123);
    const random = prng.random();
    
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const random_depth = random.int(u16);
        const random_read_only = random.boolean();
        
        evm.depth = random_depth;
        evm.read_only = random_read_only;
        
        try testing.expectEqual(random_depth, evm.depth);
        try testing.expectEqual(random_read_only, evm.read_only);
    }
}

test "Evm integration: multiple state operations" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null);
    defer evm.deinit();
    
    const addr1 = [_]u8{0x11} ** 20;
    const addr2 = [_]u8{0x22} ** 20;
    const balance1: u256 = 1000;
    const balance2: u256 = 2000;
    
    try evm.state.set_balance(addr1, balance1);
    try evm.state.set_balance(addr2, balance2);
    
    try evm.access_list.warm_address(addr1);
    
    try testing.expectEqual(balance1, try evm.state.get_balance(addr1));
    try testing.expectEqual(balance2, try evm.state.get_balance(addr2));
    try testing.expectEqual(true, evm.access_list.is_address_warm(addr1));
    try testing.expectEqual(false, evm.access_list.is_address_warm(addr2));
}

test "Evm integration: state and context interaction" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null);
    defer evm.deinit();
    
    const test_addr = [_]u8{0x42} ** 20;
    const test_balance: u256 = 500000;
    
    try evm.state.set_balance(test_addr, test_balance);
    evm.context.block.number = 12345;
    evm.context.block.timestamp = 1234567890;
    
    try testing.expectEqual(test_balance, try evm.state.get_balance(test_addr));
    try testing.expectEqual(@as(u256, 12345), evm.context.block.number);
    try testing.expectEqual(@as(u64, 1234567890), evm.context.block.timestamp);
}

test "Evm invariant: all fields properly initialized after init" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null);
    defer evm.deinit();
    
    try testing.expect(evm.allocator.ptr == allocator.ptr);
    try testing.expectEqual(@as(usize, 0), evm.return_data.len);
    try testing.expectEqual(@as(usize, 0), evm.stack.size);
    try testing.expectEqual(@as(u16, 0), evm.depth);
    try testing.expectEqual(false, evm.read_only);
    
    try testing.expect(evm.table.get(0x01) != null);
    try testing.expect(evm.chain_rules.is_precompile([_]u8{0} ** 20) == false);
    
    const test_addr = [_]u8{0x99} ** 20;
    try testing.expectEqual(@as(u256, 0), try evm.state.get_balance(test_addr));
    try testing.expectEqual(false, evm.access_list.is_address_warm(test_addr));
    
    try testing.expectEqual(@as(u256, 0), evm.context.block.number);
    try testing.expectEqual(@as(u64, 0), evm.context.block.timestamp);
    try testing.expectEqual(@as(u256, 0), evm.context.block.gas_limit);
}

test "Evm memory leak detection" {
    const allocator = testing.allocator;
    
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var memory_db = MemoryDatabase.init(allocator);
        defer memory_db.deinit();
        
        const db_interface = memory_db.to_database_interface();
        var evm = try Evm.init(allocator, db_interface, null, null);
        defer evm.deinit();
        
        const test_data = try allocator.alloc(u8, 100);
        defer allocator.free(test_data);
        
        evm.return_data = test_data[0..50];
        
        try testing.expectEqual(@as(usize, 50), evm.return_data.len);
    }
}

test "Evm edge case: empty return data" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null);
    defer evm.deinit();
    
    try testing.expectEqual(@as(usize, 0), evm.return_data.len);
    
    evm.return_data = &[_]u8{};
    try testing.expectEqual(@as(usize, 0), evm.return_data.len);
}

test "Evm resource exhaustion simulation" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null);
    defer evm.deinit();
    
    evm.depth = 1023;
    try testing.expectEqual(@as(u16, 1023), evm.depth);
    
    try evm.stack.append(1);
    try evm.stack.append(2);
    try evm.stack.append(3);
    try testing.expectEqual(@as(usize, 3), evm.stack.size);
    
    _ = try evm.stack.pop();
    _ = try evm.stack.pop();
    _ = try evm.stack.pop();
    try testing.expectEqual(@as(usize, 0), evm.stack.size);
}
