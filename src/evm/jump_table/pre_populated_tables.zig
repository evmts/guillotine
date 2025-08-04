const std = @import("std");
const Operation = @import("../opcodes/operation.zig").Operation;
const operation_config = @import("operation_config.zig");
const Hardfork = @import("../hardforks/hardfork.zig").Hardfork;
const Stack = @import("../stack/stack.zig");
const execution = @import("../execution/package.zig");
const stack_ops = execution.stack;
const log = execution.log;

/// Pre-populated jump tables for all hardforks.
///
/// This optimization eliminates runtime generation of operation structs by
/// pre-computing all possible jump table configurations at compile time.
/// 
/// Benefits:
/// 1. Eliminates runtime operation generation overhead
/// 2. Enables better compiler optimizations (const data)
/// 3. Reduces memory allocations
/// 4. Improves cache locality (const data section)
///
/// The trade-off is increased binary size, but the performance gain
/// is worth it for production deployments.

/// Generate a complete jump table for a specific hardfork at compile time.
fn generateHardforkTable(comptime hardfork: Hardfork) [256]?*const Operation {
    @setEvalBranchQuota(10000);
    var table: [256]?*const Operation = [_]?*const Operation{null} ** 256;
    
    // First, populate from ALL_OPERATIONS
    for (operation_config.ALL_OPERATIONS) |spec| {
        const op_hardfork = spec.variant orelse Hardfork.FRONTIER;
        if (@intFromEnum(op_hardfork) <= @intFromEnum(hardfork)) {
            // Check if this is the latest version for this opcode
            var is_latest = true;
            for (operation_config.ALL_OPERATIONS) |other_spec| {
                if (other_spec.opcode == spec.opcode and other_spec.variant != null) {
                    const other_hardfork = other_spec.variant.?;
                    if (@intFromEnum(other_hardfork) > @intFromEnum(op_hardfork) and
                        @intFromEnum(other_hardfork) <= @intFromEnum(hardfork)) {
                        is_latest = false;
                        break;
                    }
                }
            }
            
            if (is_latest) {
                const op_ptr = &struct {
                    pub const op = operation_config.generate_operation(spec);
                }.op;
                table[spec.opcode] = op_ptr;
            }
        }
    }
    
    // Add PUSH operations (0x60-0x7f)
    const push_ops = struct {
        pub const push1 = Operation{
            .execute = stack_ops.op_push1,
            .constant_gas = execution.gas_constants.GasFastestStep,
            .min_stack = 0,
            .max_stack = Stack.CAPACITY - 1,
        };
        
        pub const push_small = [_]Operation{
            Operation{ .execute = stack_ops.make_push_small(2), .constant_gas = execution.gas_constants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push_small(3), .constant_gas = execution.gas_constants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push_small(4), .constant_gas = execution.gas_constants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push_small(5), .constant_gas = execution.gas_constants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push_small(6), .constant_gas = execution.gas_constants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push_small(7), .constant_gas = execution.gas_constants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push_small(8), .constant_gas = execution.gas_constants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
        };
        
        pub const push_large = [_]Operation{
            Operation{ .execute = stack_ops.make_push(9), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push(10), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push(11), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push(12), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push(13), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push(14), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push(15), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push(16), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push(17), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push(18), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push(19), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push(20), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push(21), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push(22), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push(23), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push(24), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push(25), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push(26), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push(27), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push(28), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push(29), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push(30), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push(31), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_push(32), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
        };
    };
    
    // PUSH1 is special - most optimized
    table[0x60] = &push_ops.push1;
    
    // PUSH2-PUSH8 use optimized small push
    inline for (0..7) |i| {
        table[0x61 + i] = &push_ops.push_small[i];
    }
    
    // PUSH9-PUSH32 use generic push
    inline for (0..24) |i| {
        table[0x68 + i] = &push_ops.push_large[i];
    }
    
    // Add DUP operations (0x80-0x8f)
    const dup_ops = struct {
        pub const ops = [_]Operation{
            Operation{ .execute = stack_ops.make_dup(1), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 1, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_dup(2), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 2, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_dup(3), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 3, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_dup(4), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 4, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_dup(5), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 5, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_dup(6), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 6, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_dup(7), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 7, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_dup(8), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 8, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_dup(9), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 9, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_dup(10), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 10, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_dup(11), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 11, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_dup(12), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 12, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_dup(13), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 13, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_dup(14), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 14, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_dup(15), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 15, .max_stack = Stack.CAPACITY - 1 },
            Operation{ .execute = stack_ops.make_dup(16), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 16, .max_stack = Stack.CAPACITY - 1 },
        };
    };
    
    inline for (0..16) |i| {
        table[0x80 + i] = &dup_ops.ops[i];
    }
    
    // Add SWAP operations (0x90-0x9f)
    const swap_ops = struct {
        pub const ops = [_]Operation{
            Operation{ .execute = stack_ops.make_swap(1), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 2, .max_stack = Stack.CAPACITY },
            Operation{ .execute = stack_ops.make_swap(2), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 3, .max_stack = Stack.CAPACITY },
            Operation{ .execute = stack_ops.make_swap(3), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 4, .max_stack = Stack.CAPACITY },
            Operation{ .execute = stack_ops.make_swap(4), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 5, .max_stack = Stack.CAPACITY },
            Operation{ .execute = stack_ops.make_swap(5), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 6, .max_stack = Stack.CAPACITY },
            Operation{ .execute = stack_ops.make_swap(6), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 7, .max_stack = Stack.CAPACITY },
            Operation{ .execute = stack_ops.make_swap(7), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 8, .max_stack = Stack.CAPACITY },
            Operation{ .execute = stack_ops.make_swap(8), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 9, .max_stack = Stack.CAPACITY },
            Operation{ .execute = stack_ops.make_swap(9), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 10, .max_stack = Stack.CAPACITY },
            Operation{ .execute = stack_ops.make_swap(10), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 11, .max_stack = Stack.CAPACITY },
            Operation{ .execute = stack_ops.make_swap(11), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 12, .max_stack = Stack.CAPACITY },
            Operation{ .execute = stack_ops.make_swap(12), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 13, .max_stack = Stack.CAPACITY },
            Operation{ .execute = stack_ops.make_swap(13), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 14, .max_stack = Stack.CAPACITY },
            Operation{ .execute = stack_ops.make_swap(14), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 15, .max_stack = Stack.CAPACITY },
            Operation{ .execute = stack_ops.make_swap(15), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 16, .max_stack = Stack.CAPACITY },
            Operation{ .execute = stack_ops.make_swap(16), .constant_gas = execution.GasConstants.GasFastestStep, .min_stack = 17, .max_stack = Stack.CAPACITY },
        };
    };
    
    inline for (0..16) |i| {
        table[0x90 + i] = &swap_ops.ops[i];
    }
    
    // Add LOG operations (0xa0-0xa4)
    const log_ops = struct {
        pub const ops = [_]Operation{
            Operation{ .execute = log.make_log(0), .constant_gas = execution.GasConstants.LogGas, .min_stack = 2, .max_stack = Stack.CAPACITY },
            Operation{ .execute = log.make_log(1), .constant_gas = execution.GasConstants.LogGas + execution.GasConstants.LogTopicGas, .min_stack = 3, .max_stack = Stack.CAPACITY },
            Operation{ .execute = log.make_log(2), .constant_gas = execution.GasConstants.LogGas + 2 * execution.GasConstants.LogTopicGas, .min_stack = 4, .max_stack = Stack.CAPACITY },
            Operation{ .execute = log.make_log(3), .constant_gas = execution.GasConstants.LogGas + 3 * execution.GasConstants.LogTopicGas, .min_stack = 5, .max_stack = Stack.CAPACITY },
            Operation{ .execute = log.make_log(4), .constant_gas = execution.GasConstants.LogGas + 4 * execution.GasConstants.LogTopicGas, .min_stack = 6, .max_stack = Stack.CAPACITY },
        };
    };
    
    inline for (0..5) |i| {
        table[0xa0 + i] = &log_ops.ops[i];
    }
    
    return table;
}

/// Pre-populated jump tables for all hardforks.
pub const TABLES = struct {
    pub const FRONTIER = generateHardforkTable(.FRONTIER);
    pub const HOMESTEAD = generateHardforkTable(.HOMESTEAD);
    pub const DAO = generateHardforkTable(.DAO);
    pub const TANGERINE_WHISTLE = generateHardforkTable(.TANGERINE_WHISTLE);
    pub const SPURIOUS_DRAGON = generateHardforkTable(.SPURIOUS_DRAGON);
    pub const BYZANTIUM = generateHardforkTable(.BYZANTIUM);
    pub const CONSTANTINOPLE = generateHardforkTable(.CONSTANTINOPLE);
    pub const PETERSBURG = generateHardforkTable(.PETERSBURG);
    pub const ISTANBUL = generateHardforkTable(.ISTANBUL);
    pub const MUIR_GLACIER = generateHardforkTable(.MUIR_GLACIER);
    pub const BERLIN = generateHardforkTable(.BERLIN);
    pub const LONDON = generateHardforkTable(.LONDON);
    pub const ARROW_GLACIER = generateHardforkTable(.ARROW_GLACIER);
    pub const GRAY_GLACIER = generateHardforkTable(.GRAY_GLACIER);
    pub const MERGE = generateHardforkTable(.MERGE);
    pub const SHANGHAI = generateHardforkTable(.SHANGHAI);
    pub const CANCUN = generateHardforkTable(.CANCUN);
};

/// Get the pre-populated table for a hardfork.
pub fn getTable(hardfork: Hardfork) [256]?*const Operation {
    return switch (hardfork) {
        .FRONTIER => TABLES.FRONTIER,
        .HOMESTEAD => TABLES.HOMESTEAD,
        .DAO => TABLES.DAO,
        .TANGERINE_WHISTLE => TABLES.TANGERINE_WHISTLE,
        .SPURIOUS_DRAGON => TABLES.SPURIOUS_DRAGON,
        .BYZANTIUM => TABLES.BYZANTIUM,
        .CONSTANTINOPLE => TABLES.CONSTANTINOPLE,
        .PETERSBURG => TABLES.PETERSBURG,
        .ISTANBUL => TABLES.ISTANBUL,
        .MUIR_GLACIER => TABLES.MUIR_GLACIER,
        .BERLIN => TABLES.BERLIN,
        .LONDON => TABLES.LONDON,
        .ARROW_GLACIER => TABLES.ARROW_GLACIER,
        .GRAY_GLACIER => TABLES.GRAY_GLACIER,
        .MERGE => TABLES.MERGE,
        .SHANGHAI => TABLES.SHANGHAI,
        .CANCUN => TABLES.CANCUN,
    };
}

// Tests
const testing = std.testing;

test "pre-populated tables contain expected operations" {
    // Test that CANCUN table has expected operations
    const cancun_table = TABLES.CANCUN;
    
    // Check some key operations exist
    try testing.expect(cancun_table[0x01] != null); // ADD
    try testing.expect(cancun_table[0x60] != null); // PUSH1
    try testing.expect(cancun_table[0x80] != null); // DUP1
    try testing.expect(cancun_table[0x90] != null); // SWAP1
    try testing.expect(cancun_table[0xa0] != null); // LOG0
    
    // Check that newer opcodes are present in newer hardforks
    try testing.expect(cancun_table[0x5f] != null); // PUSH0 (Shanghai+)
    
    // Check that they're missing in older hardforks
    const frontier_table = TABLES.FRONTIER;
    try testing.expect(frontier_table[0x5f] == null); // PUSH0 not in Frontier
}

test "pre-populated tables have correct operation properties" {
    const cancun_table = TABLES.CANCUN;
    
    // Check ADD operation
    if (cancun_table[0x01]) |add_op| {
        try testing.expectEqual(@as(u32, 2), add_op.min_stack);
        try testing.expectEqual(@as(u32, Stack.CAPACITY), add_op.max_stack);
        try testing.expect(add_op.constant_gas == 3); // GasFastestStep
    }
    
    // Check PUSH1 operation
    if (cancun_table[0x60]) |push1_op| {
        try testing.expectEqual(@as(u32, 0), push1_op.min_stack);
        try testing.expectEqual(@as(u32, Stack.CAPACITY - 1), push1_op.max_stack);
    }
}

test "all hardfork tables are populated" {
    // Ensure all tables have some operations
    try testing.expect(countOperations(TABLES.FRONTIER) > 100);
    try testing.expect(countOperations(TABLES.CANCUN) > countOperations(TABLES.FRONTIER));
}

fn countOperations(table: [256]?*const Operation) usize {
    var count: usize = 0;
    for (table) |op| {
        if (op != null) count += 1;
    }
    return count;
}