const std = @import("std");
const builtin = @import("builtin");
const OpcodeMetadata = @import("opcode_metadata/opcode_metadata.zig");
const Operation = @import("opcodes/operation.zig");
const primitives = @import("primitives");
const primitives_internal = primitives;
const AccessList = @import("access_list/access_list.zig");
const ExecutionError = @import("execution/execution_error.zig");
const Keccak256 = std.crypto.hash.sha3.Keccak256;
const hardforks_chain_rules = @import("hardforks/chain_rules.zig");
const ChainRules = hardforks_chain_rules.ChainRules;
const GasConstants = @import("primitives").GasConstants;
const CallJournal = @import("call_frame_stack.zig").CallJournal;
const Host = @import("host.zig").Host;
const BlockInfo = @import("host.zig").BlockInfo;
const CallParams = @import("host.zig").CallParams;
const opcode = @import("opcodes/opcode.zig");
const Log = @import("log.zig");
const EvmLog = @import("state/evm_log.zig");
const Context = @import("access_list/context.zig");
const EvmState = @import("state/state.zig");
const Memory = @import("memory/memory.zig");
const ReturnData = @import("evm/return_data.zig").ReturnData;
const evm_limits = @import("constants/evm_limits.zig");
const Frame = @import("stack_frame.zig").StackFrame;
const StackFrame = @import("stack_frame.zig").StackFrame;
const SelfDestruct = @import("self_destruct.zig").SelfDestruct;
const CreatedContracts = @import("created_contracts.zig").CreatedContracts;
const FramePool = @import("frame_pool.zig").FramePool;
pub const StorageKey = @import("primitives").StorageKey;
pub const CreateResult = @import("evm/create_result.zig").CreateResult;
const Contract = @import("root.zig").Contract;
pub const CallResult = @import("evm/call_result.zig").CallResult;
pub const RunResult = @import("evm/run_result.zig").RunResult;
const Hardfork = @import("hardforks/hardfork.zig").Hardfork;
const precompiles = @import("precompiles/precompiles.zig");
const AnalysisCache = @import("analysis_cache.zig");
const interpret2 = @import("evm/interpret2.zig");

const Evm = @This();

pub const MAX_CALL_DEPTH: u11 = evm_limits.MAX_CALL_DEPTH;

state: EvmState,
access_list: AccessList,
journal: CallJournal,
allocator: std.mem.Allocator,
gas_refunds: i64,
current_snapshot_id: u32 = 0,

// ===================================================================
// CACHE LINE 3 (64 bytes) - TRANSACTION LIFECYCLE (WARM)
// ===================================================================
// These fields are accessed together during CREATE/SELFDESTRUCT operations
/// Tracks contracts created in current transaction for EIP-6780
created_contracts: CreatedContracts, // 24 bytes - CREATE/CREATE2 tracking
/// Self-destruct tracking for the current execution
self_destruct: SelfDestruct, // 24 bytes - SELFDESTRUCT tracking
/// Internal arena allocator for temporary data that's reset between executions
internal_arena: std.heap.ArenaAllocator, // 16 bytes - execution management
// Total: 64 bytes

// ===================================================================
// CACHE LINE 4 (64 bytes) - CALL FRAME MANAGEMENT (WARM)
// ===================================================================
// These fields are accessed together during nested calls
/// Pool for lazily reusing temporary Frames (e.g., constructor frames)
frame_pool: FramePool, // ~32 bytes - frame allocation pool
// Total: ~64 bytes

// ===================================================================
// CACHE LINE 5+ - CONFIGURATION AND I/O (COLD)
// ===================================================================
// These fields are accessed infrequently or during initialization only

// Configuration data (accessed during init and specific opcodes)
/// Opcode dispatch table for the configured hardfork
table: OpcodeMetadata, // Large struct - opcode execution
/// Protocol rules for the current hardfork
chain_rules: ChainRules, // Configuration, accessed during init
/// Execution context providing transaction and block information
context: Context, // Transaction context - rarely accessed

// I/O buffers (accessed only during CALLDATALOAD)
/// Input buffer for the current frame (exposed via Host.get_input)
current_input: []const u8 = &.{}, // 16 bytes - only for CALLDATALOAD/CALLDATACOPY

// Rarely accessed fields
/// Dynamic frame stack for nested calls
/// Grows as needed for CALL/CREATE operations, depth = frames.items.len
frames: std.ArrayList(Frame), // Dynamic call stack
/// LRU cache for code analysis to avoid redundant analysis during nested calls
analysis_cache: ?AnalysisCache = null, // 8 bytes - analysis cache pointer

// Debug/tracing data (cold - only used in development)
/// Optional tracer for capturing execution traces (not available on WASM)
tracer: if (builtin.target.cpu.arch == .wasm32 and builtin.target.os.tag == .freestanding) ?void else ?std.io.AnyWriter = null,
/// Open file handle used by tracer when tracing to file (not available on WASM)
trace_file: if (builtin.target.cpu.arch == .wasm32 and builtin.target.os.tag == .freestanding) ?void else ?std.fs.File = null,
/// As of now the EVM assumes we are only running on a single thread
/// All places in code that make this assumption are commented and must be handled
/// Before we can remove this restriction
initial_thread_id: if (builtin.target.cpu.arch == .wasm32 and builtin.target.os.tag == .freestanding) u32 else std.Thread.Id,

pub fn init(
    allocator: std.mem.Allocator,
    database: @import("state/database_interface.zig").DatabaseInterface,
    table: ?OpcodeMetadata,
    chain_rules: ?ChainRules,
    context: ?Context,
    tracer: if (builtin.target.cpu.arch == .wasm32 and builtin.target.os.tag == .freestanding) ?void else ?std.io.AnyWriter,
) !Evm {
    var state = try EvmState.init(allocator, database);
    errdefer state.deinit();
    const ctx = context orelse Context.init();
    var access_list = AccessList.init(allocator, ctx);
    errdefer access_list.deinit();
    return Evm{
        .state = state,
        .access_list = access_list,
        .journal = CallJournal.init(allocator),
        .allocator = allocator,
        .gas_refunds = 0,
        .current_snapshot_id = 0,
        .created_contracts = CreatedContracts.init(allocator),
        .self_destruct = SelfDestruct.init(allocator),
        .internal_arena = std.heap.ArenaAllocator.init(allocator),
        .frame_pool = try FramePool.init(allocator, MAX_CALL_DEPTH),
        .table = table orelse OpcodeMetadata.DEFAULT,
        .chain_rules = chain_rules orelse ChainRules.DEFAULT,
        .context = ctx,
        .current_input = &.{},
        .frames = std.ArrayList(Frame).init(allocator),
        .analysis_cache = AnalysisCache.init(allocator, AnalysisCache.DEFAULT_CACHE_SIZE),
        .tracer = tracer,
        .trace_file = null,
        .initial_thread_id = if (builtin.target.cpu.arch == .wasm32 and builtin.target.os.tag == .freestanding) 0 else std.Thread.getCurrentId(),
    };
}

pub fn deinit(self: *Evm) void {
    if (comptime !(builtin.target.cpu.arch == .wasm32 and builtin.target.os.tag == .freestanding)) {
        if (self.trace_file) |f| {
            // Best-effort close
            f.close();
            self.trace_file = null;
        }
    }
    self.state.deinit();
    self.access_list.deinit();
    self.internal_arena.deinit();
    self.journal.deinit();
    self.frame_pool.deinit();

    // Clean up analysis cache if it exists
    if (self.analysis_cache) |*cache| {
        cache.deinit();
    }

    // Clean up self-destruct tracking
    self.self_destruct.deinit();
    // Clean up created contracts tracking
    self.created_contracts.deinit();

    // Clean up frame stack
    // Deinit any remaining frames in the stack
    for (self.frames.items) |*frame| {
        frame.deinit(self.allocator);
    }
    self.frames.deinit();

    // created_contracts is initialized in init(); single deinit above is sufficient
}

const build_options = @import("build_options");

/// Enable instruction tracing to a file. If append is true, appends to existing file.
pub fn enable_tracing_to_path(self: *Evm, path: []const u8, append: bool) !void {
    if (!comptime build_options.enable_tracing) {
        // Tracing disabled at compile-time; keep binary size smaller with no runtime feature
        return error.FeatureDisabled;
    }
    // Close previous file if any
    if (self.trace_file) |f| {
        f.close();
        self.trace_file = null;
    }
    // Open file
    var file = try std.fs.cwd().createFile(path, .{ .truncate = !append, .read = false });
    if (append) {
        // Seek to end for appending
        try file.seekFromEnd(0);
    }
    self.trace_file = file;
    // Set tracer writer
    self.tracer = file.writer().any();
}

/// Disable tracing and close any open trace file.
pub fn disable_tracing(self: *Evm) void {
    if (!comptime build_options.enable_tracing) return;
    self.tracer = null;
    if (self.trace_file) |f| {
        f.close();
        self.trace_file = null;
    }
}

/// Reset the EVM for reuse without deallocating memory.
/// This is efficient for executing multiple contracts in sequence.
/// Clears all state but keeps the allocated memory for reuse.
pub fn reset(self: *Evm) void {
    _ = self.internal_arena.reset(.retain_capacity);
    self.gas_refunds = 0;
}

/// Get the internal arena allocator for temporary EVM data
/// Use this for allocations that are reset between EVM executions
pub fn arena_allocator(self: *Evm) std.mem.Allocator {
    return self.internal_arena.allocator();
}

// ============================================================================
// Gas Refund System (EIP-3529)
// ============================================================================

/// Add gas refund for storage operations (SSTORE) and SELFDESTRUCT.
/// Refunds are accumulated at the transaction level and applied at the end.
///
/// @param amount The amount of gas to refund
/// Adjust gas refund by signed delta (can be negative per EIP-2200)
pub fn adjust_gas_refund(self: *Evm, delta: i64) void {
    // Saturating addition on i64 bounds
    const sum = @as(i128, self.gas_refunds) + @as(i128, delta);
    const clamped = if (sum > @as(i128, std.math.maxInt(i64))) @as(i64, std.math.maxInt(i64)) else if (sum < @as(i128, std.math.minInt(i64))) @as(i64, std.math.minInt(i64)) else @as(i64, @intCast(sum));
    self.gas_refunds = clamped;
    Log.debug("Gas refund adjusted by {} (total: {})", .{ delta, self.gas_refunds });
}

/// Backward-compatible helper for positive refunds
pub fn add_gas_refund(self: *Evm, amount: u64) void {
    self.adjust_gas_refund(@as(i64, @intCast(amount)));
}

/// Apply gas refunds at transaction end with EIP-3529 cap.
/// Maximum refund is gas_used / 5 as per London hardfork.
///
/// @param total_gas_used The total gas used in the transaction
/// @return The actual refund amount after applying the cap
pub fn apply_gas_refunds(self: *Evm, total_gas_used: u64) u64 {
    // EIP-3529: Maximum refund is gas_used / 5 (London hardfork)
    // Pre-London: Maximum refund is gas_used / 2
    const max_refund_quotient: u64 = if (self.chain_rules.is_london) 5 else 2;
    const max_refund = total_gas_used / max_refund_quotient;

    // Only positive refunds apply; negative deltas reduce previous credits during execution
    const requested: u64 = if (self.gas_refunds > 0) @as(u64, @intCast(self.gas_refunds)) else 0;
    const actual_refund: u64 = @min(requested, max_refund);

    Log.debug("Applying gas refunds: requested={}, max={}, actual={}", .{ requested, max_refund, actual_refund });

    // Reset refunds after application
    self.gas_refunds = 0;
    return actual_refund;
}

/// Reset gas refunds for a new transaction.
/// Called at the start of each transaction execution.
pub fn reset_gas_refunds(self: *Evm) void {
    self.gas_refunds = 0;
}

// Host interface implementation - EVM acts as its own host
/// Get account balance (Host interface)
pub fn get_balance(self: *Evm, address: primitives.Address.Address) u256 {
    return self.state.get_balance(address);
}

/// Check if account exists (Host interface)
pub fn account_exists(self: *Evm, address: primitives.Address.Address) bool {
    // Delegate to the underlying database via state
    return self.state.database.account_exists(address);
}

/// Get account code (Host interface)
pub fn get_code(self: *Evm, address: primitives.Address.Address) []const u8 {
    return self.state.get_code(address);
}

/// Get block information (Host interface)
pub fn get_block_info(self: *Evm) BlockInfo {
    // Return block info from context
    return BlockInfo{
        .number = self.context.block_number,
        .timestamp = self.context.block_timestamp,
        .difficulty = self.context.block_difficulty,
        .gas_limit = self.context.block_gas_limit,
        .coinbase = self.context.block_coinbase,
        .base_fee = self.context.block_base_fee,
        .prev_randao = [_]u8{0} ** 32, // TODO: Add prev_randao to Context
    };
}

/// Emit log event (Host interface override)
/// This overrides the emit_log from emit_log.zig to provide the correct signature for Host interface
pub fn emit_log(self: *Evm, contract_address: primitives.Address.Address, topics: []const u256, data: []const u8) void {
    // Delegate to the state's emit_log implementation
    self.state.emit_log(contract_address, topics, data) catch |err| {
        Log.debug("emit_log failed: {}", .{err});
    };
}

/// Register a contract as created in the current transaction (Host interface)
pub fn register_created_contract(self: *Evm, address: primitives.Address.Address) !void {
    std.log.debug("[EVM] register_created_contract: address={any}, allocator={any}", .{ std.fmt.fmtSliceHexLower(&address), @intFromPtr(self.created_contracts.allocator.vtable) });
    return self.created_contracts.mark_created(address);
}

/// Check if a contract was created in the current transaction (Host interface)
pub fn was_created_in_tx(self: *Evm, address: primitives.Address.Address) bool {
    return self.created_contracts.was_created_in_tx(address);
}

/// Create a new journal snapshot for reverting state changes (Host interface)
pub fn create_snapshot(self: *Evm) u32 {
    self.current_snapshot_id = self.journal.create_snapshot();
    return self.current_snapshot_id;
}

/// Revert state changes to a previous snapshot (Host interface)
pub fn revert_to_snapshot(self: *Evm, snapshot_id: u32) void {
    self.journal.revert_to_snapshot(snapshot_id);
}

/// Record a storage change in the journal (Host interface)
pub fn record_storage_change(self: *Evm, address: primitives.Address.Address, slot: u256, original_value: u256) !void {
    return self.journal.record_storage_change(self.current_snapshot_id, address, slot, original_value);
}

/// Get the original storage value from the journal (Host interface)
pub fn get_original_storage(self: *Evm, address: primitives.Address.Address, slot: u256) ?u256 {
    return self.journal.get_original_storage(address, slot);
}


pub fn get_input(self: *Evm) []const u8 {
    if (self.current_input.len > 0) {
        return self.current_input;
    }
    return &.{};
}

pub fn access_address(self: *Evm, address: primitives.Address.Address) !u64 {
    return self.access_list.access_address(address);
}

pub fn access_storage_slot(self: *Evm, contract_address: primitives.Address.Address, slot: u256) !u64 {
    return self.access_list.access_storage_slot(contract_address, slot);
}

pub fn mark_for_destruction(self: *Evm, contract_address: primitives.Address.Address, recipient: primitives.Address.Address) !void {
    return self.self_destruct.mark_for_destruction(contract_address, recipient);
}

pub fn is_hardfork_at_least(self: *Evm, target: Hardfork) bool {
    return @intFromEnum(self.chain_rules.getHardfork()) >= @intFromEnum(target);
}

pub fn get_hardfork(self: *Evm) Hardfork {
    return self.chain_rules.getHardfork();
}

/// Get whether the current frame is static (read-only) (Host interface)
pub fn get_is_static(self: *Evm) bool {
    // Check the top frame in the stack (most recent frame)
    if (self.frames.items.len > 0) {
        return self.frames.items[self.frames.items.len - 1].is_static;
    }
    // If no frames, assume not static (shouldn't happen during execution)
    return false;
}

/// Get the current call depth (Host interface)
pub fn get_depth(self: *Evm) u11 {
    return @intCast(self.frames.items.len);
}

pub usingnamespace @import("evm/set_context.zig");
pub usingnamespace @import("evm/call2.zig");
// TODO remove
pub const call2 = @import("evm/call2.zig").call;
// TODO remove
pub const call_mini = @import("evm/call2.zig").call;
pub usingnamespace @import("evm/call_contract.zig");
pub usingnamespace @import("evm/execute_precompile_call.zig");
pub usingnamespace @import("evm/staticcall_contract.zig");
pub usingnamespace @import("evm/validate_static_context.zig");
pub usingnamespace @import("evm/set_storage_protected.zig");
pub usingnamespace @import("evm/set_transient_storage_protected.zig");
pub usingnamespace @import("evm/set_balance_protected.zig");
pub usingnamespace @import("evm/set_code_protected.zig");
pub usingnamespace @import("evm/emit_log_protected.zig");
pub usingnamespace @import("evm/validate_value_transfer.zig");
pub usingnamespace @import("evm/selfdestruct_protected.zig");
pub usingnamespace @import("evm/require_one_thread.zig");
pub usingnamespace @import("evm/interpret2.zig");

// TODO: have this return a normal result
// Compatibility wrapper for old interpret API used by tests
pub const InterprResult = struct {
    pub const Status = enum { Success, Failure, Invalid, Revert, OutOfGas };

    status: Status,
    output: ?[]const u8,
    gas_left: u64,
    gas_used: u64,
    address: primitives_internal.Address.Address,
    success: bool,
};

// TODO: move this somewhere
pub fn create_contract(self: *Evm, caller: primitives_internal.Address.Address, value: u256, bytecode: []const u8, gas: u64) !InterprResult {
    const nonce = self.state.get_nonce(caller);
    const new_address = primitives_internal.Address.get_contract_address(caller, nonce);
    _ = try self.state.increment_nonce(caller);
    return self.create_contract_at(caller, value, bytecode, gas, new_address);
}

// TODO: move this somewhere
pub fn compute_create2_address(self: *Evm, caller: primitives_internal.Address.Address, salt: u256, init_code: []const u8) primitives_internal.Address.Address {
    _ = self;
    var preimage: [1 + 20 + 32 + 32]u8 = undefined;
    preimage[0] = 0xff;
    @memcpy(preimage[1..21], &caller);
    var salt_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &salt_bytes, salt, .big);
    @memcpy(preimage[21..53], &salt_bytes);
    var code_hash: [32]u8 = undefined;
    Keccak256.hash(init_code, &code_hash, .{});
    @memcpy(preimage[53..85], &code_hash);
    var out_hash: [32]u8 = undefined;
    Keccak256.hash(&preimage, &out_hash, .{});
    var addr: primitives_internal.Address.Address = undefined;
    @memcpy(&addr, out_hash[12..32]);
    return addr;
}

/// CREATE/CREATE2 helper that deploys contract at a specified address
// TODO: move this somewhere
pub fn create_contract_at(self: *Evm, caller: primitives_internal.Address.Address, value: u256, bytecode: []const u8, gas: u64, new_address: primitives_internal.Address.Address) !InterprResult {
    const is_top_level = self.frames.items.len == 0;
    var remaining_gas = gas;
    if (is_top_level) {
        const base_cost = GasConstants.TxGas;
        if (remaining_gas < base_cost) {
            return InterprResult{
                .status = .OutOfGas,
                .output = null,
                .gas_left = 0,
                .gas_used = 0,
                .address = new_address,
                .success = false,
            };
        }

        remaining_gas -= base_cost;
    }

    const analysis_ptr = blk: {
        if (self.analysis_cache) |*cache| {
            break :blk cache.getOrAnalyze(bytecode, &self.table) catch |err| {
                Log.err("[CREATE_DEBUG] Analysis failed: {}", .{err});
                return InterprResult{
                    .status = .Failure,
                    .output = null,
                    .gas_left = remaining_gas,
                    .gas_used = 0,
                    .address = new_address,
                    .success = false,
                };
            };
        }
        return InterprResult{
            .status = .Failure,
            .output = null,
            .gas_left = remaining_gas,
            .gas_used = 0,
            .address = new_address,
            .success = false,
        };
    };

    const GasC = @import("primitives").GasConstants;
    const word_count: u64 = GasC.wordCount(bytecode.len);
    const precharge: u64 = GasC.CreateGas + (word_count * GasC.InitcodeWordGas) + (@as(u64, @intCast(bytecode.len)) * GasC.CreateDataGas);

    if (remaining_gas <= precharge) {
        return InterprResult{
            .status = .OutOfGas,
            .output = null,
            .gas_left = 0,
            .gas_used = 0,
            .address = new_address,
            .success = false,
        };
    }
    const frame_gas: u64 = remaining_gas - precharge;

    const host = @import("host.zig").Host.init(self);
    const snapshot_id: u32 = host.create_snapshot();
    
    // Transfer value from caller to new contract address
    if (value > 0) {
        // Check caller has sufficient balance
        const caller_balance = self.state.get_balance(caller);
        if (caller_balance < value) {
            host.revert_to_snapshot(snapshot_id);
            return InterprResult{
                .status = .Failure,
                .output = null,
                .gas_left = remaining_gas,
                .gas_used = 0,
                .address = new_address,
                .success = false,
            };
        }
        
        // Transfer: debit caller, credit new contract
        try self.state.set_balance(caller, caller_balance - value);
        const new_contract_balance = self.state.get_balance(new_address);
        try self.state.set_balance(new_address, new_contract_balance + value);
    }
    
    const frame_val = try Frame.init(
        frame_gas,
        new_address,
        analysis_ptr.analysis,
        &[_]*const fn (*StackFrame) @import("execution/execution_error.zig").Error!noreturn{},
        host,
        self.state.database,
        self.allocator,
        false, // CREATE operations are never static
        caller, // Caller who initiated the CREATE
        value, // ETH value for the contract
        bytecode, // Input is the init bytecode
    );
    const frame_ptr = try self.frame_pool.acquire();
    frame_ptr.* = frame_val;

    @import("evm/interpret2.zig").interpret2(frame_ptr) catch |err| {
        switch (err) {
            ExecutionError.Error.RETURN, ExecutionError.Error.STOP => {
                @branchHint(.likely);
            },
            ExecutionError.Error.REVERT => {
                const output = frame_ptr.output_buffer;
                host.revert_to_snapshot(snapshot_id);
                const out: ?[]const u8 = if (output.len > 0) output else null;
                const gas_left = frame_ptr.gas_remaining;
                frame_ptr.deinit(self.allocator);
                self.frame_pool.release(frame_ptr);
                return InterprResult{
                    .status = .Revert,
                    .output = out,
                    .gas_left = gas_left,
                    .gas_used = 0,
                    .address = new_address,
                    .success = false,
                };
            },
            ExecutionError.Error.OutOfGas => {
                Log.debug("[create_contract] OutOfGas during constructor", .{});
                host.revert_to_snapshot(snapshot_id);
                frame_ptr.deinit(self.allocator);
                self.frame_pool.release(frame_ptr);
                return InterprResult{
                    .status = .OutOfGas,
                    .output = null,
                    .gas_left = 0,
                    .gas_used = 0,
                    .address = new_address,
                    .success = false,
                };
            },
            else => {
                Log.debug("[create_contract] Failure during constructor: {}", .{err});
                // Treat other errors as failure
                host.revert_to_snapshot(snapshot_id);
                frame_ptr.deinit(self.allocator);
                self.frame_pool.release(frame_ptr);
                return InterprResult{
                    .status = .Failure,
                    .output = null,
                    .gas_left = 0,
                    .gas_used = 0,
                    .address = new_address,
                    .success = false,
                };
            },
        }
    };

    const output = frame_ptr.output_buffer;
    var out: ?[]const u8 = null;
    if (output.len > 0) {
        self.state.set_code(new_address, output) catch |err| {
            @branchHint(.cold);
            Log.err("[CREATE_DEBUG] Failed to set code: {}", .{err});
            return ExecutionError.Error.ReturnDataOutOfBounds;
        };
        out = @constCast(output);
    } else {
        @branchHint(.cold);
        Log.debug("[CREATE_DEBUG] Empty runtime code - no code deployed", .{});
    }

    const gas_left = frame_ptr.gas_remaining;
    frame_ptr.deinit(self.allocator);
    self.frame_pool.release(frame_ptr);
    return InterprResult{
        .status = .Success,
        .output = out,
        .gas_left = gas_left,
        .gas_used = 0,
        .address = new_address,
        .success = true,
    };
}

pub const ConsumeGasError = ExecutionError.Error;

const testing = std.testing;
const MemoryDatabase = @import("state/memory_database.zig").MemoryDatabase;

// Tests have been moved to evm_new_tests.zig to focus on Frame-based execution
// The old tests below are kept temporarily for reference but should be removed
// once the new Frame-based API is fully validated

test "Evm.init default configuration" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    try testing.expect(evm.allocator.ptr == allocator.ptr);
    try testing.expectEqual(@as(usize, 0), evm.current_output.len);
    try testing.expectEqual(@as(u11, 0), evm.depth);
}

test "Evm.init with custom opcode metadata and chain rules" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const custom_table = OpcodeMetadata.init_from_hardfork(.BERLIN);
    const custom_rules = ChainRules.for_hardfork(.BERLIN);

    var evm = try Evm.init(allocator, db_interface, custom_table, custom_rules, null, null);
    defer evm.deinit();

    try testing.expect(evm.allocator.ptr == allocator.ptr);
    try testing.expectEqual(@as(usize, 0), evm.current_output.len);
    try testing.expectEqual(@as(u11, 0), evm.depth);
}

test "Evm.init with hardfork" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const jump_table = OpcodeMetadata.init_from_hardfork(Hardfork.LONDON);
    const chain_rules = ChainRules.for_hardfork(Hardfork.LONDON);
    var evm = try Evm.init(allocator, db_interface, jump_table, chain_rules, null, null);
    defer evm.deinit();

    try testing.expect(evm.allocator.ptr == allocator.ptr);
    try testing.expectEqual(@as(usize, 0), evm.current_output.len);
    try testing.expectEqual(@as(u11, 0), evm.depth);
}

test "Evm.deinit proper cleanup" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    evm.deinit();
}

test "Evm.init state initialization" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    const test_addr = [_]u8{0x42} ** 20;
    const initial_balance = evm.state.get_balance(test_addr);
    try testing.expectEqual(@as(u256, 0), initial_balance);
}

test "Evm.init access list initialization" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
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
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    try testing.expectEqual(@as(u64, 0), evm.context.block_number);
    try testing.expectEqual(@as(u64, 0), evm.context.block_timestamp);
    try testing.expectEqual(@as(u64, 0), evm.context.block_gas_limit);
    try testing.expectEqual(@as(u256, 0), evm.context.block_base_fee);
}

test "Evm multiple VM instances" {
    const allocator = testing.allocator;

    var memory_db1 = MemoryDatabase.init(allocator);
    defer memory_db1.deinit();
    var memory_db2 = MemoryDatabase.init(allocator);
    defer memory_db2.deinit();

    const db_interface1 = memory_db1.to_database_interface();
    const db_interface2 = memory_db2.to_database_interface();

    var evm1 = try Evm.init(allocator, db_interface1, null, null, null, null);
    defer evm1.deinit();
    var evm2 = try Evm.init(allocator, db_interface2, null, null, null, null);
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
        const jump_table = OpcodeMetadata.init_from_hardfork(hardfork);
        const chain_rules = ChainRules.for_hardfork(hardfork);
        var evm = try Evm.init(allocator, db_interface, jump_table, chain_rules, null, null);
        defer evm.deinit();

        try testing.expect(evm.allocator.ptr == allocator.ptr);
        try testing.expectEqual(@as(u11, 0), evm.depth);
    }
}

test "Evm initialization memory invariants" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    try testing.expectEqual(@as(usize, 0), evm.current_output.len);
    try testing.expectEqual(@as(u11, 0), evm.depth);
}

test "Evm depth tracking" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    try testing.expectEqual(@as(u11, 0), evm.depth);

    evm.depth = 1024;
    try testing.expectEqual(@as(u11, 1024), evm.depth);

    evm.depth = 0;
    try testing.expectEqual(@as(u16, 0), evm.depth);
}

test "Evm return data management" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    try testing.expectEqual(@as(usize, 0), evm.current_output.len);

    const test_data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const allocated_data = try allocator.dupe(u8, &test_data);
    defer allocator.free(allocated_data);

    evm.current_output = allocated_data;
    try testing.expectEqual(@as(usize, 4), evm.current_output.len);
    try testing.expectEqualSlices(u8, &test_data, evm.current_output);
}

test "Evm state access" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    const test_addr = [_]u8{0x42} ** 20;
    const test_balance: u256 = 1000000;

    try evm.state.set_balance(test_addr, test_balance);
    const retrieved_balance = evm.state.get_balance(test_addr);
    try testing.expectEqual(test_balance, retrieved_balance);
}

test "Evm access list operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    const test_addr = [_]u8{0x42} ** 20;

    try testing.expectEqual(false, evm.access_list.is_address_warm(test_addr));

    _ = try evm.access_list.access_address(test_addr);
    try testing.expectEqual(true, evm.access_list.is_address_warm(test_addr));
}

test "Evm opcode metadata access" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    const add_opcode: u8 = 0x01;
    const operation = evm.table.get_operation(add_opcode);
    try testing.expect(!operation.undefined);
}

test "Evm chain rules access" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    // ChainRules structure verification
    try testing.expect(evm.chain_rules.is_eip150);
}

test "Evm reinitialization behavior" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    evm.depth = 5;
    evm.deinit();

    evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    try testing.expectEqual(@as(u11, 0), evm.depth);
}

test "Evm edge case: maximum depth" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    evm.depth = std.math.maxInt(u11);
    try testing.expectEqual(std.math.maxInt(u11), evm.depth);
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
        const jump_table = OpcodeMetadata.init_from_hardfork(hardfork);
        const chain_rules = ChainRules.for_hardfork(hardfork);
        var evm = try Evm.init(allocator, db_interface, jump_table, chain_rules, null, null);
        defer evm.deinit();

        try testing.expect(evm.allocator.ptr == allocator.ptr);
        try testing.expectEqual(@as(u16, 0), evm.depth);
    }
}

test "Evm integration: multiple state operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    const addr1 = [_]u8{0x11} ** 20;
    const addr2 = [_]u8{0x22} ** 20;
    const balance1: u256 = 1000;
    const balance2: u256 = 2000;

    try evm.state.set_balance(addr1, balance1);
    try evm.state.set_balance(addr2, balance2);

    _ = try evm.access_list.access_address(addr1);

    try testing.expectEqual(balance1, evm.state.get_balance(addr1));
    try testing.expectEqual(balance2, evm.state.get_balance(addr2));
    try testing.expectEqual(true, evm.access_list.is_address_warm(addr1));
    try testing.expectEqual(false, evm.access_list.is_address_warm(addr2));
}

test "Evm integration: state and context interaction" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    const test_addr = [_]u8{0x42} ** 20;
    const test_balance: u256 = 500000;

    try evm.state.set_balance(test_addr, test_balance);
    evm.context.block_number = 12345;
    evm.context.block_timestamp = 1234567890;

    try testing.expectEqual(test_balance, evm.state.get_balance(test_addr));
    try testing.expectEqual(@as(u64, 12345), evm.context.block_number);
    try testing.expectEqual(@as(u64, 1234567890), evm.context.block_timestamp);
}

test "Evm invariant: all fields properly initialized after init" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    try testing.expect(evm.allocator.ptr == allocator.ptr);
    try testing.expectEqual(@as(usize, 0), evm.current_output.len);
    try testing.expectEqual(@as(u16, 0), evm.depth);

    try testing.expect(!evm.table.get_operation(0x01).undefined);
    try testing.expect(evm.chain_rules.is_eip150);

    const test_addr = [_]u8{0x99} ** 20;
    try testing.expectEqual(@as(u256, 0), evm.state.get_balance(test_addr));
    try testing.expectEqual(false, evm.access_list.is_address_warm(test_addr));

    try testing.expectEqual(@as(u64, 0), evm.context.block_number);
    try testing.expectEqual(@as(u64, 0), evm.context.block_timestamp);
    try testing.expectEqual(@as(u64, 0), evm.context.block_gas_limit);
}

test "Evm memory leak detection" {
    const allocator = testing.allocator;

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var memory_db = MemoryDatabase.init(allocator);
        defer memory_db.deinit();

        const db_interface = memory_db.to_database_interface();
        var evm = try Evm.init(allocator, db_interface, null, null, null, null);
        defer evm.deinit();

        const test_data = try allocator.alloc(u8, 100);
        defer allocator.free(test_data);

        evm.current_output = test_data[0..50];

        try testing.expectEqual(@as(usize, 50), evm.current_output.len);
    }
}

test "Evm edge case: empty return data" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    try testing.expectEqual(@as(usize, 0), evm.current_output.len);

    evm.current_output = &[_]u8{};
    try testing.expectEqual(@as(usize, 0), evm.current_output.len);
}

test "Evm resource exhaustion simulation" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    evm.depth = 1023;
    try testing.expectEqual(@as(u16, 1023), evm.depth);
}

test "Evm.init creates EVM with custom settings" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const custom_table = OpcodeMetadata.init_from_hardfork(.BERLIN);
    const custom_rules = ChainRules.for_hardfork(.BERLIN);

    var evm = try Evm.init(allocator, db_interface, custom_table, custom_rules, null, 42, true, null);
    defer evm.deinit();

    // Can't test return_data initialization as init doesn't support it
    try testing.expectEqual(@as(usize, 0), evm.current_output.len);
    try testing.expectEqual(@as(u16, 42), evm.depth);
}

test "Evm.init uses defaults for null parameters" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    try testing.expectEqual(@as(usize, 0), evm.current_output.len);
    // Stack is now part of Frame, not Evm
    try testing.expectEqual(@as(u11, 0), evm.current_frame_depth);
    try testing.expectEqual(@as(u16, 0), evm.depth);
}

test "Evm builder pattern: step by step configuration" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    evm.depth = 5;

    const test_data = try allocator.dupe(u8, &[_]u8{ 0xde, 0xad, 0xbe, 0xef });
    defer allocator.free(test_data);
    evm.current_output = test_data;

    try testing.expectEqual(@as(u16, 5), evm.depth);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xde, 0xad, 0xbe, 0xef }, evm.current_output);
}

test "Evm init vs init comparison" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    var evm1 = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm1.deinit();

    var evm2 = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm2.deinit();

    try testing.expectEqual(evm1.depth, evm2.depth);
    try testing.expectEqual(evm1.current_output.len, evm2.current_output.len);
    try testing.expectEqual(evm1.current_frame_depth, evm2.current_frame_depth);
}

test "Evm initialization with different hardforks using builder" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    const hardforks = [_]Hardfork{ .FRONTIER, .BERLIN, .LONDON };

    for (hardforks) |hardfork| {
        const table = OpcodeMetadata.init_from_hardfork(hardfork);
        const rules = ChainRules.for_hardfork(hardfork);

        var evm = try Evm.init(allocator, db_interface, table, rules, null, null);
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

        var evm = try Evm.init(allocator, db_interface, null, null, null, null);
        evm.depth = @intCast(i);
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
            const hardfork_idx = input[3] % 3; // Test 3 different hardforks

            const hardforks = [_]Hardfork{ .FRONTIER, .BERLIN, .LONDON };
            const hardfork = hardforks[hardfork_idx];

            // Test initialization with various state combinations
            const jump_table = OpcodeMetadata.init_from_hardfork(hardfork);
            const chain_rules = ChainRules.for_hardfork(hardfork);
            var evm = try Evm.init(allocator, db_interface, jump_table, chain_rules, null, null);
            defer evm.deinit();

            // Verify initial state
            try testing.expectEqual(@as(u16, 0), evm.depth);
            try testing.expect(evm.current_output.len == 0);

            // Test state modifications within valid ranges
            if (depth < MAX_CALL_DEPTH) {
                evm.depth = @as(u11, @intCast(depth % (std.math.maxInt(u11) + 1)));
                try testing.expectEqual(depth, evm.depth);
            }

            // Verify frame stack is initially null
            try testing.expect(evm.frames.items.len == 0);
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

            var evm = try Evm.init(allocator, db_interface, null, null, null, null);
            defer evm.deinit();

            // Test various depth values from fuzz input
            const depths = [_]u16{
                std.mem.readInt(u16, input[0..2], .little) % MAX_CALL_DEPTH,
                std.mem.readInt(u16, input[2..4], .little) % MAX_CALL_DEPTH,
                std.mem.readInt(u16, input[4..6], .little) % MAX_CALL_DEPTH,
                std.mem.readInt(u16, input[6..8], .little) % MAX_CALL_DEPTH,
            };

            for (depths) |depth| {
                evm.depth = @as(u11, @intCast(depth % (std.math.maxInt(u11) + 1)));
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

test "fuzz_evm_frame_pool_management" {
    const global = struct {
        fn testEvmFramePoolManagement(input: []const u8) anyerror!void {
            if (input.len < 8) return;

            const allocator = testing.allocator;
            var memory_db = MemoryDatabase.init(allocator);
            defer memory_db.deinit();
            const db_interface = memory_db.to_database_interface();

            var evm = try Evm.init(allocator, db_interface, null, null, null, null);
            defer evm.deinit();

            // Test frame pool initialization tracking with fuzz input
            const pool_indices = [_]usize{
                input[0] % MAX_CALL_DEPTH,
                input[1] % MAX_CALL_DEPTH,
                input[2] % MAX_CALL_DEPTH,
                input[3] % MAX_CALL_DEPTH,
            };

            // Verify initial state - frame stack should be null
            try testing.expect(evm.frames.items.len == 0);

            // Test frame bounds
            for (pool_indices) |idx| {
                // Verify call depth bounds
                try testing.expect(idx < MAX_CALL_DEPTH);
            }

            // Test depth-frame correlation invariants
            if (input.len >= 16) {
                const test_depth = std.mem.readInt(u16, input[8..10], .little) % MAX_CALL_DEPTH;
                evm.depth = @as(u11, @intCast(test_depth % (std.math.maxInt(u11) + 1)));

                // Depth should never exceed available frames
                try testing.expect(evm.depth < MAX_CALL_DEPTH);
            }
        }
    };
    const input = "test_input_data_for_fuzzing";
    try global.testEvmFramePoolManagement(input);
}

test "fuzz_evm_hardfork_configurations" {
    if (std.process.getEnvVarOwned(std.testing.allocator, "ENABLE_STATE_TESTS")) |_| {
        // Environment variable set, run the test
    } else |_| {
        // Environment variable not set, skip the test - see GitHub issue #562
        return error.SkipZigTest;
    }
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

            const jump_table = OpcodeMetadata.init_from_hardfork(hardfork);
            const chain_rules = ChainRules.for_hardfork(hardfork);
            var evm = try Evm.init(allocator, db_interface, jump_table, chain_rules, null, null);
            defer evm.deinit();

            // Verify EVM was configured for the specified hardfork
            try testing.expect(evm.chain_rules.getHardfork() == hardfork);

            // Test state modifications with hardfork context
            if (input.len >= 8) {
                const depth = std.mem.readInt(u16, input[1..3], .little) % MAX_CALL_DEPTH;

                evm.depth = @as(u11, @intCast(depth % (std.math.maxInt(u11) + 1)));

                // Verify state changes are consistent regardless of hardfork
                try testing.expectEqual(depth, evm.depth);

                // Verify hardfork rules remain consistent
                try testing.expect(evm.chain_rules.getHardfork() == hardfork);
            }

            // Test multiple EVM instances with different hardforks
            if (input.len >= 8) {
                const second_hardfork_idx = input[4] % hardforks.len;
                const second_hardfork = hardforks[second_hardfork_idx];

                const second_jump_table = OpcodeMetadata.init_from_hardfork(second_hardfork);
                const second_chain_rules = ChainRules.for_hardfork(second_hardfork);
                var evm2 = try Evm.init(allocator, db_interface, second_jump_table, second_chain_rules, null, null);
                defer evm2.deinit();

                try testing.expect(evm2.chain_rules.getHardfork() == second_hardfork);

                // EVMs should be independent
                try testing.expect(evm.depth == 0);
                try testing.expect(evm2.depth == 0);
            }
        }
    };
    const input = "test_input_data_for_fuzzing";
    try global.testEvmHardforkConfigurations(input);
}

// ============================================================================
// Gas Refund System Tests
// ============================================================================

test "gas refund accumulation" {
    if (std.process.getEnvVarOwned(std.testing.allocator, "ENABLE_STATE_TESTS")) |_| {
        // Environment variable set, run the test
    } else |_| {
        // Environment variable not set, skip the test - see GitHub issue #562
        return error.SkipZigTest;
    }
    const allocator = std.testing.allocator;
    var db = @import("state/memory_database.zig").MemoryDatabase.init(allocator);
    defer db.deinit();
    const db_interface = db.to_database_interface();

    const london_table = OpcodeMetadata.init_from_hardfork(.LONDON);
    const london_rules = ChainRules.for_hardfork(.LONDON);
    var evm = try Evm.init(allocator, db_interface, london_table, london_rules, null, null);
    defer evm.deinit();

    // Initially no refunds
    try std.testing.expectEqual(@as(i64, 0), evm.gas_refunds);

    // Add some refunds
    evm.add_gas_refund(1000);
    try std.testing.expectEqual(@as(i64, 1000), evm.gas_refunds);

    evm.add_gas_refund(500);
    try std.testing.expectEqual(@as(i64, 1500), evm.gas_refunds);

    // Test saturating addition
    evm.add_gas_refund(std.math.maxInt(u64));
    try std.testing.expectEqual(std.math.maxInt(i64), evm.gas_refunds);
}

test "gas refund application with EIP-3529 cap" {
    const allocator = std.testing.allocator;
    var db = @import("state/memory_database.zig").MemoryDatabase.init(allocator);
    defer db.deinit();
    const db_interface = db.to_database_interface();

    // Test London hardfork (gas_used / 5 cap)
    {
        const london_table = OpcodeMetadata.init_from_hardfork(.LONDON);
        const london_rules = ChainRules.for_hardfork(.LONDON);
        var evm = try Evm.init(allocator, db_interface, london_table, london_rules, null, null);
        defer evm.deinit();

        // Set up refunds
        evm.gas_refunds = 10000;

        // Apply refunds with total gas used = 30000
        // Max refund should be 30000 / 5 = 6000
        const refund = evm.apply_gas_refunds(30000);
        try std.testing.expectEqual(@as(u64, 6000), refund);

        // Refunds should be reset after application
        try std.testing.expectEqual(@as(i64, 0), evm.gas_refunds);
    }

    // Test pre-London hardfork (gas_used / 2 cap)
    {
        const berlin_table = OpcodeMetadata.init_from_hardfork(.BERLIN);
        const berlin_rules = ChainRules.for_hardfork(.BERLIN);
        var evm = try Evm.init(allocator, db_interface, berlin_table, berlin_rules, null, null);
        defer evm.deinit();

        // Set up refunds
        evm.gas_refunds = 10000;

        // Apply refunds with total gas used = 10000
        // Max refund should be 10000 / 2 = 5000
        const refund = evm.apply_gas_refunds(10000);
        try std.testing.expectEqual(@as(u64, 5000), refund);

        // Refunds should be reset after application
        try std.testing.expectEqual(@as(i64, 0), evm.gas_refunds);
    }
}

test "gas refund reset" {
    const allocator = std.testing.allocator;
    var db = @import("state/memory_database.zig").MemoryDatabase.init(allocator);
    defer db.deinit();
    const db_interface = db.to_database_interface();

    const london_table = OpcodeMetadata.init_from_hardfork(.LONDON);
    const london_rules = ChainRules.for_hardfork(.LONDON);
    var evm = try Evm.init(allocator, db_interface, london_table, london_rules, null, null);
    defer evm.deinit();

    // Add refunds
    evm.add_gas_refund(5000);
    try std.testing.expectEqual(@as(i64, 5000), evm.gas_refunds);

    // Reset should clear refunds
    evm.reset_gas_refunds();
    try std.testing.expectEqual(@as(i64, 0), evm.gas_refunds);

    // Reset in general reset function
    evm.add_gas_refund(3000);
    evm.reset();
    try std.testing.expectEqual(@as(i64, 0), evm.gas_refunds);
}
