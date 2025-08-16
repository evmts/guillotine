const std = @import("std");
const builtin = @import("builtin");
const ExecutionError = @import("../execution/execution_error.zig");
const InterpretResult = @import("interpret_result.zig").InterpretResult;
const RunResult = @import("run_result.zig").RunResult;
const Frame = @import("../frame.zig").Frame;
const ChainRules = @import("../hardforks/chain_rules.zig").ChainRules;
const AccessList = @import("../access_list.zig").AccessList;
const SelfDestruct = @import("../self_destruct.zig").SelfDestruct;
const CreatedContracts = @import("../created_contracts.zig").CreatedContracts;
const Host = @import("../host.zig").Host;
const CodeAnalysis = @import("../analysis.zig").CodeAnalysis;
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
const Account = @import("../state/database_interface.zig").Account;

// Threshold for stack vs heap allocation optimization
const STACK_ALLOCATION_THRESHOLD = 12800; // bytes of bytecode
// Maximum stack buffer size for contracts up to 12,800 bytes
const MAX_STACK_BUFFER_SIZE = 43008; // 42KB with alignment padding

// THE EVM has no actual limit on calldata. Only indirect practical limits like gas cost exist.
// 128 KB is about the limit most rpc providers limit call data to so we use it as the default
pub const MAX_INPUT_SIZE: u18 = 128 * 1024; // 128 kb

pub fn call(self: *Evm, params: CallParams) ExecutionError.Error!CallResult {
    const Log = @import("../log.zig");
    Log.debug("[call] Starting call execution, is_executing={}, has_tracer={}, self_ptr=0x{x}, frame_depth={}", .{ self.is_currently_executing(), self.tracer != null, @intFromPtr(self), self.current_frame_depth });

    // Debug: log the call parameters to understand what's being called
    switch (params) {
        .call => |c| {
            Log.debug("[call] CALL params: to={any}, gas={}, input_len={}", .{ c.to, c.gas, c.input.len });
        },
        .staticcall => |c| {
            Log.debug("[call] STATICCALL params: to={any}, gas={}, input_len={}", .{ c.to, c.gas, c.input.len });
        },
        .delegatecall => |c| {
            Log.debug("[call] DELEGATECALL params: to={any}, gas={}, input_len={}", .{ c.to, c.gas, c.input.len });
        },
        else => {},
    }

    // Create host interface from self
    const host = Host.init(self);

    // Determine if this is a top-level call using frame depth
    // Frame depth of 0 means top-level, regardless of is_executing flag
    const is_top_level_call = self.current_frame_depth == 0;
    Log.debug("[call] is_top_level_call={}, is_executing={}, current_frame_depth={}", .{ is_top_level_call, self.is_currently_executing(), self.current_frame_depth });
    Log.debug("[call] current_output.len at start={}", .{self.current_output.len});
    // Create snapshot for nested calls early to ensure proper revert on any error
    const snapshot_id = if (!is_top_level_call) host.create_snapshot() else 0;

    // Extract call info from params - for now just handle the .call case
    // TODO: Handle other call types properly
    // Extract call information based on the call type
    var call_address: primitives.Address.Address = undefined;
    var call_code: []const u8 = undefined;
    var call_input: []const u8 = undefined;
    var call_gas: u64 = undefined;
    var call_is_static: bool = undefined;
    var is_delegatecall: bool = false;
    var is_create: bool = false;
    var is_create2: bool = false;
    var create2_salt: u256 = 0;

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
        .delegatecall => |dc| {
            // Execute code at `to` but in the context (address/storage) of the current contract
            call_address = dc.to;
            call_code = self.state.get_code(dc.to);
            call_input = dc.input;
            call_gas = dc.gas;
            call_is_static = false; // inherit static below for nested frames
            call_caller = dc.caller; // original caller preserved by opcode layer
            call_value = 0; // will be overridden from parent frame for nested execution
            is_delegatecall = true;
            Log.debug("[call] Delegatecall params: to={any}, input_len={}, gas={} ", .{ dc.to, dc.input.len, dc.gas });
        },
        .create => |cr| {
            // Handle CREATE via dedicated path
            is_create = true;
            call_gas = cr.gas;
            call_caller = cr.caller;
            call_value = cr.value;
            call_input = cr.init_code; // reuse variable for initcode
        },
        .create2 => |cr2| {
            // Handle CREATE2 via dedicated path
            is_create2 = true;
            call_gas = cr2.gas;
            call_caller = cr2.caller;
            call_value = cr2.value;
            call_input = cr2.init_code; // reuse variable for initcode
            create2_salt = cr2.salt;
        },
        else => {
            // For now, return error for unhandled call types
            Log.debug("[call] Unhandled call type", .{});
            return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
        },
    }

    // Fast-path: CREATE/CREATE2 handled through create_contract()
    if (is_create or is_create2) {
        Log.debug("[call] CREATE/CREATE2 path: is_create2={}, self_ptr=0x{x}, has_tracer={}", .{ is_create2, @intFromPtr(self), self.tracer != null });
        // Execute constructor and deploy runtime code
        const create_res = blk: {
            if (is_create2) {
                const new_addr = self.compute_create2_address(call_caller, create2_salt, call_input);
                // CREATE2 also needs to increment the nonce of the creator
                _ = try self.state.increment_nonce(call_caller);
                Log.debug("[call] About to call create_contract_at, self_ptr=0x{x}, has_tracer={}", .{ @intFromPtr(self), self.tracer != null });
                break :blk try self.create_contract_at(call_caller, call_value, call_input, call_gas, new_addr);
            } else {
                break :blk try self.create_contract(call_caller, call_value, call_input, call_gas);
            }
        };

        // On success, return address bytes as output (20 bytes)
        if (create_res.success) {
            const addr_buf = try self.allocator.alloc(u8, 20);
            @memcpy(addr_buf, &create_res.address);
            return CallResult{
                .success = true,
                .gas_left = create_res.gas_left,
                .output = addr_buf,
            };
        }

        // On revert/failure, propagate revert data if any
        return CallResult{
            .success = false,
            .gas_left = create_res.gas_left,
            .output = create_res.output,
        };
    }

    // For top-level calls, charge the base transaction cost
    var remaining_gas = call_gas;
    if (is_top_level_call) {
        const GasConstants = @import("primitives").GasConstants;
        const base_cost = GasConstants.TxGas;

        Log.debug("[call] Top-level call detected, charging base cost: {}", .{base_cost});

        // Check if we have enough gas for the base cost
        if (remaining_gas < base_cost) {
            Log.debug("[call] Insufficient gas for base transaction cost: {} < {}", .{ remaining_gas, base_cost });
            return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
        }

        remaining_gas -= base_cost;
        Log.debug("[call] Charged base transaction cost: {}, remaining: {}", .{ base_cost, remaining_gas });
    } else {
        Log.debug("[call] Nested call, no base cost charged", .{});
    }

    const call_info = .{
        .address = call_address,
        .code = call_code,
        .code_size = call_code.len,
        .input = call_input,
        .gas = remaining_gas,
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
    if (is_top_level_call) {
        // Top-level call: Initialize fresh execution state
        // Initialize fresh execution state in EVM instance (per-call isolation)
        // CRITICAL: Clear all state at beginning of top-level call
        self.current_frame_depth = 0;
        self.access_list.clear(); // Reset access list for fresh per-call state

        // Clean up old self-destruct tracker and create new one
        self.self_destruct.deinit();
        self.self_destruct = SelfDestruct.init(self.allocator);

        // Clean up old created contracts tracker and create new one
        self.created_contracts.deinit();
        self.created_contracts = CreatedContracts.init(self.allocator);

        Log.debug("[call] Clearing current_output for top-level call (was {})", .{self.current_output.len});
        self.current_output = &.{}; // Clear output buffer from previous calls

        // Clear owned output buffer to avoid double-free issues
        if (self.owned_output) |buf| {
            self.allocator.free(buf);
            self.owned_output = null;
        }

        // MEMORY ALLOCATION: Frame stack array (preallocated to max)
        // Expected size: 1024 * sizeof(Frame) ≈ 1024 * ~500 bytes = ~512KB
        // Lifetime: Per call execution (freed after call completes)
        // Frequency: Once per top-level call
        // Growth: None - preallocated to MAX_CALL_DEPTH to prevent pointer invalidation
        if (self.frame_stack == null) {
            // Allocate frame stack with maximum capacity to avoid reallocation
            // This prevents frame pointer invalidation during nested calls
            self.frame_stack = try std.heap.page_allocator.alloc(Frame, MAX_CALL_DEPTH);

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
        // Top-level delegatecall is unusual, but if it occurs, run code at target with current address context
        const contract_addr_for_frame = if (is_delegatecall) call_caller else call_info.address;
        self.frame_stack.?[0] = try Frame.init(
            call_info.gas, // gas_remaining
            call_info.is_static, // static_call
            @intCast(self.depth), // call_depth
            contract_addr_for_frame, // contract_address context
            call_caller, // caller
            call_value, // value
            analysis_ptr, // analysis
            host,
            self.state.database,
            self.allocator, // allocator for frame-owned allocations
        );
        // Code is already handled through the CodeAnalysis passed to Frame.init
        // Frame resources will be released after execution completes

        // Mark that we've allocated the first frame
        self.max_allocated_depth = 0;

        // Block context is now accessed via Host interface, no need to set
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
        const parent_stack_ptr_before: usize = @intFromPtr(&parent_frame.stack);
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
        // For DELEGATECALL: execute at parent's contract address, not target address
        const nested_contract_addr = if (is_delegatecall) parent_frame.contract_address else call_info.address;
        const nested_value: u256 = if (is_delegatecall) parent_frame.value else call_value;
        self.frame_stack.?[new_depth] = Frame.init(
            call_info.gas, // gas_remaining
            call_info.is_static or parent_frame.is_static, // inherit static context
            @intCast(new_depth), // call_depth
            nested_contract_addr, // contract_address
            call_caller, // caller (original for delegatecall)
            nested_value, // value (inherit for delegatecall)
            analysis_ptr, // analysis
            host,
            self.state.database,
            self.allocator, // allocator for frame-owned allocations
        ) catch {
            // Frame initialization failed, revert snapshot
            if (self.current_frame_depth > 0) host.revert_to_snapshot(snapshot_id);
            return CallResult{ .success = false, .gas_left = call_info.gas, .output = &.{} };
        };
        // Code is already handled through the CodeAnalysis passed to Frame.init

        // Update tracking
        self.current_frame_depth = new_depth;
        if (new_depth > self.max_allocated_depth) {
            self.max_allocated_depth = new_depth;
        }

        if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            // Verify parent frame stack pointers did not change after child init
            std.debug.assert(@intFromPtr(&parent_frame.stack) == parent_stack_ptr_before);
            std.debug.assert(@intFromPtr(parent_frame.stack.base) == parent_stack_base_before);
            std.debug.assert(@intFromPtr(parent_frame.stack.limit) == parent_stack_limit_before);
            std.debug.assert(@intFromPtr(parent_frame.stack.current) == parent_stack_current_before);
            // Verify child has a distinct stack object
            std.debug.assert(@intFromPtr(&self.frame_stack.?[new_depth].stack) != parent_stack_ptr_before);
        }

        // Block context is now accessed via Host interface, no need to copy
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
    // Expose input to Host via current frame buffer
    current_frame.input_buffer = call_info.input;
    Log.debug("[call] Starting interpret at depth {}, gas={}", .{ self.current_frame_depth, current_frame.gas_remaining });

    // For nested calls, capture parent pointers before interpret
    var parent_stack_ptr_before_interpret: usize = 0;
    var parent_stack_base_before_interpret: usize = 0;
    var parent_stack_limit_before_interpret: usize = 0;
    var parent_stack_current_before_interpret: usize = 0;

    if (!is_top_level_call) {
        const parent = &self.frame_stack.?[self.current_frame_depth - 1];
        parent_stack_ptr_before_interpret = @intFromPtr(&parent.stack);
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
    // Mark executing to enable nested-call behavior
    const was_executing = self.is_currently_executing();
    self.set_is_executing(true);
    interpret(self, current_frame) catch |err| {
        Log.warn("[call] Interpret ended with error: {}", .{err});
        exec_err = err;

        // CRITICAL DEBUG: Log specific errors that should stop execution
        if (err == ExecutionError.Error.STOP) {
            Log.warn("[call] STOP signaled (normal termination)", .{});
        } else if (err == ExecutionError.Error.RETURN) {
            Log.warn("[call] RETURN signaled (normal termination with data)", .{});
        } else if (err == ExecutionError.Error.REVERT) {
            Log.warn("[call] REVERT signaled", .{});
        } else if (err == ExecutionError.Error.OutOfGas) {
            Log.warn("[call] OutOfGas signaled", .{});
        }
    };
    // Restore executing flag
    self.set_is_executing(was_executing);

    // For nested calls, verify parent pointers after interpret
    if (!is_top_level_call) {
        const parent = &self.frame_stack.?[self.current_frame_depth - 1];

        if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            // Verify parent frame was not corrupted during interpret
            std.debug.assert(@intFromPtr(&parent.stack) == parent_stack_ptr_before_interpret);
            std.debug.assert(@intFromPtr(parent.stack.base) == parent_stack_base_before_interpret);
            std.debug.assert(@intFromPtr(parent.stack.limit) == parent_stack_limit_before_interpret);
            std.debug.assert(@intFromPtr(parent.stack.current) == parent_stack_current_before_interpret);
        }
    }

    // Handle snapshot revert for failed nested calls
    if (!is_top_level_call and exec_err != null) {
        const should_revert = switch (exec_err.?) {
            ExecutionError.Error.STOP => false,
            ExecutionError.Error.RETURN => false,
            else => true,
        };
        if (should_revert) {
            host.revert_to_snapshot(snapshot_id);
        }
    }

    // Get output from the host (where RETURN stores it via set_output)
    Log.debug("[call] About to get output, current_frame_depth={}, frame_stack={}", .{ self.current_frame_depth, self.frame_stack != null });
    if (self.frame_stack) |frames| {
        if (self.current_frame_depth < frames.len) {
            Log.debug("[call] Frame output_buffer before get: len={}", .{frames[self.current_frame_depth].output_buffer.len});
        }
    }
    const output: []const u8 = host.get_output();
    Log.debug("[call] Getting output: host.get_output().len={}, self.current_output.len={}, frame_depth={}", .{ output.len, self.current_output.len, self.current_frame_depth });
    if (output.len > 0 and output.len <= 32) {
        Log.debug("[call] Output data: {x}", .{std.fmt.fmtSliceHexLower(output)});
    }
    if (output.len == 0 and is_top_level_call) {
        Log.warn("[call] Top-level call returned empty output (code_len={}, input_len={}, exec_err={?})", .{ call_info.code_size, call_info.input.len, exec_err });
    }

    // Save gas remaining for return
    const gas_remaining = current_frame.gas_remaining;

    // For nested calls, capture parent pointers before deinit
    var parent_stack_ptr_before_deinit: usize = 0;
    var parent_stack_base_before_deinit: usize = 0;
    var parent_stack_limit_before_deinit: usize = 0;
    var parent_stack_current_before_deinit: usize = 0;

    if (!is_top_level_call) {
        const parent = &self.frame_stack.?[self.current_frame_depth - 1];
        parent_stack_ptr_before_deinit = @intFromPtr(&parent.stack);
        parent_stack_base_before_deinit = @intFromPtr(parent.stack.base);
        parent_stack_limit_before_deinit = @intFromPtr(parent.stack.limit);
        parent_stack_current_before_deinit = @intFromPtr(parent.stack.current);
    }

    // Release frame resources
    current_frame.deinit(self.allocator);

    // For nested calls, verify parent pointers after deinit
    if (self.current_frame_depth > 0) {
        const parent = &self.frame_stack.?[self.current_frame_depth - 1];

        if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            // Verify parent frame was not corrupted during child deinit
            std.debug.assert(@intFromPtr(&parent.stack) == parent_stack_ptr_before_deinit);
            std.debug.assert(@intFromPtr(parent.stack.base) == parent_stack_base_before_deinit);
            std.debug.assert(@intFromPtr(parent.stack.limit) == parent_stack_limit_before_deinit);
            std.debug.assert(@intFromPtr(parent.stack.current) == parent_stack_current_before_deinit);
        }
    }

    // Restore parent frame depth (or stay at 0 if top-level)
    if (!is_top_level_call) {
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
        ExecutionError.Error.RETURN => true,
        ExecutionError.Error.REVERT => false,
        ExecutionError.Error.OutOfGas => false,
        else => false,
    } else true;

    Log.debug("[call] Returning with success={}, gas_left={}, output_len={}", .{ success, gas_remaining, output.len });
    if (!success) {
        Log.debug("[call] Call failed with error: {?}", .{exec_err});
    }
    // Return VM-owned view; callers must not free
    const out_opt: ?[]const u8 = if (output.len > 0) output else null;
    return CallResult{
        .success = success,
        .gas_left = gas_remaining,
        .output = out_opt,
    };
}

/// Simplified EVM execution without analysis - performs lazy jumpdest validation
/// This is a simpler alternative to the analysis-based approach used in call()
pub const call_mini = @import("call_mini.zig").call_mini;
test "nested call snapshot revert on input validation failure" {
    const allocator = std.testing.allocator;
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");

    // Setup database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const jump_table = OpcodeMetadata.DEFAULT;
    const chain_rules = ChainRules{ .is_berlin = true };
    var evm = try Evm.init(allocator, db_interface, jump_table, chain_rules, null, 0, false, null);
    defer evm.deinit();

    // Setup a contract with simple code
    const code = [_]u8{0x00}; // STOP
    const addr = primitives.Address.ZERO_ADDRESS;
    _ = try memory_db.set_code(&code);

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
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");

    // Setup database and EVM
    var memory_db = MemoryDatabase.init(allocator);
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
    const code_hash = try memory_db.set_code(oversized_code);

    // Create an account with this code hash
    var account = Account.zero();
    account.code_hash = code_hash;
    try memory_db.set_account(addr, account);

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
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");

    // Setup database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const jump_table = OpcodeMetadata.DEFAULT;
    const chain_rules = ChainRules{ .is_berlin = true };
    var evm = try Evm.init(allocator, db_interface, jump_table, chain_rules, null, 0, false, null);
    defer evm.deinit();

    // Setup a simple contract
    const code = [_]u8{0x00}; // STOP
    const addr = primitives.Address.ZERO_ADDRESS;
    _ = try memory_db.set_code(&code);

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
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");

    // Setup database and EVM with Berlin rules
    var memory_db = MemoryDatabase.init(allocator);
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
    const code_hash_berlin = try memory_db.set_code(&code);
    var account_berlin = Account.zero();
    account_berlin.code_hash = code_hash_berlin;
    try memory_db.set_account(contract_addr, account_berlin);

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
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");

    // Setup database and EVM without Berlin rules
    var memory_db = MemoryDatabase.init(allocator);
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
    const code_hash_non_berlin = try memory_db.set_code(&code);
    var account_non_berlin = Account.zero();
    account_non_berlin.code_hash = code_hash_non_berlin;
    try memory_db.set_account(contract_addr, account_non_berlin);

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

test "top-level call: minimal selector dispatcher returns 32-byte value" {
    const allocator = std.testing.allocator;
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");

    // Setup database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const jump_table = OpcodeMetadata.DEFAULT;
    const chain_rules = ChainRules{ .is_berlin = true };
    var evm = try Evm.init(allocator, db_interface, jump_table, chain_rules, null, 0, false, null);
    defer evm.deinit();

    // Minimal dispatcher runtime:
    // selector 0x11223344 -> returns 32-byte 0x01; else REVERT
    const runtime = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x35, // CALLDATALOAD
        0x60, 0xe0, // PUSH1 0xe0
        0x1c, // SHR
        0x63, 0x11, 0x22, 0x33, 0x44, // PUSH4 0x11223344
        0x14, // EQ
        0x60, 0x16, // PUSH1 0x16 (dest)
        0x57, // JUMPI
        0x60, 0x00, // PUSH1 0x00 (fallback: revert)
        0x60, 0x00, // PUSH1 0x00
        0xfd, // REVERT
        0x5b, // JUMPDEST (0x16)
        0x60, 0x01, // PUSH1 0x01
        0x60, 0x1f, // PUSH1 0x1f (offset 31)
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0x00 (ret offset)
        0x60, 0x20, // PUSH1 0x20 (length 32)
        0xf3, // RETURN
    };

    const addr = [_]u8{0xaa} ** 20;
    const runtime_hash_1 = try memory_db.set_code(&runtime);
    var runtime_account_1 = Account.zero();
    runtime_account_1.code_hash = runtime_hash_1;
    try memory_db.set_account(addr, runtime_account_1);

    const caller = [_]u8{0xbb} ** 20;
    const input = [_]u8{ 0x11, 0x22, 0x33, 0x44 };

    const params = CallParams{ .call = .{
        .to = addr,
        .caller = caller,
        .input = &input,
        .value = 0,
        .gas = 200000,
    } };

    const res = try evm.call(params);
    try std.testing.expect(res.success);
    try std.testing.expectEqual(@as(usize, 32), res.output.?.len);
    try std.testing.expectEqual(@as(u8, 1), res.output.?[31]);
}

test "top-level call: AND-mask dispatcher with extra calldata returns 32-byte value" {
    const allocator = std.testing.allocator;
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");

    // Setup database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const jump_table = OpcodeMetadata.DEFAULT;
    const chain_rules = ChainRules{ .is_berlin = true };
    var evm = try Evm.init(allocator, db_interface, jump_table, chain_rules, null, 0, false, null);
    defer evm.deinit();

    // Dispatcher that uses AND 0xffffffff for selector extraction
    const runtime = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x35, // CALLDATALOAD
        0x63, 0xff, 0xff, 0xff, 0xff, // PUSH4 0xffffffff
        0x16, // AND
        0x63, 0x12, 0x34, 0x56, 0x78, // PUSH4 0x12345678
        0x14, // EQ
        0x60, 0x16, // PUSH1 0x16
        0x57, // JUMPI
        0x60, 0x00, // PUSH1 0x00
        0x60, 0x00, // PUSH1 0x00
        0xfd, // REVERT
        0x5b, // JUMPDEST @ 0x16
        0x60, 0x01, // PUSH1 0x01
        0x60, 0x1f, // PUSH1 0x1f
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0x00
        0x60, 0x20, // PUSH1 0x20
        0xf3, // RETURN
    };

    const addr = [_]u8{0xcc} ** 20;
    const runtime_hash_2 = try memory_db.set_code(&runtime);
    var runtime_account_2 = Account.zero();
    runtime_account_2.code_hash = runtime_hash_2;
    try memory_db.set_account(addr, runtime_account_2);

    const caller = [_]u8{0xdd} ** 20;

    // Build calldata: 4-byte selector + two 32-byte args
    var calldata: [4 + 32 + 32]u8 = undefined;
    calldata[0] = 0x12;
    calldata[1] = 0x34;
    calldata[2] = 0x56;
    calldata[3] = 0x78;
    @memset(calldata[4..36], 0);
    @memset(calldata[36..68], 0);

    const params = CallParams{ .call = .{
        .to = addr,
        .caller = caller,
        .input = &calldata,
        .value = 0,
        .gas = 200000,
    } };

    const res = try evm.call(params);
    try std.testing.expect(res.success);
    try std.testing.expectEqual(@as(usize, 32), res.output.?.len);
    try std.testing.expectEqual(@as(u8, 1), res.output.?[31]);
}
