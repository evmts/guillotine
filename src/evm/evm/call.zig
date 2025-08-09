const std = @import("std");
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
            Log.debug("[call] Staticcall params: to={any}, input_len={}, gas={}, static={}", .{ call_data.to, call_data.input.len, call_data.gas, true });
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

    // Input validation
    if (call_info.input.len > MAX_INPUT_SIZE) return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
    if (call_info.code_size > MAX_CODE_SIZE) return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
    if (call_info.code_size != call_info.code.len) return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
    if (call_info.gas == 0) return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
    if (call_info.code_size > 0 and call_info.code.len == 0) return CallResult{ .success = false, .gas_left = 0, .output = &.{} };

    Log.debug("[call] Code size: {}, code_len: {}", .{ call_info.code_size, call_info.code.len });

    // Do analysis using heap allocator
    var analysis = CodeAnalysis.from_code(self.allocator, call_info.code[0..call_info.code_size], &self.table) catch |err| {
        Log.err("[call] Code analysis failed: {}", .{err});
        return CallResult{ .success = false, .gas_left = call_info.gas, .output = &.{} };
    };
    defer analysis.deinit();

    Log.debug("[call] Code analysis complete: {} instructions", .{analysis.instructions.len});

    // Reinitialize if first frame
    // Only initialize EVM state if we're at depth 0 (top-level call)
    // Check current frame depth from EVM to determine if this is a nested call
    if (self.current_frame_depth == 0) {
        // Initialize fresh execution state in EVM instance (per-call isolation)
        // CRITICAL: Clear all state at beginning of top-level call
        self.current_frame_depth = 0;
        self.access_list.clear(); // Reset access list for fresh per-call state
        self.self_destruct = SelfDestruct.init(self.allocator); // Fresh self-destruct tracker
        self.created_contracts = CreatedContracts.init(self.allocator); // Fresh created contracts tracker for EIP-6780

        // Create host interface from self
        var host = Host.init(self);

        // Initialize only the first frame now. Nested frames will be initialized on demand
        const first_next_frame: ?*Frame = null; // no nested calls pre-allocated
        self.frame_stack[0] = try Frame.init(
            call_info.gas, // gas_remaining
            call_info.is_static, // static_call
            @intCast(self.depth), // call_depth
            call_info.address, // contract_address
            call_caller, // caller
            call_value, // value
            &analysis, // analysis
            &self.access_list,
            &self.journal,
            &host,
            0, // snapshot_id
            self.state.database,
            ChainRules{},
            &self.self_destruct,
            &self.created_contracts,
            call_info.input, // input
            self.allocator, // use general allocator for frame-owned allocations
            first_next_frame,
            false, // is_create_call
            false, // is_delegate_call
        );
        // Frame resources will be released after execution completes

        // Set block context from VM's context
        self.frame_stack[0].block_number = self.context.block_number;
        self.frame_stack[0].block_timestamp = self.context.block_timestamp;
        self.frame_stack[0].block_difficulty = self.context.block_difficulty;
        self.frame_stack[0].block_gas_limit = self.context.block_gas_limit;
        self.frame_stack[0].block_coinbase = self.context.block_coinbase;
        self.frame_stack[0].block_base_fee = self.context.block_base_fee;
        self.frame_stack[0].block_blob_base_fee = if (self.context.blob_base_fee > 0) self.context.blob_base_fee else null;
    }

    if (precompile_addresses.get_precompile_id_checked(call_info.address)) |precompile_id| {
        const precompile_result = self.execute_precompile_call_by_id(precompile_id, call_info.input, call_info.gas, call_info.is_static) catch |err| {
            return switch (err) {
                else => CallResult{ .success = false, .gas_left = 0, .output = &.{} },
            };
        };

        return precompile_result;
    }

    Log.debug("[call] Starting interpret, gas={}", .{self.frame_stack[0].gas_remaining});

    // Execute and normalize result handling so we can always clean up the frame
    var exec_err: ?ExecutionError.Error = null;
    interpret(self, &self.frame_stack[0]) catch |err| {
        Log.debug("[call] Interpret ended with error: {}", .{err});
        exec_err = err;
    };

    // Copy output before frame cleanup
    var output: []const u8 = &.{};
    if (self.frame_stack[0].output.len > 0) {
        output = self.allocator.dupe(u8, self.frame_stack[0].output) catch &.{};
        Log.debug("[call] Output length: {}", .{output.len});
    }

    // Release frame resources
    self.frame_stack[0].deinit();

    // Map error to success status
    const success: bool = if (exec_err) |e| switch (e) {
        ExecutionError.Error.STOP => true,
        ExecutionError.Error.REVERT => false,
        ExecutionError.Error.OutOfGas => false,
        else => false,
    } else true;

    Log.debug("[call] Returning with success={}, gas_left={}, output_len={}", .{ success, self.frame_stack[0].gas_remaining, output.len });
    return CallResult{
        .success = success,
        .gas_left = self.frame_stack[0].gas_remaining,
        .output = output,
    };
}
