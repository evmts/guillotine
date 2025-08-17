const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");

// Import interpret2 components
const interpret2 = evm.interpret2;

// =============================================================================
// Helper Functions
// =============================================================================

/// Helper to run test and check result in memory
fn runTestAndCheckResult(allocator: std.mem.Allocator, code: []const u8, expected_result: u256) !void {
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    // interpret2 now returns noreturn, so we need to catch the error
    const result = interpret2.interpret2(&frame, code) catch |err| err;
    try testing.expectEqual(evm.ExecutionError.Error.RETURN, result);
    
    const mem_result = try frame.memory.get_u256(0);
    try testing.expectEqual(expected_result, mem_result);
}

// =============================================================================
// ADD Opcode Tests (0x01)
// =============================================================================

test "interpret2: ADD happy path" {
    const allocator = testing.allocator;
    
    // ADD 5 + 3 = 8
    const code = [_]u8{
        0x60, 0x05,  // PUSH1 5
        0x60, 0x03,  // PUSH1 3
        0x01,        // ADD
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 8);
}

test "interpret2: ADD with zero" {
    const allocator = testing.allocator;
    
    // ADD 0 + 42 = 42
    const code = [_]u8{
        0x60, 0x00,  // PUSH1 0
        0x60, 0x2A,  // PUSH1 42
        0x01,        // ADD
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 42);
}

test "interpret2: ADD overflow wrapping" {
    const allocator = testing.allocator;
    
    // ADD MAX_U256 + 1 = 0 (overflow wraps)
    const code = [_]u8{
        0x7F, // PUSH32 MAX_U256
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x60, 0x01,  // PUSH1 1
        0x01,        // ADD
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 0);
}

// =============================================================================
// MUL Opcode Tests (0x02)
// =============================================================================

test "interpret2: MUL happy path" {
    const allocator = testing.allocator;
    
    // MUL 6 * 7 = 42
    const code = [_]u8{
        0x60, 0x06,  // PUSH1 6
        0x60, 0x07,  // PUSH1 7
        0x02,        // MUL
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 42);
}

test "interpret2: MUL with zero" {
    const allocator = testing.allocator;
    
    // MUL 100 * 0 = 0
    const code = [_]u8{
        0x60, 0x64,  // PUSH1 100
        0x60, 0x00,  // PUSH1 0
        0x02,        // MUL
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 0);
}

test "interpret2: MUL with one" {
    const allocator = testing.allocator;
    
    // MUL 123 * 1 = 123
    const code = [_]u8{
        0x60, 0x7B,  // PUSH1 123
        0x60, 0x01,  // PUSH1 1
        0x02,        // MUL
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 123);
}

test "interpret2: MUL overflow wrapping" {
    const allocator = testing.allocator;
    
    // MUL 2^255 * 2 = 0 (overflow wraps)
    const code = [_]u8{
        0x7F, // PUSH32 2^255
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x60, 0x02,  // PUSH1 2
        0x02,        // MUL
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 0);
}

// =============================================================================
// SUB Opcode Tests (0x03)
// =============================================================================

test "interpret2: SUB happy path" {
    const allocator = testing.allocator;
    
    // SUB 10 - 3 = 7
    const code = [_]u8{
        0x60, 0x03,  // PUSH1 3
        0x60, 0x0A,  // PUSH1 10
        0x03,        // SUB
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 7);
}

test "interpret2: SUB with zero" {
    const allocator = testing.allocator;
    
    // SUB 42 - 0 = 42
    const code = [_]u8{
        0x60, 0x00,  // PUSH1 0
        0x60, 0x2A,  // PUSH1 42
        0x03,        // SUB
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 42);
}

test "interpret2: SUB underflow wrapping" {
    const allocator = testing.allocator;
    
    // SUB 0 - 1 = MAX_U256 (underflow wraps)
    const code = [_]u8{
        0x60, 0x01,  // PUSH1 1
        0x60, 0x00,  // PUSH1 0
        0x03,        // SUB
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, std.math.maxInt(u256));
}

// =============================================================================
// DIV Opcode Tests (0x04)
// =============================================================================

test "interpret2: DIV happy path" {
    const allocator = testing.allocator;
    
    // DIV 21 / 3 = 7
    const code = [_]u8{
        0x60, 0x03,  // PUSH1 3 (divisor)
        0x60, 0x15,  // PUSH1 21 (dividend)
        0x04,        // DIV
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 7);
}

test "interpret2: DIV by zero returns zero" {
    const allocator = testing.allocator;
    
    // DIV 100 / 0 = 0 (EVM rule: division by zero returns 0)
    const code = [_]u8{
        0x60, 0x00,  // PUSH1 0 (divisor)
        0x60, 0x64,  // PUSH1 100 (dividend)
        0x04,        // DIV
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 0);
}

test "interpret2: DIV with remainder" {
    const allocator = testing.allocator;
    
    // DIV 10 / 3 = 3 (integer division, remainder discarded)
    const code = [_]u8{
        0x60, 0x03,  // PUSH1 3 (divisor)
        0x60, 0x0A,  // PUSH1 10 (dividend)
        0x04,        // DIV
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 3);
}

// =============================================================================
// SDIV Opcode Tests (0x05)
// =============================================================================

test "interpret2: SDIV positive numbers" {
    const allocator = testing.allocator;
    
    // SDIV 20 / 4 = 5
    const code = [_]u8{
        0x60, 0x04,  // PUSH1 4 (divisor)
        0x60, 0x14,  // PUSH1 20 (dividend)
        0x05,        // SDIV
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 5);
}

test "interpret2: SDIV by zero returns zero" {
    const allocator = testing.allocator;
    
    // SDIV 100 / 0 = 0 (EVM rule: division by zero returns 0)
    const code = [_]u8{
        0x60, 0x00,  // PUSH1 0 (divisor)
        0x60, 0x64,  // PUSH1 100 (dividend)
        0x05,        // SDIV
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 0);
}

test "interpret2: SDIV negative divided by positive" {
    const allocator = testing.allocator;
    
    // SDIV -20 / 4 = -5
    // -20 in two's complement u256: 0xFFFF...FFEC
    const code = [_]u8{
        0x60, 0x04,  // PUSH1 4 (divisor)
        0x7F, // PUSH32 -20 (0xFFFF...FFEC)
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xEC,
        0x05,        // SDIV
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    // Expected result: -5 in two's complement u256: 0xFFFF...FFFB
    const expected: u256 = @bitCast(@as(i256, -5));
    try runTestAndCheckResult(allocator, &code, expected);
}

test "interpret2: SDIV overflow case MIN_I256 / -1" {
    const allocator = testing.allocator;
    
    // SDIV MIN_I256 / -1 = MIN_I256 (overflow protection)
    // MIN_I256 = 0x8000...0000, -1 = 0xFFFF...FFFF
    const code = [_]u8{
        0x7F, // PUSH32 -1 (0xFFFF...FFFF)
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x7F, // PUSH32 MIN_I256 (0x8000...0000)
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x05,        // SDIV
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    // Expected result: MIN_I256 (0x8000...0000)
    const expected: u256 = @as(u256, 1) << 255;
    try runTestAndCheckResult(allocator, &code, expected);
}

// =============================================================================
// MOD Opcode Tests (0x06)
// =============================================================================

test "interpret2: MOD happy path" {
    const allocator = testing.allocator;
    
    // MOD 17 % 5 = 2
    const code = [_]u8{
        0x60, 0x05,  // PUSH1 5 (divisor)
        0x60, 0x11,  // PUSH1 17 (dividend)
        0x06,        // MOD
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 2);
}

test "interpret2: MOD by zero returns zero" {
    const allocator = testing.allocator;
    
    // MOD 100 % 0 = 0 (EVM rule: modulo by zero returns 0)
    const code = [_]u8{
        0x60, 0x00,  // PUSH1 0 (divisor)
        0x60, 0x64,  // PUSH1 100 (dividend)
        0x06,        // MOD
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 0);
}

test "interpret2: MOD exact division" {
    const allocator = testing.allocator;
    
    // MOD 15 % 5 = 0
    const code = [_]u8{
        0x60, 0x05,  // PUSH1 5 (divisor)
        0x60, 0x0F,  // PUSH1 15 (dividend)
        0x06,        // MOD
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 0);
}

// =============================================================================
// SMOD Opcode Tests (0x07)
// =============================================================================

test "interpret2: SMOD positive numbers" {
    const allocator = testing.allocator;
    
    // SMOD 17 % 5 = 2
    const code = [_]u8{
        0x60, 0x05,  // PUSH1 5 (divisor)
        0x60, 0x11,  // PUSH1 17 (dividend)
        0x07,        // SMOD
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 2);
}

test "interpret2: SMOD by zero returns zero" {
    const allocator = testing.allocator;
    
    // SMOD 100 % 0 = 0 (EVM rule: modulo by zero returns 0)
    const code = [_]u8{
        0x60, 0x00,  // PUSH1 0 (divisor)
        0x60, 0x64,  // PUSH1 100 (dividend)
        0x07,        // SMOD
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 0);
}

test "interpret2: SMOD negative dividend" {
    const allocator = testing.allocator;
    
    // SMOD -17 % 5 = -2 (result has same sign as dividend)
    // -17 in two's complement u256: 0xFFFF...FFEF
    const code = [_]u8{
        0x60, 0x05,  // PUSH1 5 (divisor)
        0x7F, // PUSH32 -17 (0xFFFF...FFEF)
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xEF,
        0x07,        // SMOD
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    // Expected result: -2 in two's complement u256: 0xFFFF...FFFE
    const expected: u256 = @bitCast(@as(i256, -2));
    try runTestAndCheckResult(allocator, &code, expected);
}

// =============================================================================
// ADDMOD Opcode Tests (0x08)
// =============================================================================

test "interpret2: ADDMOD happy path" {
    const allocator = testing.allocator;
    
    // ADDMOD (10 + 20) % 7 = 2
    const code = [_]u8{
        0x60, 0x07,  // PUSH1 7 (modulus)
        0x60, 0x14,  // PUSH1 20 (second addend)
        0x60, 0x0A,  // PUSH1 10 (first addend)
        0x08,        // ADDMOD
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 2);
}

test "interpret2: ADDMOD by zero returns zero" {
    const allocator = testing.allocator;
    
    // ADDMOD (10 + 20) % 0 = 0 (modulo by zero returns 0)
    const code = [_]u8{
        0x60, 0x00,  // PUSH1 0 (modulus)
        0x60, 0x14,  // PUSH1 20 (second addend)
        0x60, 0x0A,  // PUSH1 10 (first addend)
        0x08,        // ADDMOD
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 0);
}

test "interpret2: ADDMOD with overflow" {
    const allocator = testing.allocator;
    
    // ADDMOD (MAX_U256 + 5) % 10 = 0 (handles overflow correctly)
    // MAX_U256 % 10 = 5, so (5 + 5) % 10 = 0
    const code = [_]u8{
        0x60, 0x0A,  // PUSH1 10 (modulus)
        0x60, 0x05,  // PUSH1 5 (second addend)
        0x7F, // PUSH32 MAX_U256 (first addend)
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x08,        // ADDMOD
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 0);
}

// =============================================================================
// MULMOD Opcode Tests (0x09)
// =============================================================================

test "interpret2: MULMOD happy path" {
    const allocator = testing.allocator;
    
    // MULMOD (10 * 20) % 7 = 4
    const code = [_]u8{
        0x60, 0x07,  // PUSH1 7 (modulus)
        0x60, 0x14,  // PUSH1 20 (second multiplicand)
        0x60, 0x0A,  // PUSH1 10 (first multiplicand)
        0x09,        // MULMOD
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 4);
}

test "interpret2: MULMOD by zero returns zero" {
    const allocator = testing.allocator;
    
    // MULMOD (10 * 20) % 0 = 0 (modulo by zero returns 0)
    const code = [_]u8{
        0x60, 0x00,  // PUSH1 0 (modulus)
        0x60, 0x14,  // PUSH1 20 (second multiplicand)
        0x60, 0x0A,  // PUSH1 10 (first multiplicand)
        0x09,        // MULMOD
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 0);
}

test "interpret2: MULMOD with large numbers" {
    const allocator = testing.allocator;
    
    // MULMOD (2^128 * 2^128) % 100 = 36 (2^256 % 100 = 36, handled correctly)
    const code = [_]u8{
        0x60, 0x64,  // PUSH1 100 (modulus)
        0x70, // PUSH17 2^128
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x70, // PUSH17 2^128
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x09,        // MULMOD
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 36);
}

// =============================================================================
// EXP Opcode Tests (0x0A)
// =============================================================================

test "interpret2: EXP happy path" {
    const allocator = testing.allocator;
    
    // EXP 2^10 = 1024
    const code = [_]u8{
        0x60, 0x0A,  // PUSH1 10 (exponent)
        0x60, 0x02,  // PUSH1 2 (base)
        0x0A,        // EXP
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 1024);
}

test "interpret2: EXP to power of zero" {
    const allocator = testing.allocator;
    
    // EXP 123^0 = 1 (anything to power 0 is 1)
    const code = [_]u8{
        0x60, 0x00,  // PUSH1 0 (exponent)
        0x60, 0x7B,  // PUSH1 123 (base)
        0x0A,        // EXP
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 1);
}

test "interpret2: EXP zero to positive power" {
    const allocator = testing.allocator;
    
    // EXP 0^10 = 0 (zero to any positive power is 0)
    const code = [_]u8{
        0x60, 0x0A,  // PUSH1 10 (exponent)
        0x60, 0x00,  // PUSH1 0 (base)
        0x0A,        // EXP
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 0);
}

test "interpret2: EXP one to any power" {
    const allocator = testing.allocator;
    
    // EXP 1^255 = 1 (one to any power is 1)
    const code = [_]u8{
        0x60, 0xFF,  // PUSH1 255 (exponent)
        0x60, 0x01,  // PUSH1 1 (base)
        0x0A,        // EXP
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 1);
}

test "interpret2: EXP to first power" {
    const allocator = testing.allocator;
    
    // EXP 42^1 = 42 (anything to power 1 is itself)
    const code = [_]u8{
        0x60, 0x01,  // PUSH1 1 (exponent)
        0x60, 0x2A,  // PUSH1 42 (base)
        0x0A,        // EXP
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 42);
}

// =============================================================================
// SIGNEXTEND Opcode Tests (0x0B)
// =============================================================================

test "interpret2: SIGNEXTEND from byte 0 positive" {
    const allocator = testing.allocator;
    
    // SIGNEXTEND 0x7F from byte 0 = 0x7F (positive, no extension needed)
    const code = [_]u8{
        0x60, 0x7F,  // PUSH1 0x7F (value)
        0x60, 0x00,  // PUSH1 0 (byte position)
        0x0B,        // SIGNEXTEND
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 0x7F);
}

test "interpret2: SIGNEXTEND from byte 0 negative" {
    const allocator = testing.allocator;
    
    // SIGNEXTEND 0x80 from byte 0 = 0xFFFF...FF80 (negative, extend with 1s)
    const code = [_]u8{
        0x60, 0x80,  // PUSH1 0x80 (value)
        0x60, 0x00,  // PUSH1 0 (byte position)
        0x0B,        // SIGNEXTEND
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xF3,        // RETURN
    };
    
    // Expected: 0xFFFF...FF80
    var expected: u256 = 0x80;
    expected |= ~(@as(u256, 0xFF)); // Fill upper bits with 1s
    try runTestAndCheckResult(allocator, &code, expected);
}

test "interpret2: SIGNEXTEND from byte 1 positive" {
    const allocator = testing.allocator;
    
    // SIGNEXTEND 0x7FFF from byte 1 = 0x7FFF (positive 16-bit)
    const code = [_]u8{
        0x61, 0x7F, 0xFF,  // PUSH2 0x7FFF (value)
        0x60, 0x01,        // PUSH1 1 (byte position)
        0x0B,              // SIGNEXTEND
        0x60, 0x00,        // PUSH1 0 (memory offset)
        0x52,              // MSTORE
        0x60, 0x20,        // PUSH1 32 (size)
        0x60, 0x00,        // PUSH1 0 (offset)
        0xF3,              // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 0x7FFF);
}

test "interpret2: SIGNEXTEND from byte 1 negative" {
    const allocator = testing.allocator;
    
    // SIGNEXTEND 0x8000 from byte 1 = 0xFFFF...8000 (negative 16-bit)
    const code = [_]u8{
        0x61, 0x80, 0x00,  // PUSH2 0x8000 (value)
        0x60, 0x01,        // PUSH1 1 (byte position)
        0x0B,              // SIGNEXTEND
        0x60, 0x00,        // PUSH1 0 (memory offset)
        0x52,              // MSTORE
        0x60, 0x20,        // PUSH1 32 (size)
        0x60, 0x00,        // PUSH1 0 (offset)
        0xF3,              // RETURN
    };
    
    // Expected: 0xFFFF...8000
    var expected: u256 = 0x8000;
    expected |= ~(@as(u256, 0xFFFF)); // Fill upper bits with 1s
    try runTestAndCheckResult(allocator, &code, expected);
}

test "interpret2: SIGNEXTEND beyond valid range" {
    const allocator = testing.allocator;
    
    // SIGNEXTEND from byte 32 = no change (already full width)
    const code = [_]u8{
        0x61, 0x12, 0x34,  // PUSH2 0x1234 (value)
        0x60, 0x20,        // PUSH1 32 (byte position >= 31)
        0x0B,              // SIGNEXTEND
        0x60, 0x00,        // PUSH1 0 (memory offset)
        0x52,              // MSTORE
        0x60, 0x20,        // PUSH1 32 (size)
        0x60, 0x00,        // PUSH1 0 (offset)
        0xF3,              // RETURN
    };
    
    try runTestAndCheckResult(allocator, &code, 0x1234);
}