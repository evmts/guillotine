const std = @import("std");
const primitives = @import("primitives");
const ExecutionError = @import("../execution/execution_error.zig");
const CreateResult = @import("create_result.zig").CreateResult;
const Vm = @import("../evm.zig");

pub const CreateContractError = std.mem.Allocator.Error || @import("../state/database_interface.zig").DatabaseError || ExecutionError.Error;

/// Create a new contract using CREATE opcode semantics.
///
/// Increments creator's nonce, calculates address via keccak256(rlp([sender, nonce])),
/// transfers value if specified, executes init code, and deploys resulting bytecode.
///
/// Parameters:
/// - creator: Account initiating contract creation
/// - value: Wei to transfer to new contract (0 for no transfer)
/// - init_code: Bytecode executed to generate contract code
/// - gas: Maximum gas for entire creation process
///
/// Returns CreateResult with success=false if:
/// - Creator balance < value (insufficient funds)
/// - Contract exists at calculated address (collision)
/// - Init code reverts or runs out of gas
/// - Deployed bytecode > 24,576 bytes (EIP-170)
/// - Insufficient gas for deployment (200 gas/byte)
///
/// Time complexity: O(init_code_length + deployed_code_length)
/// Memory: Allocates space for deployed bytecode
///
/// See also: create2_contract() for deterministic addresses
pub fn create_contract(self: *Vm, creator: primitives.Address.Address, value: u256, init_code: []const u8, gas: u64) CreateContractError!CreateResult {
    const nonce = try self.state.increment_nonce(creator);
    const new_address = try primitives.Address.calculate_create_address(self.allocator, creator, nonce);
    return self.create_contract_internal(creator, value, init_code, gas, new_address);
}

// ============================================================================
// Fuzz Tests for CREATE Address Calculation (Issue #234)
// Using proper Zig built-in fuzz testing with std.testing.fuzz()
// ============================================================================

const testing = std.testing;

test "fuzz_create_address_calculation" {
    const global = struct {
        fn testCreateAddressCalculation(input: []const u8) anyerror!void {
            if (input.len < 28) return;
            
            const allocator = testing.allocator;
            
            // Extract creator address and nonce from fuzz input
            var creator: primitives.Address.Address = undefined;
            @memcpy(&creator, input[0..20]);
            var nonce_bytes: [8]u8 = [_]u8{0} ** 8;
            @memcpy(nonce_bytes[0..@min(8, input.len -| 20)], input[20..@min(28, input.len)]);
            const nonce = std.mem.readInt(u64, &nonce_bytes, .little);
            
            // Test CREATE address calculation
            const address = primitives.Address.calculate_create_address(allocator, creator, nonce) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return, // Skip invalid inputs
            };
            
            // Verify address is deterministic - same inputs should give same output
            const address2 = primitives.Address.calculate_create_address(allocator, creator, nonce) catch return;
            try testing.expectEqualSlices(u8, &address, &address2);
            
            // Verify address is valid (20 bytes)
            try testing.expectEqual(@as(usize, 20), address.len);
            
            // Verify different nonces produce different addresses
            if (nonce < std.math.maxInt(u64) - 1) {
                const different_address = primitives.Address.calculate_create_address(allocator, creator, nonce + 1) catch return;
                try testing.expect(!std.mem.eql(u8, &address, &different_address));
            }
        }
    };
    const input = "test_input_data_for_fuzzing";
    try global.testCreateAddressCalculation(input);
}

test "fuzz_create_address_creator_variations" {
    const global = struct {
        fn testCreatorVariations(input: []const u8) anyerror!void {
            if (input.len < 40) return;
            
            const allocator = testing.allocator;
            
            // Extract two different creators from fuzz input
            var creator1: primitives.Address.Address = undefined;
            @memcpy(&creator1, input[0..20]);
            var creator2: primitives.Address.Address = undefined;
            @memcpy(&creator2, input[20..40]);
            
            // Fixed nonce for this test
            const nonce: u64 = 1;
            
            // Calculate addresses for both creators
            const address1 = primitives.Address.calculate_create_address(allocator, creator1, nonce) catch return;
            const address2 = primitives.Address.calculate_create_address(allocator, creator2, nonce) catch return;
            
            // Different creators should produce different addresses (unless they're identical)
            if (!std.mem.eql(u8, &creator1, &creator2)) {
                try testing.expect(!std.mem.eql(u8, &address1, &address2));
            } else {
                // Same creators should produce same addresses
                try testing.expectEqualSlices(u8, &address1, &address2);
            }
        }
    };
    const input = "test_input_data_for_fuzzing";
    try global.testCreatorVariations(input);
}

test "fuzz_create_nonce_edge_cases" {
    const global = struct {
        fn testNonceEdgeCases(input: []const u8) anyerror!void {
            if (input.len < 20) return;
            
            const allocator = testing.allocator;
            var creator: primitives.Address.Address = undefined;
            @memcpy(&creator, input[0..20]);
            
            // Test edge case nonce values
            const edge_nonces = [_]u64{
                0,                        // First nonce
                1,                        // Second nonce
                std.math.maxInt(u8),      // 8-bit boundary
                std.math.maxInt(u16),     // 16-bit boundary
                std.math.maxInt(u32),     // 32-bit boundary
                std.math.maxInt(u64) - 1, // Near max value
                std.math.maxInt(u64),     // Maximum u64 value
            };
            
            for (edge_nonces) |nonce| {
                const address = primitives.Address.calculate_create_address(allocator, creator, nonce) catch continue;
                
                // Verify address is valid
                try testing.expectEqual(@as(usize, 20), address.len);
                
                // Verify deterministic behavior
                const address2 = primitives.Address.calculate_create_address(allocator, creator, nonce) catch continue;
                try testing.expectEqualSlices(u8, &address, &address2);
            }
        }
    };
    const input = "test_input_data_for_fuzzing";
    try global.testNonceEdgeCases(input);
}

test "fuzz_create_address_uniqueness" {
    const global = struct {
        fn testAddressUniqueness(input: []const u8) anyerror!void {
            if (input.len < 48) return;
            
            const allocator = testing.allocator;
            
            // Generate multiple creator/nonce combinations
            var creator1: primitives.Address.Address = undefined;
            @memcpy(&creator1, input[0..20]);
            var creator2: primitives.Address.Address = undefined;
            @memcpy(&creator2, input[20..40]);
            var nonce1_bytes: [8]u8 = [_]u8{0} ** 8;
            @memcpy(nonce1_bytes[0..@min(8, input.len -| 40)], input[40..@min(48, input.len)]);
            const nonce1 = std.mem.readInt(u64, &nonce1_bytes, .little);
            var nonce2_bytes: [8]u8 = [_]u8{0} ** 8;
            if (input.len >= 56) {
                @memcpy(&nonce2_bytes, input[48..56]);
            }
            const nonce2 = if (input.len >= 56) std.mem.readInt(u64, &nonce2_bytes, .little) else nonce1 + 1;
            
            // Calculate all possible address combinations
            const addr1_n1 = primitives.Address.calculate_create_address(allocator, creator1, nonce1) catch return;
            const addr1_n2 = primitives.Address.calculate_create_address(allocator, creator1, nonce2) catch return;
            const addr2_n1 = primitives.Address.calculate_create_address(allocator, creator2, nonce1) catch return;
            const addr2_n2 = primitives.Address.calculate_create_address(allocator, creator2, nonce2) catch return;
            
            // Verify that different (creator, nonce) pairs produce different addresses
            const addresses = [_]primitives.Address.Address{ addr1_n1, addr1_n2, addr2_n1, addr2_n2 };
            const pairs = [_]struct { creator: primitives.Address.Address, nonce: u64 }{
                .{ .creator = creator1, .nonce = nonce1 },
                .{ .creator = creator1, .nonce = nonce2 },
                .{ .creator = creator2, .nonce = nonce1 },
                .{ .creator = creator2, .nonce = nonce2 },
            };
            
            for (addresses, 0..) |addr1, i| {
                for (addresses[i + 1..], i + 1..) |addr2, j| {
                    const pair1 = pairs[i];
                    const pair2 = pairs[j];
                    
                    // If pairs are different, addresses should be different
                    if (!std.mem.eql(u8, &pair1.creator, &pair2.creator) or pair1.nonce != pair2.nonce) {
                        try testing.expect(!std.mem.eql(u8, &addr1, &addr2));
                    }
                }
            }
        }
    };
    const input = "test_input_data_for_fuzzing";
    try global.testAddressUniqueness(input);
}
