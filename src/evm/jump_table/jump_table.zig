const std = @import("std");
const builtin = @import("builtin");
const Opcode = @import("../opcodes/opcode.zig");
const operation_module = @import("../opcodes/operation.zig");
const Operation = operation_module.Operation;
const ExecutionFunc = operation_module.ExecutionFunc;
const GasFunc = operation_module.GasFunc;
const MemorySizeFunc = operation_module.MemorySizeFunc;
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
/// into arrays of function pointers and metadata.
///
/// ## Design Rationale
/// - Parallel arrays provide better cache locality than array-of-structs
/// - Hot data (execute functions, gas costs) are in contiguous memory
/// - Cache-line alignment improves memory access patterns
/// - Direct indexing eliminates branch prediction overhead
///
/// ## Memory Layout (Struct-of-Arrays)
/// - execute_funcs: 256 * 8 bytes = 2KB (hot path)
/// - constant_gas: 256 * 8 bytes = 2KB (hot path)
/// - min_stack: 256 * 4 bytes = 1KB (validation)
/// - max_stack: 256 * 4 bytes = 1KB (validation)
/// - dynamic_gas: 256 * 8 bytes = 2KB (cold path)
/// - memory_size: 256 * 8 bytes = 2KB (cold path)
/// - undefined_flags: 256 * 1 byte = 256 bytes (cold path)
/// Total: ~10.25KB with better cache utilization
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

/// Hot path arrays - accessed every opcode execution
execute_funcs: [256]ExecutionFunc align(CACHE_LINE_SIZE),
constant_gas: [256]u64 align(CACHE_LINE_SIZE),

/// Validation arrays - accessed for stack checks
min_stack: [256]u32 align(CACHE_LINE_SIZE),
max_stack: [256]u32 align(CACHE_LINE_SIZE),

/// Cold path arrays - rarely accessed
dynamic_gas: [256]?GasFunc align(CACHE_LINE_SIZE),
memory_size: [256]?MemorySizeFunc align(CACHE_LINE_SIZE),
undefined_flags: [256]bool align(CACHE_LINE_SIZE),

/// CANCUN jump table, pre-generated at compile time.
/// This is the latest hardfork configuration.
pub const CANCUN = init_from_hardfork(.CANCUN);

/// Default jump table for the latest hardfork.
/// References CANCUN to avoid generating the same table twice.
/// This is what gets used when no jump table is specified.
pub const DEFAULT = CANCUN;

/// Create an empty jump table with all entries set to defaults.
///
/// This creates a blank jump table that must be populated with
/// operations before use. Typically, you'll want to use
/// init_from_hardfork() instead to get a pre-configured table.
///
/// @return An empty jump table
pub fn init() JumpTable {
    const undefined_execute = operation_module.NULL_OPERATION.execute;
    return JumpTable{
        .execute_funcs = [_]ExecutionFunc{undefined_execute} ** 256,
        .constant_gas = [_]u64{0} ** 256,
        .min_stack = [_]u32{0} ** 256,
        .max_stack = [_]u32{Stack.CAPACITY} ** 256,
        .dynamic_gas = [_]?GasFunc{null} ** 256,
        .memory_size = [_]?MemorySizeFunc{null} ** 256,
        .undefined_flags = [_]bool{true} ** 256,
    };
}

/// Temporary struct returned by get_operation for API compatibility
pub const OperationView = struct {
    execute: ExecutionFunc,
    constant_gas: u64,
    min_stack: u32,
    max_stack: u32,
    dynamic_gas: ?GasFunc,
    memory_size: ?MemorySizeFunc,
    undefined: bool,
};

/// Get the operation handler for a given opcode.
///
/// Returns a view of the operation data for the opcode.
/// This maintains API compatibility while using parallel arrays internally.
///
/// @param self The jump table
/// @param opcode The opcode byte value (0x00-0xFF)
/// @return Operation view struct
///
/// Example:
/// ```zig
/// const op = table.get_operation(0x01); // Get ADD operation
/// ```
pub inline fn get_operation(self: *const JumpTable, opcode: u8) OperationView {
    return OperationView{
        .execute = self.execute_funcs[opcode],
        .constant_gas = self.constant_gas[opcode],
        .min_stack = self.min_stack[opcode],
        .max_stack = self.max_stack[opcode],
        .dynamic_gas = self.dynamic_gas[opcode],
        .memory_size = self.memory_size[opcode],
        .undefined = self.undefined_flags[opcode],
    };
}

/// Execute an opcode using the jump table.
///
/// This is the main dispatch function that:
/// 1. Looks up the operation data for the opcode
/// 2. Validates stack requirements
/// 3. Consumes gas
/// 4. Executes the operation
///
/// The parallel array structure provides better cache locality:
/// - execute_funcs and constant_gas are accessed together (hot path)
/// - Stack validation data is in separate cache lines
/// - Cold path data (dynamic_gas, memory_size) doesn't pollute hot cache
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
    
    Log.debug("JumpTable.execute: Executing opcode 0x{x:0>2} at pc={}, gas={}, stack_size={}", .{ opcode, pc, frame.gas_remaining, frame.stack.size });

    // Handle undefined opcodes (cold path)
    if (self.undefined_flags[opcode]) {
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
            self.min_stack[opcode],
            self.max_stack[opcode],
        );
    } else {
        // Create temporary operation view for stack validation
        const op_view = OperationView{
            .execute = self.execute_funcs[opcode],
            .constant_gas = self.constant_gas[opcode],
            .min_stack = self.min_stack[opcode],
            .max_stack = self.max_stack[opcode],
            .dynamic_gas = self.dynamic_gas[opcode],
            .memory_size = self.memory_size[opcode],
            .undefined = self.undefined_flags[opcode],
        };
        const stack_validation = @import("../stack/stack_validation.zig");
        try stack_validation.validate_stack_requirements(&frame.stack, &op_view);
    }

    // Gas consumption - consume_gas already handles zero cost efficiently
    const gas_cost = self.constant_gas[opcode];
    Log.debug("JumpTable.execute: Consuming {} gas for opcode 0x{x:0>2}", .{ gas_cost, opcode });
    try frame.consume_gas(gas_cost);

    const res = try self.execute_funcs[opcode](pc, interpreter, frame);
    Log.debug("JumpTable.execute: Opcode 0x{x:0>2} completed, gas_remaining={}", .{ opcode, frame.gas_remaining });
    return res;
}

/// Validate and fix the jump table.
///
/// Ensures all entries are valid:
/// - Operations with memory_size must have dynamic_gas
/// - Invalid operations are logged and marked as undefined
///
/// This should be called after manually constructing a jump table
/// to ensure it's safe for execution.
///
/// @param self The jump table to validate
pub fn validate(self: *JumpTable) void {
    for (0..256) |i| {
        // Check for invalid operation configuration (error path)
        if (self.memory_size[i] != null and self.dynamic_gas[i] == null) {
            @branchHint(.cold);
            // Log error instead of panicking
            Log.debug("Warning: Operation 0x{x} has memory size but no dynamic gas calculation", .{i});
            // Mark as undefined to prevent issues
            self.undefined_flags[i] = true;
            self.execute_funcs[i] = operation_module.NULL_OPERATION.execute;
        }
    }
}

pub fn copy(self: *const JumpTable, allocator: std.mem.Allocator) !JumpTable {
    _ = allocator;
    return JumpTable{
        .execute_funcs = self.execute_funcs,
        .constant_gas = self.constant_gas,
        .min_stack = self.min_stack,
        .max_stack = self.max_stack,
        .dynamic_gas = self.dynamic_gas,
        .memory_size = self.memory_size,
        .undefined_flags = self.undefined_flags,
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
            const op = operation_config.generate_operation(spec);
            const idx = spec.opcode;
            jt.execute_funcs[idx] = op.execute;
            jt.constant_gas[idx] = op.constant_gas;
            jt.min_stack[idx] = op.min_stack;
            jt.max_stack[idx] = op.max_stack;
            jt.dynamic_gas[idx] = op.dynamic_gas;
            jt.memory_size[idx] = op.memory_size;
            jt.undefined_flags[idx] = op.undefined;
        }
    }
    
    // 0x60s & 0x70s: Push operations
    if (comptime builtin.mode == .ReleaseSmall) {
        // Use static const operations to avoid memory corruption in ReleaseSmall
        for (0..32) |i| {
            jt.execute_funcs[0x60 + i] = stack_ops.push_n;
            jt.constant_gas[0x60 + i] = execution.GasConstants.GasFastestStep;
            jt.min_stack[0x60 + i] = 0;
            jt.max_stack[0x60 + i] = Stack.CAPACITY - 1;
            jt.undefined_flags[0x60 + i] = false;
        }
    } else {
        // Optimized implementations for common small PUSH operations
        // PUSH1 - most common, optimized with direct byte access
        jt.execute_funcs[0x60] = stack_ops.op_push1;
        jt.constant_gas[0x60] = execution.gas_constants.GasFastestStep;
        jt.min_stack[0x60] = 0;
        jt.max_stack[0x60] = Stack.CAPACITY - 1;
        jt.undefined_flags[0x60] = false;

        // PUSH2-PUSH8 - optimized with u64 arithmetic
        inline for (1..8) |i| {
            const n = i + 1;
            jt.execute_funcs[0x60 + i] = stack_ops.make_push_small(n);
            jt.constant_gas[0x60 + i] = execution.gas_constants.GasFastestStep;
            jt.min_stack[0x60 + i] = 0;
            jt.max_stack[0x60 + i] = Stack.CAPACITY - 1;
            jt.undefined_flags[0x60 + i] = false;
        }

        // PUSH9-PUSH32 - use generic implementation
        inline for (8..32) |i| {
            const n = i + 1;
            jt.execute_funcs[0x60 + i] = stack_ops.make_push(n);
            jt.constant_gas[0x60 + i] = execution.GasConstants.GasFastestStep;
            jt.min_stack[0x60 + i] = 0;
            jt.max_stack[0x60 + i] = Stack.CAPACITY - 1;
            jt.undefined_flags[0x60 + i] = false;
        }
    }
    
    // 0x80s: Duplication Operations
    if (comptime builtin.mode == .ReleaseSmall) {
        // Use specific functions for each DUP operation to avoid opcode detection issues
        const dup_functions = [_]ExecutionFunc{
            stack_ops.dup_1,  stack_ops.dup_2,  stack_ops.dup_3,  stack_ops.dup_4,
            stack_ops.dup_5,  stack_ops.dup_6,  stack_ops.dup_7,  stack_ops.dup_8,
            stack_ops.dup_9,  stack_ops.dup_10, stack_ops.dup_11, stack_ops.dup_12,
            stack_ops.dup_13, stack_ops.dup_14, stack_ops.dup_15, stack_ops.dup_16,
        };

        inline for (1..17) |n| {
            const idx = 0x80 + n - 1;
            jt.execute_funcs[idx] = dup_functions[n - 1];
            jt.constant_gas[idx] = execution.GasConstants.GasFastestStep;
            jt.min_stack[idx] = @intCast(n);
            jt.max_stack[idx] = Stack.CAPACITY - 1;
            jt.undefined_flags[idx] = false;
        }
    } else {
        inline for (1..17) |n| {
            const idx = 0x80 + n - 1;
            jt.execute_funcs[idx] = stack_ops.make_dup(n);
            jt.constant_gas[idx] = execution.GasConstants.GasFastestStep;
            jt.min_stack[idx] = @intCast(n);
            jt.max_stack[idx] = Stack.CAPACITY - 1;
            jt.undefined_flags[idx] = false;
        }
    }
    
    // 0x90s: Exchange Operations
    if (comptime builtin.mode == .ReleaseSmall) {
        // Use specific functions for each SWAP operation to avoid opcode detection issues
        const swap_functions = [_]ExecutionFunc{
            stack_ops.swap_1,  stack_ops.swap_2,  stack_ops.swap_3,  stack_ops.swap_4,
            stack_ops.swap_5,  stack_ops.swap_6,  stack_ops.swap_7,  stack_ops.swap_8,
            stack_ops.swap_9,  stack_ops.swap_10, stack_ops.swap_11, stack_ops.swap_12,
            stack_ops.swap_13, stack_ops.swap_14, stack_ops.swap_15, stack_ops.swap_16,
        };

        inline for (1..17) |n| {
            const idx = 0x90 + n - 1;
            jt.execute_funcs[idx] = swap_functions[n - 1];
            jt.constant_gas[idx] = execution.GasConstants.GasFastestStep;
            jt.min_stack[idx] = @intCast(n + 1);
            jt.max_stack[idx] = Stack.CAPACITY;
            jt.undefined_flags[idx] = false;
        }
    } else {
        inline for (1..17) |n| {
            const idx = 0x90 + n - 1;
            jt.execute_funcs[idx] = stack_ops.make_swap(n);
            jt.constant_gas[idx] = execution.GasConstants.GasFastestStep;
            jt.min_stack[idx] = @intCast(n + 1);
            jt.max_stack[idx] = Stack.CAPACITY;
            jt.undefined_flags[idx] = false;
        }
    }
    
    // 0xa0s: Logging Operations
    if (comptime builtin.mode == .ReleaseSmall) {
        // Use specific functions for each LOG operation to avoid opcode detection issues
        const log_functions = [_]ExecutionFunc{
            log.log_0, log.log_1, log.log_2, log.log_3, log.log_4,
        };

        inline for (0..5) |n| {
            const idx = 0xa0 + n;
            jt.execute_funcs[idx] = log_functions[n];
            jt.constant_gas[idx] = execution.GasConstants.LogGas + execution.GasConstants.LogTopicGas * n;
            jt.min_stack[idx] = @intCast(n + 2);
            jt.max_stack[idx] = Stack.CAPACITY;
            jt.undefined_flags[idx] = false;
        }
    } else {
        inline for (0..5) |n| {
            const idx = 0xa0 + n;
            jt.execute_funcs[idx] = log.make_log(n);
            jt.constant_gas[idx] = execution.GasConstants.LogGas + execution.GasConstants.LogTopicGas * n;
            jt.min_stack[idx] = @intCast(n + 2);
            jt.max_stack[idx] = Stack.CAPACITY;
            jt.undefined_flags[idx] = false;
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
    var vm = try @import("../evm.zig").Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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