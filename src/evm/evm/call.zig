const std = @import("std");
const builtin = @import("builtin");
const ExecutionError = @import("../execution/execution_error.zig");
const InterpretResult = @import("interpret_result.zig").InterpretResult;
const RunResult = @import("run_result.zig").RunResult;
const Frame = @import("../frame.zig").Frame;
const ChainRules = @import("../frame.zig").ChainRules;
const AccessList = @import("../access_list.zig").AccessList;
const SelfDestruct = @import("../self_destruct.zig").SelfDestruct;
const CreatedContracts = @import("../created_contracts.zig").CreatedContracts;
const Host = @import("../host.zig").Host;
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
const CallJournal = @import("../call_frame_stack.zig").CallJournal;

// Threshold for stack vs heap allocation optimization
const STACK_ALLOCATION_THRESHOLD = 12800; // bytes of bytecode
// Maximum stack buffer size for contracts up to 12,800 bytes
const MAX_STACK_BUFFER_SIZE = 43008; // 42KB with alignment padding

// THE EVM has no actual limit on calldata. Only indirect practical limits like gas cost exist.
// 128 KB is about the limit most rpc providers limit call data to so we use it as the default
pub const MAX_INPUT_SIZE: u18 = 128 * 1024; // 128 kb

pub inline fn call(self: *Evm, params: CallParams) ExecutionError.Error!CallResult {
    const Log = @import("../log.zig");
    Log.debug("[call] Starting call execution", .{});

    // Create host interface from self
    const host = Host.init(self);
    
    // Create snapshot for nested calls early to ensure proper revert on any error
    const snapshot_id = if (self.current_frame_depth > 0) host.create_snapshot() else 0;

    // Extract call info from params - for now just handle the .call case
    // TODO: Handle other call types properly
    // Extract call information based on the call type
    var call_address: primitives.Address.Address = undefined;
    var call_code: []const u8 = undefined;
    var call_input: []const u8 = undefined;
    var call_gas: u64 = undefined;
    var call_is_static: bool = undefined;

    var call_caller: primitives.Address.Address = undefined;
    var call_value: u256 = undefined;

    switch (params) {
        .call => |call_data| {
            call_address = call_data.to;
            call_code = self.state.get_code(call_data.to);
            call_input = call_data.input;
            call_gas = call_data.gas;
            call_is_static = false;
            call_caller = call_data.caller;
            call_value = call_data.value;
            Log.debug("[call] Call params: to={any}, input_len={}, gas={}, static={}", .{ call_data.to, call_data.input.len, call_data.gas, false });
        },
        .staticcall => |call_data| {
            call_address = call_data.to;
            call_code = self.state.get_code(call_data.to);
            call_input = call_data.input;
            call_gas = call_data.gas;
            call_is_static = true;
            call_caller = call_data.caller;
            call_value = 0; // Static calls have no value transfer
            Log.debug("[call] Staticcall params: to={any}, input_len={}, gas={}, static={}, code_len={}", .{ call_data.to, call_data.input.len, call_data.gas, true, call_code.len });
        },
        else => {
            // For now, return error for unhandled call types
            Log.debug("[call] Unhandled call type", .{});
            return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
        },
    }

    const call_info = .{
        .address = call_address,
        .code = call_code,
        .code_size = call_code.len,
        .input = call_input,
        .gas = call_gas,
        .is_static = call_is_static,
    };

    // Input validation - revert snapshot on errors for nested calls
    if (call_info.input.len > MAX_INPUT_SIZE) {
        if (self.current_frame_depth > 0) host.revert_to_snapshot(snapshot_id);
        return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
    }
    if (call_info.code_size > MAX_CODE_SIZE) {
        if (self.current_frame_depth > 0) host.revert_to_snapshot(snapshot_id);
        return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
    }
    if (call_info.code_size != call_info.code.len) {
        if (self.current_frame_depth > 0) host.revert_to_snapshot(snapshot_id);
        return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
    }
    if (call_info.gas == 0) {
        if (self.current_frame_depth > 0) host.revert_to_snapshot(snapshot_id);
        return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
    }
    if (call_info.code_size > 0 and call_info.code.len == 0) {
        if (self.current_frame_depth > 0) host.revert_to_snapshot(snapshot_id);
        return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
    }

    Log.debug("[call] Code size: {}, code_len: {}", .{ call_info.code_size, call_info.code.len });

    // Use cached analysis if available, otherwise analyze and cache
    var analysis_owned = false;
    var analysis_ptr: *CodeAnalysis = if (self.analysis_cache) |*cache| blk: {
        Log.debug("[call] Using analysis cache for code analysis", .{});
        break :blk cache.getOrAnalyze(call_info.code[0..call_info.code_size], &self.table) catch |err| {
            Log.err("[call] Cached code analysis failed: {}", .{err});
            if (self.current_frame_depth > 0) host.revert_to_snapshot(snapshot_id);
            return CallResult{ .success = false, .gas_left = call_info.gas, .output = &.{} };
        };
    } else blk: {
        Log.debug("[call] No cache available, analyzing code directly", .{});
        // Fallback to direct analysis if no cache
        var analysis_val = CodeAnalysis.from_code(self.allocator, call_info.code[0..call_info.code_size], &self.table) catch |err| {
            Log.err("[call] Code analysis failed: {}", .{err});
            if (self.current_frame_depth > 0) host.revert_to_snapshot(snapshot_id);
            return CallResult{ .success = false, .gas_left = call_info.gas, .output = &.{} };
        };
        // Heap-allocate CodeAnalysis when not using cache to ensure valid lifetime
        const analysis_heap = self.allocator.create(CodeAnalysis) catch {
            analysis_val.deinit();
            if (self.current_frame_depth > 0) host.revert_to_snapshot(snapshot_id);
            return CallResult{ .success = false, .gas_left = call_info.gas, .output = &.{} };
        };
        analysis_heap.* = analysis_val;
        // Note: We must remember to deinit and destroy this after execution completes
        analysis_owned = true;
        break :blk analysis_heap;
    };

    // Don't defer deinit when using cache - cache manages lifetime
    const analysis = analysis_ptr.*;

    Log.debug("[call] Code analysis complete: {} instructions", .{analysis.instructions.len});

    // Prewarm addresses after analysis but before frame allocation
    // EIP-2929: Warm the target contract address and caller for gas optimization
    // This reduces gas costs for common access patterns
    if (self.chain_rules.is_berlin) {
        // Warm the target contract address and caller
        const addresses_to_warm = [_]primitives.Address.Address{ call_info.address, call_caller };
        self.access_list.pre_warm_addresses(&addresses_to_warm) catch |err| {
            Log.debug("[call] Failed to warm addresses: {}", .{err});
            // Non-fatal, continue execution
        };
    }

    // Handle frame allocation based on call depth
    if (self.current_frame_depth == 0) {
        // Top-level call: Initialize fresh execution state
        // Initialize fresh execution state in EVM instance (per-call isolation)
        // CRITICAL: Clear all state at beginning of top-level call
        self.current_frame_depth = 0;
        self.access_list.clear(); // Reset access list for fresh per-call state
        self.self_destruct = SelfDestruct.init(self.allocator); // Fresh self-destruct tracker
        self.created_contracts = CreatedContracts.init(self.allocator); // Fresh created contracts tracker for EIP-6780

        // MEMORY ALLOCATION: Frame stack array (preallocated to max)
        // Expected size: 1024 * sizeof(Frame) ≈ 1024 * ~500 bytes = ~512KB
        // Lifetime: Per call execution (freed after call completes)
        // Frequency: Once per top-level call
        // Growth: None - preallocated to MAX_CALL_DEPTH to prevent pointer invalidation
        if (self.frame_stack == null) {
            // Allocate frame stack with maximum capacity to avoid reallocation
            // This prevents frame pointer invalidation during nested calls
            self.frame_stack = try self.allocator.alloc(Frame, MAX_CALL_DEPTH);

            if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
                // Verify initial allocation is within expected bounds
                const frame_size = @sizeOf(Frame);
                const allocated_size = self.frame_stack.?.len * frame_size;
                // Frame is a large struct, likely 200-500 bytes
                // 1024 frames * 500 bytes = ~512KB
                std.debug.assert(allocated_size <= 1024 * 1024); // 1MB max
                std.debug.assert(self.frame_stack.?.len == MAX_CALL_DEPTH);
            }
        }

        // Initialize only the first frame now. Nested frames will be initialized on demand
        self.frame_stack.?[0] = try Frame.init(
            call_info.gas, // gas_remaining
            call_info.is_static, // static_call
            @intCast(self.depth), // call_depth
            call_info.address, // contract_address
            call_caller, // caller
            call_value, // value
            analysis_ptr, // analysis
            host,
            self.state.database,
            ChainRules{},
            &self.self_destruct,
            call_info.input, // input
            self.allocator, // use general allocator for frame-owned allocations
            false, // is_create_call
            false, // is_delegate_call
        );
        self.frame_stack.?[0].code = call_info.code;
        // Frame resources will be released after execution completes

        // Mark that we've allocated the first frame
        self.max_allocated_depth = 0;

        // Set block context from VM's context
        self.frame_stack.?[0].block_number = self.context.block_number;
        self.frame_stack.?[0].block_timestamp = self.context.block_timestamp;
        self.frame_stack.?[0].block_difficulty = self.context.block_difficulty;
        self.frame_stack.?[0].block_gas_limit = self.context.block_gas_limit;
        self.frame_stack.?[0].block_coinbase = self.context.block_coinbase;
        self.frame_stack.?[0].block_base_fee = self.context.block_base_fee;
        self.frame_stack.?[0].block_blob_base_fee = if (self.context.blob_base_fee > 0) self.context.blob_base_fee else null;
    } else {
        // Nested call: Allocate a new frame on-demand
        const new_depth = self.current_frame_depth + 1;

        // Check call depth limit
        if (new_depth >= MAX_CALL_DEPTH) {
            if (self.current_frame_depth > 0) host.revert_to_snapshot(snapshot_id);
            return CallResult{ .success = false, .gas_left = call_info.gas, .output = &.{} };
        }

        // Verify we have frame stack allocated (should always be true with MAX_CALL_DEPTH preallocation)
        if (self.frame_stack == null) {
            // Should not happen, but handle gracefully
            if (self.current_frame_depth > 0) host.revert_to_snapshot(snapshot_id);
            return CallResult{ .success = false, .gas_left = call_info.gas, .output = &.{} };
        }


        // Initialize the new frame
        const parent_frame = &self.frame_stack.?[self.current_frame_depth];
        const parent_stack_ptr_before: usize = @intFromPtr(parent_frame.stack);
        const parent_stack_base_before: usize = @intFromPtr(parent_frame.stack.base);
        const parent_stack_limit_before: usize = @intFromPtr(parent_frame.stack.limit);
        const parent_stack_current_before: usize = @intFromPtr(parent_frame.stack.current);
        
        if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            // Basic invariants on parent frame before child init
            std.debug.assert(parent_stack_base_before != 0);
            std.debug.assert(parent_stack_limit_before != 0);
            std.debug.assert(parent_stack_current_before >= parent_stack_base_before);
            std.debug.assert(parent_stack_current_before <= parent_stack_limit_before);
        }
        self.frame_stack.?[new_depth] = Frame.init(
            call_info.gas, // gas_remaining
            call_info.is_static or parent_frame.is_static, // inherit static context
            @intCast(new_depth), // call_depth
            call_info.address, // contract_address
            call_caller, // caller
            call_value, // value
            analysis_ptr, // analysis
            host,
            self.state.database,
            ChainRules{},
            &self.self_destruct,
            call_info.input, // input
            self.allocator, // use general allocator for frame-owned allocations
            false, // is_create_call
            false, // is_delegate_call
        ) catch {
            // Frame initialization failed, revert snapshot
            if (self.current_frame_depth > 0) host.revert_to_snapshot(snapshot_id);
            return CallResult{ .success = false, .gas_left = call_info.gas, .output = &.{} };
        };
        self.frame_stack.?[new_depth].code = call_info.code;

        // Update tracking
        self.current_frame_depth = new_depth;
        if (new_depth > self.max_allocated_depth) {
            self.max_allocated_depth = new_depth;
        }

        if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            // Verify parent frame stack pointers did not change after child init
            std.debug.assert(@intFromPtr(parent_frame.stack) == parent_stack_ptr_before);
            std.debug.assert(@intFromPtr(parent_frame.stack.base) == parent_stack_base_before);
            std.debug.assert(@intFromPtr(parent_frame.stack.limit) == parent_stack_limit_before);
            std.debug.assert(@intFromPtr(parent_frame.stack.current) == parent_stack_current_before);
            // Verify child has a distinct stack object
            std.debug.assert(@intFromPtr(self.frame_stack.?[new_depth].stack) != parent_stack_ptr_before);
        }

        // Copy block context from parent frame
        self.frame_stack.?[new_depth].block_number = parent_frame.block_number;
        self.frame_stack.?[new_depth].block_timestamp = parent_frame.block_timestamp;
        self.frame_stack.?[new_depth].block_difficulty = parent_frame.block_difficulty;
        self.frame_stack.?[new_depth].block_gas_limit = parent_frame.block_gas_limit;
        self.frame_stack.?[new_depth].block_coinbase = parent_frame.block_coinbase;
        self.frame_stack.?[new_depth].block_base_fee = parent_frame.block_base_fee;
        self.frame_stack.?[new_depth].block_blob_base_fee = parent_frame.block_blob_base_fee;
    }

    if (precompile_addresses.get_precompile_id_checked(call_info.address)) |precompile_id| {
        const precompile_result = self.execute_precompile_call_by_id(precompile_id, call_info.input, call_info.gas, call_info.is_static) catch |err| {
            // Revert snapshot on precompile failure for nested calls
            if (self.current_frame_depth > 0) host.revert_to_snapshot(snapshot_id);
            return switch (err) {
                else => CallResult{ .success = false, .gas_left = 0, .output = &.{} },
            };
        };

        // For nested calls, check if precompile failed and revert if needed
        if (self.current_frame_depth > 0 and !precompile_result.success) {
            host.revert_to_snapshot(snapshot_id);
        }

        return precompile_result;
    }

    const current_frame = &self.frame_stack.?[self.current_frame_depth];
    Log.debug("[call] Starting interpret at depth {}, gas={}", .{ self.current_frame_depth, current_frame.gas_remaining });

    // For nested calls, capture parent pointers before interpret
    var parent_stack_ptr_before_interpret: usize = 0;
    var parent_stack_base_before_interpret: usize = 0;
    var parent_stack_limit_before_interpret: usize = 0;
    var parent_stack_current_before_interpret: usize = 0;
    
    if (self.current_frame_depth > 0) {
        const parent = &self.frame_stack.?[self.current_frame_depth - 1];
        parent_stack_ptr_before_interpret = @intFromPtr(parent.stack);
        parent_stack_base_before_interpret = @intFromPtr(parent.stack.base);
        parent_stack_limit_before_interpret = @intFromPtr(parent.stack.limit);
        parent_stack_current_before_interpret = @intFromPtr(parent.stack.current);
        
        if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            // Verify parent invariants before interpret
            std.debug.assert(parent_stack_base_before_interpret != 0);
            std.debug.assert(parent_stack_limit_before_interpret != 0);
            std.debug.assert(parent_stack_current_before_interpret >= parent_stack_base_before_interpret);
            std.debug.assert(parent_stack_current_before_interpret <= parent_stack_limit_before_interpret);
        }
    }

    // Execute and normalize result handling so we can always clean up the frame
    var exec_err: ?ExecutionError.Error = null;
    interpret(self, current_frame) catch |err| {
        Log.debug("[call] Interpret ended with error: {}", .{err});
        exec_err = err;
    };
    
    // For nested calls, verify parent pointers after interpret
    if (self.current_frame_depth > 0) {
        const parent = &self.frame_stack.?[self.current_frame_depth - 1];
        
        if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            // Verify parent frame was not corrupted during interpret
            std.debug.assert(@intFromPtr(parent.stack) == parent_stack_ptr_before_interpret);
            std.debug.assert(@intFromPtr(parent.stack.base) == parent_stack_base_before_interpret);
            std.debug.assert(@intFromPtr(parent.stack.limit) == parent_stack_limit_before_interpret);
            std.debug.assert(@intFromPtr(parent.stack.current) == parent_stack_current_before_interpret);
        }
    }

    // Handle snapshot revert for failed nested calls
    if (self.current_frame_depth > 0 and exec_err != null) {
        const should_revert = switch (exec_err.?) {
            ExecutionError.Error.STOP => false,
            else => true,
        };
        if (should_revert) {
            host.revert_to_snapshot(snapshot_id);
        }
    }

    // Copy output before frame cleanup
    var output: []const u8 = &.{};
    const host_output = host.get_output();
    if (host_output.len > 0) {
        output = self.allocator.dupe(u8, host_output) catch &.{};
        Log.debug("[call] Output length: {}", .{output.len});
    }

    // Save gas remaining for return
    const gas_remaining = current_frame.gas_remaining;

    // For nested calls, capture parent pointers before deinit
    var parent_stack_ptr_before_deinit: usize = 0;
    var parent_stack_base_before_deinit: usize = 0;
    var parent_stack_limit_before_deinit: usize = 0;
    var parent_stack_current_before_deinit: usize = 0;
    
    if (self.current_frame_depth > 0) {
        const parent = &self.frame_stack.?[self.current_frame_depth - 1];
        parent_stack_ptr_before_deinit = @intFromPtr(parent.stack);
        parent_stack_base_before_deinit = @intFromPtr(parent.stack.base);
        parent_stack_limit_before_deinit = @intFromPtr(parent.stack.limit);
        parent_stack_current_before_deinit = @intFromPtr(parent.stack.current);
    }

    // Release frame resources
    current_frame.deinit();
    
    // For nested calls, verify parent pointers after deinit
    if (self.current_frame_depth > 0) {
        const parent = &self.frame_stack.?[self.current_frame_depth - 1];
        
        if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            // Verify parent frame was not corrupted during child deinit
            std.debug.assert(@intFromPtr(parent.stack) == parent_stack_ptr_before_deinit);
            std.debug.assert(@intFromPtr(parent.stack.base) == parent_stack_base_before_deinit);
            std.debug.assert(@intFromPtr(parent.stack.limit) == parent_stack_limit_before_deinit);
            std.debug.assert(@intFromPtr(parent.stack.current) == parent_stack_current_before_deinit);
        }
    }

    // Restore parent frame depth (or stay at 0 if top-level)
    if (self.current_frame_depth > 0) {
        self.current_frame_depth -= 1;
    }

    // Clean up analysis if we allocated it locally (no cache)
    if (analysis_owned) {
        analysis_ptr.deinit();
        self.allocator.destroy(analysis_ptr);
    }

    // Map error to success status
    const success: bool = if (exec_err) |e| switch (e) {
        ExecutionError.Error.STOP => true,
        ExecutionError.Error.REVERT => false,
        ExecutionError.Error.OutOfGas => false,
        else => false,
    } else true;

    Log.debug("[call] Returning with success={}, gas_left={}, output_len={}", .{ success, gas_remaining, output.len });
    return CallResult{
        .success = success,
        .gas_left = gas_remaining,
        .output = output,
    };
}

test "nested call snapshot revert on input validation failure" {
    const allocator = std.testing.allocator;
    const MemoryDatabase = @import("../state/memory_database.zig");
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");

    // Setup database and EVM
    var memory_db = try MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const jump_table = OpcodeMetadata.DEFAULT;
    const chain_rules = ChainRules{ .is_berlin = true };
    var evm = try Evm.init(allocator, db_interface, jump_table, chain_rules, null, 0, false, null);
    defer evm.deinit();

    // Setup a contract with simple code
    const code = [_]u8{0x00}; // STOP
    const addr = primitives.Address.ZERO_ADDRESS;
    try memory_db.set_code(addr, &code);

    // Simulate being in a nested call
    evm.current_frame_depth = 1;

    // Create an oversized input that should fail validation
    const oversized_input = try allocator.alloc(u8, MAX_INPUT_SIZE + 1);
    defer allocator.free(oversized_input);
    @memset(oversized_input, 0xAA);

    // Take initial snapshot count
    const initial_snapshot_count = evm.journal.next_snapshot_id;

    // Make nested call with oversized input
    const nested_call = CallParams{ .call = .{
        .to = addr,
        .caller = addr,
        .input = oversized_input,
        .value = 0,
        .gas = 50000,
    } };

    const result = try evm.call(nested_call);

    // Verify call failed
    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(u64, 0), result.gas_left);

    // Verify snapshot was created and reverted (next_snapshot_id should be unchanged)
    try std.testing.expectEqual(initial_snapshot_count, evm.journal.next_snapshot_id);
}

test "nested call snapshot revert on code analysis failure" {
    const allocator = std.testing.allocator;
    const MemoryDatabase = @import("../state/memory_database.zig");
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");

    // Setup database and EVM
    var memory_db = try MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const jump_table = OpcodeMetadata.DEFAULT;
    const chain_rules = ChainRules{ .is_berlin = true };
    var evm = try Evm.init(allocator, db_interface, jump_table, chain_rules, null, 0, false, null);
    defer evm.deinit();

    // Setup a contract with oversized code
    const oversized_code = try allocator.alloc(u8, MAX_CODE_SIZE + 1);
    defer allocator.free(oversized_code);
    @memset(oversized_code, 0x00);

    const addr = primitives.Address.ZERO_ADDRESS;
    try memory_db.set_code(addr, oversized_code);

    evm.current_frame_depth = 1; // Simulate being in a nested call

    // Take initial snapshot count
    const initial_snapshot_count = evm.journal.next_snapshot_id;

    // Make nested call that should fail due to code size
    const nested_call = CallParams{ .call = .{
        .to = addr,
        .caller = addr,
        .input = &.{},
        .value = 0,
        .gas = 50000,
    } };

    const result = try evm.call(nested_call);

    // Verify call failed
    try std.testing.expect(!result.success);

    // Verify snapshot was properly handled
    try std.testing.expectEqual(initial_snapshot_count, evm.journal.next_snapshot_id);
}

test "nested call snapshot revert on max depth exceeded" {
    const allocator = std.testing.allocator;
    const MemoryDatabase = @import("../state/memory_database.zig");
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");

    // Setup database and EVM
    var memory_db = try MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const jump_table = OpcodeMetadata.DEFAULT;
    const chain_rules = ChainRules{ .is_berlin = true };
    var evm = try Evm.init(allocator, db_interface, jump_table, chain_rules, null, 0, false, null);
    defer evm.deinit();

    // Setup a simple contract
    const code = [_]u8{0x00}; // STOP
    const addr = primitives.Address.ZERO_ADDRESS;
    try memory_db.set_code(addr, &code);

    // Set depth to just below max
    evm.current_frame_depth = MAX_CALL_DEPTH - 1;

    // Allocate frame stack
    evm.frame_stack = try allocator.alloc(Frame, MAX_CALL_DEPTH);
    defer allocator.free(evm.frame_stack.?);

    // Take initial snapshot count
    const initial_snapshot_count = evm.journal.next_snapshot_id;

    // Make nested call that should fail due to depth limit
    const nested_call = CallParams{ .call = .{
        .to = addr,
        .caller = addr,
        .input = &.{},
        .value = 0,
        .gas = 50000,
    } };

    const result = try evm.call(nested_call);

    // Verify call failed
    try std.testing.expect(!result.success);

    // Verify snapshot was properly handled
    try std.testing.expectEqual(initial_snapshot_count, evm.journal.next_snapshot_id);
}

test "address prewarming for Berlin hardfork" {
    const allocator = std.testing.allocator;
    const MemoryDatabase = @import("../state/memory_database.zig");
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");

    // Setup database and EVM with Berlin rules
    var memory_db = try MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const jump_table = OpcodeMetadata.DEFAULT;
    const chain_rules = ChainRules{ .is_berlin = true };
    var evm = try Evm.init(allocator, db_interface, jump_table, chain_rules, null, 0, false, null);
    defer evm.deinit();

    // Setup contracts
    const code = [_]u8{0x00}; // STOP
    const contract_addr = [_]u8{0x11} ** 20;
    const caller_addr = [_]u8{0x22} ** 20;
    try memory_db.set_code(contract_addr, &code);

    // Clear access list to ensure clean state
    evm.access_list.clear();

    // Make call
    const call_params = CallParams{ .call = .{
        .to = contract_addr,
        .caller = caller_addr,
        .input = &.{},
        .value = 0,
        .gas = 100000,
    } };

    _ = try evm.call(call_params);

    // Verify both addresses were warmed
    try std.testing.expect(evm.access_list.is_address_warm(contract_addr));
    try std.testing.expect(evm.access_list.is_address_warm(caller_addr));
}

test "no address prewarming for pre-Berlin hardfork" {
    const allocator = std.testing.allocator;
    const MemoryDatabase = @import("../state/memory_database.zig");
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");

    // Setup database and EVM without Berlin rules
    var memory_db = try MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const jump_table = OpcodeMetadata.DEFAULT;
    const chain_rules = ChainRules{ .is_berlin = false };
    var evm = try Evm.init(allocator, db_interface, jump_table, chain_rules, null, 0, false, null);
    defer evm.deinit();

    // Setup contracts
    const code = [_]u8{0x00}; // STOP
    const contract_addr = [_]u8{0x11} ** 20;
    const caller_addr = [_]u8{0x22} ** 20;
    try memory_db.set_code(contract_addr, &code);

    // Clear access list to ensure clean state
    evm.access_list.clear();

    // Make call
    const call_params = CallParams{ .call = .{
        .to = contract_addr,
        .caller = caller_addr,
        .input = &.{},
        .value = 0,
        .gas = 100000,
    } };

    _ = try evm.call(call_params);

    // Verify addresses were NOT warmed (pre-Berlin behavior)
    try std.testing.expect(!evm.access_list.is_address_warm(contract_addr));
    try std.testing.expect(!evm.access_list.is_address_warm(caller_addr));
}
