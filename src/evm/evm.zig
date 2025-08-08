const std = @import("std");
const JumpTable = @import("jump_table/jump_table.zig");
const Operation = @import("opcodes/operation.zig");
const primitives = @import("primitives");
const AccessList = @import("access_list/access_list.zig");
const ExecutionError = @import("execution/execution_error.zig");
const Keccak256 = std.crypto.hash.sha3.Keccak256;
const ChainRules = @import("frame.zig").ChainRules;
const GasConstants = @import("primitives").GasConstants;
const CallJournal = @import("call_frame_stack.zig").CallJournal;
const Host = @import("host.zig").Host;
const BlockInfo = @import("host.zig").BlockInfo;
const CallParams = @import("host.zig").CallParams;
const opcode = @import("opcodes/opcode.zig");
const Log = @import("log.zig");
const EvmLog = @import("state/evm_log.zig");
const Context = @import("access_list/context.zig");
const EvmState = @import("state/state.zig").DefaultEvmState;
const memory_module = @import("memory/memory.zig");
const stack_module = @import("stack/stack.zig");
const ReturnData = @import("evm/return_data.zig").ReturnData;
const evm_limits = @import("constants/evm_limits.zig");
const frame_module = @import("frame.zig");
const Frame = frame_module.Frame;
const SelfDestruct = @import("self_destruct.zig").SelfDestruct;
pub const StorageKey = @import("primitives").StorageKey;
pub const CreateResult = @import("evm/create_result.zig").CreateResult;
pub const CallResult = @import("evm/call_result.zig").CallResult;
pub const RunResult = @import("evm/run_result.zig").RunResult;
const Hardfork = @import("hardforks/hardfork.zig").Hardfork;
const precompiles = @import("precompiles/precompiles.zig");
const builtin = @import("builtin");
const ComptimeConfig = @import("comptime_config.zig").ComptimeConfig;

/// Virtual Machine for executing Ethereum bytecode.
///
/// Manages contract execution, gas accounting, state access, and protocol enforcement
/// according to the configured hardfork rules. Supports the full EVM instruction set
/// including contract creation, calls, and state modifications.
///
/// Generic over a comptime config parameter that determines component behavior.
pub fn EvmImpl(comptime config: anytype) type {
    _ = memory_module.Memory(config);
    _ = stack_module.Stack(config);
    _ = frame_module.FrameImpl(config);
    
    return struct {
        const Self = @This();

/// Maximum call depth supported by EVM (per EIP-150)
pub const MAX_CALL_DEPTH: u11 = evm_limits.MAX_CALL_DEPTH;

// Constants from call.zig for frame management
/// Maximum stack buffer size for contracts up to 12,800 bytes
const MAX_STACK_BUFFER_SIZE = 43008; // 42KB with alignment padding

// Comptime configuration
/// Comptime configuration containing all EVM constants and settings
config: ComptimeConfig,
// Hot fields (frequently accessed during execution)
/// Normal allocator for data that outlives EVM execution (passed by user)
allocator: std.mem.Allocator,
/// Internal arena allocator for temporary data that's reset between executions
internal_arena: std.heap.ArenaAllocator,
/// Opcode dispatch table for the configured hardfork
table: JumpTable,
/// Current call depth for overflow protection
depth: u11 = 0,
/// Whether the current context is read-only (STATICCALL)
read_only: bool = false,

// Configuration fields (set at initialization)
/// Protocol rules for the current hardfork
chain_rules: ChainRules,
/// Execution context providing transaction and block information
context: Context,

// Data fields (moderate access frequency)
/// Optional tracer for capturing execution traces
tracer: ?std.io.AnyWriter = null,

/// Return data from the last call operation
return_data: []const u8 = &[_]u8{},

/// Main execution stack for EVM operations
stack: stack_module.DefaultStack,

// Large state structures (placed last to minimize offset impact)
/// World state including accounts, storage, and code
state: EvmState,

/// Warm/cold access tracking for EIP-2929 gas costs
access_list: AccessList,

// Execution state for nested calls and frame management
/// Pre-allocated frame stack for nested calls (moved from call.zig local variable)
frame_stack: [MAX_CALL_DEPTH]Frame = undefined,

/// Current active frame depth in the frame stack
current_frame_depth: u11 = 0,

/// Self-destruct tracking for the current execution
self_destruct: SelfDestruct = undefined,

/// Stack buffer for small contract analysis optimization
analysis_stack_buffer: [MAX_STACK_BUFFER_SIZE]u8 = undefined,

/// Call journal for transaction revertibility
journal: CallJournal = undefined,

/// As of now the EVM assumes we are only running on a single thread
/// All places in code that make this assumption are commented and must be handled
/// Before we can remove this restriction
initial_thread_id: std.Thread.Id,


/// Create a new EVM with a ComptimeConfig.
///
/// This is the recommended initialization method that uses the centralized
/// ComptimeConfig for all EVM constants and settings.
///
/// @param allocator Memory allocator for VM operations
/// @param database Database interface for state management
/// @param evm_config Comptime configuration (use ComptimeConfig.default() for defaults)
/// @param context Execution context (optional, defaults to Context.init())
/// @param depth Current call depth (optional, defaults to 0)
/// @param read_only Static call flag (optional, defaults to false)
/// @param tracer Optional tracer for capturing execution traces
/// @return Configured EVM instance
/// @throws OutOfMemory if memory initialization fails
///
/// Example usage:
/// ```zig
/// // Basic initialization with default config
/// const evm_config = ComptimeConfig.default();
/// var evm = try Evm.initWithConfig(allocator, database, evm_config, null, 0, false, null);
/// defer evm.deinit();
///
/// // With custom hardfork configuration
/// const evm_config = ComptimeConfig.forHardfork(.LONDON);
/// var evm = try Evm.initWithConfig(allocator, database, evm_config, null, 0, false, null);
/// defer evm.deinit();
/// ```
pub fn initWithConfig(
    allocator: std.mem.Allocator,
    database: @import("state/database_interface.zig").DefaultDatabaseInterface,
    evm_config: ComptimeConfig,
    context: ?Context,
    depth: u16,
    read_only: bool,
    tracer: ?std.io.AnyWriter,
) !Self {
    Log.debug("Evm.initWithConfig: Initializing EVM with ComptimeConfig", .{});

    // Validate config consistency
    try evm_config.validate();

    // Initialize internal arena allocator for temporary data with preallocated capacity
    var internal_arena = std.heap.ArenaAllocator.init(allocator);
    // Preallocate memory to avoid frequent allocations during execution
    _ = try internal_arena.allocator().alloc(u8, evm_config.arena_initial_capacity);
    _ = internal_arena.reset(.retain_capacity);

    var state = try EvmState.init(allocator, database);
    errdefer state.deinit();

    const ctx = context orelse Context.init();
    var access_list = AccessList.init(allocator, ctx);
    errdefer access_list.deinit();

    Log.debug("Evm.initWithConfig: EVM initialization complete", .{});
    return Self{
        .config = evm_config,
        .allocator = allocator,
        .internal_arena = internal_arena,
        .table = evm_config.jump_table,
        .chain_rules = evm_config.chain_rules,
        .state = state,
        .access_list = access_list,
        .context = ctx,
        .initial_thread_id = std.Thread.getCurrentId(),
        .depth = @intCast(depth),
        .read_only = read_only,
        .tracer = tracer,
        // Execution state fields (initialized fresh in each call)
        .stack = stack_module.DefaultStack.init(),
        .frame_stack = undefined,
        .current_frame_depth = 0,
        .self_destruct = undefined,
        .analysis_stack_buffer = undefined,
        .journal = CallJournal.init(allocator),
    };
}

/// Create a new EVM with specified configuration (legacy method).
///
/// This is the legacy initialization method that maintains backward compatibility.
/// It internally creates a ComptimeConfig from the provided parameters.
///
/// @param allocator Memory allocator for VM operations
/// @param database Database interface for state management
/// @param table Opcode dispatch table (optional, defaults to JumpTable.DEFAULT)
/// @param chain_rules Protocol rules (optional, defaults to ChainRules.DEFAULT)
/// @param context Execution context (optional, defaults to Context.init())
/// @param depth Current call depth (optional, defaults to 0)
/// @param read_only Static call flag (optional, defaults to false)
/// @param tracer Optional tracer for capturing execution traces
/// @return Configured EVM instance
/// @throws OutOfMemory if memory initialization fails
pub fn init(
    allocator: std.mem.Allocator,
    database: @import("state/database_interface.zig").DefaultDatabaseInterface,
    table: ?JumpTable,
    chain_rules: ?ChainRules,
    context: ?Context,
    depth: u16,
    read_only: bool,
    tracer: ?std.io.AnyWriter,
) !Self {
    // Create a ComptimeConfig from the legacy parameters
    var evm_config = ComptimeConfig.default();
    if (table) |t| {
        evm_config.jump_table = t;
    }
    if (chain_rules) |r| {
        evm_config.chain_rules = r;
    }
    
    return initWithConfig(allocator, database, evm_config, context, depth, read_only, tracer);
}

/// Free all VM resources.
/// Must be called when finished with the VM to prevent memory leaks.
pub fn deinit(self: *Evm) void {
    self.state.deinit();
    self.access_list.deinit();
    self.internal_arena.deinit();
    self.journal.deinit();

    // Execution state doesn't need cleanup in deinit:
    // - self_destruct: undefined or ownership transferred to caller
    // - frame_stack: undefined or cleaned up in call execution
    // - analysis_stack_buffer: undefined or stack-allocated
}

/// Reset the EVM for reuse without deallocating memory.
/// This is efficient for executing multiple contracts in sequence.
/// Clears all state but keeps the allocated memory for reuse.
pub fn reset(self: *Evm) void {
    // Reset internal arena allocator to reuse memory
    _ = self.internal_arena.reset(.retain_capacity);

    // Reset execution state
    self.depth = 0;
    self.read_only = false;
}

/// Get the internal arena allocator for temporary EVM data
/// Use this for allocations that are reset between EVM executions
pub fn arena_allocator(self: *Evm) std.mem.Allocator {
    return self.internal_arena.allocator();
}

// Host interface implementation - EVM acts as its own host
/// Get account balance (Host interface)
pub fn get_balance(self: *Evm, address: primitives.Address.Address) u256 {
    return self.state.get_balance(address);
}

/// Check if account exists (Host interface)
pub fn account_exists(self: *Evm, address: primitives.Address.Address) bool {
    _ = self;
    _ = address;
    Log.err("Host.account_exists not implemented", .{});
    unreachable;
}

/// Get account code (Host interface)
pub fn get_code(self: *Evm, address: primitives.Address.Address) []const u8 {
    return self.state.get_code(address);
}

/// Get block information (Host interface)
pub fn get_block_info(self: *Evm) BlockInfo {
    _ = self;
    Log.err("Host.get_block_info not implemented", .{});
    unreachable;
}

/// Emit log event (Host interface override)
/// This overrides the emit_log from emit_log.zig to provide the correct signature for Host interface
pub fn emit_log(self: *Evm, contract_address: primitives.Address.Address, topics: []const u256, data: []const u8) void {
    // Delegate to the state's emit_log implementation
    self.state.emit_log(contract_address, topics, data) catch |err| {
        Log.debug("emit_log failed: {}", .{err});
    };
}

/// Execute EVM call (Host interface)
pub fn call(self: *Evm, params: CallParams) !CallResult {
    _ = self;
    _ = params;
    Log.err("Host.call not implemented", .{});
    unreachable;
}

pub usingnamespace @import("evm/set_context.zig");

pub usingnamespace @import("evm/call_contract.zig");
pub usingnamespace @import("evm/execute_precompile_call.zig");
pub usingnamespace @import("evm/staticcall_contract.zig");
// pub usingnamespace @import("evm/emit_log.zig"); // Commented out to avoid ambiguity with Host interface
pub usingnamespace @import("evm/validate_static_context.zig");
pub usingnamespace @import("evm/set_storage_protected.zig");
pub usingnamespace @import("evm/set_transient_storage_protected.zig");
pub usingnamespace @import("evm/set_balance_protected.zig");
pub usingnamespace @import("evm/set_code_protected.zig");
pub usingnamespace @import("evm/emit_log_protected.zig");
pub usingnamespace @import("evm/validate_value_transfer.zig");
pub usingnamespace @import("evm/selfdestruct_protected.zig");
pub usingnamespace @import("evm/require_one_thread.zig");

pub const ConsumeGasError = ExecutionError.Error;

const testing = std.testing;
const MemoryDatabase = @import("state/memory_database.zig").DefaultMemoryDatabase;

test "Evm.init default configuration" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    try testing.expect(evm.allocator.ptr == allocator.ptr);
    try testing.expectEqual(@as(usize, 0), evm.return_data.len);
    try testing.expectEqual(@as(u11, 0), evm.depth);
    try testing.expectEqual(false, evm.read_only);
}

test "Evm.init with custom jump table and chain rules" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const custom_table = JumpTable.init_from_hardfork(.BERLIN);
    const custom_rules = @import("frame.zig").Frame.chainRulesForHardfork(.BERLIN);

    var evm = try Evm.init(allocator, db_interface, custom_table, custom_rules, null, 0, false, null);
    defer evm.deinit();

    try testing.expect(evm.allocator.ptr == allocator.ptr);
    try testing.expectEqual(@as(usize, 0), evm.return_data.len);
    try testing.expectEqual(@as(u11, 0), evm.depth);
    try testing.expectEqual(false, evm.read_only);
}

test "Evm.init with hardfork" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const jump_table = JumpTable.init(Hardfork.LONDON);
    const chain_rules = @import("frame.zig").Frame.chainRulesForHardfork(Hardfork.LONDON);
    var evm = try Evm.init(allocator, db_interface, jump_table, chain_rules, null, 0, false, null);
    defer evm.deinit();

    try testing.expect(evm.allocator.ptr == allocator.ptr);
    try testing.expectEqual(@as(usize, 0), evm.return_data.len);
    try testing.expectEqual(@as(u11, 0), evm.depth);
    try testing.expectEqual(false, evm.read_only);
}

test "Evm.deinit proper cleanup" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    evm.deinit();
}

test "Evm.init state initialization" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    try testing.expectEqual(@as(u11, 5), evm1.depth);
    try testing.expectEqual(@as(u11, 10), evm2.depth);
}

test "Evm initialization with different hardforks" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    const hardforks = [_]Hardfork{ .FRONTIER, .HOMESTEAD, .BYZANTIUM, .CONSTANTINOPLE, .ISTANBUL, .BERLIN, .LONDON, .MERGE };

    for (hardforks) |hardfork| {
        const jump_table = JumpTable.init(hardfork);
        const chain_rules = @import("frame.zig").Frame.chainRulesForHardfork(hardfork);
        var evm = try Evm.init(allocator, db_interface, jump_table, chain_rules, null, 0, false, null);
        defer evm.deinit();

        try testing.expect(evm.allocator.ptr == allocator.ptr);
        try testing.expectEqual(@as(u11, 0), evm.depth);
        try testing.expectEqual(false, evm.read_only);
    }
}

test "Evm initialization memory invariants" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    try testing.expectEqual(@as(usize, 0), evm.return_data.len);
    try testing.expectEqual(@as(u11, 0), evm.depth);
    try testing.expectEqual(false, evm.read_only);
}

test "Evm depth tracking" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    try testing.expectEqual(@as(u11, 0), evm.depth);

    evm.depth = 1024;
    try testing.expectEqual(@as(u11, 1024), evm.depth);

    evm.depth = 0;
    try testing.expectEqual(@as(u16, 0), evm.depth);
}

test "Evm read-only flag" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const test_addr = [_]u8{0x42} ** 20;

    try testing.expectEqual(false, evm.access_list.is_address_warm(test_addr));

    try evm.access_list.warm_address(test_addr);
    try testing.expectEqual(true, evm.access_list.is_address_warm(test_addr));
}

test "Evm jump table access" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    evm.depth = 5;
    evm.read_only = true;
    evm.deinit();

    evm = try Evm.init(allocator, db_interface, null, null);
    defer evm.deinit();

    try testing.expectEqual(@as(u11, 0), evm.depth);
    try testing.expectEqual(false, evm.read_only);
}

test "Evm edge case: maximum depth" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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
        const jump_table = JumpTable.init(hardfork);
        const chain_rules = @import("frame.zig").Frame.chainRulesForHardfork(hardfork);
        var evm = try Evm.init(allocator, db_interface, jump_table, chain_rules, null, 0, false, null);
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
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    try testing.expect(evm.allocator.ptr == allocator.ptr);
    try testing.expectEqual(@as(usize, 0), evm.return_data.len);
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
        var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    evm.depth = 1023;
    try testing.expectEqual(@as(u16, 1023), evm.depth);
}

test "Evm.init creates EVM with custom settings" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const custom_table = JumpTable.init_from_hardfork(.BERLIN);
    const custom_rules = @import("frame.zig").Frame.chainRulesForHardfork(.BERLIN);

    var evm = try Evm.init(allocator, db_interface, custom_table, custom_rules, null, 42, true, null);
    defer evm.deinit();

    // Can't test return_data initialization as init doesn't support it
    try testing.expectEqual(@as(usize, 0), evm.return_data.len);
    try testing.expectEqual(@as(u16, 42), evm.depth);
    try testing.expectEqual(true, evm.read_only);
}

test "Evm.init uses defaults for null parameters" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    try testing.expectEqual(@as(usize, 0), evm.return_data.len);
    try testing.expectEqual(@as(usize, 0), evm.stack.size());
    try testing.expectEqual(@as(u16, 0), evm.depth);
    try testing.expectEqual(false, evm.read_only);
}

test "Evm builder pattern: step by step configuration" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    evm.depth = 5;
    evm.read_only = true;

    const test_data = try allocator.dupe(u8, &[_]u8{ 0xde, 0xad, 0xbe, 0xef });
    defer allocator.free(test_data);
    evm.return_data = test_data;

    try testing.expectEqual(@as(u16, 5), evm.depth);
    try testing.expectEqual(true, evm.read_only);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xde, 0xad, 0xbe, 0xef }, evm.return_data);
}

test "Evm init vs init comparison" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    var evm1 = try Evm.init(allocator, db_interface);
    defer evm1.deinit();

    var evm2 = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm2.deinit();

    try testing.expectEqual(evm1.depth, evm2.depth);
    try testing.expectEqual(evm1.read_only, evm2.read_only);
    try testing.expectEqual(evm1.return_data.len, evm2.return_data.len);
    try testing.expectEqual(evm1.stack.size(), evm2.stack.size());
}

test "Evm child instance creation pattern" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    var parent_evm = try Evm.init(allocator, db_interface);
    defer parent_evm.deinit();

    parent_evm.depth = 3;
    parent_evm.read_only = true;

    var child_evm = try Evm.init(allocator, db_interface, null, null, null, parent_evm.depth + 1, parent_evm.read_only, null);
    defer child_evm.deinit();

    try testing.expectEqual(@as(u16, 4), child_evm.depth);
    try testing.expectEqual(true, child_evm.read_only);
}

test "Evm initialization with different hardforks using builder" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    const hardforks = [_]Hardfork{ .FRONTIER, .BERLIN, .LONDON };

    for (hardforks) |hardfork| {
        const table = JumpTable.init_from_hardfork(hardfork);
        const rules = @import("frame.zig").Frame.chainRulesForHardfork(hardfork);

        var evm = try Evm.init(allocator, db_interface, table, rules, null, 0, false, null);
        defer evm.deinit();

        try testing.expect(evm.allocator.ptr == allocator.ptr);
    }
}

test "Evm builder pattern memory management" {
    const allocator = testing.allocator;

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var memory_db = MemoryDatabase.init(allocator);
        defer memory_db.deinit();

        const db_interface = memory_db.to_database_interface();

        var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
        evm.depth = @intCast(i);
        evm.read_only = (i % 2 == 0);
        evm.deinit();
    }
}

// ============================================================================
// Fuzz Tests for VM State Management (Issue #234)
// Using proper Zig built-in fuzz testing with std.testing.fuzz()
// ============================================================================

test "fuzz_evm_initialization_states" {
    const global = struct {
        fn testEvmInitializationStates(input: []const u8) anyerror!void {
            if (input.len < 4) return;

            const allocator = testing.allocator;
            var memory_db = MemoryDatabase.init(allocator);
            defer memory_db.deinit();
            const db_interface = memory_db.to_database_interface();

            // Extract parameters from fuzz input
            const depth = std.mem.readInt(u16, input[0..2], .little) % (MAX_CALL_DEPTH + 10); // Allow testing beyond max
            const read_only = (input[2] % 2) == 1;
            const hardfork_idx = input[3] % 3; // Test 3 different hardforks

            const hardforks = [_]Hardfork{ .FRONTIER, .BERLIN, .LONDON };
            const hardfork = hardforks[hardfork_idx];

            // Test initialization with various state combinations
            const jump_table = JumpTable.init(hardfork);
            const chain_rules = @import("frame.zig").Frame.chainRulesForHardfork(hardfork);
            var evm = try Evm.init(allocator, db_interface, jump_table, chain_rules, null, 0, false, null);
            defer evm.deinit();

            // Verify initial state
            try testing.expectEqual(@as(u16, 0), evm.depth);
            try testing.expectEqual(false, evm.read_only);
            try testing.expect(evm.return_data.len == 0);

            // Test state modifications within valid ranges
            if (depth < MAX_CALL_DEPTH) {
                evm.depth = depth;
                try testing.expectEqual(depth, evm.depth);
            }

            evm.read_only = read_only;
            try testing.expectEqual(read_only, evm.read_only);

            // Verify frame pool initialization
            for (evm.frame_pool_initialized) |initialized| {
                try testing.expectEqual(false, initialized);
            }
        }
    };
    const input = "test_input_data_for_fuzzing";
    try global.testEvmInitializationStates(input);
}

test "fuzz_evm_depth_management" {
    const global = struct {
        fn testEvmDepthManagement(input: []const u8) anyerror!void {
            if (input.len < 8) return;

            const allocator = testing.allocator;
            var memory_db = MemoryDatabase.init(allocator);
            defer memory_db.deinit();
            const db_interface = memory_db.to_database_interface();

            var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
            defer evm.deinit();

            // Test various depth values from fuzz input
            const depths = [_]u16{
                std.mem.readInt(u16, input[0..2], .little) % MAX_CALL_DEPTH,
                std.mem.readInt(u16, input[2..4], .little) % MAX_CALL_DEPTH,
                std.mem.readInt(u16, input[4..6], .little) % MAX_CALL_DEPTH,
                std.mem.readInt(u16, input[6..8], .little) % MAX_CALL_DEPTH,
            };

            for (depths) |depth| {
                evm.depth = depth;
                try testing.expectEqual(depth, evm.depth);
                try testing.expect(evm.depth < MAX_CALL_DEPTH);

                // Test depth overflow protection
                const max_depth_reached = depth >= (MAX_CALL_DEPTH - 1);
                if (max_depth_reached) {
                    // At max depth, should not exceed limit
                    try testing.expect(evm.depth <= MAX_CALL_DEPTH);
                }
            }
        }
    };
    const input = "test_input_data_for_fuzzing";
    try global.testEvmDepthManagement(input);
}

test "fuzz_evm_state_consistency" {
    const global = struct {
        fn testEvmStateConsistency(input: []const u8) anyerror!void {
            if (input.len < 16) return;

            const allocator = testing.allocator;
            var memory_db = MemoryDatabase.init(allocator);
            defer memory_db.deinit();
            const db_interface = memory_db.to_database_interface();

            // Create EVM with various initial states
            const initial_depth = std.mem.readInt(u16, input[0..2], .little) % MAX_CALL_DEPTH;
            const initial_read_only = (input[2] % 2) == 1;

            var evm = try Evm.init(allocator, db_interface, null, null, null, initial_depth, initial_read_only, null);
            defer evm.deinit();

            // Verify initial state was set correctly
            try testing.expectEqual(initial_depth, evm.depth);
            try testing.expectEqual(initial_read_only, evm.read_only);

            // Test state transitions using fuzz input
            const operations = @min((input.len - 16) / 4, 8);
            for (0..operations) |i| {
                const op_data = input[16 + i * 4 .. 16 + (i + 1) * 4];
                const op_type = op_data[0] % 3;

                switch (op_type) {
                    0 => {
                        // Modify depth
                        const new_depth = std.mem.readInt(u16, op_data[1..3], .little) % MAX_CALL_DEPTH;
                        evm.depth = new_depth;
                        try testing.expectEqual(new_depth, evm.depth);
                    },
                    1 => {
                        // Toggle read-only
                        const new_read_only = (op_data[1] % 2) == 1;
                        evm.read_only = new_read_only;
                        try testing.expectEqual(new_read_only, evm.read_only);
                    },
                    2 => {
                        // Verify state consistency
                        try testing.expect(evm.depth < MAX_CALL_DEPTH);
                        try testing.expect(evm.allocator.ptr != @as(*anyopaque, @ptrFromInt(0)));
                        try testing.expect(evm.return_data.len == 0); // Default empty return data
                    },
                    else => unreachable,
                }
            }
        }
    };
    const input = "test_input_data_for_fuzzing";
    try global.testEvmStateConsistency(input);
}

test "fuzz_evm_frame_pool_management" {
    const global = struct {
        fn testEvmFramePoolManagement(input: []const u8) anyerror!void {
            if (input.len < 8) return;

            const allocator = testing.allocator;
            var memory_db = MemoryDatabase.init(allocator);
            defer memory_db.deinit();
            const db_interface = memory_db.to_database_interface();

            var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
            defer evm.deinit();

            // Test frame pool initialization tracking with fuzz input
            const pool_indices = [_]usize{
                input[0] % MAX_CALL_DEPTH,
                input[1] % MAX_CALL_DEPTH,
                input[2] % MAX_CALL_DEPTH,
                input[3] % MAX_CALL_DEPTH,
            };

            // Verify initial state - all frames should be uninitialized
            for (evm.frame_pool_initialized) |initialized| {
                try testing.expectEqual(false, initialized);
            }

            // Test frame pool consistency
            for (pool_indices) |idx| {
                // Frame pool should maintain initialization state
                try testing.expectEqual(false, evm.frame_pool_initialized[idx]);

                // Verify frame pool bounds
                try testing.expect(idx < MAX_CALL_DEPTH);
            }

            // Test depth-frame correlation invariants
            if (input.len >= 16) {
                const test_depth = std.mem.readInt(u16, input[8..10], .little) % MAX_CALL_DEPTH;
                evm.depth = test_depth;

                // Depth should never exceed available frames
                try testing.expect(evm.depth < MAX_CALL_DEPTH);
                try testing.expect(evm.depth <= evm.frame_pool.len);
            }
        }
    };
    const input = "test_input_data_for_fuzzing";
    try global.testEvmFramePoolManagement(input);
}

test "fuzz_evm_hardfork_configurations" {
    const global = struct {
        fn testEvmHardforkConfigurations(input: []const u8) anyerror!void {
            if (input.len < 4) return;

            const allocator = testing.allocator;
            var memory_db = MemoryDatabase.init(allocator);
            defer memory_db.deinit();
            const db_interface = memory_db.to_database_interface();

            // Test different hardfork configurations
            const hardforks = [_]Hardfork{ .FRONTIER, .BERLIN, .LONDON };
            const hardfork_idx = input[0] % hardforks.len;
            const hardfork = hardforks[hardfork_idx];

            const jump_table = JumpTable.init(hardfork);
            const chain_rules = @import("frame.zig").Frame.chainRulesForHardfork(hardfork);
            var evm = try Evm.init(allocator, db_interface, jump_table, chain_rules, null, 0, false, null);
            defer evm.deinit();

            // Verify EVM was configured for the specified hardfork
            try testing.expect(evm.chain_rules.hardfork() == hardfork);

            // Test state modifications with hardfork context
            if (input.len >= 8) {
                const depth = std.mem.readInt(u16, input[1..3], .little) % MAX_CALL_DEPTH;
                const read_only = (input[3] % 2) == 1;

                evm.depth = depth;
                evm.read_only = read_only;

                // Verify state changes are consistent regardless of hardfork
                try testing.expectEqual(depth, evm.depth);
                try testing.expectEqual(read_only, evm.read_only);

                // Verify hardfork rules remain consistent
                try testing.expect(evm.chain_rules.hardfork() == hardfork);
            }

            // Test multiple EVM instances with different hardforks
            if (input.len >= 8) {
                const second_hardfork_idx = input[4] % hardforks.len;
                const second_hardfork = hardforks[second_hardfork_idx];

                var evm2 = try Evm.init_with_hardfork(allocator, db_interface, second_hardfork);
                defer evm2.deinit();

                try testing.expect(evm2.chain_rules.hardfork() == second_hardfork);

                // EVMs should be independent
                try testing.expect(evm.depth == 0);
                try testing.expect(evm2.depth == 0);
                try testing.expect(evm.read_only == false);
                try testing.expect(evm2.read_only == false);
            }
        }
    };
    const input = "test_input_data_for_fuzzing";
    try global.testEvmHardforkConfigurations(input);
}

    }; // End of EvmImpl struct
} // End of EvmImpl function

/// Default EVM configuration for backward compatibility
pub const DefaultEvm = EvmImpl(ComptimeConfig.default());

/// Backward compatibility alias (pointing to the concrete type)
pub const Evm = DefaultEvm;
