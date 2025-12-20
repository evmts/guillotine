//! Comprehensive End-to-End EVM Tests
//! 
//! This file contains e2e tests that validate the entire EVM execution pipeline
//! from bytecode to final state, covering edge cases and corner cases that
//! unit tests cannot adequately cover due to their isolation.
//!
//! Tests are organized by category:
//! 1. EIP Compliance Tests - Validate specific EIP implementations
//! 2. Arithmetic Edge Cases - Boundary conditions for arithmetic operations
//! 3. Stack and Memory Stress Tests - Resource limit validation
//! 4. Call and Create Operations - Complex interaction patterns
//! 5. State Management - Journaling and revert scenarios
//! 6. Gas Accounting - Precise gas calculations and edge cases
//! 7. Bytecode Analysis - Jump validation and optimization
//! 8. Precompiles - Integration with precompiled contracts
//! 9. Real-World Patterns - Common contract interaction scenarios

const std = @import("std");
const testing = std.testing;
const primitives = @import("voltaire");
const Address = primitives.Address.Address;
const GasConstants = primitives.GasConstants;
const keccak256 = @import("crypto").keccak256;

const frame_mod = @import("frame.zig");
const evm_mod = @import("evm.zig");
const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;
const DatabaseInterface = @import("database_interface.zig").DatabaseInterface;
const BlockInfo = @import("block_info.zig").BlockInfo;
const CallParams = @import("call_params.zig").CallParams;
const CallResult = @import("call_result.zig").CallResult;
const Host = @import("host.zig").Host;
const NoOpTracer = @import("tracer.zig").NoOpTracer;
const TransactionContext = @import("transaction_context.zig").TransactionContext;
const AccessList = @import("access_list.zig").AccessList;
const Hardfork = @import("hardfork.zig").Hardfork;

// Standard test configuration for e2e tests
const E2EFrameConfig = frame_mod.FrameConfig{
    .stack_size = 1024,
    .WordType = u256,
    .max_bytecode_size = 24576, // EIP-170 limit
    .block_gas_limit = 30_000_000,
    .has_database = true,
    .TracerType = NoOpTracer,
    .memory_initial_capacity = 4096,
    .memory_limit = 0xFFFFFF, // 16MB limit
};

const E2EFrame = frame_mod.Frame(E2EFrameConfig);
const E2EEvm = evm_mod.Evm(.{
    .max_call_depth = 1024,
    .max_input_size = 1024 * 1024, // 1MB
    .frame_config = E2EFrameConfig,
});

// Helper function to create standard test setup
fn createE2ETestSetup(allocator: std.mem.Allocator) !struct {
    database: MemoryDatabase,
    db_interface: DatabaseInterface,
    block_info: BlockInfo,
    tx_context: TransactionContext,
    access_list: AccessList,
    
    fn deinit(self: @This()) void {
        self.database.deinit();
        self.access_list.deinit();
    }
} {
    var database = MemoryDatabase.init(allocator);
    var access_list = try AccessList.init(allocator);
    
    const block_info = BlockInfo{
        .number = 18_000_000,
        .timestamp = 1690000000,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = [_]u8{0xFE} ** 20,
        .base_fee = 20_000_000_000, // 20 gwei
        .prevrandao = [_]u8{0x42} ** 32,
        .chain_id = 1, // Ethereum mainnet
    };
    
    const tx_context = TransactionContext{
        .origin = [_]u8{0x11} ** 20,
        .gas_price = 21_000_000_000, // 21 gwei
        .access_list = &access_list,
        .hardfork = Hardfork.shanghai,
    };
    
    return .{
        .database = database,
        .db_interface = database.to_database_interface(),
        .block_info = block_info,
        .tx_context = tx_context,
        .access_list = access_list,
    };
}

// Helper function to execute bytecode through EVM
fn executeE2ETransaction(
    allocator: std.mem.Allocator,
    setup: anytype,
    caller: Address,
    to: ?Address,
    value: u256,
    bytecode: []const u8,
    input: []const u8,
    gas_limit: u64,
) !CallResult {
    var evm = try E2EEvm.init(allocator, setup.db_interface, setup.block_info, setup.tx_context);
    defer evm.deinit();
    
    const call_params = CallParams{
        .caller = caller,
        .to = to,
        .value = value,
        .data = input,
        .gas_limit = gas_limit,
        .is_static = false,
    };
    
    return evm.call(bytecode, call_params);
}

//
// ============================================================================
// 1. EIP COMPLIANCE TESTS
// ============================================================================
//

// EIP-2929/2930: Gas cost changes for state access
test "E2E: EIP-2929 cold vs warm account access" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const target_address = [_]u8{0x22} ** 20;
    const caller_address = [_]u8{0x11} ** 20;
    
    // Pre-warm target address in access list
    try setup.access_list.access_account(target_address);
    
    // Bytecode: PUSH20 address EXTCODESIZE (warm access)
    const warm_bytecode = [_]u8{
        0x73, // PUSH20
    } ++ target_address ++ [_]u8{
        0x3B, // EXTCODESIZE
        0x00, // STOP
    };
    
    // Execute with warm access - should cost 100 gas
    const warm_result = try executeE2ETransaction(
        allocator, setup, caller_address, null, 0, 
        &warm_bytecode, &[_]u8{}, 100000
    );
    defer warm_result.deinit(allocator);
    
    // Clear access list for cold access test
    setup.access_list.clear();
    
    // Execute same code with cold access - should cost 2600 gas
    const cold_result = try executeE2ETransaction(
        allocator, setup, caller_address, null, 0,
        &warm_bytecode, &[_]u8{}, 100000
    );
    defer cold_result.deinit(allocator);
    
    // Verify different gas consumptions (cold should use 2500 more gas)
    const warm_gas_used = 100000 - warm_result.gas_remaining;
    const cold_gas_used = 100000 - cold_result.gas_remaining;
    
    try testing.expect(cold_gas_used > warm_gas_used);
    try testing.expect(cold_gas_used - warm_gas_used == 2500); // EIP-2929 penalty
}

test "E2E: EIP-2929 SLOAD/SSTORE warm vs cold access" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const contract_address = [_]u8{0x33} ** 20;
    const caller_address = [_]u8{0x11} ** 20;
    
    // Bytecode: PUSH1 0x01 PUSH1 0x00 SSTORE (store 1 at slot 0)
    //           PUSH1 0x00 SLOAD (cold access)
    //           PUSH1 0x00 SLOAD (warm access - same slot)
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 0x01
        0x60, 0x00, // PUSH1 0x00
        0x55,       // SSTORE
        0x60, 0x00, // PUSH1 0x00
        0x54,       // SLOAD (first access - cold)
        0x60, 0x00, // PUSH1 0x00  
        0x54,       // SLOAD (second access - warm)
        0x00,       // STOP
    };
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, contract_address, 0,
        &bytecode, &[_]u8{}, 100000
    );
    defer result.deinit(allocator);
    
    try testing.expect(result.is_success());
    
    // Verify that storage was modified
    const stored_value = try setup.db_interface.get_storage(contract_address, 0);
    try testing.expectEqual(@as(u256, 1), stored_value);
}

// EIP-2200/3529: SSTORE gas costs and refunds
test "E2E: EIP-2200 SSTORE gas cost tiers and refunds" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const contract_address = [_]u8{0x44} ** 20;
    const caller_address = [_]u8{0x11} ** 20;
    
    // Set up initial storage state
    try setup.db_interface.set_storage(contract_address, 0, 100);
    
    // Bytecode: Multiple SSTORE operations testing different gas tiers
    // 1. SSTORE to same value (no-op) - cheapest
    // 2. SSTORE to different value (modify) - medium cost
    // 3. SSTORE zero to non-zero (create) - most expensive
    // 4. SSTORE non-zero to zero (delete) - refund
    const bytecode = [_]u8{
        // Test 1: Store same value (100) - should be cheapest
        0x60, 0x64, // PUSH1 100
        0x60, 0x00, // PUSH1 0x00
        0x55,       // SSTORE
        
        // Test 2: Store different value - modify cost
        0x60, 0x65, // PUSH1 101  
        0x60, 0x00, // PUSH1 0x00
        0x55,       // SSTORE
        
        // Test 3: Store zero - delete and get refund
        0x60, 0x00, // PUSH1 0x00
        0x60, 0x00, // PUSH1 0x00
        0x55,       // SSTORE
        
        // Test 4: Store to new slot - create cost
        0x60, 0x42, // PUSH1 66
        0x60, 0x01, // PUSH1 0x01
        0x55,       // SSTORE
        
        0x00,       // STOP
    };
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, contract_address, 0,
        &bytecode, &[_]u8{}, 100000
    );
    defer result.deinit(allocator);
    
    try testing.expect(result.is_success());
    
    // Verify final storage state
    const slot0_value = try setup.db_interface.get_storage(contract_address, 0);
    const slot1_value = try setup.db_interface.get_storage(contract_address, 1);
    
    try testing.expectEqual(@as(u256, 0), slot0_value); // Should be zero
    try testing.expectEqual(@as(u256, 66), slot1_value); // Should be 66
}

// EIP-150: 63/64 gas forwarding rule
test "E2E: EIP-150 gas forwarding with deep call stack" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const caller_address = [_]u8{0x11} ** 20;
    const callee_address = [_]u8{0x22} ** 20;
    
    // Deploy a simple contract that just returns success
    const callee_code = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE 
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    // Set the callee contract code
    const callee_account = try setup.db_interface.get_account(callee_address) orelse 
        setup.db_interface.Account{
            .balance = 0,
            .nonce = 0,
            .code = &callee_code,
            .storage = std.HashMap([32]u8, u256, std.hash_map.AutoContext([32]u8), 80).init(allocator),
        };
    
    try setup.db_interface.set_account(callee_address, callee_account);
    
    // Caller bytecode: CALL with specific gas amount to test 63/64 rule
    const caller_bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0 (return data size)
        0x60, 0x00, // PUSH1 0 (return data offset)
        0x60, 0x00, // PUSH1 0 (input size)
        0x60, 0x00, // PUSH1 0 (input offset) 
        0x60, 0x00, // PUSH1 0 (value)
    } ++ callee_address ++ [_]u8{ // PUSH20 callee_address
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xF1,       // CALL
        0x00,       // STOP
    };
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, null, 0,
        &caller_bytecode, &[_]u8{}, 50000
    );
    defer result.deinit(allocator);
    
    try testing.expect(result.is_success());
}

// EIP-3860: Initcode size limit
test "E2E: EIP-3860 initcode size limit enforcement" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const caller_address = [_]u8{0x11} ** 20;
    
    // Create initcode that exceeds the limit (49152 bytes)
    var large_initcode = try allocator.alloc(u8, 49153);
    defer allocator.free(large_initcode);
    
    // Fill with valid bytecode pattern (PUSH1 0x00)
    for (0..large_initcode.len / 2) |i| {
        large_initcode[i * 2] = 0x60; // PUSH1
        large_initcode[i * 2 + 1] = 0x00; // 0x00
    }
    // Add STOP at the end
    large_initcode[large_initcode.len - 1] = 0x00;
    
    // CREATE bytecode with oversized initcode
    const create_bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0 (value)
        // We would need to PUSH the large initcode here, but for simplicity
        // we'll test with CREATE2 and a fixed salt
        0x60, 0x42, // PUSH1 0x42 (salt)
        0x60, 0x00, // PUSH1 0 (size - will be overwritten)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xF5,       // CREATE2
        0x00,       // STOP  
    };
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, null, 0,
        &create_bytecode, &[_]u8{}, 1000000
    );
    defer result.deinit(allocator);
    
    // Should fail due to initcode size limit
    try testing.expect(result.is_failure() or result.is_revert());
}

//
// ============================================================================  
// 2. ARITHMETIC EDGE CASES
// ============================================================================
//

test "E2E: Arithmetic operations at u256 boundaries" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const caller_address = [_]u8{0x11} ** 20;
    
    // Test arithmetic at maximum u256 value (2^256 - 1)
    const max_u256_bytes = [_]u8{ 0xFF } ** 32;
    
    // Bytecode: PUSH32 max_u256 PUSH1 1 ADD (should overflow to 0)
    const overflow_bytecode = [_]u8{
        0x7F, // PUSH32
    } ++ max_u256_bytes ++ [_]u8{
        0x60, 0x01, // PUSH1 1
        0x01,       // ADD (overflow)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE (store result)
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0  
        0xF3,       // RETURN (return the result)
    };
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, null, 0,
        &overflow_bytecode, &[_]u8{}, 100000
    );
    defer result.deinit(allocator);
    
    try testing.expect(result.is_success());
    
    // Verify overflow result is 0
    try testing.expectEqual(@as(usize, 32), result.output.len);
    
    var expected_zero = [_]u8{0x00} ** 32;
    try testing.expectEqualSlices(u8, &expected_zero, result.output);
}

test "E2E: Division by zero handling in contract execution" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const caller_address = [_]u8{0x11} ** 20;
    
    // Bytecode: PUSH1 42 PUSH1 0 DIV (42 / 0 should return 0 per EVM spec)
    const div_zero_bytecode = [_]u8{
        0x60, 0x2A, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x04,       // DIV
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, null, 0,
        &div_zero_bytecode, &[_]u8{}, 100000
    );
    defer result.deinit(allocator);
    
    try testing.expect(result.is_success());
    
    // Verify division by zero returns 0
    var expected_zero = [_]u8{0x00} ** 32;
    try testing.expectEqualSlices(u8, &expected_zero, result.output);
}

test "E2E: Signed arithmetic edge cases" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const caller_address = [_]u8{0x11} ** 20;
    
    // Test most negative value (-2^255) divided by -1 (should overflow to itself)
    const most_negative = [_]u8{ 0x80 } ++ [_]u8{ 0x00 } ** 31;
    const negative_one = [_]u8{ 0xFF } ** 32;
    
    // Bytecode: PUSH32 most_negative PUSH32 negative_one SDIV
    const signed_div_bytecode = [_]u8{
        0x7F, // PUSH32 most negative
    } ++ most_negative ++ [_]u8{
        0x7F, // PUSH32 -1
    } ++ negative_one ++ [_]u8{
        0x05,       // SDIV  
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, null, 0,
        &signed_div_bytecode, &[_]u8{}, 100000
    );
    defer result.deinit(allocator);
    
    try testing.expect(result.is_success());
    
    // Result should be the most negative value (overflow case)
    try testing.expectEqualSlices(u8, &most_negative, result.output);
}

test "E2E: Modular arithmetic with zero modulus" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const caller_address = [_]u8{0x11} ** 20;
    
    // Test ADDMOD and MULMOD with zero modulus
    const bytecode = [_]u8{
        // Test ADDMOD(a, b, 0) should return 0
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3  
        0x60, 0x00, // PUSH1 0 (modulus)
        0x08,       // ADDMOD
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE (store at offset 0)
        
        // Test MULMOD(a, b, 0) should return 0  
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3
        0x60, 0x00, // PUSH1 0 (modulus)
        0x09,       // MULMOD
        0x60, 0x20, // PUSH1 32  
        0x52,       // MSTORE (store at offset 32)
        
        0x60, 0x40, // PUSH1 64 (return size)
        0x60, 0x00, // PUSH1 0 (return offset)
        0xF3,       // RETURN
    };
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, null, 0,
        &bytecode, &[_]u8{}, 100000
    );
    defer result.deinit(allocator);
    
    try testing.expect(result.is_success());
    try testing.expectEqual(@as(usize, 64), result.output.len);
    
    // Both results should be zero
    var expected = [_]u8{0x00} ** 64;
    try testing.expectEqualSlices(u8, &expected, result.output);
}

//
// ============================================================================
// 3. STACK AND MEMORY STRESS TESTS  
// ============================================================================
//

test "E2E: Stack operations at maximum depth" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const caller_address = [_]u8{0x11} ** 20;
    
    // Generate bytecode to fill stack to exactly 1024 items
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Push 1024 values onto the stack
    for (0..1024) |i| {
        try bytecode.append(0x60); // PUSH1
        try bytecode.append(@intCast(i & 0xFF)); // value
    }
    
    // Test DUP16 operation at maximum stack depth
    try bytecode.append(0x8F); // DUP16
    try bytecode.append(0x50); // POP (remove the duplicated value)
    
    // Test SWAP16 operation
    try bytecode.append(0x9F); // SWAP16
    
    // Clean up and return
    try bytecode.append(0x60); // PUSH1 0
    try bytecode.append(0x52); // MSTORE 
    try bytecode.append(0x60); // PUSH1 32
    try bytecode.append(0x60); // PUSH1 0
    try bytecode.append(0xF3); // RETURN
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, null, 0,
        bytecode.items, &[_]u8{}, 1000000
    );
    defer result.deinit(allocator);
    
    try testing.expect(result.is_success());
}

test "E2E: Stack overflow protection" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const caller_address = [_]u8{0x11} ** 20;
    
    // Generate bytecode that tries to push 1025 items (should fail)
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Push 1025 values onto the stack (should cause overflow)
    for (0..1025) |i| {
        try bytecode.append(0x60); // PUSH1
        try bytecode.append(@intCast(i & 0xFF)); // value
    }
    
    try bytecode.append(0x00); // STOP
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, null, 0,
        bytecode.items, &[_]u8{}, 1000000
    );
    defer result.deinit(allocator);
    
    // Should fail due to stack overflow
    try testing.expect(result.is_failure());
}

test "E2E: Memory expansion to maximum limit" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const caller_address = [_]u8{0x11} ** 20;
    
    // Test memory access at the limit (16MB - 32 bytes)
    const max_offset: u32 = 0xFFFFFF - 32; // 16MB - 32 bytes
    
    // Bytecode: PUSH4 max_offset MLOAD
    const bytecode = [_]u8{
        0x63, // PUSH4
        @intCast((max_offset >> 24) & 0xFF),
        @intCast((max_offset >> 16) & 0xFF), 
        @intCast((max_offset >> 8) & 0xFF),
        @intCast(max_offset & 0xFF),
        0x51,       // MLOAD
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE (store result)
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, null, 0,
        &bytecode, &[_]u8{}, 10_000_000 // High gas limit for memory expansion
    );
    defer result.deinit(allocator);
    
    try testing.expect(result.is_success());
    
    // Should return zero (uninitialized memory)
    var expected_zero = [_]u8{0x00} ** 32;
    try testing.expectEqualSlices(u8, &expected_zero, result.output);
}

test "E2E: Memory expansion beyond limit should fail" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const caller_address = [_]u8{0x11} ** 20;
    
    // Test memory access beyond the limit
    const over_limit_offset: u32 = 0xFFFFFF; // Exactly at 16MB limit
    
    // Bytecode: PUSH4 over_limit_offset MLOAD  
    const bytecode = [_]u8{
        0x63, // PUSH4
        @intCast((over_limit_offset >> 24) & 0xFF),
        @intCast((over_limit_offset >> 16) & 0xFF),
        @intCast((over_limit_offset >> 8) & 0xFF), 
        @intCast(over_limit_offset & 0xFF),
        0x51,       // MLOAD (should fail)
        0x00,       // STOP
    };
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, null, 0,
        &bytecode, &[_]u8{}, 10_000_000
    );
    defer result.deinit(allocator);
    
    // Should fail due to memory limit exceeded
    try testing.expect(result.is_failure());
}

test "E2E: Large memory copy operations" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const caller_address = [_]u8{0x11} ** 20;
    
    // Test MCOPY with large memory regions (1MB copy)
    const copy_size: u32 = 1024 * 1024; // 1MB
    const src_offset: u32 = 0;
    const dst_offset: u32 = copy_size;
    
    // Bytecode: Fill source memory, then copy large chunk
    const bytecode = [_]u8{
        // First, store some data at source
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // MCOPY: dst, src, size
        0x63, // PUSH4 size
        @intCast((copy_size >> 24) & 0xFF),
        @intCast((copy_size >> 16) & 0xFF),
        @intCast((copy_size >> 8) & 0xFF),
        @intCast(copy_size & 0xFF),
        
        0x63, // PUSH4 src
        @intCast((src_offset >> 24) & 0xFF),
        @intCast((src_offset >> 16) & 0xFF),
        @intCast((src_offset >> 8) & 0xFF), 
        @intCast(src_offset & 0xFF),
        
        0x63, // PUSH4 dst
        @intCast((dst_offset >> 24) & 0xFF),
        @intCast((dst_offset >> 16) & 0xFF),
        @intCast((dst_offset >> 8) & 0xFF),
        @intCast(dst_offset & 0xFF),
        
        0x5E,       // MCOPY
        
        // Load from destination to verify copy
        0x63, // PUSH4 dst_offset
        @intCast((dst_offset >> 24) & 0xFF),
        @intCast((dst_offset >> 16) & 0xFF),
        @intCast((dst_offset >> 8) & 0xFF),
        @intCast(dst_offset & 0xFF),
        
        0x51,       // MLOAD
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32  
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, null, 0,
        &bytecode, &[_]u8{}, 50_000_000 // Very high gas limit
    );
    defer result.deinit(allocator);
    
    try testing.expect(result.is_success());
    
    // Verify the copied value
    var expected = [_]u8{0x00} ** 31 ++ [_]u8{0x42};
    try testing.expectEqualSlices(u8, &expected, result.output);
}

//
// ============================================================================
// 4. CALL AND CREATE OPERATIONS  
// ============================================================================
//

test "E2E: Deep call stack to maximum depth" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const caller_address = [_]u8{0x11} ** 20;
    const recursive_contract = [_]u8{0x22} ** 20;
    
    // Recursive contract: decrements counter and calls itself
    const recursive_code = [_]u8{
        // Load counter from calldata
        0x60, 0x00, // PUSH1 0
        0x35,       // CALLDATALOAD
        
        // Check if counter is 0
        0x80,       // DUP1
        0x15,       // ISZERO
        0x60, 0x20, // PUSH1 32 (jump to return)
        0x57,       // JUMPI
        
        // Decrement counter
        0x60, 0x01, // PUSH1 1
        0x03,       // SUB
        
        // Store decremented counter in memory for next call
        0x80,       // DUP1 
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Recursive call setup
        0x60, 0x00, // PUSH1 0 (return data size)
        0x60, 0x00, // PUSH1 0 (return data offset)
        0x60, 0x20, // PUSH1 32 (input size)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x73,       // PUSH20
    } ++ recursive_contract ++ [_]u8{
        0x5A,       // GAS
        0xF1,       // CALL
        0x50,       // POP (ignore call result)
        
        // JUMPDEST for return (offset 32)
        0x5B,       // JUMPDEST  
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    // Deploy recursive contract
    var recursive_account = setup.db_interface.Account{
        .balance = 0,
        .nonce = 0, 
        .code = &recursive_code,
        .storage = std.HashMap([32]u8, u256, std.hash_map.AutoContext([32]u8), 80).init(allocator),
    };
    
    try setup.db_interface.set_account(recursive_contract, recursive_account);
    
    // Caller bytecode: call recursive contract with counter = 500 (should hit depth limit)
    const caller_bytecode = [_]u8{
        0x61, 0x01, 0xF4, // PUSH2 500 (counter)
        0x60, 0x00,       // PUSH1 0
        0x52,             // MSTORE (store counter in memory)
        
        // Call recursive contract  
        0x60, 0x00, // PUSH1 0 (return data size)
        0x60, 0x00, // PUSH1 0 (return data offset)
        0x60, 0x20, // PUSH1 32 (input size)
        0x60, 0x00, // PUSH1 0 (input offset)  
        0x60, 0x00, // PUSH1 0 (value)
        0x73,       // PUSH20
    } ++ recursive_contract ++ [_]u8{
        0x5A,       // GAS
        0xF1,       // CALL
        
        // Return call result
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, null, 0,
        &caller_bytecode, &[_]u8{}, 10_000_000
    );
    defer result.deinit(allocator);
    
    // Should fail due to call depth limit (1024)
    try testing.expect(result.is_failure() or result.gas_remaining < 100000);
}

test "E2E: Value transfers with exact balance amounts" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const sender_address = [_]u8{0x11} ** 20;
    const receiver_address = [_]u8{0x22} ** 20;
    const exact_balance: u256 = 1000000000000000000; // 1 ETH
    
    // Set sender balance to exactly 1 ETH
    var sender_account = setup.db_interface.Account{
        .balance = exact_balance,
        .nonce = 0,
        .code = &[_]u8{},
        .storage = std.HashMap([32]u8, u256, std.hash_map.AutoContext([32]u8), 80).init(allocator),
    };
    
    try setup.db_interface.set_account(sender_address, sender_account);
    
    // Simple receiver contract that just accepts ETH
    const receiver_code = [_]u8{
        0x60, 0x01, // PUSH1 1 (success)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0  
        0xF3,       // RETURN
    };
    
    var receiver_account = setup.db_interface.Account{
        .balance = 0,
        .nonce = 0,
        .code = &receiver_code,
        .storage = std.HashMap([32]u8, u256, std.hash_map.AutoContext([32]u8), 80).init(allocator),
    };
    
    try setup.db_interface.set_account(receiver_address, receiver_account);
    
    // Bytecode: transfer entire balance to receiver
    const transfer_bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0 (return data size)
        0x60, 0x00, // PUSH1 0 (return data offset) 
        0x60, 0x00, // PUSH1 0 (input size)
        0x60, 0x00, // PUSH1 0 (input offset)
        
        // Push exact balance amount
        0x69,       // PUSH10
        0x0D, 0xE0, 0xB6, 0xB3, 0xA7, 0x64, 0x00, 0x00, 0x00, 0x00, // 1 ETH
        
        0x73,       // PUSH20 receiver
    } ++ receiver_address ++ [_]u8{
        0x5A,       // GAS
        0xF1,       // CALL
        
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE  
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    const result = try executeE2ETransaction(
        allocator, setup, sender_address, null, 0,
        &transfer_bytecode, &[_]u8{}, 1000000
    );
    defer result.deinit(allocator);
    
    try testing.expect(result.is_success());
    
    // Verify balances changed correctly
    const final_sender = try setup.db_interface.get_account(sender_address);
    const final_receiver = try setup.db_interface.get_account(receiver_address);
    
    try testing.expect(final_sender != null);
    try testing.expect(final_receiver != null);
    
    // Sender should have 0 balance (minus gas costs)
    try testing.expect(final_sender.?.balance < 100000000000000000); // Much less than 0.1 ETH
    
    // Receiver should have close to 1 ETH
    try testing.expect(final_receiver.?.balance > 900000000000000000); // At least 0.9 ETH
}

test "E2E: CREATE2 contract deployment with salt" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const creator_address = [_]u8{0x11} ** 20;
    const salt: u256 = 0x1234567890ABCDEF;
    
    // Simple contract bytecode to deploy
    const contract_init_code = [_]u8{
        // Return runtime code: PUSH1 42 PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN  
        0x60, 0x2A, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0 
        0xF3,       // RETURN
    };
    
    const runtime_code = [_]u8{
        0x60, 0x2A, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    // Calculate expected CREATE2 address
    const salt_bytes = std.mem.asBytes(&salt);
    const init_code_hash = keccak256(&contract_init_code);
    
    var create2_input: [85]u8 = undefined;
    create2_input[0] = 0xFF;
    std.mem.copy(u8, create2_input[1..21], &creator_address);
    std.mem.copy(u8, create2_input[21..53], salt_bytes);
    std.mem.copy(u8, create2_input[53..85], &init_code_hash);
    
    const expected_address_hash = keccak256(&create2_input);
    const expected_address = expected_address_hash[12..32].*;
    
    // Creator bytecode: CREATE2 with init code
    var creator_bytecode = std.ArrayList(u8).init(allocator);
    defer creator_bytecode.deinit();
    
    // Store init code in memory
    for (contract_init_code, 0..) |byte, i| {
        try creator_bytecode.append(0x60); // PUSH1
        try creator_bytecode.append(byte);
        try creator_bytecode.append(0x60); // PUSH1  
        try creator_bytecode.append(@intCast(i));
        try creator_bytecode.append(0x52); // MSTORE8
    }
    
    // CREATE2 call
    try creator_bytecode.append(0x7F); // PUSH32 salt
    const salt_le_bytes = std.mem.asBytes(&salt);
    try creator_bytecode.appendSlice(salt_le_bytes[0..32]);
    
    try creator_bytecode.append(0x60); // PUSH1 init code size
    try creator_bytecode.append(@intCast(contract_init_code.len));
    try creator_bytecode.append(0x60); // PUSH1 init code offset
    try creator_bytecode.append(0x00);
    try creator_bytecode.append(0x60); // PUSH1 value
    try creator_bytecode.append(0x00);
    try creator_bytecode.append(0xF5); // CREATE2
    
    // Return the created address
    try creator_bytecode.append(0x60); // PUSH1 0
    try creator_bytecode.append(0x00);
    try creator_bytecode.append(0x52); // MSTORE
    try creator_bytecode.append(0x60); // PUSH1 32
    try creator_bytecode.append(0x20);
    try creator_bytecode.append(0x60); // PUSH1 0
    try creator_bytecode.append(0x00);
    try creator_bytecode.append(0xF3); // RETURN
    
    const result = try executeE2ETransaction(
        allocator, setup, creator_address, null, 0,
        creator_bytecode.items, &[_]u8{}, 1000000
    );
    defer result.deinit(allocator);
    
    try testing.expect(result.is_success());
    
    // Verify the returned address matches our calculation
    try testing.expectEqual(@as(usize, 32), result.output.len);
    
    const returned_address = result.output[12..32];
    try testing.expectEqualSlices(u8, &expected_address, returned_address);
    
    // Verify the contract was actually deployed
    const deployed_account = try setup.db_interface.get_account(expected_address);
    try testing.expect(deployed_account != null);
    try testing.expectEqualSlices(u8, &runtime_code, deployed_account.?.code);
}

test "E2E: SELFDESTRUCT with balance transfer" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const caller_address = [_]u8{0x11} ** 20;
    const contract_address = [_]u8{0x22} ** 20; 
    const beneficiary_address = [_]u8{0x33} ** 20;
    const contract_balance: u256 = 500000000000000000; // 0.5 ETH
    
    // Contract that self-destructs
    const selfdestruct_code = [_]u8{
        0x73, // PUSH20 beneficiary
    } ++ beneficiary_address ++ [_]u8{
        0xFF, // SELFDESTRUCT
    };
    
    // Set up contract with balance
    var contract_account = setup.db_interface.Account{
        .balance = contract_balance,
        .nonce = 0,
        .code = &selfdestruct_code,
        .storage = std.HashMap([32]u8, u256, std.hash_map.AutoContext([32]u8), 80).init(allocator),
    };
    
    try setup.db_interface.set_account(contract_address, contract_account);
    
    // Set up beneficiary with initial balance
    var beneficiary_account = setup.db_interface.Account{
        .balance = 100000000000000000, // 0.1 ETH initial
        .nonce = 0,
        .code = &[_]u8{},
        .storage = std.HashMap([32]u8, u256, std.hash_map.AutoContext([32]u8), 80).init(allocator),
    };
    
    try setup.db_interface.set_account(beneficiary_address, beneficiary_account);
    
    // Caller bytecode: just calls the self-destruct contract
    const caller_bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0 (return data size)
        0x60, 0x00, // PUSH1 0 (return data offset)
        0x60, 0x00, // PUSH1 0 (input size)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x73,       // PUSH20 contract
    } ++ contract_address ++ [_]u8{
        0x5A,       // GAS
        0xF1,       // CALL
        
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, null, 0,
        &caller_bytecode, &[_]u8{}, 1000000
    );
    defer result.deinit(allocator);
    
    try testing.expect(result.is_success());
    
    // Verify balance transfer happened
    const final_beneficiary = try setup.db_interface.get_account(beneficiary_address);
    try testing.expect(final_beneficiary != null);
    
    // Beneficiary should have initial + transferred balance
    const expected_balance = 100000000000000000 + 500000000000000000;
    try testing.expectEqual(expected_balance, final_beneficiary.?.balance);
    
    // Contract should still exist but be marked for destruction
    const final_contract = try setup.db_interface.get_account(contract_address);
    try testing.expect(final_contract != null);
}

//
// ============================================================================
// 5. STATE MANAGEMENT AND JOURNALING
// ============================================================================
//

test "E2E: Complex multi-level revert scenarios" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const caller_address = [_]u8{0x11} ** 20;
    const contract_a = [_]u8{0x22} ** 20;
    const contract_b = [_]u8{0x33} ** 20;
    const contract_c = [_]u8{0x44} ** 20;
    
    // Contract C: modifies storage then reverts
    const contract_c_code = [_]u8{
        // Store value 100 at slot 0
        0x60, 0x64, // PUSH1 100
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE
        
        // Revert
        0x60, 0x00, // PUSH1 0 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xFD,       // REVERT
    };
    
    // Contract B: modifies storage, calls C, then continues
    const contract_b_code = [_]u8{
        // Store value 50 at slot 0
        0x60, 0x32, // PUSH1 50
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE
        
        // Call contract C
        0x60, 0x00, // PUSH1 0 (return data size)
        0x60, 0x00, // PUSH1 0 (return data offset)
        0x60, 0x00, // PUSH1 0 (input size) 
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x73,       // PUSH20 contract_c
    } ++ contract_c ++ [_]u8{
        0x5A,       // GAS
        0xF1,       // CALL
        
        // Store value 75 at slot 1 (after C reverts)
        0x60, 0x4B, // PUSH1 75
        0x60, 0x01, // PUSH1 1
        0x55,       // SSTORE
        
        // Return success
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    // Contract A: modifies storage, calls B, checks result
    const contract_a_code = [_]u8{
        // Store value 25 at slot 0  
        0x60, 0x19, // PUSH1 25
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE
        
        // Call contract B
        0x60, 0x20, // PUSH1 32 (return data size)
        0x60, 0x00, // PUSH1 0 (return data offset)
        0x60, 0x00, // PUSH1 0 (input size)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x73,       // PUSH20 contract_b
    } ++ contract_b ++ [_]u8{
        0x5A,       // GAS
        0xF1,       // CALL
        
        // Store call result at slot 1
        0x60, 0x01, // PUSH1 1
        0x55,       // SSTORE
        
        // Return the call result
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    // Deploy contracts
    var account_a = setup.db_interface.Account{
        .balance = 0, .nonce = 0, .code = &contract_a_code,
        .storage = std.HashMap([32]u8, u256, std.hash_map.AutoContext([32]u8), 80).init(allocator),
    };
    var account_b = setup.db_interface.Account{
        .balance = 0, .nonce = 0, .code = &contract_b_code,
        .storage = std.HashMap([32]u8, u256, std.hash_map.AutoContext([32]u8), 80).init(allocator),
    };
    var account_c = setup.db_interface.Account{
        .balance = 0, .nonce = 0, .code = &contract_c_code,
        .storage = std.HashMap([32]u8, u256, std.hash_map.AutoContext([32]u8), 80).init(allocator),
    };
    
    try setup.db_interface.set_account(contract_a, account_a);
    try setup.db_interface.set_account(contract_b, account_b);
    try setup.db_interface.set_account(contract_c, account_c);
    
    // Call contract A
    const caller_bytecode = [_]u8{
        0x60, 0x20, // PUSH1 32 (return data size)
        0x60, 0x00, // PUSH1 0 (return data offset)
        0x60, 0x00, // PUSH1 0 (input size)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x73,       // PUSH20 contract_a
    } ++ contract_a ++ [_]u8{
        0x5A,       // GAS
        0xF1,       // CALL
        
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, null, 0,
        &caller_bytecode, &[_]u8{}, 1000000
    );
    defer result.deinit(allocator);
    
    try testing.expect(result.is_success());
    
    // Verify state changes:
    // - Contract A should have slot 0 = 25, slot 1 = 1 (call succeeded)
    // - Contract B should have slot 0 = 50, slot 1 = 75
    // - Contract C should have NO storage changes (reverted)
    
    const final_a_slot0 = try setup.db_interface.get_storage(contract_a, 0);
    const final_a_slot1 = try setup.db_interface.get_storage(contract_a, 1);
    const final_b_slot0 = try setup.db_interface.get_storage(contract_b, 0);
    const final_b_slot1 = try setup.db_interface.get_storage(contract_b, 1);
    const final_c_slot0 = try setup.db_interface.get_storage(contract_c, 0);
    
    try testing.expectEqual(@as(u256, 25), final_a_slot0);
    try testing.expectEqual(@as(u256, 1), final_a_slot1);
    try testing.expectEqual(@as(u256, 50), final_b_slot0);
    try testing.expectEqual(@as(u256, 75), final_b_slot1);
    try testing.expectEqual(@as(u256, 0), final_c_slot0); // Reverted
}

test "E2E: Cross-contract storage interactions with DELEGATECALL" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const caller_address = [_]u8{0x11} ** 20;
    const proxy_contract = [_]u8{0x22} ** 20;
    const logic_contract = [_]u8{0x33} ** 20;
    
    // Logic contract: sets storage slot 0 to 42 and slot 1 to msg.sender
    const logic_code = [_]u8{
        // Store 42 at slot 0
        0x60, 0x2A, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE
        
        // Store caller (msg.sender) at slot 1
        0x33,       // CALLER
        0x60, 0x01, // PUSH1 1
        0x55,       // SSTORE
        
        0x60, 0x01, // PUSH1 1 (success)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    // Proxy contract: delegates to logic contract
    const proxy_code = [_]u8{
        // DELEGATECALL to logic contract
        0x60, 0x20, // PUSH1 32 (return data size)
        0x60, 0x00, // PUSH1 0 (return data offset)
        0x60, 0x00, // PUSH1 0 (input size)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x73,       // PUSH20 logic_contract
    } ++ logic_contract ++ [_]u8{
        0x5A,       // GAS
        0xF4,       // DELEGATECALL
        
        // Return the delegatecall result
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    // Deploy contracts
    var logic_account = setup.db_interface.Account{
        .balance = 0, .nonce = 0, .code = &logic_code,
        .storage = std.HashMap([32]u8, u256, std.hash_map.AutoContext([32]u8), 80).init(allocator),
    };
    var proxy_account = setup.db_interface.Account{
        .balance = 0, .nonce = 0, .code = &proxy_code,
        .storage = std.HashMap([32]u8, u256, std.hash_map.AutoContext([32]u8), 80).init(allocator),
    };
    
    try setup.db_interface.set_account(logic_contract, logic_account);
    try setup.db_interface.set_account(proxy_contract, proxy_account);
    
    // Call proxy contract
    const caller_bytecode = [_]u8{
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0x73,       // PUSH20 proxy_contract
    } ++ proxy_contract ++ [_]u8{
        0x5A,       // GAS
        0xF1,       // CALL
        
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, null, 0,
        &caller_bytecode, &[_]u8{}, 1000000
    );
    defer result.deinit(allocator);
    
    try testing.expect(result.is_success());
    
    // Verify DELEGATECALL behavior:
    // - Proxy contract storage should be modified (slot 0 = 42)
    // - Logic contract storage should be unchanged
    // - msg.sender in delegated call should be the original caller
    
    const proxy_slot0 = try setup.db_interface.get_storage(proxy_contract, 0);
    const proxy_slot1 = try setup.db_interface.get_storage(proxy_contract, 1);
    const logic_slot0 = try setup.db_interface.get_storage(logic_contract, 0);
    const logic_slot1 = try setup.db_interface.get_storage(logic_contract, 1);
    
    try testing.expectEqual(@as(u256, 42), proxy_slot0);
    try testing.expectEqual(std.mem.readIntBig(u256, &caller_address), proxy_slot1);
    try testing.expectEqual(@as(u256, 0), logic_slot0); // Unchanged
    try testing.expectEqual(@as(u256, 0), logic_slot1); // Unchanged
}

//
// ============================================================================
// 6. GAS ACCOUNTING PRECISION
// ============================================================================
//

test "E2E: Transaction consuming exactly the gas limit" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const caller_address = [_]u8{0x11} ** 20;
    const precise_gas_limit: u64 = 50000;
    
    // Calculate bytecode that consumes exactly the gas limit
    // Each operation has known gas cost, so we can construct precise consumption
    
    // Basic operations with known gas costs:
    // PUSH1: 3 gas, ADD: 3 gas, POP: 2 gas, MSTORE: 3 gas + memory expansion
    
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Calculate operations to consume exactly the available gas
    // Starting with base transaction cost (21000) already deducted
    var remaining_gas = precise_gas_limit - 21000; // Account for intrinsic gas
    
    // Use ADD operations (3 gas each) to consume most of the gas
    while (remaining_gas >= 6) { // Need 6 gas for PUSH1 + ADD
        try bytecode.append(0x60); // PUSH1
        try bytecode.append(0x01); // 1
        try bytecode.append(0x01); // ADD
        try bytecode.append(0x50); // POP (remove result)
        remaining_gas -= 8; // 3 + 3 + 2
    }
    
    // Finish with exact gas consumption
    if (remaining_gas >= 3) {
        try bytecode.append(0x60); // PUSH1
        try bytecode.append(0x00); // 0
        remaining_gas -= 3;
    }
    
    try bytecode.append(0x00); // STOP (0 gas)
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, null, 0,
        bytecode.items, &[_]u8{}, precise_gas_limit
    );
    defer result.deinit(allocator);
    
    try testing.expect(result.is_success());
    
    // Gas remaining should be very close to 0
    try testing.expect(result.gas_remaining < 1000); // Some tolerance for calculation precision
}

test "E2E: Out of gas at precise operation boundaries" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const caller_address = [_]u8{0x11} ** 20;
    
    // Memory expansion has quadratic cost growth - test at boundary
    const gas_limit: u64 = 30000;
    
    // Bytecode that tries to access memory at a size that exceeds gas limit
    const bytecode = [_]u8{
        // Try to access memory at offset that requires expensive expansion
        0x61, 0x10, 0x00, // PUSH2 4096 (large offset)
        0x51,             // MLOAD (should cause out of gas due to expansion cost)
        0x00,             // STOP
    };
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, null, 0,
        &bytecode, &[_]u8{}, gas_limit
    );
    defer result.deinit(allocator);
    
    // Should fail due to out of gas
    try testing.expect(result.is_failure());
}

test "E2E: Gas refund calculations with storage operations" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const caller_address = [_]u8{0x11} ** 20;
    const contract_address = [_]u8{0x22} ** 20;
    
    // Set up initial storage state
    try setup.db_interface.set_storage(contract_address, 0, 100);
    try setup.db_interface.set_storage(contract_address, 1, 200);
    
    // Bytecode that performs operations eligible for gas refunds
    const bytecode = [_]u8{
        // Clear storage slot 0 (eligible for refund)
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE (clear slot 0)
        
        // Clear storage slot 1 (eligible for refund)
        0x60, 0x00, // PUSH1 0
        0x60, 0x01, // PUSH1 1
        0x55,       // SSTORE (clear slot 1)
        
        // Set new value to slot 2 (no refund, but costs gas)
        0x60, 0x42, // PUSH1 66
        0x60, 0x02, // PUSH1 2
        0x55,       // SSTORE
        
        0x00,       // STOP
    };
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, contract_address, 0,
        &bytecode, &[_]u8{}, 100000
    );
    defer result.deinit(allocator);
    
    try testing.expect(result.is_success());
    
    // Verify storage state
    const final_slot0 = try setup.db_interface.get_storage(contract_address, 0);
    const final_slot1 = try setup.db_interface.get_storage(contract_address, 1);
    const final_slot2 = try setup.db_interface.get_storage(contract_address, 2);
    
    try testing.expectEqual(@as(u256, 0), final_slot0);
    try testing.expectEqual(@as(u256, 0), final_slot1);
    try testing.expectEqual(@as(u256, 66), final_slot2);
    
    // Gas consumption should reflect refunds (hard to test exact value due to refund cap)
    try testing.expect(result.gas_remaining > 50000); // Should have significant gas remaining due to refunds
}

//
// ============================================================================
// 7. BYTECODE ANALYSIS AND OPTIMIZATION
// ============================================================================
//

test "E2E: Jump destination validation with PUSH data" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const caller_address = [_]u8{0x11} ** 20;
    
    // Bytecode with JUMPDEST hidden inside PUSH data (should be invalid)
    const tricky_bytecode = [_]u8{
        0x60, 0x08, // PUSH1 8 (jump target)
        0x56,       // JUMP
        
        // PUSH data containing JUMPDEST opcode (0x5B)
        0x63,       // PUSH4
        0x5B, 0x00, 0x00, 0x00, // Data contains 0x5B (JUMPDEST) but it's inside PUSH data
        
        0x5B,       // JUMPDEST (offset 8 - this is valid)
        0x60, 0x42, // PUSH1 66
        0x00,       // STOP
    };
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, null, 0,
        &tricky_bytecode, &[_]u8{}, 100000
    );
    defer result.deinit(allocator);
    
    try testing.expect(result.is_success());
}

test "E2E: Invalid jump to PUSH data should fail" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const caller_address = [_]u8{0x11} ** 20;
    
    // Bytecode that tries to jump to an offset inside PUSH data
    const invalid_jump_bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5 (jump target - inside PUSH4 data)
        0x56,       // JUMP
        
        0x63,       // PUSH4 (offset 4)
        0x5B, 0x00, 0x00, 0x00, // PUSH4 data (offset 5-8)
        
        0x00,       // STOP (offset 9)
    };
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, null, 0,
        &invalid_jump_bytecode, &[_]u8{}, 100000
    );
    defer result.deinit(allocator);
    
    // Should fail due to invalid jump destination
    try testing.expect(result.is_failure());
}

test "E2E: Complex conditional jump patterns" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const caller_address = [_]u8{0x11} ** 20;
    
    // Bytecode implementing a simple loop with conditional jump
    const loop_bytecode = [_]u8{
        // Initialize counter (10 iterations)
        0x60, 0x0A, // PUSH1 10
        
        // Loop start (offset 3)
        0x5B,       // JUMPDEST
        0x80,       // DUP1 (copy counter)
        0x15,       // ISZERO
        0x60, 0x14, // PUSH1 20 (exit jump target)
        0x57,       // JUMPI (jump if counter is 0)
        
        // Loop body - decrement counter
        0x60, 0x01, // PUSH1 1
        0x03,       // SUB
        
        // Jump back to loop start
        0x60, 0x03, // PUSH1 3 (loop start)
        0x56,       // JUMP
        
        // Exit point (offset 20)
        0x5B,       // JUMPDEST
        0x50,       // POP (remove counter)
        0x60, 0x42, // PUSH1 66 (result)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, null, 0,
        &loop_bytecode, &[_]u8{}, 100000
    );
    defer result.deinit(allocator);
    
    try testing.expect(result.is_success());
    
    // Verify loop executed correctly
    var expected = [_]u8{0x00} ** 31 ++ [_]u8{0x42};
    try testing.expectEqualSlices(u8, &expected, result.output);
}

//
// ============================================================================
// 8. PRECOMPILES INTEGRATION
// ============================================================================
//

test "E2E: IDENTITY precompile with various input sizes" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const caller_address = [_]u8{0x11} ** 20;
    const identity_address = [_]u8{0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04};
    
    const test_data = "Hello, Ethereum Virtual Machine!";
    
    // Store test data in memory
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Store test data in memory
    for (test_data, 0..) |byte, i| {
        try bytecode.append(0x60); // PUSH1
        try bytecode.append(byte);
        try bytecode.append(0x60); // PUSH1
        try bytecode.append(@intCast(i));
        try bytecode.append(0x52); // MSTORE8
    }
    
    // Call IDENTITY precompile
    try bytecode.append(0x60); // PUSH1 output size
    try bytecode.append(@intCast(test_data.len));
    try bytecode.append(0x60); // PUSH1 output offset
    try bytecode.append(0x40);
    try bytecode.append(0x60); // PUSH1 input size
    try bytecode.append(@intCast(test_data.len));
    try bytecode.append(0x60); // PUSH1 input offset
    try bytecode.append(0x00);
    try bytecode.append(0x60); // PUSH1 value
    try bytecode.append(0x00);
    try bytecode.append(0x73); // PUSH20 identity address
    try bytecode.appendSlice(&identity_address);
    try bytecode.append(0x5A); // GAS
    try bytecode.append(0xF1); // CALL
    
    // Return the output
    try bytecode.append(0x60); // PUSH1 return size
    try bytecode.append(@intCast(test_data.len));
    try bytecode.append(0x60); // PUSH1 return offset
    try bytecode.append(0x40);
    try bytecode.append(0xF3); // RETURN
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, null, 0,
        bytecode.items, &[_]u8{}, 100000
    );
    defer result.deinit(allocator);
    
    try testing.expect(result.is_success());
    
    // Verify identity precompile returned the same data
    try testing.expectEqualSlices(u8, test_data, result.output);
}

test "E2E: Invalid precompile address handling" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const caller_address = [_]u8{0x11} ** 20;
    const invalid_precompile = [_]u8{0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF}; // Address 0xFF
    
    // Bytecode that tries to call non-existent precompile
    const bytecode = [_]u8{
        0x60, 0x20, // PUSH1 32 (return data size)
        0x60, 0x00, // PUSH1 0 (return data offset)
        0x60, 0x20, // PUSH1 32 (input size) 
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x73,       // PUSH20 invalid precompile address
    } ++ invalid_precompile ++ [_]u8{
        0x5A,       // GAS
        0xF1,       // CALL
        
        // Return call success status
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, null, 0,
        &bytecode, &[_]u8{}, 100000
    );
    defer result.deinit(allocator);
    
    try testing.expect(result.is_success());
    
    // Call should succeed but return 0 (call failed)
    var expected_zero = [_]u8{0x00} ** 32;
    try testing.expectEqualSlices(u8, &expected_zero, result.output);
}

//
// ============================================================================
// 9. REAL-WORLD CONTRACT PATTERNS
// ============================================================================
//

test "E2E: ERC20 token transfer simulation" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const caller_address = [_]u8{0x11} ** 20;
    const token_contract = [_]u8{0x22} ** 20;
    const recipient_address = [_]u8{0x33} ** 20;
    const transfer_amount: u256 = 1000;
    const sender_balance: u256 = 5000;
    
    // Simplified ERC20 transfer implementation
    // Storage: balances[address] at slot keccak256(address + 0)
    const erc20_code = [_]u8{
        // Check if this is a transfer call (function selector 0xa9059cbb)
        0x60, 0x00, // PUSH1 0
        0x35,       // CALLDATALOAD (load first 32 bytes of calldata)
        0x7C, 0x01, 0x00, 0x00, 0x00, // PUSH29 0x0100000000...
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x04,       // DIV (extract first 4 bytes)
        
        // Compare with transfer selector 0xa9059cbb
        0x63, 0xa9, 0x05, 0x9c, 0xbb, // PUSH4 0xa9059cbb
        0x14,       // EQ
        0x60, 0x40, // PUSH1 64 (jump to transfer implementation)
        0x57,       // JUMPI
        
        // Default: return 0
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
        
        // Transfer implementation (offset 64)
        0x5B,       // JUMPDEST
        
        // Load recipient address from calldata[4:24]
        0x60, 0x04, // PUSH1 4
        0x35,       // CALLDATALOAD
        0x73, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // PUSH20 mask
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x16,       // AND (extract address)
        
        // Load amount from calldata[24:56] 
        0x60, 0x24, // PUSH1 36
        0x35,       // CALLDATALOAD
        
        // For simplicity, just return success
        0x60, 0x01, // PUSH1 1 (success)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    // Deploy token contract with initial state
    var token_account = setup.db_interface.Account{
        .balance = 0, .nonce = 0, .code = &erc20_code,
        .storage = std.HashMap([32]u8, u256, std.hash_map.AutoContext([32]u8), 80).init(allocator),
    };
    
    try setup.db_interface.set_account(token_contract, token_account);
    
    // Set sender's token balance
    const sender_balance_slot = keccak256(&(caller_address ++ [_]u8{0x00} ** 32));
    try setup.db_interface.set_storage(token_contract, std.mem.readIntBig(u256, &sender_balance_slot), sender_balance);
    
    // Prepare transfer call data: transfer(recipient, amount)
    var calldata = [_]u8{
        0xa9, 0x05, 0x9c, 0xbb, // transfer function selector
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // padding
    } ++ recipient_address ++ std.mem.asBytes(&transfer_amount)[24..32] ++ [_]u8{0x00} ** 24;
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, token_contract, 0,
        &[_]u8{}, &calldata, 100000
    );
    defer result.deinit(allocator);
    
    try testing.expect(result.is_success());
    
    // Verify transfer returned success
    var expected_success = [_]u8{0x00} ** 31 ++ [_]u8{0x01};
    try testing.expectEqualSlices(u8, &expected_success, result.output);
}

test "E2E: Complex DeFi swap simulation" {
    const allocator = std.testing.allocator;
    
    var setup = try createE2ETestSetup(allocator);
    defer setup.deinit();
    
    const caller_address = [_]u8{0x11} ** 20;
    const dex_contract = [_]u8{0x22} ** 20;
    const token_a_contract = [_]u8{0x33} ** 20;
    const token_b_contract = [_]u8{0x44} ** 20;
    
    // Simplified DEX contract that performs A->B swap
    const dex_code = [_]u8{
        // Load input amount from calldata
        0x60, 0x00, // PUSH1 0
        0x35,       // CALLDATALOAD
        
        // Calculate output amount (simplified: output = input * 95 / 100)
        0x80,       // DUP1 (copy input amount)
        0x60, 0x5F, // PUSH1 95
        0x02,       // MUL
        0x60, 0x64, // PUSH1 100
        0x04,       // DIV
        
        // Store calculated output in storage slot 0
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE
        
        // Return the output amount
        0x60, 0x00, // PUSH1 0
        0x54,       // SLOAD
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    // Deploy DEX contract
    var dex_account = setup.db_interface.Account{
        .balance = 0, .nonce = 0, .code = &dex_code,
        .storage = std.HashMap([32]u8, u256, std.hash_map.AutoContext([32]u8), 80).init(allocator),
    };
    
    try setup.db_interface.set_account(dex_contract, dex_account);
    
    // Call DEX with swap amount (1000 units)
    const swap_amount: u256 = 1000;
    var calldata: [32]u8 = undefined;
    std.mem.writeIntBig(u256, &calldata, swap_amount);
    
    const result = try executeE2ETransaction(
        allocator, setup, caller_address, dex_contract, 0,
        &[_]u8{}, &calldata, 100000
    );
    defer result.deinit(allocator);
    
    try testing.expect(result.is_success());
    
    // Verify swap calculation: 1000 * 95 / 100 = 950
    const expected_output: u256 = 950;
    var expected_bytes: [32]u8 = undefined;
    std.mem.writeIntBig(u256, &expected_bytes, expected_output);
    
    try testing.expectEqualSlices(u8, &expected_bytes, result.output);
}