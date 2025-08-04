const std = @import("std");
const builtin = @import("builtin");
const Opcode = @import("../opcodes/opcode.zig");
const operation_module = @import("../opcodes/operation.zig");
const Operation = operation_module.Operation;
const Hardfork = @import("../hardforks/hardfork.zig").Hardfork;
const ExecutionError = @import("../execution/execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Frame = @import("../frame/frame.zig");
const Contract = @import("../frame/contract.zig");
const primitives = @import("primitives");
const Log = @import("../log.zig");

// Export inline hot ops optimization
pub const execute_with_inline_hot_ops = @import("inline_hot_ops.zig").execute_with_inline_hot_ops;

const execution = @import("../execution/package.zig");
const stack_ops = execution.stack;
const log = execution.log;
const operation_config = @import("operation_config.zig");

/// EVM jump table for efficient opcode dispatch.
///
/// The jump table is a critical performance optimization that maps opcodes
/// to their execution handlers. Instead of using a switch statement with
/// 256 cases, the jump table provides O(1) dispatch by indexing directly
/// into an array of function pointers.
///
/// ## Design Rationale
/// - Array indexing is faster than switch statement branching
/// - Cache-line alignment improves memory access patterns
/// - Hardfork-specific tables allow for efficient versioning
/// - Null entries default to UNDEFINED operation
///
/// ## Hardfork Evolution
/// The jump table evolves with each hardfork:
/// - New opcodes are added (e.g., PUSH0 in Shanghai)
/// - Gas costs change (e.g., SLOAD in Berlin)
/// - Opcodes are removed or modified
///
/// ## Performance Considerations
/// - 64-byte cache line alignment reduces cache misses
/// - Direct indexing eliminates branch prediction overhead
/// - Operation structs are immutable for thread safety
///
/// Example:
/// ```zig
/// const table = JumpTable.init_from_hardfork(.CANCUN);
/// const opcode = bytecode[pc];
/// const operation = table.get_operation(opcode);
/// const result = try table.execute(pc, interpreter, state, opcode);
/// ```
pub const JumpTable = @This();

/// CPU cache line size for optimal memory alignment.
/// Most modern x86/ARM processors use 64-byte cache lines.
const CACHE_LINE_SIZE = 64;

/// Array of operation handlers indexed by opcode value.
/// Aligned to cache line boundaries for optimal performance.
/// Null entries are treated as undefined opcodes.
table: [256]?*const Operation align(CACHE_LINE_SIZE),

/// CANCUN jump table, pre-generated at compile time.
/// This is the latest hardfork configuration.
pub const CANCUN = init_from_hardfork(.CANCUN);

/// Default jump table for the latest hardfork.
/// References CANCUN to avoid generating the same table twice.
/// This is what gets used when no jump table is specified.
pub const DEFAULT = CANCUN;

/// Create an empty jump table with all entries set to null.
///
/// This creates a blank jump table that must be populated with
/// operations before use. Typically, you'll want to use
/// init_from_hardfork() instead to get a pre-configured table.
///
/// @return An empty jump table
pub fn init() JumpTable {
    return JumpTable{
        .table = [_]?*const Operation{null} ** 256,
    };
}

/// Get the operation handler for a given opcode.
///
/// Returns the operation associated with the opcode, or the NULL
/// operation if the opcode is undefined in this jump table.
///
/// @param self The jump table
/// @param opcode The opcode byte value (0x00-0xFF)
/// @return Operation handler (never null)
///
/// Example:
/// ```zig
/// const op = table.get_operation(0x01); // Get ADD operation
/// ```
pub inline fn get_operation(self: *const JumpTable, opcode: u8) *const Operation {
    return self.table[opcode] orelse &operation_module.NULL_OPERATION;
}

/// Execute an opcode using the jump table.
///
/// This is the main dispatch function that:
/// 1. Looks up the operation for the opcode
/// 2. Validates stack requirements (CRITICAL: This enables size optimization!)
/// 3. Consumes gas
/// 4. Executes the operation
///
/// ## SIZE OPTIMIZATION SAFETY GUARANTEE
///
/// The `validate_stack_requirements()` call at line 139 provides comprehensive
/// stack validation for ALL operations using the min_stack/max_stack metadata
/// from operation_config.zig. This validation ensures:
///
/// - Operations requiring 2 stack items (ADD, SUB, etc.) have >= 2 items
/// - Operations requiring 3 stack items (ADDMOD, etc.) have >= 3 items
/// - Operations that push have sufficient capacity (stack.size <= max_stack)
///
/// BECAUSE of this validation, individual operations can safely use:
/// - `stack.pop_unsafe()` without size checks
/// - `stack.append_unsafe()` without capacity checks
/// - `stack.dup_unsafe()` without bounds checks
/// - `stack.swap_unsafe()` without bounds checks
///
/// This eliminates redundant size checks in hot paths, reducing binary size
/// while maintaining EVM correctness and safety.
///
/// @param self The jump table
/// @param pc Current program counter
/// @param interpreter VM interpreter context
/// @param state Execution state (cast to Frame internally)
/// @param opcode The opcode to execute
/// @return Execution result with gas consumed
/// @throws InvalidOpcode if opcode is undefined
/// @throws StackUnderflow/Overflow if validation fails
/// @throws OutOfGas if insufficient gas
///
/// Example:
/// ```zig
/// const result = try table.execute(pc, &interpreter, &state, bytecode[pc]);
/// ```
pub inline fn execute(self: *const JumpTable, pc: usize, interpreter: operation_module.Interpreter, frame: operation_module.State, opcode: u8) ExecutionError.Error!operation_module.ExecutionResult {
    @branchHint(.likely);
    const operation = self.get_operation(opcode);

    Log.debug("JumpTable.execute: Executing opcode 0x{x:0>2} at pc={}, gas={}, stack_size={}", .{ opcode, pc, frame.gas_remaining, frame.stack.size });

    // Handle undefined opcodes (cold path)
    if (operation.undefined) {
        @branchHint(.cold);
        Log.debug("JumpTable.execute: Invalid opcode 0x{x:0>2}", .{opcode});
        frame.gas_remaining = 0;
        return ExecutionError.Error.InvalidOpcode;
    }

    // Use fast stack validation in ReleaseFast mode, traditional in other modes
    if (comptime builtin.mode == .ReleaseFast) {
        const stack_height_changes = @import("../opcodes/stack_height_changes.zig");
        try stack_height_changes.validate_stack_requirements_fast(
            @intCast(frame.stack.size),
            opcode,
            operation.min_stack,
            operation.max_stack,
        );
    } else {
        const stack_validation = @import("../stack/stack_validation.zig");
        try stack_validation.validate_stack_requirements(&frame.stack, operation);
    }

    // Gas consumption (likely path)
    if (operation.constant_gas > 0) {
        @branchHint(.likely);
        Log.debug("JumpTable.execute: Consuming {} gas for opcode 0x{x:0>2}", .{ operation.constant_gas, opcode });
        try frame.consume_gas(operation.constant_gas);
    }

    const res = try operation.execute(pc, interpreter, frame);
    Log.debug("JumpTable.execute: Opcode 0x{x:0>2} completed, gas_remaining={}", .{ opcode, frame.gas_remaining });
    return res;
}

/// Validate and fix the jump table.
///
/// Ensures all entries are valid:
/// - Null entries are replaced with UNDEFINED operation
/// - Operations with memory_size must have dynamic_gas
/// - Invalid operations are logged and replaced
///
/// This should be called after manually constructing a jump table
/// to ensure it's safe for execution.
///
/// @param self The jump table to validate
pub fn validate(self: *JumpTable) void {
    for (0..256) |i| {
        // Handle null entries (less common)
        if (self.table[i] == null) {
            @branchHint(.cold);
            self.table[i] = &operation_module.NULL_OPERATION;
            continue;
        }

        // Check for invalid operation configuration (error path)
        const operation = self.table[i].?;
        if (operation.memory_size != null and operation.dynamic_gas == null) {
            @branchHint(.cold);
            // Log error instead of panicking
            Log.debug("Warning: Operation 0x{x} has memory size but no dynamic gas calculation", .{i});
            // Set to NULL to prevent issues
            self.table[i] = &operation_module.NULL_OPERATION;
        }
    }
}

pub fn copy(self: *const JumpTable, allocator: std.mem.Allocator) !JumpTable {
    _ = allocator;
    return JumpTable{
        .table = self.table,
    };
}

/// Create a jump table configured for a specific hardfork.
///
/// This is the primary way to create a jump table. It starts with
/// the Frontier base configuration and applies all changes up to
/// the specified hardfork.
///
/// @param hardfork The target hardfork configuration
/// @return A fully configured jump table
///
/// Hardfork progression:
/// - FRONTIER: Base EVM opcodes
/// - HOMESTEAD: DELEGATECALL
/// - TANGERINE_WHISTLE: Gas repricing (EIP-150)
/// - BYZANTIUM: REVERT, RETURNDATASIZE, STATICCALL
/// - CONSTANTINOPLE: CREATE2, SHL/SHR/SAR, EXTCODEHASH
/// - ISTANBUL: CHAINID, SELFBALANCE, more gas changes
/// - BERLIN: Access lists, cold/warm storage
/// - LONDON: BASEFEE
/// - SHANGHAI: PUSH0
/// - CANCUN: BLOBHASH, MCOPY, transient storage
///
/// Example:
/// ```zig
/// const table = JumpTable.init_from_hardfork(.CANCUN);
/// // Table includes all opcodes through Cancun
/// ```
pub fn init_from_hardfork(hardfork: Hardfork) JumpTable {
    @setEvalBranchQuota(10000);
    var jt = JumpTable.init();
    // With ALL_OPERATIONS sorted by hardfork, we can iterate once.
    // Each opcode will be set to the latest active version for the target hardfork.
    inline for (operation_config.ALL_OPERATIONS) |spec| {
        const op_hardfork = spec.variant orelse Hardfork.FRONTIER;
        // Most operations are included in hardforks (likely path)
        if (@intFromEnum(op_hardfork) <= @intFromEnum(hardfork)) {
            const op = struct {
                pub const operation = operation_config.generate_operation(spec);
            };
            jt.table[spec.opcode] = &op.operation;
        }
    }
    // 0x60s & 0x70s: Push operations
    if (comptime builtin.mode == .ReleaseSmall) {
        // Use static const operations to avoid memory corruption in ReleaseSmall
        const static_push_op = struct {
            const op = Operation{
                .execute = stack_ops.push_n,
                .constant_gas = execution.GasConstants.GasFastestStep,
                .min_stack = 0,
                .max_stack = Stack.CAPACITY - 1,
            };
        };

        for (0..32) |i| {
            jt.table[0x60 + i] = &static_push_op.op;
        }
    } else {
        // Optimized implementations for common small PUSH operations
        // PUSH1 - most common, optimized with direct byte access
        jt.table[0x60] = &Operation{
            .execute = stack_ops.op_push1,
            .constant_gas = execution.gas_constants.GasFastestStep,
            .min_stack = 0,
            .max_stack = Stack.CAPACITY - 1,
        };

        // PUSH2-PUSH8 - optimized with u64 arithmetic
        inline for (1..8) |i| {
            const n = i + 1;
            jt.table[0x60 + i] = &Operation{
                .execute = stack_ops.make_push_small(n),
                .constant_gas = execution.gas_constants.GasFastestStep,
                .min_stack = 0,
                .max_stack = Stack.CAPACITY - 1,
            };
        }

        // PUSH9-PUSH32 - use generic implementation
        inline for (8..32) |i| {
            const n = i + 1;
            jt.table[0x60 + i] = &Operation{
                .execute = stack_ops.make_push(n),
                .constant_gas = execution.GasConstants.GasFastestStep,
                .min_stack = 0,
                .max_stack = Stack.CAPACITY - 1,
            };
        }
    }
    // 0x80s: Duplication Operations
    if (comptime builtin.mode == .ReleaseSmall) {
        // Use specific functions for each DUP operation to avoid opcode detection issues
        const dup_functions = [_]fn (usize, operation_module.Interpreter, operation_module.State) ExecutionError.Error!operation_module.ExecutionResult{
            stack_ops.dup_1,  stack_ops.dup_2,  stack_ops.dup_3,  stack_ops.dup_4,
            stack_ops.dup_5,  stack_ops.dup_6,  stack_ops.dup_7,  stack_ops.dup_8,
            stack_ops.dup_9,  stack_ops.dup_10, stack_ops.dup_11, stack_ops.dup_12,
            stack_ops.dup_13, stack_ops.dup_14, stack_ops.dup_15, stack_ops.dup_16,
        };

        inline for (1..17) |n| {
            const dup_op = struct {
                const op = Operation{
                    .execute = dup_functions[n - 1],
                    .constant_gas = execution.GasConstants.GasFastestStep,
                    .min_stack = @intCast(n),
                    .max_stack = Stack.CAPACITY - 1,
                };
            };
            jt.table[0x80 + n - 1] = &dup_op.op;
        }
    } else {
        inline for (1..17) |n| {
            jt.table[0x80 + n - 1] = &Operation{
                .execute = stack_ops.make_dup(n),
                .constant_gas = execution.GasConstants.GasFastestStep,
                .min_stack = @intCast(n),
                .max_stack = Stack.CAPACITY - 1,
            };
        }
    }
    // 0x90s: Exchange Operations
    if (comptime builtin.mode == .ReleaseSmall) {
        // Use specific functions for each SWAP operation to avoid opcode detection issues
        const swap_functions = [_]fn (usize, operation_module.Interpreter, operation_module.State) ExecutionError.Error!operation_module.ExecutionResult{
            stack_ops.swap_1,  stack_ops.swap_2,  stack_ops.swap_3,  stack_ops.swap_4,
            stack_ops.swap_5,  stack_ops.swap_6,  stack_ops.swap_7,  stack_ops.swap_8,
            stack_ops.swap_9,  stack_ops.swap_10, stack_ops.swap_11, stack_ops.swap_12,
            stack_ops.swap_13, stack_ops.swap_14, stack_ops.swap_15, stack_ops.swap_16,
        };

        inline for (1..17) |n| {
            const swap_op = struct {
                const op = Operation{
                    .execute = swap_functions[n - 1],
                    .constant_gas = execution.GasConstants.GasFastestStep,
                    .min_stack = @intCast(n + 1),
                    .max_stack = Stack.CAPACITY,
                };
            };
            jt.table[0x90 + n - 1] = &swap_op.op;
        }
    } else {
        inline for (1..17) |n| {
            jt.table[0x90 + n - 1] = &Operation{
                .execute = stack_ops.make_swap(n),
                .constant_gas = execution.GasConstants.GasFastestStep,
                .min_stack = @intCast(n + 1),
                .max_stack = Stack.CAPACITY,
            };
        }
    }
    // 0xa0s: Logging Operations
    if (comptime builtin.mode == .ReleaseSmall) {
        // Use specific functions for each LOG operation to avoid opcode detection issues
        const log_functions = [_]fn (usize, operation_module.Interpreter, operation_module.State) ExecutionError.Error!operation_module.ExecutionResult{
            log.log_0, log.log_1, log.log_2, log.log_3, log.log_4,
        };

        inline for (0..5) |n| {
            const log_op = struct {
                const op = Operation{
                    .execute = log_functions[n],
                    .constant_gas = execution.GasConstants.LogGas + execution.GasConstants.LogTopicGas * n,
                    .min_stack = @intCast(n + 2),
                    .max_stack = Stack.CAPACITY,
                };
            };
            jt.table[0xa0 + n] = &log_op.op;
        }
    } else {
        inline for (0..5) |n| {
            jt.table[0xa0 + n] = &Operation{
                .execute = log.make_log(n),
                .constant_gas = execution.GasConstants.LogGas + execution.GasConstants.LogTopicGas * n,
                .min_stack = @intCast(n + 2),
                .max_stack = Stack.CAPACITY,
            };
        }
    }
    jt.validate();
    return jt;
}

test "jump_table_benchmarks" {
    const Timer = std.time.Timer;
    var timer = try Timer.start();
    const allocator = std.testing.allocator;

    // Setup test environment
    var memory_db = @import("../state/memory_database.zig").MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    var vm = try @import("../evm.zig").Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const iterations = 100000;

    // Benchmark 1: Opcode dispatch performance comparison
    const cancun_table = JumpTable.init_from_hardfork(.CANCUN);
    const shanghai_table = JumpTable.init_from_hardfork(.SHANGHAI);
    const berlin_table = JumpTable.init_from_hardfork(.BERLIN);

    timer.reset();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        // Test common opcodes across different hardforks
        const opcode: u8 = @intCast(i % 256);
        _ = cancun_table.get_operation(opcode);
    }
    const cancun_dispatch_ns = timer.read();

    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        const opcode: u8 = @intCast(i % 256);
        _ = shanghai_table.get_operation(opcode);
    }
    const shanghai_dispatch_ns = timer.read();

    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        const opcode: u8 = @intCast(i % 256);
        _ = berlin_table.get_operation(opcode);
    }
    const berlin_dispatch_ns = timer.read();

    // Benchmark 2: Hot path opcode execution (common operations)
    const hot_opcodes = [_]u8{ 0x60, 0x80, 0x01, 0x50, 0x90 }; // PUSH1, DUP1, ADD, POP, SWAP1

    timer.reset();
    for (hot_opcodes) |opcode| {
        i = 0;
        while (i < iterations / hot_opcodes.len) : (i += 1) {
            const operation = cancun_table.get_operation(opcode);
            // Simulate getting operation metadata
            _ = operation.constant_gas;
            _ = operation.min_stack;
            _ = operation.max_stack;
        }
    }
    const hot_path_ns = timer.read();

    // Benchmark 3: Cold path opcode handling (undefined/invalid opcodes)
    timer.reset();
    const invalid_opcodes = [_]u8{ 0x0c, 0x0d, 0x0e, 0x0f, 0x1e, 0x1f }; // Invalid opcodes

    for (invalid_opcodes) |opcode| {
        i = 0;
        while (i < 1000) : (i += 1) { // Fewer iterations for cold path
            const operation = cancun_table.get_operation(opcode);
            // These should return null or undefined operation
            _ = operation;
        }
    }
    const cold_path_ns = timer.read();

    // Benchmark 4: Hardfork-specific opcode availability
    timer.reset();
    const hardfork_specific_opcodes = [_]struct { opcode: u8, hardfork: Hardfork }{
        .{ .opcode = 0x5f, .hardfork = .SHANGHAI }, // PUSH0 - only available from Shanghai
        .{ .opcode = 0x46, .hardfork = .BERLIN }, // CHAINID - available from Istanbul
        .{ .opcode = 0x48, .hardfork = .LONDON }, // BASEFEE - available from London
    };

    for (hardfork_specific_opcodes) |test_case| {
        const table = JumpTable.init_from_hardfork(test_case.hardfork);
        i = 0;
        while (i < 10000) : (i += 1) {
            const operation = table.get_operation(test_case.opcode);
            _ = operation;
        }
    }
    const hardfork_specific_ns = timer.read();

    // Benchmark 5: Branch prediction impact (predictable vs unpredictable patterns)
    var rng = std.Random.DefaultPrng.init(12345);
    const random = rng.random();

    // Predictable pattern - sequential opcodes
    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        const opcode: u8 = @intCast(i % 50); // Sequential pattern
        _ = cancun_table.get_operation(opcode);
    }
    const predictable_ns = timer.read();

    // Unpredictable pattern - random opcodes
    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        const opcode: u8 = random.int(u8); // Random pattern
        _ = cancun_table.get_operation(opcode);
    }
    const unpredictable_ns = timer.read();

    // Benchmark 6: Cache locality test with table scanning
    timer.reset();
    i = 0;
    while (i < 1000) : (i += 1) { // Fewer iterations due to full scan cost
        // Scan entire jump table (tests cache locality)
        for (0..256) |opcode_idx| {
            _ = cancun_table.get_operation(@intCast(opcode_idx));
        }
    }
    const table_scan_ns = timer.read();

    // Print benchmark results
    std.log.debug("Jump Table Benchmarks:", .{});
    std.log.debug("  Cancun dispatch ({} ops): {} ns", .{ iterations, cancun_dispatch_ns });
    std.log.debug("  Shanghai dispatch ({} ops): {} ns", .{ iterations, shanghai_dispatch_ns });
    std.log.debug("  Berlin dispatch ({} ops): {} ns", .{ iterations, berlin_dispatch_ns });
    std.log.debug("  Hot path operations: {} ns", .{hot_path_ns});
    std.log.debug("  Cold path operations: {} ns", .{cold_path_ns});
    std.log.debug("  Hardfork-specific ops: {} ns", .{hardfork_specific_ns});
    std.log.debug("  Predictable pattern ({} ops): {} ns", .{ iterations, predictable_ns });
    std.log.debug("  Unpredictable pattern ({} ops): {} ns", .{ iterations, unpredictable_ns });
    std.log.debug("  Full table scan (1000x): {} ns", .{table_scan_ns});

    // Performance analysis
    const avg_dispatch_ns = cancun_dispatch_ns / iterations;
    const avg_predictable_ns = predictable_ns / iterations;
    const avg_unpredictable_ns = unpredictable_ns / iterations;

    std.log.debug("  Average dispatch time: {} ns/op", .{avg_dispatch_ns});
    std.log.debug("  Average predictable: {} ns/op", .{avg_predictable_ns});
    std.log.debug("  Average unpredictable: {} ns/op", .{avg_unpredictable_ns});

    // Branch prediction analysis
    if (avg_predictable_ns < avg_unpredictable_ns) {
        std.log.debug("✓ Branch prediction benefit observed");
    }

    // Hardfork dispatch performance comparison
    const cancun_avg = cancun_dispatch_ns / iterations;
    const shanghai_avg = shanghai_dispatch_ns / iterations;
    const berlin_avg = berlin_dispatch_ns / iterations;

    std.log.debug("  Hardfork dispatch comparison:");
    std.log.debug("    Berlin avg: {} ns/op", .{berlin_avg});
    std.log.debug("    Shanghai avg: {} ns/op", .{shanghai_avg});
    std.log.debug("    Cancun avg: {} ns/op", .{cancun_avg});

    // Expect very fast dispatch (should be just array indexing)
    if (avg_dispatch_ns < 10) {
        std.log.debug("✓ Jump table showing expected O(1) performance");
    }
}
