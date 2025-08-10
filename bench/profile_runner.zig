const std = @import("std");
const root = @import("root.zig");
const Allocator = std.mem.Allocator;

// Import EVM components
const Evm = root.Evm;
const Frame = Evm.Frame;
const Contract = Evm.Contract;
const MemoryDatabase = Evm.MemoryDatabase;
const Operation = Evm.Operation;
const Address = root.primitives.Address;

pub const BenchmarkProfile = enum {
    all,
    arithmetic_ops,
    memory_ops,
    storage_ops,
    stack_ops,
    control_flow,
    precompiles,
    contract_calls,
};

pub fn run_profiling_workload(allocator: Allocator, profile: BenchmarkProfile) !void {
    // Run longer iterations for better profiling data
    const profile_iterations = 100;

    switch (profile) {
        .all => try run_all_profiles(allocator, profile_iterations),
        .arithmetic_ops => try profile_arithmetic_ops(allocator, profile_iterations),
        .memory_ops => try profile_memory_ops(allocator, profile_iterations),
        .storage_ops => try profile_storage_ops(allocator, profile_iterations),
        .stack_ops => try profile_stack_ops(allocator, profile_iterations),
        .control_flow => try profile_control_flow(allocator, profile_iterations),
        .precompiles => try profile_precompiles(allocator, profile_iterations),
        .contract_calls => try profile_contract_calls(allocator, profile_iterations),
    }
}

fn run_all_profiles(allocator: Allocator, iterations: usize) !void {
    std.log.info("Running all profiling workloads", .{});
    const per_profile = iterations / 8;
    try profile_arithmetic_ops(allocator, per_profile);
    try profile_memory_ops(allocator, per_profile);
    try profile_storage_ops(allocator, per_profile);
    try profile_stack_ops(allocator, per_profile);
    try profile_control_flow(allocator, per_profile);
    try profile_precompiles(allocator, per_profile);
    try profile_contract_calls(allocator, per_profile);
}

// Profile arithmetic operations (ADD, MUL, DIV, MOD, EXP)
fn profile_arithmetic_ops(allocator: Allocator, iterations: usize) !void {
    std.log.info("Profiling arithmetic operations ({} iterations)", .{iterations});

    // Bytecode: Complex arithmetic operations
    const bytecode = [_]u8{
        // Push operands and perform various arithmetic
        0x60, 0xFF, // PUSH1 255
        0x60, 0x02, // PUSH1 2
        0x02, // MUL
        0x60, 0x03, // PUSH1 3
        0x01, // ADD
        0x60, 0x04, // PUSH1 4
        0x04, // DIV
        0x60, 0x05, // PUSH1 5
        0x06, // MOD
        0x60, 0x02, // PUSH1 2
        0x60, 0x08, // PUSH1 8
        0x0A, // EXP
        0x01, // ADD
        0x00, // STOP
    };

    try execute_bytecode_iterations(allocator, &bytecode, iterations);
}

// Profile memory operations (MLOAD, MSTORE, MSTORE8)
fn profile_memory_ops(allocator: Allocator, iterations: usize) !void {
    std.log.info("Profiling memory operations ({} iterations)", .{iterations});

    // Bytecode: Memory read/write patterns
    const bytecode = [_]u8{
        // Store values at different memory locations
        0x60, 0x42, // PUSH1 66
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x99, // PUSH1 153
        0x60, 0x20, // PUSH1 32
        0x52, // MSTORE

        // Load and manipulate
        0x60, 0x00, // PUSH1 0
        0x51, // MLOAD
        0x60, 0x20, // PUSH1 32
        0x51, // MLOAD
        0x01, // ADD
        0x60, 0x40, // PUSH1 64
        0x52, // MSTORE

        // MSTORE8 test
        0x60, 0xFF, // PUSH1 255
        0x60, 0x80, // PUSH1 128
        0x53, // MSTORE8
        0x00, // STOP
    };

    try execute_bytecode_iterations(allocator, &bytecode, iterations);
}

// Profile storage operations (SLOAD, SSTORE)
fn profile_storage_ops(allocator: Allocator, iterations: usize) !void {
    std.log.info("Profiling storage operations ({} iterations)", .{iterations});

    // Bytecode: Storage read/write patterns
    const bytecode = [_]u8{
        // Store values in storage slots
        0x60, 0x42, // PUSH1 66
        0x60, 0x00, // PUSH1 0
        0x55, // SSTORE
        0x60, 0x99, // PUSH1 153
        0x60, 0x01, // PUSH1 1
        0x55, // SSTORE

        // Load and manipulate
        0x60, 0x00, // PUSH1 0
        0x54, // SLOAD
        0x60, 0x01, // PUSH1 1
        0x54, // SLOAD
        0x01, // ADD
        0x60, 0x02, // PUSH1 2
        0x55, // SSTORE
        0x00, // STOP
    };

    try execute_bytecode_iterations(allocator, &bytecode, iterations);
}

// Profile stack operations (PUSH, POP, DUP, SWAP)
fn profile_stack_ops(allocator: Allocator, iterations: usize) !void {
    std.log.info("Profiling stack operations ({} iterations)", .{iterations});

    // Bytecode: Intensive stack manipulation
    const bytecode = [_]u8{
        // Push multiple values
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x60, 0x03, // PUSH1 3
        0x60, 0x04, // PUSH1 4
        0x60, 0x05, // PUSH1 5
        0x60, 0x06, // PUSH1 6

        // DUP operations
        0x80, // DUP1
        0x81, // DUP2
        0x82, // DUP3

        // SWAP operations
        0x90, // SWAP1
        0x91, // SWAP2
        0x92, // SWAP3

        // POP to clean up
        0x50, // POP
        0x50, // POP
        0x50, // POP
        0x50, // POP
        0x50, // POP
        0x50, // POP
        0x00, // STOP
    };

    try execute_bytecode_iterations(allocator, &bytecode, iterations);
}

// Profile control flow operations (JUMP, JUMPI, PC)
fn profile_control_flow(allocator: Allocator, iterations: usize) !void {
    std.log.info("Profiling control flow operations ({} iterations)", .{iterations});

    // Bytecode: Loops and conditional jumps
    const bytecode = [_]u8{
        // Counter setup
        0x60, 0x00, // PUSH1 0 (counter)

        // Loop start (JUMPDEST at position 2)
        0x5B, // JUMPDEST

        // Increment counter
        0x60, 0x01, // PUSH1 1
        0x01, // ADD

        // Check if counter < 10
        0x80, // DUP1
        0x60, 0x0A, // PUSH1 10
        0x10, // LT

        // Jump back if true
        0x60, 0x02, // PUSH1 2 (jump destination)
        0x57, // JUMPI

        // End
        0x50, // POP (clear counter)
        0x00, // STOP
    };

    try execute_bytecode_iterations(allocator, &bytecode, iterations);
}

// Profile precompile calls
fn profile_precompiles(allocator: Allocator, iterations: usize) !void {
    std.log.info("Profiling precompile calls ({} iterations)", .{iterations});

    // Bytecode: Call SHA256 precompile (address 0x02)
    const bytecode = [_]u8{
        // Prepare input data in memory
        0x7F, // PUSH32
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE

        // Call precompile
        0x60, 0x20, // PUSH1 32 (output size)
        0x60, 0x00, // PUSH1 0 (output offset)
        0x60, 0x20, // PUSH1 32 (input size)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x02, // PUSH1 2 (SHA256 address)
        0x61, 0xFF, 0xFF, // PUSH2 65535 (gas)
        0xF1, // CALL
        0x50, // POP (clear return value)
        0x00, // STOP
    };

    try execute_bytecode_iterations(allocator, &bytecode, iterations);
}

// Profile contract calls (CALL, DELEGATECALL, STATICCALL)
fn profile_contract_calls(allocator: Allocator, iterations: usize) !void {
    std.log.info("Profiling contract calls ({} iterations)", .{iterations});

    // This requires setting up a target contract first
    // For now, we'll use a simpler bytecode that prepares for calls
    const bytecode = [_]u8{
        // Prepare call data
        0x60, 0x00, // PUSH1 0 (return data size)
        0x60, 0x00, // PUSH1 0 (return data offset)
        0x60, 0x00, // PUSH1 0 (input size)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x73, // PUSH20 (address)
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x01,
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xF1, // CALL
        0x50, // POP
        0x00, // STOP
    };

    try execute_bytecode_iterations(allocator, &bytecode, iterations);
}

// Helper function to execute bytecode for a given number of iterations
fn execute_bytecode_iterations(allocator: Allocator, bytecode: []const u8, iterations: usize) !void {
    // Set up EVM once
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);
    var evm = try builder.build();
    defer evm.deinit();

    // Set up contract with bytecode
    const caller_address = Address.ZERO;
    const contract_address: Address.Address = [_]u8{0x01} ** 20;

    // Store contract code
    try evm.state.set_code(contract_address, bytecode);

    // Execute multiple times
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        // Create contract instance
        var contract = Contract.init_at_address(caller_address, contract_address, 0, // value
            1_000_000, // gas_limit
            bytecode, &.{}, // input_data
            false // is_static
        );
        defer contract.deinit(allocator, null);

        // Create frame
        var frame_builder = Frame.builder(allocator);
        var frame = try frame_builder
            .withVm(&evm)
            .withContract(&contract)
            .withGas(1_000_000)
            .build();
        defer frame.deinit();

        // Execute bytecode
        const interpreter: Operation.Interpreter = &evm;
        const state: Operation.State = &frame;

        // Execute until STOP or error
        while (frame.pc < bytecode.len and !frame.stop) {
            const opcode = bytecode[frame.pc];
            const old_pc = frame.pc;

            const result = evm.table.execute(frame.pc, interpreter, state, opcode) catch |err| {
                // Handle expected errors
                switch (err) {
                    error.InvalidJump, error.OutOfGas, error.STOP, error.StackUnderflow, error.InvalidOpcode => break,
                    else => return err,
                }
            };

            // Check if execution should halt
            if (result.output.len > 0) {
                break;
            }

            // Advance PC if not modified by instruction (JUMP/JUMPI modify it)
            if (frame.pc == old_pc) {
                frame.pc += result.bytes_consumed;
            }
        }
    }
}
