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

    const frames: [STACK_SIZE]Frame = [_]Frame{Frame{}};

    var instruction = analysis.next_instruction();
    var loops = 0;

    while (instruction != null) {
        instruction = instruction[0].run(instruction, state);
    }

    // handle execution result

    unreachable;
}

const Instruction = struct { execute: *const fn (*const Instruction, *Frame) ?*const Instruction, arg: union(enum) {
    none,
    block_metrics: BlockMetrics,
    push_value: u256,
} };

fn translate_bytecode(
self: *const Evm,
bytecode: []const u8,
boundaries: *const std.StaticBitSet(MAX_CONTRACT_SIZE),
) [MAX_INSTRUCTIONS]Instruction {
    var result = TranslationResult{}; // The buffer to fill.
        var stream_idx: usize = 0; // The current index in our result.instructions array.

        var pc: usize = 0;
        while (pc < bytecode.len) {
            // --- Step 1: Check for Block Start ---
            if (boundaries.isSet(pc)) {
                // TODO:
                // 1. Find block end.
                // 2. Get block bytecode slice.
                // 3. Call BlockMetrics.from_block().
                // 4. Assign the synthetic `opx_beginblock` to `result.instructions[stream_idx]`.
                // 5. Increment stream_idx.
            }

            // --- Step 2: Translate the Current Opcode ---
            const opcode = bytecode[pc];

            // TODO:
            // 1. Get the function pointer.
            // 2. If PUSH, get the value.
            // 3. Assign the real instruction to `result.instructions[stream_idx]`.
            // 4. Increment stream_idx.

            // --- Step 3: Advance PC ---
            const instruction_len = // ...
            pc += instruction_len;
        }

        result.count = stream_idx;
        return result;
}

/// Metrics about a given block of opcodes
const BlockMetrics = struct {
    gas_cost: i64 = 0,
    stack_req: u16 = 0,
    stack_max_growth: u16 = 0,

    fn from_block(bytecode: []const u8, opcode_table: JumpTable) BlockMetrics {
        std.debug.assert(bytecode.len <= MAX_CONTRACT_SIZE);
        var metrics = BlockMetrics{};

        var simulated_stack_height: i16 = 0;

        var pc: usize = 0;
        while (pc < bytecode.len) {
            const op = bytecode[pc];

            const items_popped = opcode_table.min_stack[opcode];

            if (simulated_stack_height < items_popped) {
                const deficit: u16 = items_popped - simulated_stack_height;
                if (metrics.stack_req < deficit) {
                    metrics.stack_req = deficit;
                }
            }

            const items_pushed = STACK_SIZE - opcode_table.max_stack[opcode];
            simulated_stack_height += items_pushed - items_popped; // increase stack height must happen before checking max height

            if (simulated_stack_height > metrics.stack_max_growth) {
                metrics.stack_max_growth = simulated_stack_height;
            }

            const constant_gas = opcode_table.constant_gas[opcode];
            metrics.gas_cost += constant_gas;

            const next_pc = if (op >= 0x60 and op <= 0x7f) // PUSH
                // handle push opcodes will have some amount of data based on the push we need to skip
                1 + (op - 0x60 + 1)
            else
                1;
            std.debug.assert(next_pc > pc); // guarantees no infinite loops
            pc = next_pc;
        }

        return metrics;
    }
};

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
