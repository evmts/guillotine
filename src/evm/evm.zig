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

/// Memory allocator for VM operations
allocator: std.mem.Allocator,
/// Return data from the most recent operation
return_data: []u8 = &[_]u8{},
/// Legacy stack field (unused in current implementation)
stack: Stack = .{},
/// Opcode dispatch table for the configured hardfork
table: JumpTable,
/// Protocol rules for the current hardfork
chain_rules: ChainRules,
// TODO should be injected
/// World state including accounts, storage, and code
state: EvmState,
/// Warm/cold access tracking for EIP-2929 gas costs
access_list: AccessList,
/// Execution context providing transaction and block information
context: Context,
/// Current call depth for overflow protection
depth: u16 = 0,
/// Whether the current context is read-only (STATICCALL)
read_only: bool = false,

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
        .chain_rules = (chain_rules orelse &ChainRules.DEFAULT).*,
        .state = state,
        .access_list = access_list,
        .context = context,
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
