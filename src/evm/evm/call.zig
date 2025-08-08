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
                self.arena_allocator(), // Arena is preallocated with 256KB capacity in EVM init
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
