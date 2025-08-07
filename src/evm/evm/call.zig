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
const Contract = Evm.Contract;
const interpret = @import("interpret.zig");
const MAX_CODE_SIZE = @import("../opcodes/opcode.zig").MAX_CODE_SIZE;
const MAX_CALL_DEPTH = @import("../constants/evm_limits.zig").MAX_CALL_DEPTH;
const primitives = @import("primitives");

// Threshold for stack vs heap allocation optimization
const STACK_ALLOCATION_THRESHOLD = 12800; // bytes of bytecode
// Maximum stack buffer size for contracts up to 12,800 bytes
const MAX_STACK_BUFFER_SIZE = 43008; // 42KB with alignment padding

// THE EVM has no actual limit on calldata. Only indirect practical limits like gas cost exist.
// 128 KB is about the limit most rpc providers limit call data to so we use it as the default
pub const MAX_INPUT_SIZE: u18 = 128 * 1024; // 128 kb

pub inline fn call(self: *Evm, contract: *Contract, input: []const u8, comptime is_static: bool) ExecutionError.Error!InterpretResult {
    {
        if (contract.input.len > MAX_INPUT_SIZE) return ExecutionError.Error.InputSizeExceeded;
        if (contract.code_size > MAX_CODE_SIZE) return ExecutionError.Error.MaxCodeSizeExceeded;
        if (contract.code_size != contract.code.len) return ExecutionError.Error.CodeSizeMismatch;
        if (contract.gas == 0) return ExecutionError.Error.OutOfGas;
        if (contract.code_size > 0 and contract.code.len == 0) return ExecutionError.Error.CodeSizeMismatch;
    }

    const initial_gas = contract.gas;

    // Initialize the call stack with MAX_CALL_DEPTH frames
    var frame_stack: [MAX_CALL_DEPTH]Frame = undefined;

    // Do analysis on stack if contract is small
    var stack_buffer: [MAX_STACK_BUFFER_SIZE]u8 = undefined;
    const analysis_allocator = if (contract.code_size <= STACK_ALLOCATION_THRESHOLD)
        std.heap.FixedBufferAllocator.init(&stack_buffer)
    else
        self.allocator;
    var analysis = try CodeAnalysis.from_code(analysis_allocator, contract.code[0..contract.code_size], &self.table);
    defer analysis.deinit();

    // Create access list and self destruct trackers
    var access_list = AccessList.init(self.allocator);
    var self_destruct = SelfDestruct.init(self.allocator);

    // Initialize all frames in the stack and link them together
    for (0..MAX_CALL_DEPTH) |i| {
        const next_frame = if (i + 1 < MAX_CALL_DEPTH) &frame_stack[i + 1] else null;
        frame_stack[i] = try Frame.init(
            0, // gas_remaining - will be set properly for frame 0
            false, // static_call - will be set properly for frame 0  
            @intCast(i), // call_depth
            primitives.Address.ZERO_ADDRESS, // contract_address - will be set properly for frame 0
            &analysis, // analysis - will be set properly for each frame when used
            &access_list,
            self.state,
            ChainRules{},
            &self_destruct,
            &[_]u8{}, // input - will be set properly for frame 0
            self.arena_allocator(),
            next_frame,
        );
    }
    
    // Set up the first frame properly for execution
    frame_stack[0].gas_remaining = contract.gas;
    frame_stack[0].hot_flags.is_static = is_static;
    frame_stack[0].hot_flags.depth = @intCast(self.depth);
    frame_stack[0].contract_address = contract.address;
    frame_stack[0].input = input;
    
    // Ensure all frames are properly deinitialized
    defer {
        for (0..MAX_CALL_DEPTH) |i| {
            frame_stack[i].deinit();
        }
    }

    // Call interpret with the first frame
    interpret.interpret(self, &frame_stack[0]) catch |err| {
        // Handle error cases and transform to InterpretResult
        var output: ?[]const u8 = null;
        if (frame_stack[0].output.len > 0) {
            output = self.allocator.dupe(u8, frame_stack[0].output) catch {
                return InterpretResult.init(self.allocator, initial_gas, 0, .OutOfGas, ExecutionError.Error.OutOfMemory, null, access_list, self_destruct);
            };
        }

        const status: RunResult.Status = switch (err) {
            ExecutionError.Error.STOP => .Success,
            ExecutionError.Error.REVERT => .Revert,
            ExecutionError.Error.OutOfGas => .OutOfGas,
            else => .Invalid,
        };

        return InterpretResult.init(self.allocator, initial_gas, frame_stack[0].gas_remaining, status, err, output, access_list, self_destruct);
    };

    // Success case - update contract gas and copy output if needed
    contract.gas = frame_stack[0].gas_remaining;
    var output: ?[]const u8 = null;
    if (frame_stack[0].output.len > 0) {
        output = try self.allocator.dupe(u8, frame_stack[0].output);
    }

    // Apply destructions before returning
    // TODO: Apply destructions to state
    return InterpretResult.init(self.allocator, initial_gas, frame_stack[0].gas_remaining, .Success, null, output, access_list, self_destruct);
}
