const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
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
const Log = @import("../log.zig");

// Maximum input size for call data (128 KB)
pub const MAX_INPUT_SIZE: u18 = 128 * 1024;

/// Unified execution entry point for the EVM.
/// 
/// This function handles both root-level and nested calls uniformly,
/// eliminating the need for conditional logic based on call depth.
/// 
/// ## Design Principles
/// - Single entry point for all execution types
/// - Uniform frame management regardless of depth
/// - Clean separation between execution setup and interpretation
/// - Proper resource lifecycle management
///
/// @param self The EVM instance
/// @param params Call parameters (CALL, DELEGATECALL, STATICCALL, CREATE, CREATE2)
/// @return CallResult with success status, gas remaining, and output
pub fn execute(self: *Evm, params: CallParams) ExecutionError.Error!CallResult {
    Log.debug("[execute] Starting execution", .{});
    
    // Extract call parameters based on type
    var call_address: primitives.Address.Address = undefined;
    var call_code: []const u8 = undefined;
    var call_input: []const u8 = undefined;
    var call_gas: u64 = undefined;
    var call_is_static: bool = undefined;
    var call_caller: primitives.Address.Address = undefined;
    var call_value: u256 = undefined;
    var is_create: bool = false;
    var is_delegate: bool = false;
    
    switch (params) {
        .call => |call_data| {
            call_address = call_data.to;
            call_code = self.state.get_code(call_data.to);
            call_input = call_data.input;
            call_gas = call_data.gas;
            call_is_static = false;
            call_caller = call_data.caller;
            call_value = call_data.value;
            Log.debug("[execute] CALL to={any}, gas={}", .{ call_data.to, call_data.gas });
        },
        .delegatecall => |call_data| {
            call_address = call_data.to;
            call_code = self.state.get_code(call_data.to);
            call_input = call_data.input;
            call_gas = call_data.gas;
            call_is_static = false; // Inherits from parent frame
            call_caller = call_data.caller; // Preserved original caller
            call_value = 0; // No value transfer in delegatecall
            is_delegate = true;
            Log.debug("[execute] DELEGATECALL to={any}, gas={}", .{ call_data.to, call_data.gas });
        },
        .staticcall => |call_data| {
            call_address = call_data.to;
            call_code = self.state.get_code(call_data.to);
            call_input = call_data.input;
            call_gas = call_data.gas;
            call_is_static = true;
            call_caller = call_data.caller;
            call_value = 0; // No value transfer in static calls
            Log.debug("[execute] STATICCALL to={any}, gas={}", .{ call_data.to, call_data.gas });
        },
        .create => |create_data| {
            // For CREATE, we need to compute the contract address
            // and treat init_code as the code to execute
            call_address = compute_create_address(create_data.caller, self.state.get_nonce(create_data.caller));
            call_code = create_data.init_code;
            call_input = &.{}; // CREATE has no input
            call_gas = create_data.gas;
            call_is_static = false;
            call_caller = create_data.caller;
            call_value = create_data.value;
            is_create = true;
            Log.debug("[execute] CREATE from={any}, gas={}", .{ create_data.caller, create_data.gas });
        },
        .create2 => |create_data| {
            // For CREATE2, compute deterministic address
            call_address = compute_create2_address(create_data.caller, create_data.salt, create_data.init_code);
            call_code = create_data.init_code;
            call_input = &.{}; // CREATE2 has no input
            call_gas = create_data.gas;
            call_is_static = false;
            call_caller = create_data.caller;
            call_value = create_data.value;
            is_create = true;
            Log.debug("[execute] CREATE2 from={any}, gas={}", .{ create_data.caller, create_data.gas });
        },
    }
    
    // Input validation
    if (call_input.len > MAX_INPUT_SIZE) {
        return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
    }
    if (call_code.len > MAX_CODE_SIZE) {
        return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
    }
    if (call_gas == 0) {
        return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
    }
    
    // Check for precompiled contracts
    if (!is_create) {
        if (precompile_addresses.get_precompile_id_checked(call_address)) |precompile_id| {
            return self.execute_precompile_call_by_id(precompile_id, call_input, call_gas, call_is_static) catch |err| {
                Log.debug("[execute] Precompile error: {}", .{err});
                return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
            };
        }
    }
    
    // Perform code analysis
    var analysis = CodeAnalysis.from_code(self.allocator, call_code, &self.table) catch |err| {
        Log.err("[execute] Code analysis failed: {}", .{err});
        return CallResult{ .success = false, .gas_left = call_gas, .output = &.{} };
    };
    defer analysis.deinit();
    
    Log.debug("[execute] Code analysis complete: {} instructions", .{analysis.instructions.len});
    
    // Initialize execution state if needed
    if (self.current_frame_depth == 0) {
        try self.init_execution_state();
    }
    
    // Check call depth limit
    if (self.current_frame_depth >= MAX_CALL_DEPTH) {
        return CallResult{ .success = false, .gas_left = call_gas, .output = &.{} };
    }
    
    // Allocate and initialize new frame
    const frame = try self.allocate_frame(
        call_gas,
        call_is_static,
        call_address,
        call_caller,
        call_value,
        &analysis,
        call_input,
        is_create,
        is_delegate,
    );
    defer self.deallocate_frame(frame);
    
    // Execute the frame
    var exec_err: ?ExecutionError.Error = null;
    interpret(self, frame) catch |err| {
        Log.debug("[execute] Interpret ended with error: {}", .{err});
        exec_err = err;
    };
    
    // Copy output before frame cleanup
    var output: []const u8 = &.{};
    if (frame.output.len > 0) {
        output = self.allocator.dupe(u8, frame.output) catch &.{};
        Log.debug("[execute] Output length: {}", .{output.len});
    }
    
    // Map error to success status
    const success: bool = if (exec_err) |e| switch (e) {
        ExecutionError.Error.STOP => true,
        ExecutionError.Error.REVERT => false,
        ExecutionError.Error.OutOfGas => false,
        else => false,
    } else true;
    
    // Handle CREATE specific logic
    if (is_create and success) {
        // Deploy the code returned as output
        if (output.len > 0) {
            self.state.set_code(call_address, output) catch {};
        }
        // Return the created address as output
        output = std.mem.asBytes(&call_address);
    }
    
    Log.debug("[execute] Returning with success={}, gas_left={}, output_len={}", .{ 
        success, 
        frame.gas_remaining, 
        output.len 
    });
    
    return CallResult{
        .success = success,
        .gas_left = frame.gas_remaining,
        .output = output,
    };
}

/// Initialize execution state for a new transaction
fn init_execution_state(self: *Evm) ExecutionError.Error!void {
    Log.debug("[execute] Initializing execution state", .{});
    
    // Clear per-transaction state
    self.current_frame_depth = 0;
    self.max_allocated_depth = 0;
    self.access_list.clear();
    self.self_destruct = SelfDestruct.init(self.allocator);
    self.created_contracts = CreatedContracts.init(self.allocator);
    self.journal = CallJournal.init(self.allocator);
    self.gas_refunds = 0;
    
    // Allocate frame stack if needed
    if (self.frame_stack == null) {
        const initial_capacity = 16; // Start with space for 16 frames
        self.frame_stack = try self.allocator.alloc(Frame, initial_capacity);
    }
}

/// Allocate and initialize a new frame
fn allocate_frame(
    self: *Evm,
    gas: u64,
    is_static: bool,
    contract_address: primitives.Address.Address,
    caller: primitives.Address.Address,
    value: u256,
    analysis: *const CodeAnalysis,
    input: []const u8,
    is_create: bool,
    is_delegate: bool,
) ExecutionError.Error!*Frame {
    const depth = self.current_frame_depth;
    
    // Ensure frame stack has capacity
    if (self.frame_stack) |frames| {
        if (depth >= frames.len) {
            const new_capacity = @min(frames.len * 2, MAX_CALL_DEPTH);
            const new_frames = try self.allocator.realloc(frames, new_capacity);
            self.frame_stack = new_frames;
        }
    } else {
        return ExecutionError.Error.INVALID;
    }
    
    // Create host interface
    var host = Host.init(self);
    
    // Get parent frame's static context if nested
    var actual_is_static = is_static;
    if (depth > 0) {
        const parent_frame = &self.frame_stack.?[depth - 1];
        actual_is_static = is_static or parent_frame.is_static();
    }
    
    // Create snapshot for revertibility
    const snapshot_id = if (depth > 0) self.journal.create_snapshot() else 0;
    
    // Initialize frame
    self.frame_stack.?[depth] = try Frame.init(
        gas,
        actual_is_static,
        @intCast(depth),
        contract_address,
        caller,
        value,
        analysis,
        &self.access_list,
        &self.journal,
        &host,
        snapshot_id,
        self.state.database,
        ChainRules{},
        &self.self_destruct,
        &self.created_contracts,
        input,
        self.allocator,
        null, // next_frame
        is_create,
        is_delegate,
    );
    
    const frame = &self.frame_stack.?[depth];
    
    // Copy block context from parent or set from VM context
    if (depth > 0) {
        const parent_frame = &self.frame_stack.?[depth - 1];
        frame.block_number = parent_frame.block_number;
        frame.block_timestamp = parent_frame.block_timestamp;
        frame.block_difficulty = parent_frame.block_difficulty;
        frame.block_gas_limit = parent_frame.block_gas_limit;
        frame.block_coinbase = parent_frame.block_coinbase;
        frame.block_base_fee = parent_frame.block_base_fee;
        frame.block_blob_base_fee = parent_frame.block_blob_base_fee;
    } else {
        frame.block_number = self.context.block_number;
        frame.block_timestamp = self.context.block_timestamp;
        frame.block_difficulty = self.context.block_difficulty;
        frame.block_gas_limit = self.context.block_gas_limit;
        frame.block_coinbase = self.context.block_coinbase;
        frame.block_base_fee = self.context.block_base_fee;
        frame.block_blob_base_fee = if (self.context.blob_base_fee > 0) self.context.blob_base_fee else null;
    }
    
    // Update tracking
    self.current_frame_depth = depth + 1;
    if (depth > self.max_allocated_depth) {
        self.max_allocated_depth = @intCast(depth);
    }
    
    return frame;
}

/// Deallocate frame and restore state
fn deallocate_frame(self: *Evm, frame: *Frame) void {
    _ = frame;
    
    // Note: We don't call frame.deinit() here because frames are stored
    // in the frame_stack array and will be cleaned up in vm.deinit()
    // Calling deinit here would cause a double-free
    
    if (self.current_frame_depth > 0) {
        self.current_frame_depth -= 1;
    }
}

/// Compute CREATE address (based on sender and nonce)
fn compute_create_address(sender: primitives.Address.Address, nonce: u64) primitives.Address.Address {
    // TODO: Implement proper CREATE address computation
    // For now, return a placeholder
    _ = sender;
    _ = nonce;
    return primitives.Address.ZERO;
}

/// Compute CREATE2 address (deterministic based on sender, salt, and init code)
fn compute_create2_address(sender: primitives.Address.Address, salt: u256, init_code: []const u8) primitives.Address.Address {
    // TODO: Implement proper CREATE2 address computation
    // For now, return a placeholder
    _ = sender;
    _ = salt;
    _ = init_code;
    return primitives.Address.ZERO;
}