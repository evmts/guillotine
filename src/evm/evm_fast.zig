const std = @import("std");
const JumpTable = @import("jump_table/jump_table.zig");
const Frame = @import("frame/frame.zig");
const Operation = @import("opcodes/operation.zig");
const primitives = @import("primitives");
const StoragePool = @import("frame/storage_pool.zig");
const AccessList = @import("access_list/access_list.zig");
const ExecutionError = @import("execution/execution_error.zig");
const Keccak256 = std.crypto.hash.sha3.Keccak256;
const ChainRules = @import("hardforks/chain_rules.zig");
const GasConstants = @import("primitives").GasConstants;
const opcode = @import("opcodes/opcode.zig");
const Log = @import("log.zig");
const EvmLog = @import("state/evm_log.zig");
const Context = @import("access_list/context.zig");
const EvmState = @import("state/state.zig");
const Memory = @import("memory/memory.zig");
const ReturnData = @import("evm/return_data.zig").ReturnData;
pub const StorageKey = @import("primitives").StorageKey;
pub const CreateResult = @import("evm/create_result.zig").CreateResult;
pub const CallResult = @import("evm/call_result.zig").CallResult;
pub const RunResult = @import("evm/run_result.zig").RunResult;
const Hardfork = @import("hardforks/hardfork.zig").Hardfork;
const precompiles = @import("precompiles/precompiles.zig");
const Message = @import("message_fast.zig");
const EvmHost = struct {};
const builtin = @import("builtin");
const Opcode = @import("../opcodes/opcode.zig").Opcode;
const OpcodeTable = @import("../opcodes/opcode_table.zig").OpcodeTable;
const ExecutionError = @import("../execution_error.zig").ExecutionError;
const operation = @import("../opcodes/operation.zig");
const Frame = @import("../frame/frame.zig").Frame;
const opx_beginblock = @import("execution/opx.zig").begin_block;

const MAX_CONTRACT_SIZE = 24_576;
const MAX_INSTRUCTIONS = MAX_CONTRACT_SIZE * 2; 
const STACK_SIZE = 256;
const IS_SAFE = builtin.mode == .ReleaseSafe or builtin.mode == .Debug;
pub const MAX_CALL_DEPTH = 1024;

const Evm = @This();

opcode_table: JumpTable = JumpTable.DEFAULT,

   pub const MAX_INSTRUCTIONS = MAX_CONTRACT_SIZE * 2;

    const TranslationResult = struct {
        instructions: [MAX_INSTRUCTIONS]Instruction = undefined,
        count: usize = 0,
    };

pub fn execute(self: *Evm, host: *EvmHost, bytecode: *const []u8, message: Message) ExecutionError.Error!ReturnData {
    if (bytecode.len >= MAX_CONTRACT_SIZE) {
        return ExecutionError.Error.MAX_CONTRACT_SIZE;
    }

    _ = host;
    _ = message;

    const boundaries = self.find_block_boundaries(bytecode);
    const next_instructions = self.translate_bytecode(bytecode, &boundaries);
    const frame = Frame{};

    while (next_instructions) |instructions| {
        next_instruction = instructions[0].run(instructions, frame);
    }

    // handle execution result

    unreachable;
}

const Instruction = struct { execute: *const fn (*const Instruction, *Frame) ?*const Instruction, arg: union(enum) {
    none,
    block_metrics: BlockMetrics,
    push_value: u256,
} };

/// Represents a single translated instruction in the instruction stream.
const BlockMetrics = struct {
    stack_required: u16,
    stack_change: i16,

    pub fn from_block(
        bytecode: []const u8,
        table: *const OpcodeTable,
    ) BlockMetrics {
        var stack_req: u16 = 0;
        var stack_change: i16 = 0;
        var max_stack_req: u16 = 0;

        var pc: usize = 0;
        while (pc < bytecode.len) {
            const op_code = bytecode[pc];
            const op = &table.metadatas[op_code];

            const req = @intFromEnum(op.stack_read);
            if (stack_change < req) {
                stack_req += @intCast(req - stack_change);
                stack_change = 0;
            } else {
                stack_change -= req;
            }

            stack_change += @intFromEnum(op.stack_write);

            if (stack_req > max_stack_req) {
                max_stack_req = stack_req;
            }
            pc += get_instruction_length(op_code);
        }

        return .{
            .stack_required = max_stack_req,
            .stack_change = stack_change,
        };
    }
};

/// The result of translating bytecode into our internal representation.
const TranslationResult = struct {
    instructions: [MAX_INSTRUCTIONS]Instruction = undefined,
    count: usize = 0,
};

/// Returns the length of an instruction in bytes.
fn get_instruction_length(opcode: u8) usize {
    if (opcode >= 0x60 and opcode <= 0x7f) { // PUSH1-PUSH32
        return @as(usize, opcode - 0x60) + 2;
    }
    return 1;
}

// This is your top-level analysis function.
fn translate_bytecode(
    self: *const Evm,
    bytecode: []const u8,
    boundaries: *const std.StaticBitSet(MAX_CONTRACT_SIZE),
) TranslationResult {
    var result = TranslationResult{};
    var stream_idx: usize = 0;

    var pc: usize = 0;
    while (pc < bytecode.len) {
        // --- Step 1: Check for and Prepend Block Headers ---
        if (boundaries.isSet(pc)) {
            // Find the end of this basic block.
            var block_end = pc;
            while (block_end < bytecode.len) {
                block_end += get_instruction_length(bytecode[block_end]);
                if (block_end >= bytecode.len or boundaries.isSet(block_end)) {
                    break;
                }
            }

            if (block_end > bytecode.len) {
                block_end = bytecode.len;
            }

            const block_bytecode = bytecode[pc..block_end];

            // Analyze the block to get its metrics.
            const metrics = BlockMetrics.from_block(block_bytecode, &self.opcode_table);

            // Assign the synthetic `opx_beginblock` to the stream.
            result.instructions[stream_idx] = .{
                .fn = opx_beginblock,
                .arg = .{ .block_metrics = metrics },
            };
            stream_idx += 1;
        }

        // --- Step 2: Translate the Real Opcode ---
        const opcode_val = bytecode[pc];
        var instruction_len = get_instruction_length(opcode_val);

        // Directly get the compatible function pointer from your OpcodeTable.
        const exec_fn = self.opcode_table.execute_funcs[opcode_val];

        if (opcode_val >= 0x60 and opcode_val <= 0x7f) { // PUSH1 to PUSH32
            if (pc + instruction_len > bytecode.len) {
                // Malformed bytecode, push reads past contract end.
                // We'll let execution handle this as an error.
                // For translation, we stop here.
                break;
            }

            const data_slice = bytecode[pc + 1 .. pc + instruction_len];
            const push_value = u256.from_slice_be(data_slice);

            // Assign the PUSH instruction with its value argument.
            result.instructions[stream_idx] = .{
                .fn = exec_fn,
                .arg = .{ .push_value = push_value },
            };
        } else {
            // For all other instructions, there is no argument.
            result.instructions[stream_idx] = .{
                .fn = exec_fn,
                .arg = .none,
            };
        }
        stream_idx += 1;

        // --- Step 3: Advance PC ---
        pc += instruction_len;
    }

    result.count = stream_idx;
    return result;
}

///  Finds block boundaries and returns a StaticBitSet with boundaries set.
///  Block boundaries are places in bytecode we can identify a jump happens
pub fn find_block_boundaries(bytecode: []const u8) std.StaticBitSet(MAX_CONTRACT_SIZE) {
    std.debug.assert(bytecode.len <= MAX_CONTRACT_SIZE);
    // Use MAX_CONTRACT_SIZE to avoid heap allocation
    var boundaries = std.StaticBitSet(MAX_CONTRACT_SIZE);
    var pc: usize = 0;

    while (pc < bytecode.len) {
        const op = bytecode[pc];

        const next_pc: usize = pc + if (op >= 0x60 and op <= 0x7f) // PUSH
            // handle push opcodes will have some amount of data based on the push we need to skip
            1 + (op - 0x60 + 1)
        else
            1;

        switch (op) {
            0x5b => { // JUMPDEST
                boundaries.set(pc);
            },
            // opcodes that end execution
            0x00, // STOP
            0x56, // JUMP
            0xf3, // RETURN
            0xfd, // REVERT
            0xfe, // INVALID
            0xff, // SELFDESTRUCT
            0x57, // JUMPI (because it's conditional we consider it terminating)
            => {
                if (next_pc < bytecode.len) {
                    boundaries.set(next_pc);
                }
            },
            else => {}, // DO nothing for most opcodes
        }

        // We know this will not infinite loop because we are always incrementing it
        std.debug.assert(next_pc > pc);
        pc = next_pc;
    }

    return boundaries;
}
