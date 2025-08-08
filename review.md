I want you to analyze the architecture of my EVM. I'm trying to build the most performant evm I can.

## Evm

The main struct is evm.zig. So right away you can see we use the implicit module pattern if Evm = @This(). I want to move away from this though actually and just use struct consistentally. One big reason I want to do this is I want to abstract comptime configuration into a single configuration object. It should include every flag that exists in our evm. It should replace any use of builtin. Any check for wasm. It should abstract every global constant we have like MAX_CALL_DEPTH and MAX_STACK_BUFFER or MAX_CALL_DEPTH and many constants that aren't even in this struct. And we should have simple factories that take this config and return an Evm struct.

Anyways we are trying to be very intentional with our data usage.

So we take in the allocator and hold on a reference to that. Right away I see issue where the allocator is at top of struct that is not where we should put it using data oriented design. From that allocator we internally create a simple arena allocator. We ar enot using that here but I want to change this so we explicitly wrap it in an arena using standard library.

I actually don't know if allocated_size is even used or where

capcity same not sure maybe it's used maybe not we should look into it

Base ponter again no clue why that is there.

use_doubling_strategy should be in that comptime config object instead. Behavior of the evm that can be configured at comptime should be configured at comptime.

Then I want to preallocate INITIAL_SIZE. But here is the thing. We should be calculating INITIAL_SIZE at comptime based on the memory we need. IMO this should be a part of the config object. At comptime we want to warn if these are not set to reasonable limits given their architecture.

So the way this EVM works is that call stores the data at the depth 0 callframe. This init method's job is to just allocate memory and nothing more. We try our best to allocate only once for most contract calls

````typescript
const std = @import("std");
const JumpTable = @import("jump_table/jump_table.zig");
const Operation = @import("opcodes/operation.zig");
const primitives = @import("primitives");
const AccessList = @import("access_list/access_list.zig");
const ExecutionError = @import("execution/execution_error.zig");
const Keccak256 = std.crypto.hash.sha3.Keccak256;
const ChainRules = @import("frame.zig").ChainRules;
const GasConstants = @import("primitives").GasConstants;
const opcode = @import("opcodes/opcode.zig");
const Log = @import("log.zig");
const EvmLog = @import("state/evm_log.zig");
const Context = @import("access_list/context.zig");
const EvmState = @import("state/state.zig");
const Memory = @import("memory/memory.zig");
const ReturnData = @import("evm/return_data.zig").ReturnData;
const EvmMemoryAllocator = @import("memory/evm_allocator.zig").EvmMemoryAllocator;
const evm_limits = @import("constants/evm_limits.zig");
const Frame = @import("frame.zig").Frame;
const SelfDestruct = @import("self_destruct.zig").SelfDestruct;
pub const StorageKey = @import("primitives").StorageKey;
pub const CreateResult = @import("evm/create_result.zig").CreateResult;
pub const CallResult = @import("evm/call_result.zig").CallResult;
pub const RunResult = @import("evm/run_result.zig").RunResult;
const Hardfork = @import("hardforks/hardfork.zig").Hardfork;
const precompiles = @import("precompiles/precompiles.zig");
const builtin = @import("builtin");

/// Virtual Machine for executing Ethereum bytecode.
///
/// Manages contract execution, gas accounting, state access, and protocol enforcement
/// according to the configured hardfork rules. Supports the full EVM instruction set
/// including contract creation, calls, and state modifications.
const Evm = @This();

/// Maximum call depth supported by EVM (per EIP-150)
pub const MAX_CALL_DEPTH: u11 = evm_limits.MAX_CALL_DEPTH;

// Constants from call.zig for frame management
/// Maximum stack buffer size for contracts up to 12,800 bytes
const MAX_STACK_BUFFER_SIZE = 43008; // 42KB with alignment padding
// Hot fields (frequently accessed during execution)
/// Normal allocator for data that outlives EVM execution (passed by user)
allocator: std.mem.Allocator,
/// Internal arena allocator for temporary data that's reset between executions
internal_allocator: EvmMemoryAllocator,
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

/// As of now the EVM assumes we are only running on a single thread
/// All places in code that make this assumption are commented and must be handled
/// Before we can remove this restriction
initial_thread_id: std.Thread.Id,

// Compile-time validation and optimizations
comptime {
    std.debug.assert(@alignOf(Evm) >= 8); // Ensure proper alignment for performance
    std.debug.assert(@sizeOf(Evm) > 0); // Struct must have size
}

/// Create a new EVM with specified configuration.
///
/// This is the initialization method for EVM instances. All parameters except
/// allocator and database are optional and will use sensible defaults if not provided.
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
///
/// Example usage:
/// ```zig
/// // Basic initialization with defaults
/// var evm = try Evm.init(allocator, database, null, null, null, 0, false, null);
/// defer evm.deinit();
///
/// // With custom hardfork and configuration
/// const table = JumpTable.init_from_hardfork(.LONDON);
/// const rules = Frame.chainRulesForHardfork(.LONDON);
/// var evm = try Evm.init(allocator, database, table, rules, null, 0, false, null);
/// defer evm.deinit();
/// ```
pub fn init(
    allocator: std.mem.Allocator,
    database: @import("state/database_interface.zig").DatabaseInterface,
    table: ?JumpTable,
    chain_rules: ?ChainRules,
    context: ?Context,
    depth: u16,
    read_only: bool,
    tracer: ?std.io.AnyWriter,
) !Evm {
    Log.debug("Evm.init: Initializing EVM with configuration", .{});

    // Initialize internal arena allocator for temporary data
    var internal_allocator = try EvmMemoryAllocator.init(allocator);
    errdefer internal_allocator.deinit();

    var state = try EvmState.init(allocator, database);
    errdefer state.deinit();

    const ctx = context orelse Context.init();
    var access_list = AccessList.init(allocator, ctx);
    errdefer access_list.deinit();

    // NOTE: Execution state is left undefined - will be initialized fresh in each call
    // - frame_stack: initialized in call execution
    // - self_destruct: initialized in call execution
    // - analysis_stack_buffer: initialized in call execution

    Log.debug("Evm.init: EVM initialization complete", .{});
    return Evm{
        .allocator = allocator,
        .internal_allocator = internal_allocator,
        .table = table orelse JumpTable.DEFAULT,
        .chain_rules = chain_rules orelse ChainRules.DEFAULT,
        .state = state,
        .access_list = access_list,
        .context = ctx,
        .initial_thread_id = std.Thread.getCurrentId(),
        .depth = depth,
        .read_only = read_only,
        .tracer = tracer,
        // New execution state fields (initialized fresh in each call)
        .frame_stack = undefined,
        .current_frame_depth = 0,
        .self_destruct = undefined,
        .analysis_stack_buffer = undefined,
    };
}

/// Free all VM resources.
/// Must be called when finished with the VM to prevent memory leaks.
pub fn deinit(self: *Evm) void {
    self.state.deinit();
    self.access_list.deinit();
    self.internal_allocator.deinit();

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
    self.internal_allocator.reset();

    // Reset execution state
    self.depth = 0;
    self.read_only = false;
}

/// Get the internal arena allocator for temporary EVM data
/// Use this for allocations that are reset between EVM executions
pub fn arena_allocator(self: *Evm) std.mem.Allocator {
    return self.internal_allocator.allocator();
}

pub usingnamespace @import("evm/set_context.zig");

pub usingnamespace @import("evm/call_contract.zig");
pub usingnamespace @import("evm/execute_precompile_call.zig");
pub usingnamespace @import("evm/staticcall_contract.zig");
pub usingnamespace @import("evm/emit_log.zig");
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
const MemoryDatabase = @import("state/memory_database.zig").MemoryDatabase;
````

## Call

So the main method in our EVM is call. It takes params

```
pub const CallParams = union(enum) {
    /// Regular CALL operation
    call: struct {
        caller: Address,
        to: Address,
        value: u256,
        input: []const u8,
        gas: u64,
    },
    /// DELEGATECALL operation (preserves caller context)
    delegatecall: struct {
        caller: Address,  // Original caller, not current contract
        to: Address,
        input: []const u8,
        gas: u64,
    },
    /// STATICCALL operation (read-only)
    staticcall: struct {
        caller: Address,
        to: Address,
        input: []const u8,
        gas: u64,
    },
    /// CREATE operation
    create: struct {
        caller: Address,
        value: u256,
        init_code: []const u8,
        gas: u64,
    },
    /// CREATE2 operation
    create2: struct {
        caller: Address,
        value: u256,
        init_code: []const u8,
        salt: u256,
        gas: u64,
    },
};
```

And it returns a CallResult or an ExecutionError

````
const std = @import("std");

/// ExecutionError represents various error conditions that can occur during EVM execution
///
/// This module defines all possible error conditions that can occur during the execution
/// of EVM bytecode. These errors are used throughout the EVM implementation to signal
/// various failure conditions, from normal stops to critical errors.
///
/// ## Error Categories
///
/// The errors can be broadly categorized into:
///
/// 1. **Normal Termination**: STOP, REVERT, INVALID
/// 2. **Resource Exhaustion**: OutOfGas, StackOverflow, MemoryLimitExceeded
/// 3. **Invalid Operations**: InvalidJump, InvalidOpcode, StaticStateChange
/// 4. **Bounds Violations**: StackUnderflow, OutOfOffset, ReturnDataOutOfBounds
/// 5. **Contract Creation**: DeployCodeTooBig, MaxCodeSizeExceeded, InvalidCodeEntry
/// 6. **Call Stack**: DepthLimit
/// 7. **Memory Management**: OutOfMemory, InvalidOffset, InvalidSize, ChildContextActive
/// 8. **Future Features**: EOFNotSupported
const ExecutionError = @This();

/// Error types for EVM execution
///
/// Each error represents a specific condition that can occur during EVM execution.
/// Some errors (like STOP and REVERT) are normal termination conditions, while
/// others represent actual failure states.
pub const Error = error{
    MAX_CONTRACT_SIZE,
    /// Normal termination via STOP opcode (0x00)
    /// This is not an error condition - it signals successful completion
    STOP,

    /// State reversion via REVERT opcode (0xFD)
    /// Returns data and reverts all state changes in the current context
    REVERT,

    /// Execution of INVALID opcode (0xFE)
    /// Consumes all remaining gas and reverts state
    INVALID,

    /// Insufficient gas to complete operation
    /// Occurs when gas_remaining < gas_required for any operation
    OutOfGas,

    /// Attempted to pop from empty stack or insufficient stack items
    /// Stack operations require specific minimum stack sizes
    StackUnderflow,

    /// Stack size exceeded maximum of 1024 elements
    /// Pushing to a full stack causes this error
    StackOverflow,

    /// JUMP/JUMPI to invalid destination
    /// Destination must be a JUMPDEST opcode at a valid position
    InvalidJump,

    /// Attempted to execute undefined opcode
    /// Not all byte values 0x00-0xFF are defined opcodes
    InvalidOpcode,

    /// Attempted state modification in static call context
    /// SSTORE, LOG*, CREATE*, and SELFDESTRUCT are forbidden in static calls
    StaticStateChange,

    /// Memory or calldata access beyond valid bounds
    /// Usually from integer overflow in offset calculations
    OutOfOffset,

    /// Gas calculation resulted in integer overflow
    /// Can occur with extremely large memory expansions
    GasUintOverflow,

    /// Attempted write in read-only context
    /// Similar to StaticStateChange but more general
    WriteProtection,

    /// RETURNDATACOPY accessing data beyond RETURNDATASIZE
    /// Unlike other copy operations, this is a hard error
    ReturnDataOutOfBounds,

    /// Invalid access to return data buffer
    /// Occurs when RETURNDATACOPY offset + size > return data size
    InvalidReturnDataAccess,

    /// Contract deployment code exceeds maximum size
    /// Deployment bytecode has its own size limits
    DeployCodeTooBig,

    /// Deployed contract code exceeds 24,576 byte limit (EIP-170)
    /// Prevents storing excessively large contracts
    MaxCodeSizeExceeded,

    /// Invalid contract initialization code
    /// Can occur with malformed constructor bytecode
    InvalidCodeEntry,

    /// Call stack depth exceeded 1024 levels
    /// Prevents infinite recursion and stack overflow attacks
    DepthLimit,

    /// Memory allocation failed (host environment issue)
    /// Not a normal EVM error - indicates system resource exhaustion
    OutOfMemory,

    /// Invalid memory offset in operation
    /// Usually from malformed offset values
    InvalidOffset,

    /// Invalid memory size in operation
    /// Usually from malformed size values
    InvalidSize,

    /// Memory expansion would exceed configured limits
    /// Prevents excessive memory usage (typically 32MB limit)
    MemoryLimitExceeded,

    /// Attempted operation while child memory context is active
    /// Memory contexts must be properly managed
    ChildContextActive,

    /// Attempted to revert/commit without active child context
    /// Memory context operations must be balanced
    NoChildContextToRevertOrCommit,

    /// EOF (EVM Object Format) features not yet implemented
    /// Placeholder for future EOF-related opcodes
    EOFNotSupported,

    // Database errors from the database interface
    /// Account not found in the database
    AccountNotFound,
    /// Storage slot not found for the given address
    StorageNotFound,
    /// Contract code not found for the given hash
    CodeNotFound,
    /// Invalid address format
    InvalidAddress,
    /// Database corruption detected
    DatabaseCorrupted,
    /// Network error when accessing remote database
    NetworkError,
    /// Permission denied accessing database
    PermissionDenied,
    /// Invalid snapshot identifier
    InvalidSnapshot,
    /// Batch operation not in progress
    NoBatchInProgress,
    /// Snapshot not found
    SnapshotNotFound,

    // Instruction translation errors
    /// Instruction limit exceeded during translation
    InstructionLimitExceeded,
    /// Opcode not implemented in translator
    OpcodeNotImplemented,

    /// Contract input (calldata) size exceeds maximum allowed size
    /// Typically 128KB limit imposed by RPC providers
    InputSizeExceeded,

    /// Contract code size mismatch between expected and actual size
    /// Occurs when contract.code_size doesn't match contract.input.len
    CodeSizeMismatch,

    /// SELFDESTRUCT opcode not available in current hardfork
    /// Some hardforks disable SELFDESTRUCT functionality
    SelfDestructNotAvailable,
};

/// Get a human-readable description for an execution error
///
/// Provides detailed descriptions of what each error means and when it occurs.
/// Useful for debugging, logging, and error reporting.
///
/// ## Parameters
/// - `err`: The execution error to describe
///
/// ## Returns
/// A string slice containing a human-readable description of the error
///
/// ## Example
/// ```zig
/// const err = Error.StackOverflow;
/// const desc = get_description(err);
/// std.log.err("EVM execution failed: {s}", .{desc});
/// ```
pub fn get_description(err: Error) []const u8 {
    return switch (err) {
        Error.MAX_CONTRACT_SIZE => "Contract size exceeds maximum allowed",
        Error.STOP => "Normal STOP opcode execution",
        Error.REVERT => "REVERT opcode - state reverted",
        Error.INVALID => "INVALID opcode or invalid operation",
        Error.OutOfGas => "Out of gas",
        Error.StackUnderflow => "Stack underflow",
        Error.StackOverflow => "Stack overflow (beyond 1024 elements)",
        Error.InvalidJump => "Jump to invalid destination",
        Error.InvalidOpcode => "Undefined opcode",
        Error.StaticStateChange => "State modification in static context",
        Error.OutOfOffset => "Memory access out of bounds",
        Error.GasUintOverflow => "Gas calculation overflow",
        Error.WriteProtection => "Write to protected storage",
        Error.ReturnDataOutOfBounds => "Return data access out of bounds",
        Error.InvalidReturnDataAccess => "Invalid return data access - offset + size exceeds data length",
        Error.DeployCodeTooBig => "Contract creation code too large",
        Error.MaxCodeSizeExceeded => "Contract code size exceeds limit",
        Error.InvalidCodeEntry => "Invalid contract entry code",
        Error.DepthLimit => "Call depth exceeds limit (1024)",
        Error.OutOfMemory => "Out of memory allocation failed",
        Error.InvalidOffset => "Invalid memory offset",
        Error.InvalidSize => "Invalid memory size",
        Error.MemoryLimitExceeded => "Memory limit exceeded",
        Error.ChildContextActive => "Child context is active",
        Error.NoChildContextToRevertOrCommit => "No child context to revert or commit",
        Error.EOFNotSupported => "EOF (EVM Object Format) opcode not supported",
        Error.AccountNotFound => "Account not found in database",
        Error.StorageNotFound => "Storage slot not found in database",
        Error.CodeNotFound => "Contract code not found in database",
        Error.InvalidAddress => "Invalid address format",
        Error.DatabaseCorrupted => "Database corruption detected",
        Error.NetworkError => "Network error accessing database",
        Error.PermissionDenied => "Permission denied accessing database",
        Error.InvalidSnapshot => "Invalid snapshot identifier",
        Error.NoBatchInProgress => "No batch operation in progress",
        Error.SnapshotNotFound => "Snapshot not found in database",
        Error.InstructionLimitExceeded => "Instruction limit exceeded during translation",
        Error.OpcodeNotImplemented => "Opcode not implemented in translator",
        Error.InputSizeExceeded => "Contract input size exceeds maximum allowed size",
        Error.CodeSizeMismatch => "Contract code size mismatch between expected and actual size",
        Error.SelfDestructNotAvailable => "SELFDESTRUCT opcode not available in current hardfork",
    };
}

// Tests

const testing = std.testing;

test "get_description returns correct message for STOP error" {
    const desc = get_description(Error.STOP);
    try testing.expectEqualStrings("Normal STOP opcode execution", desc);
}

test "get_description returns correct message for REVERT error" {
    const desc = get_description(Error.REVERT);
    try testing.expectEqualStrings("REVERT opcode - state reverted", desc);
}

test "get_description returns correct message for INVALID error" {
    const desc = get_description(Error.INVALID);
    try testing.expectEqualStrings("INVALID opcode or invalid operation", desc);
}

test "get_description returns correct message for OutOfGas error" {
    const desc = get_description(Error.OutOfGas);
    try testing.expectEqualStrings("Out of gas", desc);
}

test "get_description returns correct message for StackUnderflow error" {
    const desc = get_description(Error.StackUnderflow);
    try testing.expectEqualStrings("Stack underflow", desc);
}

test "get_description returns correct message for StackOverflow error" {
    const desc = get_description(Error.StackOverflow);
    try testing.expectEqualStrings("Stack overflow (beyond 1024 elements)", desc);
}

test "get_description returns correct message for InvalidJump error" {
    const desc = get_description(Error.InvalidJump);
    try testing.expectEqualStrings("Jump to invalid destination", desc);
}

test "get_description returns correct message for InvalidOpcode error" {
    const desc = get_description(Error.InvalidOpcode);
    try testing.expectEqualStrings("Undefined opcode", desc);
}

test "get_description returns correct message for StaticStateChange error" {
    const desc = get_description(Error.StaticStateChange);
    try testing.expectEqualStrings("State modification in static context", desc);
}

test "get_description returns correct message for OutOfOffset error" {
    const desc = get_description(Error.OutOfOffset);
    try testing.expectEqualStrings("Memory access out of bounds", desc);
}

test "get_description returns correct message for GasUintOverflow error" {
    const desc = get_description(Error.GasUintOverflow);
    try testing.expectEqualStrings("Gas calculation overflow", desc);
}

test "get_description returns correct message for WriteProtection error" {
    const desc = get_description(Error.WriteProtection);
    try testing.expectEqualStrings("Write to protected storage", desc);
}

test "get_description returns correct message for ReturnDataOutOfBounds error" {
    const desc = get_description(Error.ReturnDataOutOfBounds);
    try testing.expectEqualStrings("Return data access out of bounds", desc);
}

test "get_description returns correct message for InvalidReturnDataAccess error" {
    const desc = get_description(Error.InvalidReturnDataAccess);
    try testing.expectEqualStrings("Invalid return data access - offset + size exceeds data length", desc);
}

test "get_description returns correct message for DeployCodeTooBig error" {
    const desc = get_description(Error.DeployCodeTooBig);
    try testing.expectEqualStrings("Contract creation code too large", desc);
}

test "get_description returns correct message for MaxCodeSizeExceeded error" {
    const desc = get_description(Error.MaxCodeSizeExceeded);
    try testing.expectEqualStrings("Contract code size exceeds limit", desc);
}

test "get_description returns correct message for InvalidCodeEntry error" {
    const desc = get_description(Error.InvalidCodeEntry);
    try testing.expectEqualStrings("Invalid contract entry code", desc);
}

test "get_description returns correct message for DepthLimit error" {
    const desc = get_description(Error.DepthLimit);
    try testing.expectEqualStrings("Call depth exceeds limit (1024)", desc);
}

test "get_description returns correct message for OutOfMemory error" {
    const desc = get_description(Error.OutOfMemory);
    try testing.expectEqualStrings("Out of memory allocation failed", desc);
}

test "get_description returns correct message for InvalidOffset error" {
    const desc = get_description(Error.InvalidOffset);
    try testing.expectEqualStrings("Invalid memory offset", desc);
}

test "get_description returns correct message for InvalidSize error" {
    const desc = get_description(Error.InvalidSize);
    try testing.expectEqualStrings("Invalid memory size", desc);
}

test "get_description returns correct message for MemoryLimitExceeded error" {
    const desc = get_description(Error.MemoryLimitExceeded);
    try testing.expectEqualStrings("Memory limit exceeded", desc);
}

test "get_description returns correct message for ChildContextActive error" {
    const desc = get_description(Error.ChildContextActive);
    try testing.expectEqualStrings("Child context is active", desc);
}

test "get_description returns correct message for NoChildContextToRevertOrCommit error" {
    const desc = get_description(Error.NoChildContextToRevertOrCommit);
    try testing.expectEqualStrings("No child context to revert or commit", desc);
}

test "get_description returns correct message for EOFNotSupported error" {
    const desc = get_description(Error.EOFNotSupported);
    try testing.expectEqualStrings("EOF (EVM Object Format) opcode not supported", desc);
}

test "get_description returns correct message for AccountNotFound error" {
    const desc = get_description(Error.AccountNotFound);
    try testing.expectEqualStrings("Account not found in database", desc);
}

test "get_description returns correct message for StorageNotFound error" {
    const desc = get_description(Error.StorageNotFound);
    try testing.expectEqualStrings("Storage slot not found in database", desc);
}

test "get_description returns correct message for CodeNotFound error" {
    const desc = get_description(Error.CodeNotFound);
    try testing.expectEqualStrings("Contract code not found in database", desc);
}

test "get_description returns correct message for InvalidAddress error" {
    const desc = get_description(Error.InvalidAddress);
    try testing.expectEqualStrings("Invalid address format", desc);
}

test "get_description returns correct message for DatabaseCorrupted error" {
    const desc = get_description(Error.DatabaseCorrupted);
    try testing.expectEqualStrings("Database corruption detected", desc);
}

test "get_description returns correct message for NetworkError error" {
    const desc = get_description(Error.NetworkError);
    try testing.expectEqualStrings("Network error accessing database", desc);
}

test "get_description returns correct message for PermissionDenied error" {
    const desc = get_description(Error.PermissionDenied);
    try testing.expectEqualStrings("Permission denied accessing database", desc);
}

test "get_description returns correct message for InvalidSnapshot error" {
    const desc = get_description(Error.InvalidSnapshot);
    try testing.expectEqualStrings("Invalid snapshot identifier", desc);
}

test "get_description returns correct message for NoBatchInProgress error" {
    const desc = get_description(Error.NoBatchInProgress);
    try testing.expectEqualStrings("No batch operation in progress", desc);
}

test "get_description returns correct message for SnapshotNotFound error" {
    const desc = get_description(Error.SnapshotNotFound);
    try testing.expectEqualStrings("Snapshot not found in database", desc);
}

test "get_description consistency - all errors have non-empty descriptions" {
    for (all_errors) |err| {
        const desc = get_description(err);
        try testing.expect(desc.len > 0);
    }
}

test "get_description formatting - descriptions are properly formatted" {
    for (all_errors) |err| {
        const desc = get_description(err);
        try testing.expect(desc.len < 100);
        try testing.expect(!std.mem.startsWith(u8, desc, " "));
        try testing.expect(!std.mem.endsWith(u8, desc, " "));
    }
}

// ============================================================================
// Fuzz Tests for Error Enumeration Completeness (Issue #234)
// Using proper Zig built-in fuzz testing with std.testing.fuzz()
// ============================================================================

const all_errors = [_]Error{
    Error.STOP,                  Error.REVERT,                  Error.INVALID,            Error.OutOfGas,
    Error.StackUnderflow,        Error.StackOverflow,           Error.InvalidJump,        Error.InvalidOpcode,
    Error.StaticStateChange,     Error.OutOfOffset,             Error.GasUintOverflow,    Error.WriteProtection,
    Error.ReturnDataOutOfBounds, Error.InvalidReturnDataAccess, Error.DeployCodeTooBig,   Error.MaxCodeSizeExceeded,
    Error.InvalidCodeEntry,      Error.DepthLimit,              Error.OutOfMemory,        Error.InvalidOffset,
    Error.InvalidSize,           Error.MemoryLimitExceeded,     Error.ChildContextActive, Error.NoChildContextToRevertOrCommit,
    Error.EOFNotSupported,       Error.AccountNotFound,         Error.StorageNotFound,    Error.CodeNotFound,
    Error.InvalidAddress,        Error.DatabaseCorrupted,       Error.NetworkError,       Error.PermissionDenied,
    Error.InvalidSnapshot,       Error.NoBatchInProgress,       Error.SnapshotNotFound,   Error.InstructionLimitExceeded,
    Error.OpcodeNotImplemented,  Error.InputSizeExceeded,       Error.CodeSizeMismatch,   Error.SelfDestructNotAvailable,
};

````

````
/// Result structure returned by contract call operations.
///
/// This structure encapsulates the outcome of executing a contract call in the EVM,
/// including standard calls (CALL), code calls (CALLCODE), delegate calls (DELEGATECALL),
/// and static calls (STATICCALL). It provides a unified interface for handling the
/// results of all inter-contract communication operations.
///
/// ## Usage
/// This structure is returned by the VM's call methods and contains all information
/// needed to determine the outcome of a call and process its results.
///
/// ## Call Types
/// - **CALL**: Standard contract call with its own storage context
/// - **CALLCODE**: Executes external code in current storage context (deprecated)
/// - **DELEGATECALL**: Executes external code with current storage and msg context
/// - **STATICCALL**: Read-only call that cannot modify state
///
/// ## Example
/// ```zig
/// const result = try vm.call_contract(caller, to, value, input, gas, is_static);
/// if (result.success) {
///     // Process successful call
///     if (result.output) |data| {
///         // Handle returned data
///     }
/// } else {
///     // Handle failed call - gas_left indicates remaining gas
/// }
/// defer if (result.output) |output| allocator.free(output);
/// ```
pub const CallResult = @This();

/// Indicates whether the call completed successfully.
///
/// - `true`: Call executed without errors and any state changes were committed
/// - `false`: Call failed due to revert, out of gas, or other errors
///
/// Note: A successful call may still have no output data if the called
/// contract intentionally returns nothing.
success: bool,

/// Amount of gas remaining after the call execution.
///
/// This value is important for gas accounting:
/// - For successful calls: Indicates unused gas to be refunded to the caller
/// - For failed calls: May be non-zero if the call reverted (vs running out of gas)
///
/// The calling context should add this back to its available gas to continue execution.
gas_left: u64,

/// Optional output data returned by the called contract.
///
/// - `null`: No data was returned (valid for both success and failure)
/// - `[]const u8`: Returned data buffer
///
/// ## Memory Management
/// The output data is allocated by the VM and ownership is transferred to the caller.
/// The caller is responsible for freeing this memory when no longer needed.
///
/// ## For Different Call Types
/// - **RETURN**: Contains the data specified in the RETURN opcode
/// - **REVERT**: Contains the revert reason/data if provided
/// - **STOP**: Will be null (no data returned)
/// - **Out of Gas/Invalid**: Will be null
output: ?[]const u8,
````

The call method will handle every type of call with a switch statement. I see that is not implemented. I see even more constants that should be on a config object. But the API here is excellent and simple. So callinitializes all data is depth is 0. It does a lot of input validation. It handles precompiles.

NOw here is the most interesting part of the Evm. Code analysis. We will dive deeper into it soon but very quickly, we turn the bytecode info and the comptime generated jumptable (btw jump table since it is comptime should be a part of the config.) So analysis happens before we initialize the evm state and start executing. We put analysis on the stack when it fits but otherwise on heap if it is large. We preallocate worst case is the plan here and then we the analysis only returns data we need freeing everything else. These instructions have a bitmap that tells us what the correct jumpdest are as well as a null terminated stream of instructions that we execute with the evm. It precomputes gas and has other optimizations from this analysis phase and makes the evm highly performant.

SO when we initialize the evm we want the Evm struct itself to have the state. We made the evm syncronous you would have to make a new instance to execute more than one at once. So we store the data the Evm every time it runs. We always free heap data at the end though using our arena allocator. Every run we freshly allocate up front so most contract allocation is minimal. Frame is the core data structure of the Evm state representing a call frame as a linked list of frames living in a fixed size array of max call depth. Frame has ways of dealing with journaling and reverting too.

Precompiles are handled as a special case

Then we call the intpret method the interpret method is what executes a single frame of the evm. If it needs to make an inner call it recursively calls call. The interpret operates only on frame and is built for high performance. We pass in a reference of frame linked list to it and it operates on it. After iterpreter runs we handle the result.

```
const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const InterpretResult = @import("interpret_result.zig").InterpretResult;
const RunResult = @import("run_result.zig").RunResult;
const Frame = @import("../frame.zig").Frame;
const ChainRules = @import("../frame.zig").ChainRules;
const AccessList = @import("../access_list.zig").AccessList;
const SelfDestruct = @import("../self_destruct.zig").SelfDestruct;
const CodeAnalysis = @import("../analysis.zig");
const Evm = @import("../evm.zig");
const interpret = @import("interpret.zig").interpret;
const MAX_CODE_SIZE = @import("../opcodes/opcode.zig").MAX_CODE_SIZE;
const MAX_CALL_DEPTH = @import("../constants/evm_limits.zig").MAX_CALL_DEPTH;
const primitives = @import("primitives");
const precompiles = @import("../precompiles/precompiles.zig");
const precompile_addresses = @import("../precompiles/precompile_addresses.zig");
const CallResult = @import("call_result.zig").CallResult;
const CallParams = @import("../host.zig").CallParams;

// Threshold for stack vs heap allocation optimization
const STACK_ALLOCATION_THRESHOLD = 12800; // bytes of bytecode
// Maximum stack buffer size for contracts up to 12,800 bytes
const MAX_STACK_BUFFER_SIZE = 43008; // 42KB with alignment padding

// THE EVM has no actual limit on calldata. Only indirect practical limits like gas cost exist.
// 128 KB is about the limit most rpc providers limit call data to so we use it as the default
pub const MAX_INPUT_SIZE: u18 = 128 * 1024; // 128 kb

pub inline fn call(self: *Evm, params: CallParams) ExecutionError.Error!CallResult {
    // Extract call info from params - for now just handle the .call case
    // TODO: Handle other call types properly
    const call_info = switch (params) {
        .call => |call_data| .{
            .address = call_data.to,
            .code = &[_]u8{}, // TODO: Load from state
            .code_size = 0,
            .input = call_data.input,
            .gas = call_data.gas,
            .is_static = false,
        },
        .staticcall => |call_data| .{
            .address = call_data.to,
            .code = &[_]u8{}, // TODO: Load from state
            .code_size = 0,
            .input = call_data.input,
            .gas = call_data.gas,
            .is_static = true,
        },
        else => {
            // For now, return error for unhandled call types
            return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
        },
    };

    // Input validation
    if (call_info.input.len > MAX_INPUT_SIZE) return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
    if (call_info.code_size > MAX_CODE_SIZE) return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
    if (call_info.code_size != call_info.code.len) return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
    if (call_info.gas == 0) return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
    if (call_info.code_size > 0 and call_info.code.len == 0) return CallResult{ .success = false, .gas_left = 0, .output = &.{} };

    // Do analysis using EVM instance buffer if contract is small
    const analysis_allocator = if (call_info.code_size <= STACK_ALLOCATION_THRESHOLD)
        std.heap.FixedBufferAllocator.init(&self.analysis_stack_buffer)
    else
        self.allocator;
    var analysis = try CodeAnalysis.from_code(analysis_allocator, call_info.code[0..call_info.code_size], &self.table);
    defer analysis.deinit();

    // Reinitialize if first frame
    // Only initialize EVM state if we're at depth 0 (top-level call)
    // Check current frame depth from EVM to determine if this is a nested call
    if (self.current_frame_depth == 0) {
        // Initialize fresh execution state in EVM instance (per-call isolation)
        // CRITICAL: Clear all state at beginning of top-level call
        self.current_frame_depth = 0;
        self.access_list.clear(); // Reset access list for fresh per-call state
        self.self_destruct = SelfDestruct.init(self.allocator); // Fresh self-destruct tracker
        for (0..MAX_CALL_DEPTH) |i| {
            const next_frame = if (i + 1 < MAX_CALL_DEPTH) &self.frame_stack[i + 1] else null;
            self.frame_stack[i] = try Frame.init(
                0, // gas_remaining - will be set properly for frame 0
                false, // static_call - will be set properly for frame 0
                @intCast(i), // call_depth
                primitives.Address.ZERO_ADDRESS, // contract_address - will be set properly for frame 0
                &analysis, // analysis - will be set properly for each frame when used
                &self.access_list,
                self.state,
                ChainRules{},
                &self.self_destruct,
                &[_]u8{}, // input - will be set properly for frame 0
                self.arena_allocator(),
                next_frame,
            );
        }
        // Set up the first frame properly for execution
        self.frame_stack[0].gas_remaining = call_info.gas;
        self.frame_stack[0].hot_flags.is_static = call_info.is_static;
        self.frame_stack[0].hot_flags.depth = @intCast(self.depth);
        self.frame_stack[0].contract_address = call_info.address;
        self.frame_stack[0].input = call_info.input;
    }

    if (precompile_addresses.get_precompile_id_checked(call_info.address)) |precompile_id| {
        const precompile_result = self.execute_precompile_call_by_id(precompile_id, call_info.input, call_info.gas, call_info.is_static) catch |err| {
            return switch (err) {
                else => CallResult{ .success = false, .gas_left = 0, .output = &.{} },
            };
        };

        return precompile_result;
    }

    // Call interpret with the first frame
    interpret(self, &self.frame_stack[0]) catch |err| {
        // Handle error cases and transform to CallResult
        var output = &[_]u8{};
        if (self.frame_stack[0].output.len > 0) {
            output = self.allocator.dupe(u8, self.frame_stack[0].output) catch &[_]u8{};
        }

        const success = switch (err) {
            ExecutionError.Error.STOP => true,
            ExecutionError.Error.REVERT => false,
            ExecutionError.Error.OutOfGas => false,
            else => false,
        };

        return CallResult{
            .success = success,
            .gas_left = self.frame_stack[0].gas_remaining,
            .output = output,
        };
    };

    // Success case - copy output if needed
    var output = &[_]u8{};
    if (self.frame_stack[0].output.len > 0) {
        output = try self.allocator.dupe(u8, self.frame_stack[0].output);
    }

    // Apply destructions before returning
    // TODO: Apply destructions to state
    return CallResult{
        .success = true,
        .gas_left = self.frame_stack[0].gas_remaining,
        .output = output,
    };
}

```

## Frame

So frame is our core data structure and it includes sub structures

```
/// Minimal execution context for EVM opcodes - replaces the heavy Frame struct
///
/// This struct contains only the essential data needed by EVM execution handlers,
/// following data-oriented design principles for better cache performance and
/// eliminating circular dependencies.
const std = @import("std");
const primitives = @import("primitives");
const Stack = @import("stack/stack.zig");
const Memory = @import("memory/memory.zig");
const ExecutionError = @import("execution/execution_error.zig");
const CodeAnalysis = @import("analysis.zig");
const AccessList = @import("call_frame_stack.zig").AccessList;
const CallJournal = @import("call_frame_stack.zig").CallJournal;
const Host = @import("host.zig").Host;
const SelfDestruct = @import("self_destruct.zig").SelfDestruct;
const DatabaseInterface = @import("state/database_interface.zig").DatabaseInterface;
const Hardfork = @import("hardforks/hardfork.zig").Hardfork;

/// Error types for Frame operations
pub const AccessError = error{OutOfMemory};
pub const StateError = error{OutOfMemory};

/// Combined chain rules (hardforks + EIPs) for configuration input.
/// Used to create the optimized Flags packed struct.
/// NOTE: Only includes EIPs that need runtime checks during opcode execution.
/// EIPs for transaction validation, gas pricing, bytecode analysis, and pre-execution setup are handled elsewhere.
pub const ChainRules = struct {
    // Core hardfork markers (used for getHardfork() only)
    is_homestead: bool = true,
    is_byzantium: bool = true,
    is_constantinople: bool = true,
    is_petersburg: bool = true,
    is_istanbul: bool = true,
    is_berlin: bool = true,
    is_london: bool = true,
    is_merge: bool = true,
    is_shanghai: bool = true,
    is_cancun: bool = true,
    is_prague: bool = false,

    // EIPs that need runtime opcode validation (very few!)
    is_eip1153: bool = true, // Transient storage (TLOAD/TSTORE) - runtime validation

    /// Default chain rules for the latest hardfork (CANCUN).
    pub const DEFAULT = ChainRules{};
};

/// Packed flags struct - optimized for actual runtime usage
/// Only contains flags that are checked during opcode execution
pub const Flags = packed struct {
    // Hot execution state - accessed every opcode
    depth: u10, // 10 bits (0-1023) - call stack depth
    is_static: bool, // 1 bit - static call restriction (checked by SSTORE, TSTORE, etc.)

    // EIP flags checked during execution (very few!)
    is_eip1153: bool, // 1 bit - Transient storage (TLOAD/TSTORE validation)

    // Hardfork markers (only for getHardfork() method)
    is_prague: bool, // 1 bit
    is_cancun: bool, // 1 bit
    is_shanghai: bool, // 1 bit
    is_merge: bool, // 1 bit
    is_london: bool, // 1 bit
    is_berlin: bool, // 1 bit
    is_istanbul: bool, // 1 bit
    is_petersburg: bool, // 1 bit
    is_constantinople: bool, // 1 bit
    is_byzantium: bool, // 1 bit
    is_homestead: bool, // 1 bit

    // Reserved for future expansion - remaining bits
    _reserved: u41 = 0, // Ensures exactly 64 bits total (11 + 1 + 1 + 10 + 1 + 41 = 64)
};

/// Frame represents the entire execution state of the EVM as it executes opcodes
/// Layout designed around actual opcode access patterns and data correlations
pub const Frame = struct {
    // ULTRA HOT - Accessed by virtually every opcode
    stack: Stack, // 33,536 bytes - accessed by every opcode (PUSH/POP/DUP/SWAP/arithmetic/etc)
    gas_remaining: u64, // 8 bytes - checked/consumed by every opcode for gas accounting

    // HOT - Accessed by major opcode categories
    memory: *Memory, // 8 bytes - hot for memory ops (MLOAD/MSTORE/MSIZE/MCOPY/LOG*/KECCAK256)
    analysis: *const CodeAnalysis, // 8 bytes - hot for control flow (JUMP/JUMPI validation)

    // Pack hot_flags to 2 bytes for better alignment
    hot_flags: packed struct {
        depth: u10, // 10 bits - call stack depth for CALL/CREATE operations
        is_static: bool, // 1 bit - static call restriction (checked by SSTORE/TSTORE)
        is_eip1153: bool, // 1 bit - transient storage validation (TLOAD/TSTORE)
        _padding: u4 = 0, // 4 bits - align to byte boundary and room for future flags
    },

    // Call frame stack integration fields
    journal: *CallJournal, // 8 bytes - shared journaling system
    host: *Host, // 8 bytes - host interface for external operations
    snapshot_id: u32, // 4 bytes - snapshot when this frame started
    caller: primitives.Address.Address, // 20 bytes - caller address
    value: u256, // 32 bytes - value transferred in this call

    // Add padding to align storage group to 8-byte boundary
    _pad1: [4]u8 = [_]u8{0} ** 4,

    // Storage operation group (aligned to 8 bytes)
    // All storage operations (SLOAD/SSTORE/TLOAD/TSTORE) need ALL of these together
    contract_address: primitives.Address.Address, // 20 bytes - FIRST: storage key = hash(contract_address, slot)
    _pad2: [4]u8 = [_]u8{0} ** 4, // Align state to 8-byte boundary
    state: DatabaseInterface, // 16 bytes - actual storage read/write interface
    access_list: *AccessList, // 8 bytes - LAST: EIP-2929 warm/cold gas cost calculation
    // Total: 48 bytes = exactly 3/4 of a cache line

    // COLD DATA
    allocator: std.mem.Allocator, // 16 bytes
    input: []const u8, // 16 bytes - only 3 opcodes: CALLDATALOAD/SIZE/COPY (rare in most contracts)
    output: []const u8, // 16 bytes - only set by RETURN/REVERT at function exit

    // Use hardfork enum instead of boolean flags for better cache efficiency
    hardfork: Hardfork, // 1 byte instead of 16 bits of boolean flags
    _pad3: [7]u8 = [_]u8{0} ** 7, // Align to 8-byte boundary

    self_destruct: ?*SelfDestruct, // 8 bytes - extremely rare: only SELFDESTRUCT opcode

    /// Pointer to the next frame in the call stack (for nested calls)
    /// null if this is the deepest frame or no more frames available
    next_frame: ?*Frame, // 8 bytes - pointer to next frame for CALL/CREATE operations

    /// Initialize a Frame with required parameters
    pub fn init(
        gas_remaining: u64,
        static_call: bool,
        call_depth: u32,
        contract_address: primitives.Address.Address,
        caller: primitives.Address.Address,
        value: u256,
        analysis: *const CodeAnalysis,
        access_list: *AccessList,
        journal: *CallJournal,
        host: *Host,
        snapshot_id: u32,
        state: DatabaseInterface,
        chain_rules: ChainRules,
        self_destruct: ?*SelfDestruct,
        input: []const u8,
        allocator: std.mem.Allocator,
        next_frame: ?*Frame,
    ) !Frame {
        // Determine hardfork from chain rules
        const hardfork = blk: {
            if (chain_rules.is_prague) break :blk Hardfork.PRAGUE;
            if (chain_rules.is_cancun) break :blk Hardfork.CANCUN;
            if (chain_rules.is_shanghai) break :blk Hardfork.SHANGHAI;
            if (chain_rules.is_merge) break :blk Hardfork.MERGE;
            if (chain_rules.is_london) break :blk Hardfork.LONDON;
            if (chain_rules.is_berlin) break :blk Hardfork.BERLIN;
            if (chain_rules.is_istanbul) break :blk Hardfork.ISTANBUL;
            if (chain_rules.is_petersburg) break :blk Hardfork.PETERSBURG;
            if (chain_rules.is_constantinople) break :blk Hardfork.CONSTANTINOPLE;
            if (chain_rules.is_byzantium) break :blk Hardfork.BYZANTIUM;
            if (chain_rules.is_homestead) break :blk Hardfork.HOMESTEAD;
            break :blk Hardfork.FRONTIER;
        };

        return Frame{
            // Ultra hot data
            .stack = Stack.init(),
            .gas_remaining = gas_remaining,

            // Hot data
            .memory = try Memory.init_default(allocator),
            .analysis = analysis,
            .hot_flags = .{
                .depth = @intCast(call_depth),
                .is_static = static_call,
                .is_eip1153 = chain_rules.is_eip1153,
            },

            // Call frame stack integration
            .journal = journal,
            .host = host,
            .snapshot_id = snapshot_id,
            .caller = caller,
            .value = value,

            // Storage cluster
            .contract_address = contract_address,
            .state = state,
            .access_list = access_list,

            // Cold data
            .input = input,
            .output = &[_]u8{},
            .hardfork = hardfork,
            .self_destruct = self_destruct,
            .allocator = allocator,
            .next_frame = next_frame,
        };
    }

    pub fn deinit(self: *Frame) void {
        self.memory.deinit();
    }

    /// Gas consumption with bounds checking - used by all opcodes that consume gas
    pub fn consume_gas(self: *Frame, amount: u64) ExecutionError!void {
        if (self.gas_remaining < amount) return ExecutionError.Error.OutOfGas;
        self.gas_remaining -= amount;
    }

    /// Jump destination validation - uses direct bitmap access
    /// This is significantly faster than the previous function pointer approach
    pub fn valid_jumpdest(self: *Frame, dest: u256) bool {
        std.debug.assert(dest <= std.math.maxInt(u32));
        const dest_usize = @as(usize, @intCast(dest));
        return self.analysis.jumpdest_bitmap.isSet(dest_usize);
    }

    /// Address access for EIP-2929 - uses direct access list pointer
    pub fn access_address(self: *Frame, addr: primitives.Address.Address) !u64 {
        return self.access_list.access_address(addr);
    }

    /// Mark contract for destruction - uses direct self destruct pointer
    pub fn mark_for_destruction(self: *Frame, recipient: primitives.Address.Address) !void {
        if (self.self_destruct) |sd| {
            @branchHint(.likely);
            return sd.mark_for_destruction(self.contract_address, recipient);
        }
        return ExecutionError.Error.SelfDestructNotAvailable;
    }

    /// Set output data for RETURN/REVERT operations
    pub fn set_output(self: *Frame, data: []const u8) void {
        self.output = data;
    }

    /// Storage access operations for EVM opcodes
    pub fn get_storage(self: *const Frame, slot: u256) u256 {
        return self.state.get_storage(self.contract_address, slot) catch 0; // Return 0 on error (EVM behavior)
    }

    pub fn set_storage(self: *Frame, slot: u256, value: u256) !void {
        // Record the original value in journal before changing
        const original_value = self.state.get_storage(self.contract_address, slot) catch 0;
        if (original_value != value) {
            try self.journal.record_storage_change(self.snapshot_id, self.contract_address, slot, original_value);
        }
        try self.state.set_storage(self.contract_address, slot, value);
    }

    pub fn get_transient_storage(self: *const Frame, slot: u256) u256 {
        return self.state.get_transient_storage(self.contract_address, slot) catch 0; // Return 0 on error (EVM behavior)
    }

    pub fn set_transient_storage(self: *Frame, slot: u256, value: u256) !void {
        try self.state.set_transient_storage(self.contract_address, slot, value);
    }

    /// Mark storage slot as warm (EIP-2929) and return true if it was cold
    pub fn mark_storage_slot_warm(self: *Frame, slot: u256) !bool {
        return self.access_list.access_storage_key(self.contract_address, slot);
    }

    /// Add gas refund for storage operations (e.g., SSTORE refunds)
    /// TODO: This needs to be integrated with the refund tracking system
    pub fn add_gas_refund(self: *Frame, amount: u64) void {
        _ = self;
        _ = amount;
        // TODO: Implement refund tracking when the refund system is integrated
    }


    /// Backward compatibility accessors
    pub fn depth(self: *const Frame) u32 {
        return @intCast(self.hot_flags.depth);
    }

    pub fn is_static(self: *const Frame) bool {
        return self.hot_flags.is_static;
    }

    pub fn set_depth(self: *Frame, d: u32) void {
        self.hot_flags.depth = @intCast(d);
    }

    pub fn set_is_static(self: *Frame, static: bool) void {
        self.hot_flags.is_static = static;
    }

    /// ChainRules helper methods - moved from ChainRules struct for better data locality
    /// Mapping of chain rule fields to the hardfork in which they were introduced.
    const HardforkRule = struct {
        field_name: []const u8,
        introduced_in: Hardfork,
    };

    const HARDFORK_RULES = [_]HardforkRule{
        .{ .field_name = "is_homestead", .introduced_in = .HOMESTEAD },
        .{ .field_name = "is_byzantium", .introduced_in = .BYZANTIUM },
        .{ .field_name = "is_constantinople", .introduced_in = .CONSTANTINOPLE },
        .{ .field_name = "is_petersburg", .introduced_in = .PETERSBURG },
        .{ .field_name = "is_istanbul", .introduced_in = .ISTANBUL },
        .{ .field_name = "is_berlin", .introduced_in = .BERLIN },
        .{ .field_name = "is_london", .introduced_in = .LONDON },
        .{ .field_name = "is_merge", .introduced_in = .MERGE },
        .{ .field_name = "is_shanghai", .introduced_in = .SHANGHAI },
        .{ .field_name = "is_cancun", .introduced_in = .CANCUN },
        .{ .field_name = "is_eip1153", .introduced_in = .CANCUN },
    };

    /// Create ChainRules for a specific hardfork
    pub fn chainRulesForHardfork(hardfork: Hardfork) ChainRules {
        var rules = ChainRules{}; // All fields default to true

        // Disable features that were introduced after the target hardfork
        inline for (HARDFORK_RULES) |rule| {
            if (@intFromEnum(hardfork) < @intFromEnum(rule.introduced_in)) {
                @branchHint(.cold);
                @field(rules, rule.field_name) = false;
            } else {
                @branchHint(.likely);
            }
        }

        return rules;
    }

    /// Get the hardfork for this frame
    pub fn getHardfork(self: *const Frame) Hardfork {
        return self.hardfork;
    }

    /// Check if this frame's hardfork is greater than or equal to the specified hardfork
    pub fn is_at_least(self: *const Frame, target_hardfork: Hardfork) bool {
        return @intFromEnum(self.hardfork) >= @intFromEnum(target_hardfork);
    }

    /// Check if this frame's hardfork is greater than the specified hardfork
    pub fn is_greater_than(self: *const Frame, target_hardfork: Hardfork) bool {
        return @intFromEnum(self.hardfork) > @intFromEnum(target_hardfork);
    }

    /// Check if this frame's hardfork exactly matches the specified hardfork
    pub fn is_exactly(self: *const Frame, target_hardfork: Hardfork) bool {
        return self.hardfork == target_hardfork;
    }

    /// Check if a specific hardfork feature is enabled
    pub fn hasHardforkFeature(self: *const Frame, comptime field_name: []const u8) bool {
        // Check hot flags first (most likely to be accessed)
        if (@hasField(@TypeOf(self.hot_flags), field_name)) {
            return @field(self.hot_flags, field_name);
        }

        // Handle hardfork checks using the enum comparison
        if (std.mem.eql(u8, field_name, "is_prague")) return self.is_at_least(.PRAGUE);
        if (std.mem.eql(u8, field_name, "is_cancun")) return self.is_at_least(.CANCUN);
        if (std.mem.eql(u8, field_name, "is_shanghai")) return self.is_at_least(.SHANGHAI);
        if (std.mem.eql(u8, field_name, "is_merge")) return self.is_at_least(.MERGE);
        if (std.mem.eql(u8, field_name, "is_london")) return self.is_at_least(.LONDON);
        if (std.mem.eql(u8, field_name, "is_berlin")) return self.is_at_least(.BERLIN);
        if (std.mem.eql(u8, field_name, "is_istanbul")) return self.is_at_least(.ISTANBUL);
        if (std.mem.eql(u8, field_name, "is_petersburg")) return self.is_at_least(.PETERSBURG);
        if (std.mem.eql(u8, field_name, "is_constantinople")) return self.is_at_least(.CONSTANTINOPLE);
        if (std.mem.eql(u8, field_name, "is_byzantium")) return self.is_at_least(.BYZANTIUM);
        if (std.mem.eql(u8, field_name, "is_homestead")) return self.is_at_least(.HOMESTEAD);

        @compileError("Unknown hardfork feature: " ++ field_name);
    }

    /// Get the next available frame for nested calls (CALL, DELEGATECALL, etc.)
    /// Returns null if we've reached maximum call depth (stack overflow)
    pub fn get_next_frame(self: *Frame) ?*Frame {
        return self.next_frame;
    }

    /// Check if we can make another call (haven't reached max call depth)
    pub fn can_make_call(self: *const Frame) bool {
        return self.next_frame != null;
    }

    /// Prepare the next frame for a nested call
    /// This should be called by CALL/DELEGATECALL/STATICCALL/CREATE opcodes
    /// TODO: This will need to be implemented when we add actual CALL/CREATE opcodes
    pub fn prepare_call_frame(
        self: *Frame,
        gas: u64,
        static_call: bool,
        contract_address: primitives.Address.Address,
        analysis: *const CodeAnalysis,
        input: []const u8
    ) ExecutionError.Error!*Frame {
        const next_frame = self.get_next_frame() orelse return ExecutionError.Error.DepthLimit;

        // Set up the next frame for execution
        next_frame.gas_remaining = gas;
        next_frame.hot_flags.is_static = static_call;
        next_frame.hot_flags.depth = self.hot_flags.depth + 1;
        next_frame.contract_address = contract_address;
        next_frame.analysis = analysis;
        next_frame.input = input;
        next_frame.output = &[_]u8{}; // Reset output

        return next_frame;
    }
};

/// Type alias for backward compatibility
pub const ExecutionContext = Frame;

// ============================================================================
// Compile-time Frame Alignment and Layout Assertions
// ============================================================================

comptime {
    // Assert that hot data is at the beginning of the struct for cache locality
    if (@offsetOf(Frame, "stack") != 0) @compileError("Stack must be at offset 0 for cache locality");
    if (@offsetOf(Frame, "gas_remaining") != @sizeOf(Stack)) @compileError("gas_remaining must immediately follow stack");

    // Assert proper alignment of hot data (should be naturally aligned)
    if (@offsetOf(Frame, "memory") % @alignOf(*Memory) != 0) @compileError("Memory pointer must be naturally aligned");
    if (@offsetOf(Frame, "analysis") % @alignOf(*const CodeAnalysis) != 0) @compileError("Analysis pointer must be naturally aligned");

    // Assert hot_flags comes before hardfork (hot data first)
    if (@offsetOf(Frame, "hot_flags") >= @offsetOf(Frame, "hardfork")) @compileError("hot_flags must come before hardfork for data locality");

    // Assert storage cluster is properly grouped together
    const contract_address_offset = @offsetOf(Frame, "contract_address");
    const state_offset = @offsetOf(Frame, "state");
    const access_list_offset = @offsetOf(Frame, "access_list");

    // Storage cluster should be contiguous (within reasonable padding)
    if (state_offset - contract_address_offset > @sizeOf(primitives.Address.Address) + 8) @compileError("Storage cluster not contiguous: contract_address to state gap too large");
    if (access_list_offset - state_offset > @sizeOf(DatabaseInterface) + 8) @compileError("Storage cluster not contiguous: state to access_list gap too large");

    // Assert cold data comes after warm data
    if (@offsetOf(Frame, "input") <= @offsetOf(Frame, "access_list")) @compileError("Cold data (input) must come after warm data (access_list)");
    if (@offsetOf(Frame, "output") <= @offsetOf(Frame, "access_list")) @compileError("Cold data (output) must come after warm data (access_list)");
    if (@offsetOf(Frame, "self_destruct") <= @offsetOf(Frame, "access_list")) @compileError("Cold data (self_destruct) must come after warm data (access_list)");

    // Assert packed structs are properly sized
    if (@sizeOf(@TypeOf(Frame.hot_flags)) != 2) @compileError("hot_flags must be exactly 2 bytes (16 bits)");
    if (@sizeOf(Hardfork) != 1) @compileError("Hardfork enum must be exactly 1 byte");

    // Assert reasonable struct size (should be dominated by stack)
    const stack_size = @sizeOf(Stack);
    const total_size = @sizeOf(Frame);

    // Frame should be mostly stack + reasonable overhead
    if (total_size < stack_size) @compileError("Frame size cannot be smaller than stack size");
    if (total_size > stack_size + 1024) @compileError("Frame overhead exceeds 1KB - struct layout needs optimization");

    // Assert natural alignment for performance-critical fields
    if (@offsetOf(Frame, "gas_remaining") % @alignOf(u64) != 0) @compileError("gas_remaining must be naturally aligned for performance");
    if (@offsetOf(Frame, "contract_address") % @alignOf(primitives.Address.Address) != 0) @compileError("contract_address must be naturally aligned");

    // Assert that padding fields exist and are correctly positioned
    if (!@hasField(Frame, "_pad1")) @compileError("Missing _pad1 field for storage cluster alignment");
    if (!@hasField(Frame, "_pad2")) @compileError("Missing _pad2 field for state alignment");
    if (!@hasField(Frame, "_pad3")) @compileError("Missing _pad3 field for hardfork alignment");

    // Assert storage cluster is 8-byte aligned (for better cache performance)
    if (@offsetOf(Frame, "contract_address") % 8 != 0) @compileError("contract_address must be 8-byte aligned for cache efficiency");
    if (@offsetOf(Frame, "state") % 8 != 0) @compileError("state must be 8-byte aligned for cache efficiency");
    if (@offsetOf(Frame, "access_list") % 8 != 0) @compileError("access_list must be 8-byte aligned for cache efficiency");

    // Assert hardfork field comes after hot data but before allocator
    if (@offsetOf(Frame, "hardfork") <= @offsetOf(Frame, "access_list")) @compileError("hardfork must come after storage cluster");
    if (@offsetOf(Frame, "hardfork") >= @offsetOf(Frame, "allocator")) @compileError("hardfork must come before cold data (allocator)");
}
```

````
const std = @import("std");
const stack_constants = @import("../constants/stack_constants.zig");
const builtin = @import("builtin");

const CLEAR_ON_POP = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

/// High-performance EVM stack implementation using pointer arithmetic.
///
/// The Stack is a core component of the EVM execution model, providing a
/// Last-In-First-Out (LIFO) data structure for 256-bit values. All EVM
/// computations operate on this stack, making its performance critical.
///
/// ## Design Rationale
/// - Fixed capacity of 1024 elements (per EVM specification)
/// - Stack-allocated storage for direct memory access
/// - 32-byte alignment for optimal memory access on modern CPUs
/// - Pointer arithmetic eliminates integer operations on hot path
/// - Unsafe variants skip bounds checking in hot paths for performance
///
/// ## Performance Optimizations
/// - Pointer arithmetic instead of array indexing (2-3x faster)
/// - Direct stack allocation eliminates pointer indirection
/// - Aligned memory for optimal access patterns
/// - Unsafe variants used after jump table validation
/// - Hot path annotations for critical operations
/// - Hot data (pointers) placed first for cache efficiency
///
/// ## SIZE OPTIMIZATION SAFETY MODEL
///
/// This stack provides two operation variants:
/// 1. **Safe operations** (`append()`, `pop()`) - Include bounds checking
/// 2. **Unsafe operations** (`append_unsafe()`, `pop_unsafe()`) - No bounds checking
///
/// The unsafe variants are used in opcode implementations after the jump table
/// performs comprehensive validation via `validate_stack_requirements()`. This
/// centralized validation approach:
///
/// - Eliminates redundant checks in individual opcodes (smaller binary)
/// - Maintains safety by validating ALL operations before execution
/// - Enables maximum performance in the hot path
///
/// **SAFETY GUARANTEE**: All unsafe operations assume preconditions are met:
/// - `pop_unsafe()`: Stack must not be empty
/// - `append_unsafe()`: Stack must have capacity
/// - `dup_unsafe(n)`: Stack must have >= n items and capacity for +1
/// - `swap_unsafe(n)`: Stack must have >= n+1 items
///
/// These preconditions are enforced by jump table validation.
///
/// Example:
/// ```zig
/// var stack = Stack{};
/// try stack.append(100); // Safe variant (for error_mapping)
/// stack.append_unsafe(200); // Unsafe variant (for opcodes)
/// ```
pub const Stack = @This();

/// Maximum stack capacity as defined by the EVM specification.
/// This limit prevents stack-based DoS attacks.
pub const CAPACITY: usize = stack_constants.CAPACITY;

/// Error types for stack operations.
/// These map directly to EVM execution errors.
pub const Error = error{
    /// Stack would exceed 1024 elements
    StackOverflow,
    /// Attempted to pop from empty stack
    StackUnderflow,
};

// ============================================================================
// Hot data - accessed on every stack operation (cache-friendly)
// ============================================================================

/// Points to the next free slot (top of stack + 1)
current: [*]u256,

/// Points to the base of the stack (data[0])
base: [*]u256,

/// Points to the limit (data[1024]) for bounds checking
limit: [*]u256,

// ============================================================================
// Cold data - large preallocated storage
// ============================================================================

/// Stack-allocated storage for optimal performance
/// Architecture-appropriate alignment for optimal access
data: [CAPACITY]u256 align(@alignOf(u256)) = undefined,

// Compile-time validations for stack design assumptions
comptime {
    // Ensure stack capacity matches EVM specification
    std.debug.assert(CAPACITY == 1024);
}

/// Initialize a new stack with pointer setup
pub fn init() Stack {
    var stack = Stack{
        .data = undefined,
        .current = undefined,
        .base = undefined,
        .limit = undefined,
    };

    stack.base = @ptrCast(&stack.data[0]);
    stack.current = stack.base; // Empty stack: current == base
    stack.limit = stack.base + CAPACITY;

    return stack;
}

/// Clear the stack without deallocating memory - resets to initial empty state
pub fn clear(self: *Stack) void {
    // Reset current pointer to base (empty stack)
    self.current = self.base;

    // In debug/safe modes, zero out all values for security
    if (comptime CLEAR_ON_POP) {
        @memset(std.mem.asBytes(&self.data), 0);
    }
}

/// Get current stack size using pointer arithmetic
pub inline fn size(self: *const Stack) usize {
    return (@intFromPtr(self.current) - @intFromPtr(self.base)) / @sizeOf(u256);
}

/// Check if stack is empty
pub inline fn is_empty(self: *const Stack) bool {
    return self.current == self.base;
}

/// Check if stack is at capacity
pub inline fn is_full(self: *const Stack) bool {
    return self.current >= self.limit;
}

/// Push a value onto the stack (safe version).
///
/// @param self The stack to push onto
/// @param value The 256-bit value to push
/// @throws Overflow if stack is at capacity
///
/// Example:
/// ```zig
/// try stack.append(0x1234);
/// ```
pub fn append(self: *Stack, value: u256) Error!void {
    if (@intFromPtr(self.current) >= @intFromPtr(self.limit)) {
        @branchHint(.cold);
        return Error.StackOverflow;
    }
    self.append_unsafe(value);
}

/// Push a value onto the stack (unsafe version).
///
/// Caller must ensure stack has capacity. Used in hot paths
/// after validation has already been performed.
///
/// @param self The stack to push onto
/// @param value The 256-bit value to push
pub inline fn append_unsafe(self: *Stack, value: u256) void {
    @branchHint(.likely);
    self.current[0] = value;
    self.current += 1;
}

/// Pop a value from the stack (safe version).
///
/// Removes and returns the top element. Clears the popped
/// slot to prevent information leakage.
///
/// @param self The stack to pop from
/// @return The popped value
/// @throws Underflow if stack is empty
///
/// Example:
/// ```zig
/// const value = try stack.pop();
/// ```
pub fn pop(self: *Stack) Error!u256 {
    if (@intFromPtr(self.current) <= @intFromPtr(self.base)) {
        @branchHint(.cold);
        return Error.StackUnderflow;
    }
    return self.pop_unsafe();
}

/// Pop a value from the stack (unsafe version).
///
/// Caller must ensure stack is not empty. Used in hot paths
/// after validation.
///
/// @param self The stack to pop from
/// @return The popped value
pub inline fn pop_unsafe(self: *Stack) u256 {
    @branchHint(.likely);
    self.current -= 1;
    const value = self.current[0];
    if (comptime CLEAR_ON_POP) {
        self.current[0] = 0; // Clear for security
    }
    return value;
}

/// Peek at the top value without removing it (unsafe version).
///
/// Caller must ensure stack is not empty.
///
/// @param self The stack to peek at
/// @return Pointer to the top value
pub inline fn peek_unsafe(self: *const Stack) *const u256 {
    @branchHint(.likely);
    return self.current - 1;
}

/// Duplicate the nth element onto the top of stack (unsafe version).
///
/// Caller must ensure preconditions are met.
///
/// @param self The stack to operate on
/// @param n Position to duplicate from (1-16)
pub inline fn dup_unsafe(self: *Stack, n: usize) void {
    @branchHint(.likely);
    @setRuntimeSafety(false);
    const value = (self.current - n)[0];
    self.append_unsafe(value);
}

/// Pop 2 values without pushing (unsafe version)
pub inline fn pop2_unsafe(self: *Stack) struct { a: u256, b: u256 } {
    @branchHint(.likely);
    @setRuntimeSafety(false);
    self.current -= 2;
    const a = self.current[0];
    const b = self.current[1];
    if (comptime CLEAR_ON_POP) {
        // Clear for security
        self.current[0] = 0;
        self.current[1] = 0;
    }
    return .{ .a = a, .b = b };
}

/// Pop 3 values without pushing (unsafe version)
pub inline fn pop3_unsafe(self: *Stack) struct { a: u256, b: u256, c: u256 } {
    @branchHint(.likely);
    @setRuntimeSafety(false);
    self.current -= 3;
    const a = self.current[0];
    const b = self.current[1];
    const c = self.current[2];
    if (comptime CLEAR_ON_POP) {
        // Clear for security
        self.current[0] = 0;
        self.current[1] = 0;
        self.current[2] = 0;
    }
    return .{ .a = a, .b = b, .c = c };
}

/// Set the top element (unsafe version)
pub inline fn set_top_unsafe(self: *Stack, value: u256) void {
    @branchHint(.likely);
    (self.current - 1)[0] = value;
}

/// Swap the top element with the nth element below it (unsafe version).
///
/// Swaps the top stack element with the element n positions below it.
/// For SWAP1, n=1 swaps top with second element.
/// For SWAP2, n=2 swaps top with third element, etc.
///
/// @param self The stack to operate on
/// @param n Position below top to swap with (1-16)
pub inline fn swap_unsafe(self: *Stack, n: usize) void {
    @branchHint(.likely);
    std.mem.swap(u256, self.current - 1, self.current - 1 - n);
}

/// Peek at the nth element from the top (for test compatibility)
pub fn peek_n(self: *const Stack, n: usize) Error!u256 {
    const stack_size = self.size();
    if (n >= stack_size) {
        @branchHint(.cold);
        return Error.StackUnderflow;
    }
    return (self.current - 1 - n)[0];
}

// Note: test-compatibility clear consolidated with main clear() above

/// Peek at the top value (for test compatibility)
pub fn peek(self: *const Stack) Error!u256 {
    if (self.current <= self.base) {
        @branchHint(.cold);
        return Error.StackUnderflow;
    }
    return (self.current - 1)[0];
}

// ============================================================================
// Test and compatibility functions
// ============================================================================

// Fuzz testing functions
pub fn fuzz_stack_operations(allocator: std.mem.Allocator, operations: []const FuzzOperation) !void {
    _ = allocator;
    var stack = Stack.init();
    const testing = std.testing;

    for (operations) |op| {
        switch (op) {
            .push => |value| {
                const old_size = stack.size();
                const result = stack.append(value);

                if (old_size < CAPACITY) {
                    try result;
                    try testing.expectEqual(old_size + 1, stack.size());
                    try testing.expectEqual(value, (stack.current - 1)[0]);
                } else {
                    try testing.expectError(Error.StackOverflow, result);
                    try testing.expectEqual(old_size, stack.size());
                }
            },
            .pop => {
                const old_size = stack.size();
                const result = stack.pop();

                if (old_size > 0) {
                    _ = try result;
                    try testing.expectEqual(old_size - 1, stack.size());
                } else {
                    try testing.expectError(Error.StackUnderflow, result);
                    try testing.expectEqual(@as(usize, 0), stack.size());
                }
            },
            .peek => {
                const result = stack.peek();
                if (stack.size() > 0) {
                    const value = try result;
                    try testing.expectEqual((stack.current - 1)[0], value);
                } else {
                    try testing.expectError(Error.StackUnderflow, result);
                }
            },
            .clear => {
                stack.clear();
                try testing.expectEqual(@as(usize, 0), stack.size());
            },
        }

        try validate_stack_invariants(&stack);
    }
}

const FuzzOperation = union(enum) {
    push: u256,
    pop: void,
    peek: void,
    clear: void,
};

fn validate_stack_invariants(stack: *const Stack) !void {
    const testing = std.testing;

    // Check pointer relationships
    try testing.expect(@intFromPtr(stack.current) >= @intFromPtr(stack.base));
    try testing.expect(@intFromPtr(stack.current) <= @intFromPtr(stack.limit));
    try testing.expect(stack.size() <= CAPACITY);
}
````

```
const std = @import("std");
const constants = @import("constants.zig");

/// Memory implementation for EVM execution contexts.
pub const Memory = @This();

// Re-export error types and constants for convenience
pub const MemoryError = @import("errors.zig").MemoryError;
pub const INITIAL_CAPACITY = constants.INITIAL_CAPACITY;
pub const DEFAULT_MEMORY_LIMIT = constants.DEFAULT_MEMORY_LIMIT;
pub const calculate_num_words = constants.calculate_num_words;

// Core memory struct fields optimized for cache locality and minimal padding
/// Memory checkpoint for child memory isolation
/// Frequently accessed during memory operations
my_checkpoint: usize,

/// Maximum memory size limit
/// Used for bounds checking, frequently accessed
memory_limit: u64,

/// Reference to shared buffer for all memory contexts
/// Frequently accessed for actual memory operations
shared_buffer_ref: *std.ArrayList(u8),

/// Memory allocator for dynamic allocations
/// Less frequently accessed
allocator: std.mem.Allocator,

/// Whether this Memory instance owns the buffer
/// Small bool field placed last to minimize padding
owns_buffer: bool,

/// Cache for memory expansion gas cost calculations
/// Stores the last expansion calculation to avoid redundant quadratic computations
cached_expansion: struct {
    /// Last calculated memory size in bytes
    last_size: u64,
    /// Gas cost for the last calculated size
    last_cost: u64,
} = .{ .last_size = 0, .last_cost = 0 },

/// Initializes the root Memory context that owns the shared buffer.
/// This is the safe API that eliminates the undefined pointer footgun.
pub fn init(
    allocator: std.mem.Allocator,
    initial_capacity: usize,
    memory_limit: u64,
) !Memory {
    std.log.debug("Memory.init: Starting, initial_capacity={}, memory_limit={}", .{initial_capacity, memory_limit});

    std.log.debug("Memory.init: About to create shared_buffer", .{});
    const shared_buffer = try allocator.create(std.ArrayList(u8));
    errdefer allocator.destroy(shared_buffer);
    std.log.debug("Memory.init: Created shared_buffer ptr={*}", .{shared_buffer});

    std.log.debug("Memory.init: Initializing ArrayList", .{});
    shared_buffer.* = std.ArrayList(u8).init(allocator);
    errdefer shared_buffer.deinit();

    std.log.debug("Memory.init: About to ensureTotalCapacity({})", .{initial_capacity});
    try shared_buffer.ensureTotalCapacity(initial_capacity);
    std.log.debug("Memory.init: ensureTotalCapacity complete", .{});

    std.log.debug("Memory.init: Returning Memory struct", .{});
    return Memory{
        .my_checkpoint = 0,
        .memory_limit = memory_limit,
        .shared_buffer_ref = shared_buffer,
        .allocator = allocator,
        .owns_buffer = true,
    };
}

/// Creates a child Memory that shares the buffer with a different checkpoint.
/// Child memory has a view of the shared buffer starting from its checkpoint.
pub fn init_child_memory(self: *Memory, checkpoint: usize) !Memory {
    return Memory{
        .my_checkpoint = checkpoint,
        .memory_limit = self.memory_limit,
        .shared_buffer_ref = self.shared_buffer_ref,
        .allocator = self.allocator,
        .owns_buffer = false,
    };
}

pub fn init_default(allocator: std.mem.Allocator) !Memory {
    std.log.debug("Memory.init_default: Called with allocator={*}", .{allocator.ptr});
    const result = try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
    std.log.debug("Memory.init_default: Returning", .{});
    return result;
}

/// Deinitializes the Memory. Only root Memory instances clean up the shared buffer.
pub fn deinit(self: *Memory) void {
    if (self.owns_buffer) {
        self.shared_buffer_ref.deinit();
        self.allocator.destroy(self.shared_buffer_ref);
    }
}

// Import and re-export all method implementations
const context_ops = @import("context.zig");
const read_ops = @import("read.zig");
const write_ops = @import("write.zig");
const slice_ops = @import("slice.zig");

// Context operations
pub const context_size = context_ops.context_size;
pub const ensure_context_capacity = context_ops.ensure_context_capacity;
pub const ensure_context_capacity_slow = context_ops.ensure_context_capacity_slow;
pub const resize_context = context_ops.resize_context;
pub const size = context_ops.size;
pub const total_size = context_ops.total_size;

/// Clear the memory by resetting size to 0 (for call frame reuse)
pub fn clear(self: *Memory) void {
    // For shared buffer memory, we can't actually clear the buffer
    // since other contexts might be using it. Instead we reset our checkpoint
    // to the current buffer end, effectively giving us a "fresh" view
    if (self.owns_buffer) {
        // If we own the buffer, we can actually clear it
        self.shared_buffer_ref.items.len = 0;
    } else {
        // If we don't own the buffer, reset our checkpoint to current end
        // This effectively gives us a clean slate from this point forward
        self.my_checkpoint = self.shared_buffer_ref.items.len;
    }

    // Reset cached expansion calculations
    self.cached_expansion = .{ .last_size = 0, .last_cost = 0 };
}

// Read operations
pub const get_u256 = read_ops.get_u256;
pub const get_slice = read_ops.get_slice;
pub const get_byte = read_ops.get_byte;

// Write operations
pub const set_data = write_ops.set_data;
pub const set_data_bounded = write_ops.set_data_bounded;
pub const set_u256 = write_ops.set_u256;

// Slice operations
pub const slice = slice_ops.slice;

/// Lookup table for small memory sizes (0-4KB in 32-byte increments)
/// Provides O(1) access for common small memory allocations
const SMALL_MEMORY_LOOKUP_SIZE = 128; // Covers 0-4KB in 32-byte words
const SMALL_MEMORY_LOOKUP_TABLE = generate_memory_expansion_lut: {
    var table: [SMALL_MEMORY_LOOKUP_SIZE + 1]u64 = undefined;
    for (&table, 0..) |*cost, words| {
        const word_count = @as(u64, @intCast(words));
        cost.* = 3 * word_count + (word_count * word_count) / 512;
    }
    break :generate_memory_expansion_lut table;
};

/// Get memory expansion gas cost with caching optimization
/// Returns the gas cost for expanding memory from current size to new_size.
/// Uses lookup table for small sizes and cached values for larger sizes.
pub fn get_expansion_cost(self: *Memory, new_size: u64) u64 {
    const current_size = @as(u64, @intCast(self.context_size()));

    // No expansion needed if new size is not larger than current
    if (new_size <= current_size) {
        return 0;
    }

    const new_words = (new_size + 31) / 32;
    const current_words = (current_size + 31) / 32;

    // Use lookup table for small memory sizes
    if (new_words <= SMALL_MEMORY_LOOKUP_SIZE and current_words <= SMALL_MEMORY_LOOKUP_SIZE) {
        return SMALL_MEMORY_LOOKUP_TABLE[@intCast(new_words)] - SMALL_MEMORY_LOOKUP_TABLE[@intCast(current_words)];
    }

    // Check if we can use cached calculation for larger sizes
    if (new_size == self.cached_expansion.last_size) {
        // Return cached cost minus cost for current size
        const current_cost = if (current_size == 0) 0 else calculate_memory_total_cost(current_size);
        return self.cached_expansion.last_cost -| current_cost;
    }

    // Calculate new cost and update cache for larger sizes
    const new_cost = calculate_memory_total_cost(new_size);
    const current_cost = if (current_size == 0) 0 else calculate_memory_total_cost(current_size);
    const expansion_cost = new_cost - current_cost;

    // Update cache
    self.cached_expansion.last_size = new_size;
    self.cached_expansion.last_cost = new_cost;

    return expansion_cost;
}

/// Calculate total memory cost for a given size (internal helper)
inline fn calculate_memory_total_cost(size_bytes: u64) u64 {
    const words = (size_bytes + 31) / 32;
    return 3 * words + (words * words) / 512;
}

// Import fuzz tests to ensure they are compiled and run
test {
    _ = @import("fuzz_tests.zig");
}

test "memory expansion gas cost lookup table" {
    const allocator = std.testing.allocator;
    var memory = try Memory.init_default(allocator);
    defer memory.deinit();

    // Test small memory sizes use lookup table
    const test_cases = [_]struct { size: u64, expected_words: u64 }{
        .{ .size = 0, .expected_words = 0 },
        .{ .size = 32, .expected_words = 1 },     // 1 word
        .{ .size = 64, .expected_words = 2 },     // 2 words
        .{ .size = 1024, .expected_words = 32 },  // 32 words
        .{ .size = 4096, .expected_words = 128 }, // 128 words (at lookup table boundary)
    };

    for (test_cases) |tc| {
        const cost = memory.get_expansion_cost(tc.size);

        // Verify lookup table calculation matches manual calculation
        const expected_cost = 3 * tc.expected_words + (tc.expected_words * tc.expected_words) / 512;
        try std.testing.expectEqual(expected_cost, cost);

        // Verify subsequent calls return 0 (no expansion needed)
        const no_expansion = memory.get_expansion_cost(tc.size);
        try std.testing.expectEqual(@as(u64, 0), no_expansion);
    }
}

```

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const AutoHashMap = std.AutoHashMap;
const Address = @import("primitives").Address.Address;
const primitives = @import("../primitives/primitives.zig");
const Host = @import("host.zig").Host;

const Frame = @import("frame.zig").Frame;
const Memory = @import("memory/memory.zig").Memory;
const ExecutionError = @import("execution/execution_error.zig").ExecutionError;
const CodeAnalysis = @import("analysis.zig").CodeAnalysis;

/// Maximum call depth per EVM specification
pub const MAX_CALL_DEPTH = 1024;

/// Call types for different EVM operations
pub const CallType = enum {
CALL,
DELEGATECALL,
STATICCALL,
CALLCODE,
CREATE,
CREATE2,
};

/// Parameters for initializing a call frame
pub const CallParams = struct {
target: Address,
gas_limit: u64,
input: []const u8,
value: u256 = 0,
salt: ?u256 = null, // For CREATE2
init_code: ?[]const u8 = null, // For CREATE/CREATE2
};

/// Access list for EIP-2929 warm/cold address and storage tracking
pub const AccessList = struct {
/// Warm addresses accessed this transaction
warm_addresses: AutoHashMap(Address, void),
/// Warm storage slots accessed this transaction
warm_storage: AutoHashMap(Address, AutoHashMap(u256, void)),

    allocator: Allocator,

    pub fn init(allocator: Allocator) !AccessList {
        return AccessList{
            .warm_addresses = AutoHashMap(Address, void).init(allocator),
            .warm_storage = AutoHashMap(Address, AutoHashMap(u256, void)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AccessList) void {
        self.warm_addresses.deinit();

        var storage_iter = self.warm_storage.iterator();
        while (storage_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.warm_storage.deinit();
    }

    /// Mark address as accessed, return gas cost
    pub fn access_address(self: *AccessList, addr: Address) u64 {
        if (self.warm_addresses.contains(addr)) {
            return 100; // Warm access cost (EIP-2929)
        } else {
            self.warm_addresses.put(addr, {}) catch {};
            return 2600; // Cold access cost (EIP-2929)
        }
    }

    /// Mark storage slot as accessed, return gas cost
    pub fn access_storage(self: *AccessList, addr: Address, key: u256) u64 {
        const storage = self.warm_storage.getOrPut(addr) catch {
            return 2100; // Cold storage access cost
        };

        if (!storage.found_existing) {
            storage.value_ptr.* = AutoHashMap(u256, void).init(self.allocator);
        }

        if (storage.value_ptr.contains(key)) {
            return 100; // Warm storage access cost
        } else {
            storage.value_ptr.put(key, {}) catch {};
            return 2100; // Cold storage access cost
        }
    }

};

/// Journal entry types for revertible operations
pub const JournalEntry = union(enum) {
selfdestruct: struct {
snapshot_id: u32,
contract: Address,
recipient: Address,
},
storage_change: struct {
snapshot_id: u32,
address: Address,
key: u256,
original_value: u256,
},
balance_change: struct {
snapshot_id: u32,
address: Address,
original_balance: u256,
},
nonce_change: struct {
snapshot_id: u32,
address: Address,
original_nonce: u64,
},
log_entry: struct {
snapshot_id: u32,
// Log entries are just marked for removal on revert
},
};

/// Journaling system for revertible operations
pub const CallJournal = struct {
/// Journal entries for revertible operations
entries: ArrayList(JournalEntry),
/// Current snapshot ID counter
next_snapshot_id: u32,

    pub fn init(allocator: Allocator) CallJournal {
        return CallJournal{
            .entries = ArrayList(JournalEntry).init(allocator),
            .next_snapshot_id = 0,
        };
    }

    pub fn deinit(self: *CallJournal) void {
        self.entries.deinit();
    }

    /// Create a snapshot point for revertible operations
    pub fn create_snapshot(self: *CallJournal) u32 {
        const id = self.next_snapshot_id;
        self.next_snapshot_id += 1;
        return id;
    }

    /// Revert all changes back to snapshot
    pub fn revert_to_snapshot(self: *CallJournal, snapshot_id: u32) void {
        // Remove all entries with snapshot_id >= snapshot_id
        // This effectively reverts all changes made since the snapshot
        var i: usize = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.entries.items[i];

            const entry_snapshot = switch (entry) {
                .selfdestruct => |sd| sd.snapshot_id,
                .storage_change => |sc| sc.snapshot_id,
                .balance_change => |bc| bc.snapshot_id,
                .nonce_change => |nc| nc.snapshot_id,
                .log_entry => |le| le.snapshot_id,
            };

            if (entry_snapshot >= snapshot_id) {
                _ = self.entries.swapRemove(i);
            }
        }
    }

    /// Record a self-destruct operation
    pub fn record_selfdestruct(self: *CallJournal, snapshot_id: u32, contract: Address, recipient: Address) !void {
        try self.entries.append(.{
            .selfdestruct = .{
                .snapshot_id = snapshot_id,
                .contract = contract,
                .recipient = recipient,
            },
        });
    }

    /// Record a storage change
    pub fn record_storage_change(self: *CallJournal, snapshot_id: u32, address: Address, key: u256, original_value: u256) !void {
        try self.entries.append(.{
            .storage_change = .{
                .snapshot_id = snapshot_id,
                .address = address,
                .key = key,
                .original_value = original_value,
            },
        });
    }

    /// Record a balance change
    pub fn record_balance_change(self: *CallJournal, snapshot_id: u32, address: Address, original_balance: u256) !void {
        try self.entries.append(.{
            .balance_change = .{
                .snapshot_id = snapshot_id,
                .address = address,
                .original_balance = original_balance,
            },
        });
    }

    /// Record a nonce change
    pub fn record_nonce_change(self: *CallJournal, snapshot_id: u32, address: Address, original_nonce: u64) !void {
        try self.entries.append(.{
            .nonce_change = .{
                .snapshot_id = snapshot_id,
                .address = address,
                .original_nonce = original_nonce,
            },
        });
    }

    /// Record a log entry (for revert purposes)
    pub fn record_log_entry(self: *CallJournal, snapshot_id: u32) !void {
        try self.entries.append(.{
            .log_entry = .{
                .snapshot_id = snapshot_id,
            },
        });
    }

};

/// Pre-allocated call frame stack with memory pooling and journaling
pub const CallFrameStack = struct {
/// Pre-allocated frames for maximum call depth
frames: [MAX_CALL_DEPTH]Frame,

    /// Pre-allocated memory pool - each frame gets a Memory object
    memory_pool: [MAX_CALL_DEPTH]Memory,

    /// Shared access list for EIP-2929 warm/cold tracking
    /// Shared across ALL frames - never reverted
    access_list: AccessList,

    /// Journaling system for revertible operations
    journal: CallJournal,

    /// Host interface for external operations (shared across all frames)
    host: Host,

    /// Current execution depth (0 = root frame)
    current_depth: u32,

    /// Allocator for memory pool growth
    allocator: Allocator,

    /// Initialize the entire call stack upfront
    pub fn init(allocator: Allocator, host: Host) !CallFrameStack {
        var stack = CallFrameStack{
            .frames = undefined,
            .memory_pool = undefined,
            .access_list = try AccessList.init(allocator),
            .journal = CallJournal.init(allocator),
            .host = host,
            .current_depth = 0,
            .allocator = allocator,
        };

        // Initialize all memory objects in the pool
        for (&stack.memory_pool) |*memory| {
            memory.* = try Memory.init(allocator);
        }

        // Initialize frames to default state
        for (&stack.frames) |*frame| {
            frame.* = Frame{
                .stack = undefined, // Will be properly initialized when frame is used
                .gas_remaining = 0,
                .memory = undefined, // Will be set when frame is activated
                .analysis = undefined, // Will be set when frame is activated
                .access_list = &stack.access_list,
                .journal = &stack.journal,
                .host = &stack.host,
                .contract_address = Address.ZERO,
                .caller = Address.ZERO,
                .input = &.{},
                .output = &.{},
                .value = 0,
                .is_static = false,
                .depth = 0,
                .snapshot_id = 0,
                .next_frame = null,
            };
        }

        return stack;
    }

    pub fn deinit(self: *CallFrameStack) void {
        // Deinit all memory objects
        for (&self.memory_pool) |*memory| {
            memory.deinit();
        }

        self.access_list.deinit();
        self.journal.deinit();
    }

    /// Get current active frame
    pub fn current_frame(self: *CallFrameStack) *Frame {
        return &self.frames[self.current_depth];
    }

    /// Initialize a new frame for different call types
    pub fn init_call_frame(
        self: *CallFrameStack,
        call_type: CallType,
        caller_frame: *Frame,
        params: CallParams,
        analysis: *const CodeAnalysis,
    ) !*Frame {
        const depth = self.current_depth + 1;
        if (depth >= MAX_CALL_DEPTH) return ExecutionError.Error.CallDepthExceeded;

        const new_frame = &self.frames[depth];

        // Create snapshot for revertible operations
        const snapshot_id = self.journal.create_snapshot();

        // Set up memory based on call type
        new_frame.memory = switch (call_type) {
            .CALL, .STATICCALL, .CREATE, .CREATE2 => &self.memory_pool[depth],
            .DELEGATECALL, .CALLCODE => caller_frame.memory, // Share memory
        };

        // Clear memory for new frames (not for shared memory)
        switch (call_type) {
            .CALL, .STATICCALL, .CREATE, .CREATE2 => {
                new_frame.memory.clear();
            },
            else => {}, // Shared memory, don't clear
        }

        // Initialize stack
        new_frame.stack = try new_frame.stack.init(self.allocator);

        // Shared components (same for all call types)
        new_frame.access_list = &self.access_list;
        new_frame.journal = &self.journal;
        new_frame.host = &self.host;
        new_frame.snapshot_id = snapshot_id;
        new_frame.depth = depth;
        new_frame.analysis = analysis;
        new_frame.input = params.input;
        new_frame.output = &.{};
        new_frame.gas_remaining = params.gas_limit;

        // Call-specific setup
        switch (call_type) {
            .DELEGATECALL => {
                new_frame.caller = caller_frame.caller; // Preserve original caller
                new_frame.value = caller_frame.value; // Preserve original value
                new_frame.is_static = caller_frame.is_static; // Preserve static flag
                new_frame.contract_address = params.target;
            },
            .STATICCALL => {
                new_frame.is_static = true; // Force static
                new_frame.value = 0; // No value transfer
                new_frame.caller = caller_frame.contract_address;
                new_frame.contract_address = params.target;
            },
            .CALLCODE => {
                // CALLCODE executes target's code in caller's context
                new_frame.caller = caller_frame.caller;
                new_frame.value = params.value;
                new_frame.is_static = caller_frame.is_static;
                new_frame.contract_address = caller_frame.contract_address; // Keep caller's address
            },
            .CREATE, .CREATE2 => {
                // Calculate new contract address
                const new_address = if (call_type == .CREATE2) blk: {
                    const salt = params.salt orelse return ExecutionError.Error.InvalidParameters;
                    const init_code = params.init_code orelse return ExecutionError.Error.InvalidParameters;
                    break :blk try primitives.Address.calculate_create2_address(
                        self.allocator,
                        caller_frame.contract_address,
                        salt,
                        init_code,
                    );
                } else blk: {
                    // CREATE uses nonce-based address calculation
                    // This would require getting the nonce from the state
                    // For now, placeholder - actual implementation needs state access
                    break :blk try primitives.Address.calculate_create_address(
                        caller_frame.contract_address,
                        0, // TODO: Get actual nonce from state
                    );
                };

                new_frame.caller = caller_frame.contract_address;
                new_frame.value = params.value;
                new_frame.is_static = false; // CREATE operations are never static
                new_frame.contract_address = new_address;
            },
            .CALL => {
                new_frame.caller = caller_frame.contract_address;
                new_frame.value = params.value;
                new_frame.is_static = caller_frame.is_static;
                new_frame.contract_address = params.target;
            },
        }

        // Link frames for traversal
        new_frame.next_frame = if (depth + 1 < MAX_CALL_DEPTH) &self.frames[depth + 1] else null;

        self.current_depth = depth;
        return new_frame;
    }

    /// Handle revert back to calling frame
    pub fn revert_frame(self: *CallFrameStack, failed_frame: *Frame) void {
        // Revert all journaled operations back to frame's snapshot
        self.journal.revert_to_snapshot(failed_frame.snapshot_id);

        // Return to caller frame
        self.current_depth = failed_frame.depth - 1;

        // Note: Memory changes in DELEGATECALL/CALLCODE are NOT reverted
        // This is correct EVM behavior - memory sharing persists
    }

    /// Successfully complete a frame and return to caller
    pub fn complete_frame(self: *CallFrameStack, completed_frame: *Frame) void {
        // No need to revert journal entries - they become permanent

        // Return to caller frame
        self.current_depth = completed_frame.depth - 1;
    }

};

```

```

const std = @import("std");
const Address = @import("primitives").Address.Address;
const CallResult = @import("evm/call_result.zig").CallResult;
const Frame = @import("frame.zig").Frame;

/// Call operation parameters for different call types
pub const CallParams = union(enum) {
/// Regular CALL operation
call: struct {
caller: Address,
to: Address,
value: u256,
input: []const u8,
gas: u64,
},
/// DELEGATECALL operation (preserves caller context)
delegatecall: struct {
caller: Address, // Original caller, not current contract
to: Address,
input: []const u8,
gas: u64,
},
/// STATICCALL operation (read-only)
staticcall: struct {
caller: Address,
to: Address,
input: []const u8,
gas: u64,
},
/// CREATE operation
create: struct {
caller: Address,
value: u256,
init_code: []const u8,
gas: u64,
},
/// CREATE2 operation
create2: struct {
caller: Address,
value: u256,
init_code: []const u8,
salt: u256,
gas: u64,
},
};

/// Block information structure for Host interface
pub const BlockInfo = struct {
/// Block number
number: u64,
/// Block timestamp
timestamp: u64,
/// Block difficulty
difficulty: u256,
/// Block gas limit
gas_limit: u64,
/// Coinbase (miner) address
coinbase: Address,
/// Base fee per gas (EIP-1559)
base_fee: u256,
/// Block hash of previous block
prev_randao: [32]u8,
};

/// Host interface for external operations
/// This provides the EVM with access to blockchain state and external services
pub const Host = struct {
/// Pointer to the actual host implementation
ptr: *anyopaque,
/// Function pointer table for the implementation
vtable: *const VTable,

    /// Virtual function table defining all host operations
    pub const VTable = struct {
        /// Get account balance
        get_balance: *const fn (ptr: *anyopaque, address: Address) u256,
        /// Check if account exists
        account_exists: *const fn (ptr: *anyopaque, address: Address) bool,
        /// Get account code
        get_code: *const fn (ptr: *anyopaque, address: Address) []const u8,
        /// Get block information
        get_block_info: *const fn (ptr: *anyopaque) BlockInfo,
        /// Emit log event (for LOG0-LOG4 opcodes)
        emit_log: *const fn (ptr: *anyopaque, contract_address: Address, topics: []const u256, data: []const u8) void,
        /// Execute EVM call (CALL, DELEGATECALL, STATICCALL, CREATE, CREATE2)
        call: *const fn (ptr: *anyopaque, params: CallParams) CallResult,
    };

    /// Initialize a Host interface from any implementation
    pub fn init(implementation: anytype) Host {
        const Impl = @TypeOf(implementation);
        const impl_info = @typeInfo(Impl);

        if (impl_info != .pointer) {
            @compileError("Host interface requires a pointer to implementation");
        }

        const gen = struct {
            fn vtable_get_balance(ptr: *anyopaque, address: Address) u256 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_balance(address);
            }

            fn vtable_account_exists(ptr: *anyopaque, address: Address) bool {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.account_exists(address);
            }

            fn vtable_get_code(ptr: *anyopaque, address: Address) []const u8 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_code(address);
            }

            fn vtable_get_block_info(ptr: *anyopaque) BlockInfo {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_block_info();
            }

            fn vtable_emit_log(ptr: *anyopaque, contract_address: Address, topics: []const u256, data: []const u8) void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.emit_log(contract_address, topics, data);
            }

            fn vtable_call(ptr: *anyopaque, params: CallParams) CallResult {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.call(params);
            }

            const vtable = VTable{
                .get_balance = vtable_get_balance,
                .account_exists = vtable_account_exists,
                .get_code = vtable_get_code,
                .get_block_info = vtable_get_block_info,
                .emit_log = vtable_emit_log,
                .call = vtable_call,
            };
        };

        return Host{
            .ptr = implementation,
            .vtable = &gen.vtable,
        };
    }

    /// Get account balance
    pub fn get_balance(self: Host, address: Address) u256 {
        return self.vtable.get_balance(self.ptr, address);
    }

    /// Check if account exists
    pub fn account_exists(self: Host, address: Address) bool {
        return self.vtable.account_exists(self.ptr, address);
    }

    /// Get account code
    pub fn get_code(self: Host, address: Address) []const u8 {
        return self.vtable.get_code(self.ptr, address);
    }

    /// Get block information
    pub fn get_block_info(self: Host) BlockInfo {
        return self.vtable.get_block_info(self.ptr);
    }

    /// Emit log event
    pub fn emit_log(self: Host, contract_address: Address, topics: []const u256, data: []const u8) void {
        return self.vtable.emit_log(self.ptr, contract_address, topics, data);
    }

    /// Execute EVM call
    pub fn call(self: Host, params: CallParams) CallResult {
        return self.vtable.call(self.ptr, params);
    }

};

```

```

/// SELFDESTRUCT opcode implementation for contract destruction
/// Tracks contracts marked for destruction and handles deferred execution
const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;

/// Error type for SelfDestruct operations
pub const StateError = error{OutOfMemory};

/// SelfDestruct tracks contracts marked for destruction via SELFDESTRUCT opcode
/// Destruction is deferred until end of transaction to maintain proper state semantics
pub const SelfDestruct = struct {
/// HashMap mapping contract address to recipient address
/// Key: address of contract to destroy
/// Value: address to receive remaining balance
destructions: std.HashMap(Address, Address, AddressContext, std.hash_map.default_max_load_percentage),
/// Allocator for HashMap operations
allocator: std.mem.Allocator,

    /// Context for Address HashMap
    const AddressContext = struct {
        pub fn hash(self: @This(), address: Address) u64 {
            _ = self;
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(&address);
            return hasher.final();
        }

        pub fn eql(self: @This(), a: Address, b: Address) bool {
            _ = self;
            return std.mem.eql(u8, &a, &b);
        }
    };

    /// Initialize new SelfDestruct tracker with given allocator
    pub fn init(allocator: std.mem.Allocator) SelfDestruct {
        return SelfDestruct{
            .destructions = std.HashMap(Address, Address, AddressContext, std.hash_map.default_max_load_percentage).init(allocator),
            .allocator = allocator,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *SelfDestruct) void {
        self.destructions.deinit();
    }

    /// Transfer ownership of this SelfDestruct to the caller
    /// After calling this, the original SelfDestruct should not be used
    pub fn to_owned(self: SelfDestruct) SelfDestruct {
        return SelfDestruct{
            .destructions = self.destructions,
            .allocator = self.allocator,
        };
    }

    /// Mark a contract for destruction
    /// contract_addr: Address of the contract calling SELFDESTRUCT
    /// recipient: Address that will receive the contract's remaining balance
    pub fn mark_for_destruction(self: *SelfDestruct, contract_addr: Address, recipient: Address) StateError!void {
        try self.destructions.put(contract_addr, recipient);
    }

    /// Check if a contract is marked for destruction
    pub fn is_marked_for_destruction(self: *SelfDestruct, contract_addr: Address) bool {
        return self.destructions.contains(contract_addr);
    }

    /// Get the recipient address for a contract marked for destruction
    /// Returns null if the contract is not marked for destruction
    pub fn get_recipient(self: *SelfDestruct, contract_addr: Address) ?Address {
        return self.destructions.get(contract_addr);
    }

    /// Get iterator over all contracts marked for destruction
    /// Returns iterator yielding (contract_address, recipient_address) pairs
    pub fn iterator(self: *SelfDestruct) std.HashMap(Address, Address, AddressContext, std.hash_map.default_max_load_percentage).Iterator {
        return self.destructions.iterator();
    }

    /// Get count of contracts marked for destruction
    pub fn count(self: *SelfDestruct) u32 {
        return @intCast(self.destructions.count());
    }

    /// Remove a contract from the destruction list (used for testing/cleanup)
    pub fn unmark(self: *SelfDestruct, contract_addr: Address) bool {
        return self.destructions.remove(contract_addr);
    }

    /// Clear all marked contracts (used for testing/cleanup)
    pub fn clear(self: *SelfDestruct) void {
        self.destructions.clearRetainingCapacity();
    }

    /// Apply all pending destructions to the given state interface
    /// This is called at the end of transaction execution
    /// TODO: This will be implemented when we have the state interface ready
    pub fn apply_destructions(self: *SelfDestruct, state: anytype) !void {
        var iter = self.iterator();
        while (iter.next()) |entry| {
            const contract_addr = entry.key_ptr.*;
            const recipient_addr = entry.value_ptr.*;

            // TODO: Transfer balance from contract_addr to recipient_addr
            // TODO: Delete contract code and storage
            // TODO: Emit destruction log event
            _ = contract_addr;
            _ = recipient_addr;
            _ = state;
        }
    }

};

```
pub const DatabaseInterface = struct {
    /// Pointer to the actual implementation
    ptr: *anyopaque,
    /// Function pointer table for the implementation
    vtable: *const VTable,

    /// Virtual function table defining all database operations
    pub const VTable = struct {
        // Account operations
        get_account: *const fn (ptr: *anyopaque, address: [20]u8) DatabaseError!?Account,
        set_account: *const fn (ptr: *anyopaque, address: [20]u8, account: Account) DatabaseError!void,
        delete_account: *const fn (ptr: *anyopaque, address: [20]u8) DatabaseError!void,
        account_exists: *const fn (ptr: *anyopaque, address: [20]u8) bool,

        // Storage operations
        get_storage: *const fn (ptr: *anyopaque, address: [20]u8, key: u256) DatabaseError!u256,
        set_storage: *const fn (ptr: *anyopaque, address: [20]u8, key: u256, value: u256) DatabaseError!void,

        // Code operations
        get_code: *const fn (ptr: *anyopaque, code_hash: [32]u8) DatabaseError![]const u8,
        set_code: *const fn (ptr: *anyopaque, code: []const u8) DatabaseError![32]u8,

        // State root operations
        get_state_root: *const fn (ptr: *anyopaque) DatabaseError![32]u8,
        commit_changes: *const fn (ptr: *anyopaque) DatabaseError![32]u8,

        // Snapshot operations
        create_snapshot: *const fn (ptr: *anyopaque) DatabaseError!u64,
        revert_to_snapshot: *const fn (ptr: *anyopaque, snapshot_id: u64) DatabaseError!void,
        commit_snapshot: *const fn (ptr: *anyopaque, snapshot_id: u64) DatabaseError!void,

        // Batch operations
        begin_batch: *const fn (ptr: *anyopaque) DatabaseError!void,
        commit_batch: *const fn (ptr: *anyopaque) DatabaseError!void,
        rollback_batch: *const fn (ptr: *anyopaque) DatabaseError!void,

        // Lifecycle
        deinit: *const fn (ptr: *anyopaque) void,
    };

    /// Initialize a database interface from any implementation
    ///
    /// This function uses Zig's compile-time type introspection to generate
    /// the appropriate vtable for the given implementation type.
    ///
    /// ## Parameters
    /// - `implementation`: Pointer to the database implementation
    ///
    /// ## Returns
    /// DatabaseInterface wrapping the implementation
    ///
    /// ## Type Requirements
    /// The implementation must provide all required methods with correct signatures
    pub fn init(implementation: anytype) DatabaseInterface {
        const Impl = @TypeOf(implementation);
        const impl_info = @typeInfo(Impl);

        if (impl_info != .pointer) {
            @compileError("Database interface requires a pointer to implementation");
        }

        const gen = struct {
            fn vtable_get_account(ptr: *anyopaque, address: [20]u8) DatabaseError!?Account {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_account(address);
            }

            fn vtable_set_account(ptr: *anyopaque, address: [20]u8, account: Account) DatabaseError!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.set_account(address, account);
            }

            fn vtable_delete_account(ptr: *anyopaque, address: [20]u8) DatabaseError!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.delete_account(address);
            }

            fn vtable_account_exists(ptr: *anyopaque, address: [20]u8) bool {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.account_exists(address);
            }

            fn vtable_get_storage(ptr: *anyopaque, address: [20]u8, key: u256) DatabaseError!u256 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_storage(address, key);
            }

            fn vtable_set_storage(ptr: *anyopaque, address: [20]u8, key: u256, value: u256) DatabaseError!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.set_storage(address, key, value);
            }

            fn vtable_get_code(ptr: *anyopaque, code_hash: [32]u8) DatabaseError![]const u8 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_code(code_hash);
            }

            fn vtable_set_code(ptr: *anyopaque, code: []const u8) DatabaseError![32]u8 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.set_code(code);
            }

            fn vtable_get_state_root(ptr: *anyopaque) DatabaseError![32]u8 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_state_root();
            }

            fn vtable_commit_changes(ptr: *anyopaque) DatabaseError![32]u8 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.commit_changes();
            }

            fn vtable_create_snapshot(ptr: *anyopaque) DatabaseError!u64 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.create_snapshot();
            }

            fn vtable_revert_to_snapshot(ptr: *anyopaque, snapshot_id: u64) DatabaseError!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.revert_to_snapshot(snapshot_id);
            }

            fn vtable_commit_snapshot(ptr: *anyopaque, snapshot_id: u64) DatabaseError!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.commit_snapshot(snapshot_id);
            }

            fn vtable_begin_batch(ptr: *anyopaque) DatabaseError!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.begin_batch();
            }

            fn vtable_commit_batch(ptr: *anyopaque) DatabaseError!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.commit_batch();
            }

            fn vtable_rollback_batch(ptr: *anyopaque) DatabaseError!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.rollback_batch();
            }

            fn vtable_deinit(ptr: *anyopaque) void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.deinit();
            }

            const vtable = VTable{
                .get_account = vtable_get_account,
                .set_account = vtable_set_account,
                .delete_account = vtable_delete_account,
                .account_exists = vtable_account_exists,
                .get_storage = vtable_get_storage,
                .set_storage = vtable_set_storage,
                .get_code = vtable_get_code,
                .set_code = vtable_set_code,
                .get_state_root = vtable_get_state_root,
                .commit_changes = vtable_commit_changes,
                .create_snapshot = vtable_create_snapshot,
                .revert_to_snapshot = vtable_revert_to_snapshot,
                .commit_snapshot = vtable_commit_snapshot,
                .begin_batch = vtable_begin_batch,
                .commit_batch = vtable_commit_batch,
                .rollback_batch = vtable_rollback_batch,
                .deinit = vtable_deinit,
            };
        };

        return DatabaseInterface{
            .ptr = implementation,
            .vtable = &gen.vtable,
        };
    }

    // Account operations

    /// Get account data for the given address
    pub fn get_account(self: DatabaseInterface, address: [20]u8) DatabaseError!?Account {
        return self.vtable.get_account(self.ptr, address);
    }

    /// Set account data for the given address
    pub fn set_account(self: DatabaseInterface, address: [20]u8, account: Account) DatabaseError!void {
        return self.vtable.set_account(self.ptr, address, account);
    }

    /// Delete account and all associated data
    pub fn delete_account(self: DatabaseInterface, address: [20]u8) DatabaseError!void {
        return self.vtable.delete_account(self.ptr, address);
    }

    /// Check if account exists in the database
    pub fn account_exists(self: DatabaseInterface, address: [20]u8) bool {
        return self.vtable.account_exists(self.ptr, address);
    }

    // Storage operations

    /// Get storage value for the given address and key
    pub fn get_storage(self: DatabaseInterface, address: [20]u8, key: u256) DatabaseError!u256 {
        return self.vtable.get_storage(self.ptr, address, key);
    }

    /// Set storage value for the given address and key
    pub fn set_storage(self: DatabaseInterface, address: [20]u8, key: u256, value: u256) DatabaseError!void {
        return self.vtable.set_storage(self.ptr, address, key, value);
    }

    // Code operations

    /// Get contract code by hash
    pub fn get_code(self: DatabaseInterface, code_hash: [32]u8) DatabaseError![]const u8 {
        return self.vtable.get_code(self.ptr, code_hash);
    }

    /// Store contract code and return its hash
    pub fn set_code(self: DatabaseInterface, code: []const u8) DatabaseError![32]u8 {
        return self.vtable.set_code(self.ptr, code);
    }

    // State root operations

    /// Get current state root hash
    pub fn get_state_root(self: DatabaseInterface) DatabaseError![32]u8 {
        return self.vtable.get_state_root(self.ptr);
    }

    /// Commit pending changes and return new state root
    pub fn commit_changes(self: DatabaseInterface) DatabaseError![32]u8 {
        return self.vtable.commit_changes(self.ptr);
    }

    // Snapshot operations

    /// Create a state snapshot and return its ID
    pub fn create_snapshot(self: DatabaseInterface) DatabaseError!u64 {
        return self.vtable.create_snapshot(self.ptr);
    }

    /// Revert state to the given snapshot
    pub fn revert_to_snapshot(self: DatabaseInterface, snapshot_id: u64) DatabaseError!void {
        return self.vtable.revert_to_snapshot(self.ptr, snapshot_id);
    }

    /// Commit a snapshot (discard it without reverting)
    pub fn commit_snapshot(self: DatabaseInterface, snapshot_id: u64) DatabaseError!void {
        return self.vtable.commit_snapshot(self.ptr, snapshot_id);
    }

    // Batch operations

    /// Begin a batch operation for efficient bulk updates
    pub fn begin_batch(self: DatabaseInterface) DatabaseError!void {
        return self.vtable.begin_batch(self.ptr);
    }

    /// Commit all changes in the current batch
    pub fn commit_batch(self: DatabaseInterface) DatabaseError!void {
        return self.vtable.commit_batch(self.ptr);
    }

    /// Rollback all changes in the current batch
    pub fn rollback_batch(self: DatabaseInterface) DatabaseError!void {
        return self.vtable.rollback_batch(self.ptr);
    }

    // Lifecycle

    /// Clean up database resources
    pub fn deinit(self: DatabaseInterface) void {
        return self.vtable.deinit(self.ptr);
    }
};

```

## Interpret

THis is the main function making the efvm fast

```
const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const Frame = @import("../frame.zig").Frame;
const Log = @import("../log.zig");
const Evm = @import("../evm.zig");
const builtin = @import("builtin");

const SAFE = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;
const MAX_ITERATIONS = 10_000_000; // TODO set this to a real problem


/// Execute contract bytecode using block-based execution.
///
/// This version translates bytecode to an instruction stream before execution,
/// enabling better branch prediction and cache locality.
///
/// Time complexity: O(n) where n is the number of opcodes executed.
/// Memory: Uses provided Frame, no internal allocations.
///
/// The caller is responsible for creating and managing the Frame and its components.
pub inline fn interpret(self: *Evm, frame: *Frame) ExecutionError.Error!void {
    self.require_one_thread();

    // Frame is provided by caller, get the analysis from it
    var current_instruction = frame.analysis.instructions;
    var loop_iterations: usize = 0;

    while (current_instruction[0]) |nextInstruction| {
        @branchHint(.likely);

        // In safe mode we make sure we don't loop too much. If this happens
        if (comptime SAFE) {
            loop_iterations += 1;
            if (loop_iterations > MAX_ITERATIONS) {
                Log.err("interpret: Infinite loop detected after {} iterations at pc={}, depth={}, gas={}. This should never happen and indicates either the limit was set too low or a high severity bug has been found in EVM", .{ loop_iterations, current_instruction - frame.analysis.instructions, self.depth, frame.gas_remaining });
                unreachable;
            }
        }

        // Handle instruction
        switch (nextInstruction.arg) {
            // BEGINBLOCK instructions - validate entire basic block upfront
            // This eliminates per-instruction gas and stack validation for the entire block
            .block_info => {
                current_instruction += 1;
                nextInstruction.opcode_fn(@ptrCast(frame)) catch |err| {
                    return err;
                };
            },
            // For jumps we handle them inline as they are preprocessed by analysis
            // 1. Handle dynamic jumps validating it is a valid jumpdest
            // 2. Handle optional jump
            // 3. Handle normal jump
            .jump_target => |jump_target| {
                switch (jump_target.jump_type) {
                    .jump => {
                        const dest = frame.stack.pop_unsafe();
                        if (!frame.valid_jumpdest(dest)) {
                            return ExecutionError.Error.InvalidJump;
                        }
                        current_instruction = @ptrCast(jump_target.instruction);
                    },
                    .jumpi => {
                        const pops = frame.stack.pop2_unsafe();
                        const dest = pops.a;
                        const condition = pops.b;
                        if (condition != 0) {
                            if (!frame.valid_jumpdest(dest)) {
                                return ExecutionError.Error.InvalidJump;
                            }
                            current_instruction = @ptrCast(jump_target.instruction);
                        } else {
                            current_instruction += 1;
                        }
                    },
                    .other => {
                        current_instruction = @ptrCast(jump_target.instruction);
                    },
                }
            },
            .push_value => |value| {
                current_instruction += 1;
                try frame.stack.append(value);
            },
            .none => {
                @branchHint(.likely);
                // Most opcodes now have .none - no individual gas/stack validation needed
                // Gas and stack validation is handled by BEGINBLOCK instructions
                current_instruction += 1;
                nextInstruction.opcode_fn(@ptrCast(frame)) catch |err| {
                    // Frame already manages its own output, no need to copy

                    // Handle gas exhaustion for InvalidOpcode specifically
                    if (err == ExecutionError.Error.InvalidOpcode) {
                        frame.gas_remaining = 0;
                    }

                    return err;
                };
            },
            .gas_cost => |cost| {
                // Keep for special opcodes that need individual gas tracking (GAS, CALL, etc.)
                current_instruction += 1;
                if (frame.gas_remaining < cost) {
                    @branchHint(.cold);
                    frame.gas_remaining = 0;
                    return ExecutionError.Error.OutOfGas;
                }
                frame.gas_remaining -= cost;
            },
        }
    }
}
```

## Jump table

This is comptime known configuration for evm

I want to rename this it used to be a jump table for execution but now interpret is so this has a bad name. It only returns the data interpret needs.

```

```

const std = @import("std");
const builtin = @import("builtin");
const Opcode = @import("../opcodes/opcode.zig");
const operation_module = @import("../opcodes/operation.zig");
const Operation = operation_module.Operation;
const ExecutionFunc = @import("../execution_func.zig").ExecutionFunc;
const GasFunc = operation_module.GasFunc;
const MemorySizeFunc = operation_module.MemorySizeFunc;
const Hardfork = @import("../hardforks/hardfork.zig").Hardfork;
const ExecutionError = @import("../execution/execution_error.zig");
const Stack = @import("../stack/stack.zig");
const ExecutionContext = @import("../frame.zig").ExecutionContext;
const primitives = @import("primitives");
const Log = @import("../log.zig");

// Export inline hot ops optimization
pub const execute_with_inline_hot_ops = @import("inline_hot_ops.zig").execute_with_inline_hot_ops;

const execution = @import("../execution/package.zig");
const stack_ops = execution.stack;
const log = execution.log;
const operation_config = @import("operation_config.zig");

/// EVM jump table for efficient opcode dispatch.
///
/// The jump table is a critical performance optimization that maps opcodes
/// to their execution handlers. Instead of using a switch statement with
/// 256 cases, the jump table provides O(1) dispatch by indexing directly
/// into arrays of function pointers and metadata.
///
/// ## Design Rationale
/// - Parallel arrays provide better cache locality than array-of-structs
/// - Hot data (execute functions, gas costs) are in contiguous memory
/// - Cache-line alignment improves memory access patterns
/// - Direct indexing eliminates branch prediction overhead
///
/// ## Memory Layout (Struct-of-Arrays)
/// - execute_funcs: 256 _ 8 bytes = 2KB (hot path)
/// - constant_gas: 256 _ 8 bytes = 2KB (hot path)
/// - min_stack: 256 _ 4 bytes = 1KB (validation)
/// - max_stack: 256 _ 4 bytes = 1KB (validation)
/// - dynamic_gas: 256 _ 8 bytes = 2KB (cold path)
/// - memory_size: 256 _ 8 bytes = 2KB (cold path)
/// - undefined_flags: 256 \* 1 byte = 256 bytes (cold path)
/// Total: ~10.25KB with better cache utilization
///
/// Example:
/// `zig
/// const table = JumpTable.init_from_hardfork(.CANCUN);
/// const opcode = bytecode[pc];
/// const operation = table.get_operation(opcode);
/// // Old execute method removed - see ExecutionContext pattern
/// `
pub const JumpTable = @This();

/// CPU cache line size for optimal memory alignment.
/// Most modern x86/ARM processors use 64-byte cache lines.
const CACHE_LINE_SIZE = 64;

/// Hot path arrays - accessed every opcode execution
execute_funcs: [256]ExecutionFunc align(CACHE_LINE_SIZE),
constant_gas: [256]u64 align(CACHE_LINE_SIZE),

/// Validation arrays - accessed for stack checks
min_stack: [256]u32 align(CACHE_LINE_SIZE),
max_stack: [256]u32 align(CACHE_LINE_SIZE),

/// Cold path arrays - rarely accessed
dynamic_gas: [256]?GasFunc align(CACHE_LINE_SIZE),
memory_size: [256]?MemorySizeFunc align(CACHE_LINE_SIZE),
undefined_flags: [256]bool align(CACHE_LINE_SIZE),

/// CANCUN jump table, pre-generated at compile time.
/// This is the latest hardfork configuration.
pub const CANCUN = init_from_hardfork(.CANCUN);

/// Default jump table for the latest hardfork.
/// References CANCUN to avoid generating the same table twice.
/// This is what gets used when no jump table is specified.
pub const DEFAULT = CANCUN;

/// Create an empty jump table with all entries set to defaults.
///
/// This creates a blank jump table that must be populated with
/// operations before use. Typically, you'll want to use
/// init*from_hardfork() instead to get a pre-configured table.
///
/// @return An empty jump table
pub fn init() JumpTable {
const undefined_execute = operation_module.NULL_OPERATION.execute;
return JumpTable{
.execute_funcs = [*]ExecutionFunc{undefined*execute} \*\* 256,
.constant_gas = [*]u64{0} ** 256,
.min*stack = [*]u32{0} ** 256,
.max*stack = [*]u32{Stack.CAPACITY} ** 256,
.dynamic*gas = [*]?GasFunc{null} ** 256,
.memory*size = [*]?MemorySizeFunc{null} ** 256,
.undefined*flags = [*]bool{true} ** 256,
};
}

/// Temporary struct returned by get_operation for API compatibility
pub const OperationView = struct {
execute: ExecutionFunc,
constant_gas: u64,
min_stack: u32,
max_stack: u32,
dynamic_gas: ?GasFunc,
memory_size: ?MemorySizeFunc,
undefined: bool,
};

/// Get the operation handler for a given opcode.
///
/// Returns a view of the operation data for the opcode.
/// This maintains API compatibility while using parallel arrays internally.
///
/// @param self The jump table
/// @param opcode The opcode byte value (0x00-0xFF)
/// @return Operation view struct
///
/// Example:
/// `zig
/// const op = table.get_operation(0x01); // Get ADD operation
/// `
pub inline fn get_operation(self: \*const JumpTable, opcode: u8) OperationView {
return OperationView{
.execute = self.execute_funcs[opcode],
.constant_gas = self.constant_gas[opcode],
.min_stack = self.min_stack[opcode],
.max_stack = self.max_stack[opcode],
.dynamic_gas = self.dynamic_gas[opcode],
.memory_size = self.memory_size[opcode],
.undefined = self.undefined_flags[opcode],
};
}

// Note: The old execute method has been removed as it's unused in the new ExecutionContext pattern.
// Opcode execution now happens through the ExecutionFunc signature with ExecutionContext only.

/// Validate and fix the jump table.
///
/// Ensures all entries are valid:
/// - Operations with memory_size must have dynamic_gas
/// - Invalid operations are logged and marked as undefined
///
/// This should be called after manually constructing a jump table
/// to ensure it's safe for execution.
///
/// @param self The jump table to validate
pub fn validate(self: \*JumpTable) void {
for (0..256) |i| {
// Check for invalid operation configuration (error path)
if (self.memory_size[i] != null and self.dynamic_gas[i] == null) {
@branchHint(.cold);
// Log error instead of panicking
Log.debug("Warning: Operation 0x{x} has memory size but no dynamic gas calculation", .{i});
// Mark as undefined to prevent issues
self.undefined_flags[i] = true;
self.execute_funcs[i] = operation_module.NULL_OPERATION.execute;
}
}
}

pub fn copy(self: \*const JumpTable, allocator: std.mem.Allocator) !JumpTable {
\_ = allocator;
return JumpTable{
.execute_funcs = self.execute_funcs,
.constant_gas = self.constant_gas,
.min_stack = self.min_stack,
.max_stack = self.max_stack,
.dynamic_gas = self.dynamic_gas,
.memory_size = self.memory_size,
.undefined_flags = self.undefined_flags,
};
}

/// Create a jump table configured for a specific hardfork.
///
/// This is the primary way to create a jump table. It starts with
/// the Frontier base configuration and applies all changes up to
/// the specified hardfork.
///
/// @param hardfork The target hardfork configuration
/// @return A fully configured jump table
///
/// Hardfork progression:
/// - FRONTIER: Base EVM opcodes
/// - HOMESTEAD: DELEGATECALL
/// - TANGERINE_WHISTLE: Gas repricing (EIP-150)
/// - BYZANTIUM: REVERT, RETURNDATASIZE, STATICCALL
/// - CONSTANTINOPLE: CREATE2, SHL/SHR/SAR, EXTCODEHASH
/// - ISTANBUL: CHAINID, SELFBALANCE, more gas changes
/// - BERLIN: Access lists, cold/warm storage
/// - LONDON: BASEFEE
/// - SHANGHAI: PUSH0
/// - CANCUN: BLOBHASH, MCOPY, transient storage
///
/// Example:
/// `zig
/// const table = JumpTable.init_from_hardfork(.CANCUN);
/// // Table includes all opcodes through Cancun
/// `
pub fn init_from_hardfork(hardfork: Hardfork) JumpTable {
@setEvalBranchQuota(10000);
var jt = JumpTable.init();

    // With ALL_OPERATIONS sorted by hardfork, we can iterate once.
    // Each opcode will be set to the latest active version for the target hardfork.
    inline for (operation_config.ALL_OPERATIONS) |spec| {
        const op_hardfork = spec.variant orelse Hardfork.FRONTIER;
        // Most operations are included in hardforks (likely path)
        if (@intFromEnum(op_hardfork) <= @intFromEnum(hardfork)) {
            const op = operation_config.generate_operation(spec);
            const idx = spec.opcode;
            jt.execute_funcs[idx] = op.execute;
            jt.constant_gas[idx] = op.constant_gas;
            jt.min_stack[idx] = op.min_stack;
            jt.max_stack[idx] = op.max_stack;
            jt.dynamic_gas[idx] = op.dynamic_gas;
            jt.memory_size[idx] = op.memory_size;
            jt.undefined_flags[idx] = op.undefined;
        }
    }

    // 0x60s & 0x70s: Push operations
    if (comptime builtin.mode == .ReleaseSmall) {
        // Use static const operations to avoid memory corruption in ReleaseSmall
        for (0..32) |i| {
            jt.execute_funcs[0x60 + i] = stack_ops.push_n;
            jt.constant_gas[0x60 + i] = execution.GasConstants.GasFastestStep;
            jt.min_stack[0x60 + i] = 0;
            jt.max_stack[0x60 + i] = Stack.CAPACITY - 1;
            jt.undefined_flags[0x60 + i] = false;
        }
    } else {
        // Optimized implementations for common small PUSH operations
        // PUSH1 - most common, optimized with direct byte access
        jt.execute_funcs[0x60] = stack_ops.op_push1;
        jt.constant_gas[0x60] = execution.gas_constants.GasFastestStep;
        jt.min_stack[0x60] = 0;
        jt.max_stack[0x60] = Stack.CAPACITY - 1;
        jt.undefined_flags[0x60] = false;

        // PUSH2-PUSH8 - optimized with u64 arithmetic
        inline for (1..8) |i| {
            const n = i + 1;
            jt.execute_funcs[0x60 + i] = stack_ops.make_push_small(n);
            jt.constant_gas[0x60 + i] = execution.gas_constants.GasFastestStep;
            jt.min_stack[0x60 + i] = 0;
            jt.max_stack[0x60 + i] = Stack.CAPACITY - 1;
            jt.undefined_flags[0x60 + i] = false;
        }

        // PUSH9-PUSH32 - use generic implementation
        inline for (8..32) |i| {
            const n = i + 1;
            jt.execute_funcs[0x60 + i] = stack_ops.make_push(n);
            jt.constant_gas[0x60 + i] = execution.GasConstants.GasFastestStep;
            jt.min_stack[0x60 + i] = 0;
            jt.max_stack[0x60 + i] = Stack.CAPACITY - 1;
            jt.undefined_flags[0x60 + i] = false;
        }
    }

    // 0x80s: Duplication Operations
    if (comptime builtin.mode == .ReleaseSmall) {
        // Use specific functions for each DUP operation to avoid opcode detection issues
        const dup_functions = [_]ExecutionFunc{
            stack_ops.dup_1,  stack_ops.dup_2,  stack_ops.dup_3,  stack_ops.dup_4,
            stack_ops.dup_5,  stack_ops.dup_6,  stack_ops.dup_7,  stack_ops.dup_8,
            stack_ops.dup_9,  stack_ops.dup_10, stack_ops.dup_11, stack_ops.dup_12,
            stack_ops.dup_13, stack_ops.dup_14, stack_ops.dup_15, stack_ops.dup_16,
        };

        inline for (1..17) |n| {
            const idx = 0x80 + n - 1;
            jt.execute_funcs[idx] = dup_functions[n - 1];
            jt.constant_gas[idx] = execution.GasConstants.GasFastestStep;
            jt.min_stack[idx] = @intCast(n);
            jt.max_stack[idx] = Stack.CAPACITY - 1;
            jt.undefined_flags[idx] = false;
        }
    } else {
        inline for (1..17) |n| {
            const idx = 0x80 + n - 1;
            jt.execute_funcs[idx] = stack_ops.make_dup(n);
            jt.constant_gas[idx] = execution.GasConstants.GasFastestStep;
            jt.min_stack[idx] = @intCast(n);
            jt.max_stack[idx] = Stack.CAPACITY - 1;
            jt.undefined_flags[idx] = false;
        }
    }

    // 0x90s: Exchange Operations
    if (comptime builtin.mode == .ReleaseSmall) {
        // Use specific functions for each SWAP operation to avoid opcode detection issues
        const swap_functions = [_]ExecutionFunc{
            stack_ops.swap_1,  stack_ops.swap_2,  stack_ops.swap_3,  stack_ops.swap_4,
            stack_ops.swap_5,  stack_ops.swap_6,  stack_ops.swap_7,  stack_ops.swap_8,
            stack_ops.swap_9,  stack_ops.swap_10, stack_ops.swap_11, stack_ops.swap_12,
            stack_ops.swap_13, stack_ops.swap_14, stack_ops.swap_15, stack_ops.swap_16,
        };

        inline for (1..17) |n| {
            const idx = 0x90 + n - 1;
            jt.execute_funcs[idx] = swap_functions[n - 1];
            jt.constant_gas[idx] = execution.GasConstants.GasFastestStep;
            jt.min_stack[idx] = @intCast(n + 1);
            jt.max_stack[idx] = Stack.CAPACITY;
            jt.undefined_flags[idx] = false;
        }
    } else {
        inline for (1..17) |n| {
            const idx = 0x90 + n - 1;
            jt.execute_funcs[idx] = stack_ops.make_swap(n);
            jt.constant_gas[idx] = execution.GasConstants.GasFastestStep;
            jt.min_stack[idx] = @intCast(n + 1);
            jt.max_stack[idx] = Stack.CAPACITY;
            jt.undefined_flags[idx] = false;
        }
    }

    // 0xa0s: Logging Operations
    if (comptime builtin.mode == .ReleaseSmall) {
        // Use specific functions for each LOG operation to avoid opcode detection issues
        const log_functions = [_]ExecutionFunc{
            log.log_0, log.log_1, log.log_2, log.log_3, log.log_4,
        };

        inline for (0..5) |n| {
            const idx = 0xa0 + n;
            jt.execute_funcs[idx] = log_functions[n];
            jt.constant_gas[idx] = execution.GasConstants.LogGas + execution.GasConstants.LogTopicGas * n;
            jt.min_stack[idx] = @intCast(n + 2);
            jt.max_stack[idx] = Stack.CAPACITY;
            jt.undefined_flags[idx] = false;
        }
    } else {
        inline for (0..5) |n| {
            const idx = 0xa0 + n;
            jt.execute_funcs[idx] = log.make_log(n);
            jt.constant_gas[idx] = execution.GasConstants.LogGas + execution.GasConstants.LogTopicGas * n;
            jt.min_stack[idx] = @intCast(n + 2);
            jt.max_stack[idx] = Stack.CAPACITY;
            jt.undefined_flags[idx] = false;
        }
    }

    jt.validate();
    return jt;

}

test "jump_table_benchmarks" {
const Timer = std.time.Timer;
var timer = try Timer.start();
const allocator = std.testing.allocator;

    // Setup test environment
    var memory_db = @import("../state/memory_database.zig").MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    var vm = try @import("../evm.zig").Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const iterations = 100000;

    // Benchmark 1: Opcode dispatch performance comparison
    const cancun_table = JumpTable.init_from_hardfork(.CANCUN);
    const shanghai_table = JumpTable.init_from_hardfork(.SHANGHAI);
    const berlin_table = JumpTable.init_from_hardfork(.BERLIN);

    timer.reset();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        // Test common opcodes across different hardforks
        const opcode: u8 = @intCast(i % 256);
        _ = cancun_table.get_operation(opcode);
    }
    const cancun_dispatch_ns = timer.read();

    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        const opcode: u8 = @intCast(i % 256);
        _ = shanghai_table.get_operation(opcode);
    }
    const shanghai_dispatch_ns = timer.read();

    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        const opcode: u8 = @intCast(i % 256);
        _ = berlin_table.get_operation(opcode);
    }
    const berlin_dispatch_ns = timer.read();

    // Benchmark 2: Hot path opcode execution (common operations)
    const hot_opcodes = [_]u8{ 0x60, 0x80, 0x01, 0x50, 0x90 }; // PUSH1, DUP1, ADD, POP, SWAP1

    timer.reset();
    for (hot_opcodes) |opcode| {
        i = 0;
        while (i < iterations / hot_opcodes.len) : (i += 1) {
            const operation = cancun_table.get_operation(opcode);
            // Simulate getting operation metadata
            _ = operation.constant_gas;
            _ = operation.min_stack;
            _ = operation.max_stack;
        }
    }
    const hot_path_ns = timer.read();

    // Benchmark 3: Cold path opcode handling (undefined/invalid opcodes)
    timer.reset();
    const invalid_opcodes = [_]u8{ 0x0c, 0x0d, 0x0e, 0x0f, 0x1e, 0x1f }; // Invalid opcodes

    for (invalid_opcodes) |opcode| {
        i = 0;
        while (i < 1000) : (i += 1) { // Fewer iterations for cold path
            const operation = cancun_table.get_operation(opcode);
            // These should return null or undefined operation
            _ = operation;
        }
    }
    const cold_path_ns = timer.read();

    // Benchmark 4: Hardfork-specific opcode availability
    timer.reset();
    const hardfork_specific_opcodes = [_]struct { opcode: u8, hardfork: Hardfork }{
        .{ .opcode = 0x5f, .hardfork = .SHANGHAI }, // PUSH0 - only available from Shanghai
        .{ .opcode = 0x46, .hardfork = .BERLIN }, // CHAINID - available from Istanbul
        .{ .opcode = 0x48, .hardfork = .LONDON }, // BASEFEE - available from London
    };

    for (hardfork_specific_opcodes) |test_case| {
        const table = JumpTable.init_from_hardfork(test_case.hardfork);
        i = 0;
        while (i < 10000) : (i += 1) {
            const operation = table.get_operation(test_case.opcode);
            _ = operation;
        }
    }
    const hardfork_specific_ns = timer.read();

    // Benchmark 5: Branch prediction impact (predictable vs unpredictable patterns)
    var rng = std.Random.DefaultPrng.init(12345);
    const random = rng.random();

    // Predictable pattern - sequential opcodes
    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        const opcode: u8 = @intCast(i % 50); // Sequential pattern
        _ = cancun_table.get_operation(opcode);
    }
    const predictable_ns = timer.read();

    // Unpredictable pattern - random opcodes
    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        const opcode: u8 = random.int(u8); // Random pattern
        _ = cancun_table.get_operation(opcode);
    }
    const unpredictable_ns = timer.read();

    // Benchmark 6: Cache locality test with table scanning
    timer.reset();
    i = 0;
    while (i < 1000) : (i += 1) { // Fewer iterations due to full scan cost
        // Scan entire jump table (tests cache locality)
        for (0..256) |opcode_idx| {
            _ = cancun_table.get_operation(@intCast(opcode_idx));
        }
    }
    const table_scan_ns = timer.read();

    // Print benchmark results
    std.log.debug("Jump Table Benchmarks:", .{});
    std.log.debug("  Cancun dispatch ({} ops): {} ns", .{ iterations, cancun_dispatch_ns });
    std.log.debug("  Shanghai dispatch ({} ops): {} ns", .{ iterations, shanghai_dispatch_ns });
    std.log.debug("  Berlin dispatch ({} ops): {} ns", .{ iterations, berlin_dispatch_ns });
    std.log.debug("  Hot path operations: {} ns", .{hot_path_ns});
    std.log.debug("  Cold path operations: {} ns", .{cold_path_ns});
    std.log.debug("  Hardfork-specific ops: {} ns", .{hardfork_specific_ns});
    std.log.debug("  Predictable pattern ({} ops): {} ns", .{ iterations, predictable_ns });
    std.log.debug("  Unpredictable pattern ({} ops): {} ns", .{ iterations, unpredictable_ns });
    std.log.debug("  Full table scan (1000x): {} ns", .{table_scan_ns});

    // Performance analysis
    const avg_dispatch_ns = cancun_dispatch_ns / iterations;
    const avg_predictable_ns = predictable_ns / iterations;
    const avg_unpredictable_ns = unpredictable_ns / iterations;

    std.log.debug("  Average dispatch time: {} ns/op", .{avg_dispatch_ns});
    std.log.debug("  Average predictable: {} ns/op", .{avg_predictable_ns});
    std.log.debug("  Average unpredictable: {} ns/op", .{avg_unpredictable_ns});

    // Branch prediction analysis
    if (avg_predictable_ns < avg_unpredictable_ns) {
        std.log.debug("✓ Branch prediction benefit observed");
    }

    // Hardfork dispatch performance comparison
    const cancun_avg = cancun_dispatch_ns / iterations;
    const shanghai_avg = shanghai_dispatch_ns / iterations;
    const berlin_avg = berlin_dispatch_ns / iterations;

    std.log.debug("  Hardfork dispatch comparison:");
    std.log.debug("    Berlin avg: {} ns/op", .{berlin_avg});
    std.log.debug("    Shanghai avg: {} ns/op", .{shanghai_avg});
    std.log.debug("    Cancun avg: {} ns/op", .{cancun_avg});

    // Expect very fast dispatch (should be just array indexing)
    if (avg_dispatch_ns < 10) {
        std.log.debug("✓ Jump table showing expected O(1) performance");
    }

}

```

Here are opcode handlers so far they are just reusing the old ones mostly

```

const std = @import("std");
const Log = @import("../log.zig");
const ExecutionError = @import("execution_error.zig");
const ExecutionContext = @import("../frame.zig").ExecutionContext;
const AccessList = @import("../access_list/access_list.zig");
const GasConstants = @import("primitives").GasConstants;
const primitives = @import("primitives");
const from_u256 = primitives.Address.from_u256;

pub fn op*stop(context: \*anyopaque) ExecutionError.Error!void {
* = context;

    return ExecutionError.Error.STOP;

}

// DEPRECATED: JUMP is now handled directly in interpret.zig via .jump*target instruction type
// This function is no longer called and should be deleted
pub fn op_jump(context: \*anyopaque) ExecutionError.Error!void {
* = context;
// TODO_DELETE: This function is deprecated - JUMP is handled in interpret loop
unreachable;
}

// DEPRECATED: JUMPI is now handled directly in interpret.zig via .jump*target instruction type
// This function is no longer called and should be deleted
pub fn op_jumpi(context: \*anyopaque) ExecutionError.Error!void {
* = context;
// TODO_DELETE: This function is deprecated - JUMPI is handled in interpret loop
unreachable;
}

// TODO*PC_DELETE: PC operations are deprecated in the new architecture
pub fn op_pc(context: \*anyopaque) ExecutionError.Error!void {
* = context;
// TODO_DELETE: This function is deprecated - PC is not needed in new architecture
unreachable;
}

pub fn op*jumpdest(context: \*anyopaque) ExecutionError.Error!void {
* = context;

    // No-op, just marks valid jump destination

}

pub fn op_return(context: *anyopaque) ExecutionError.Error!void {
const ctx = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
const frame = ctx.frame;

    std.debug.assert(frame.stack.size() >= 2);

    // Use batch pop for performance - pop 2 values at once
    // Stack order (top to bottom): [offset, size] with offset on top
    const values = frame.stack.pop2_unsafe();
    const offset = values.b; // Top
    const size = values.a; // Second from top

    Log.debug("RETURN opcode: offset={}, size={}", .{ offset, size });

    if (size == 0) {
        @branchHint(.unlikely);
        frame.output = &[_]u8{};
    } else {
        if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
            @branchHint(.unlikely);
            return ExecutionError.Error.OutOfOffset;
        }

        const offset_usize = @as(usize, @intCast(offset));
        const size_usize = @as(usize, @intCast(size));

        // Calculate memory expansion gas cost
        const end = offset_usize + size_usize;
        if (end > offset_usize) { // Check for overflow
            const memory_gas = frame.memory.get_expansion_cost(@as(u64, @intCast(end)));
            try frame.consume_gas(memory_gas);

            _ = try frame.memory.ensure_context_capacity(end);
        }

        // Get data from memory
        const data = try frame.memory.get_slice(offset_usize, size_usize);

        Log.debug("RETURN reading {} bytes from memory[{}..{}]", .{ size_usize, offset_usize, offset_usize + size_usize });
        if (size_usize <= 32) {
            Log.debug("RETURN data: {x}", .{std.fmt.fmtSliceHexLower(data)});
        } else {
            Log.debug("RETURN data (first 32 bytes): {x}", .{std.fmt.fmtSliceHexLower(data[0..32])});
        }

        // Note: The memory gas cost already protects against excessive memory use.
        // Set the output data that will be returned to the caller
        frame.output = data;

        Log.debug("RETURN data set to frame.output, size: {}", .{data.len});
    }

    Log.debug("RETURN opcode complete, about to return STOP error", .{});
    return ExecutionError.Error.STOP; // RETURN ends execution normally

}

pub fn op_revert(context: *anyopaque) ExecutionError.Error!void {
const ctx = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
const frame = ctx.frame;

    std.debug.assert(frame.stack.size() >= 2);

    // Use batch pop for performance - pop 2 values at once
    // Stack order (top to bottom): [offset, size] with offset on top
    const values = frame.stack.pop2_unsafe();
    const offset = values.b; // Top
    const size = values.a; // Second from top

    if (size == 0) {
        @branchHint(.unlikely);
        frame.output = &[_]u8{};
    } else {
        if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
            @branchHint(.unlikely);
            return ExecutionError.Error.OutOfOffset;
        }

        const offset_usize = @as(usize, @intCast(offset));
        const size_usize = @as(usize, @intCast(size));

        // Calculate memory expansion gas cost
        const end = offset_usize + size_usize;
        if (end > offset_usize) { // Check for overflow
            const memory_gas = frame.memory.get_expansion_cost(@as(u64, @intCast(end)));
            try frame.consume_gas(memory_gas);

            _ = try frame.memory.ensure_context_capacity(end);
        }

        // Get data from memory
        const data = try frame.memory.get_slice(offset_usize, size_usize);

        // Note: The memory gas cost already protects against excessive memory use.
        // Set the output data that will be returned to the caller
        frame.output = data;
    }

    return ExecutionError.Error.REVERT;

}

pub fn op_invalid(context: *anyopaque) ExecutionError.Error!void {
const ctx = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
const frame = ctx.frame;

    // Debug: op_invalid entered
    // INVALID opcode consumes all remaining gas
    frame.gas_remaining = 0;
    // Debug: op_invalid returning InvalidOpcode

    return ExecutionError.Error.InvalidOpcode;

}

pub fn op_selfdestruct(context: *anyopaque) ExecutionError.Error!void {
const ctx = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
const frame = ctx.frame;
const vm = ctx.vm;

    // Check if we're in a static call
    if (frame.is_static) {
        @branchHint(.unlikely);
        return ExecutionError.Error.WriteProtection;
    }

    std.debug.assert(frame.stack.size() >= 1);

    // Use unsafe pop since bounds checking is done by jump_table
    const recipient_u256 = frame.stack.pop_unsafe();
    const recipient = from_u256(recipient_u256);

    // EIP-2929: Check if recipient address is cold and consume appropriate gas
    // Note: Jump table already consumes base SELFDESTRUCT gas cost
    const access_cost = vm.access_list.access_address(recipient) catch |err| switch (err) {
        error.OutOfMemory => return ExecutionError.Error.OutOfGas,
    };
    const is_cold = access_cost == AccessList.COLD_ACCOUNT_ACCESS_COST;
    if (is_cold) {
        @branchHint(.likely);
        // Cold address access costs more (2600 gas)
        try frame.consume_gas(GasConstants.ColdAccountAccessCost);
    }

    // Mark contract for destruction at end of transaction
    vm.state.mark_for_destruction(frame.contract.address, recipient) catch |err| switch (err) {
        error.OutOfMemory => return ExecutionError.Error.OutOfGas,
    };

    // Halt execution
    return ExecutionError.Error.STOP;

}

```

```

/// Arithmetic operations for the Ethereum Virtual Machine
///
/// This module implements all arithmetic opcodes for the EVM, including basic
/// arithmetic (ADD, SUB, MUL, DIV), signed operations (SDIV, SMOD), modular
/// arithmetic (MOD, ADDMOD, MULMOD), exponentiation (EXP), and sign extension
/// (SIGNEXTEND).
///
/// ## Design Philosophy
///
/// All operations follow a consistent pattern:
/// 1. Pop operands from the stack (validated by jump table)
/// 2. Perform the arithmetic operation
/// 3. Push the result back onto the stack
///
/// ## Performance Optimizations
///
/// - **Unsafe Operations**: Stack bounds checking is done by the jump table,
/// allowing opcodes to use unsafe stack operations for maximum performance
/// - **In-Place Updates**: Results are written directly to stack slots to
/// minimize memory operations
/// - **Wrapping Arithmetic**: Uses Zig's wrapping operators (`+%`, `*%`, `-%`)
/// for correct 256-bit overflow behavior
///
/// ## EVM Arithmetic Rules
///
/// - All values are 256-bit unsigned integers (u256)
/// - Overflow wraps around (e.g., MAX_U256 + 1 = 0)
/// - Division by zero returns 0 (not an error)
/// - Modulo by zero returns 0 (not an error)
/// - Signed operations interpret u256 as two's complement i256
///
/// ## Gas Costs
///
/// - ADD, SUB, NOT: 3 gas (GasFastestStep)
/// - MUL, DIV, SDIV, MOD, SMOD: 5 gas (GasFastStep)
/// - ADDMOD, MULMOD, SIGNEXTEND: 8 gas (GasMidStep)
/// - EXP: 10 gas + 50 per byte of exponent
///
/// ## Stack Requirements
///
/// Operation | Stack Input | Stack Output | Description
/// -------------|-------------|--------------|-------------
/// ADD | [a, b] | [a + b] | Addition with overflow
/// MUL | [a, b] | [a * b] | Multiplication with overflow
/// SUB | [a, b] | [a - b] | Subtraction with underflow
/// DIV | [a, b] | [a / b] | Division (b=0 returns 0)
/// SDIV | [a, b] | [a / b] | Signed division
/// MOD | [a, b] | [a % b] | Modulo (b=0 returns 0)
/// SMOD | [a, b] | [a % b] | Signed modulo
/// ADDMOD | [a, b, n] | [(a+b)%n] | Addition modulo n
/// MULMOD | [a, b, n] | [(a*b)%n] | Multiplication modulo n
/// EXP | [a, b] | [a^b] | Exponentiation
/// SIGNEXTEND | [b, x] | [y] | Sign extend x from byte b
const std = @import("std");
const ExecutionError = @import("execution_error.zig");
const ExecutionContext = @import("../frame.zig").ExecutionContext;
const primitives = @import("primitives");
const U256 = primitives.Uint(256, 4);

const ArithmeticOpType = enum {
add,
mul,
sub,
div,
sdiv,
mod,
smod,
addmod,
mulmod,
exp,
signextend,
};

// Imports for tests
const Vm = @import("../evm.zig");
const MemoryDatabase = @import("../state/memory_database.zig");
const Operation = @import("../opcodes/operation.zig");

/// ADD opcode (0x01) - Addition with wrapping overflow
pub fn op_add(context: *anyopaque) ExecutionError.Error!void {
const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
std.debug.assert(frame.stack.size() >= 2);

    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe().*;
    const result = a +% b;
    frame.stack.set_top_unsafe(result);

}

/// MUL opcode (0x02) - Multiplication operation
///
/// Pops two values from the stack, multiplies them with wrapping overflow,
/// and pushes the result.
///
/// ## Stack Input
/// - `a`: First operand (second from top)
/// - `b`: Second operand (top)
///
/// ## Stack Output
/// - `a * b`: Product with 256-bit wrapping overflow
///
/// ## Gas Cost
/// 5 gas (GasFastStep)
///
/// ## Execution
/// 1. Pop b from stack
/// 2. Pop a from stack
/// 3. Calculate product = (a * b) mod 2^256
/// 4. Push product to stack
///
/// ## Example
/// Stack: [10, 20] => [200]
/// Stack: [2^128, 2^128] => [0] (overflow wraps)
pub fn op_mul(context: *anyopaque) ExecutionError.Error!void {
const frame = @as(\*ExecutionContext, @ptrCast(@alignCast(context)));
std.debug.assert(frame.stack.size() >= 2);

    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe().*;

    // Use optimized U256 multiplication
    const a_u256 = U256.from_u256_unsafe(a);
    const b_u256 = U256.from_u256_unsafe(b);
    const product_u256 = a_u256.wrapping_mul(b_u256);
    const product = product_u256.to_u256_unsafe();

    frame.stack.set_top_unsafe(product);

}

/// SUB opcode (0x03) - Subtraction operation
///
/// Pops two values from the stack, subtracts the top from the second,
/// with wrapping underflow, and pushes the result.
///
/// ## Stack Input
/// - `a`: Minuend (second from top)
/// - `b`: Subtrahend (top)
///
/// ## Stack Output
/// - `a - b`: Difference with 256-bit wrapping underflow
///
/// ## Gas Cost
/// 3 gas (GasFastestStep)
///
/// ## Execution
/// 1. Pop b from stack
/// 2. Pop a from stack
/// 3. Calculate result = (a - b) mod 2^256
/// 4. Push result to stack
///
/// ## Example
/// Stack: [30, 10] => [20]
/// Stack: [10, 20] => [2^256 - 10] (underflow wraps)
pub fn op_sub(context: *anyopaque) ExecutionError.Error!void {
const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
std.debug.assert(frame.stack.size() >= 2);

    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe().*;

    const result = b -% a;

    frame.stack.set_top_unsafe(result);

}

/// DIV opcode (0x04) - Unsigned integer division
///
/// Pops two values from the stack, divides the second by the top,
/// and pushes the integer quotient. Division by zero returns 0.
///
/// ## Stack Input
/// - `a`: Dividend (second from top)
/// - `b`: Divisor (top)
///
/// ## Stack Output
/// - `a / b`: Integer quotient, or 0 if b = 0
///
/// ## Gas Cost
/// 5 gas (GasFastStep)
///
/// ## Execution
/// 1. Pop b from stack
/// 2. Pop a from stack
/// 3. If b = 0, result = 0 (no error)
/// 4. Else result = floor(a / b)
/// 5. Push result to stack
///
/// ## Example
/// Stack: [20, 5] => [4]
/// Stack: [7, 3] => [2] (integer division)
/// Stack: [100, 0] => [0] (division by zero)
///
/// ## Note
/// Unlike most programming languages, EVM division by zero does not
/// throw an error but returns 0. This is a deliberate design choice
/// to avoid exceptional halting conditions.
pub fn op_div(context: *anyopaque) ExecutionError.Error!void {
const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
std.debug.assert(frame.stack.size() >= 2);

    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe().*;

    const result = if (a == 0) blk: {
        break :blk 0;
    } else blk: {
        const result_u256 = U256.from_u256_unsafe(b).wrapping_div(U256.from_u256_unsafe(a));
        break :blk result_u256.to_u256_unsafe();
    };

    frame.stack.set_top_unsafe(result);

}

/// SDIV opcode (0x05) - Signed integer division
///
/// Pops two values from the stack, interprets them as signed integers,
/// divides the first popped value by the second, and pushes the signed quotient.
/// Division by zero returns 0.
///
/// ## Stack Input
/// - `b`: Dividend as signed i256 (top)
/// - `a`: Divisor as signed i256 (second from top)
///
/// ## Stack Output
/// - `b / a`: Signed integer quotient, or 0 if a = 0
///
/// ## Gas Cost
/// 5 gas (GasFastStep)
///
/// ## Execution
/// 1. Pop b from stack (dividend)
/// 2. Peek a from stack (divisor, stays on stack)
/// 3. Interpret both as two's complement signed integers
/// 4. If a = 0, result = 0
/// 5. Else if b = -2^255 and a = -1, result = -2^255 (overflow case)
/// 6. Else result = truncated division b / a
/// 7. Replace top of stack with result
///
/// ## Example
/// Stack: [20, 5] => [4]
/// Stack: [-20, 5] => [-4] (0xfff...fec / 5)
/// Stack: [-20, -5] => [4]
/// Stack: [MIN_I256, -1] => [MIN_I256] (overflow protection)
///
/// ## Note
/// The special case for MIN_I256 / -1 prevents integer overflow,
/// as the mathematical result (2^255) cannot be represented in i256.
/// In this case, we return MIN_I256 to match EVM behavior.
pub fn op_sdiv(context: *anyopaque) ExecutionError.Error!void {
const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
std.debug.assert(frame.stack.size() >= 2);

    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe().*;

    var result: u256 = undefined;
    if (a == 0) {
        @branchHint(.unlikely);
        result = 0;
    } else {
        const a_i256 = @as(i256, @bitCast(a));
        const b_i256 = @as(i256, @bitCast(b));
        const min_i256 = std.math.minInt(i256);
        if (b_i256 == min_i256 and a_i256 == -1) {
            @branchHint(.unlikely);
            // MIN_I256 / -1 = MIN_I256 (overflow wraps)
            // This matches EVM behavior where overflow wraps around
            result = b;
        } else {
            const result_i256 = @divTrunc(b_i256, a_i256);
            result = @as(u256, @bitCast(result_i256));
        }
    }

    frame.stack.set_top_unsafe(result);

}

/// MOD opcode (0x06) - Modulo remainder operation
///
/// Pops two values from the stack, calculates the remainder of dividing
/// the second by the top, and pushes the result. Modulo by zero returns 0.
///
/// ## Stack Input
/// - `a`: Dividend (second from top)
/// - `b`: Divisor (top)
///
/// ## Stack Output
/// - `a % b`: Remainder of a / b, or 0 if b = 0
///
/// ## Gas Cost
/// 5 gas (GasFastStep)
///
/// ## Execution
/// 1. Pop b from stack
/// 2. Pop a from stack

```
So that's the entire EVM. Please give it a good review and tell me what you think. Include unimplemented features bugs, performance characteristics, comments and instructions on how to improve the evm.this report should be very long and througough as we will later be giving it to agents to make the changes to productionize this evm. Don't worry about tests as we have an entire test suite I haven't shown you yet
```
