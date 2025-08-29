// ============================================================================
// HARDFORK C API TESTS - Comprehensive test suite for hardfork_c.zig
// ============================================================================

const std = @import("std");
const testing = std.testing;

// Import the C API
const hardfork_c = @import("../../src/evm/hardfork_c.zig");

test "Hardfork C API: Basic hardfork information" {
    // Test hardfork names
    const frontier_name = hardfork_c.evm_hardfork_name(.FRONTIER);
    try testing.expect(std.mem.eql(u8, std.mem.span(frontier_name), "Frontier"));
    
    const london_name = hardfork_c.evm_hardfork_name(.LONDON);
    try testing.expect(std.mem.eql(u8, std.mem.span(london_name), "London"));
    
    const cancun_name = hardfork_c.evm_hardfork_name(.CANCUN);
    try testing.expect(std.mem.eql(u8, std.mem.span(cancun_name), "Cancun"));
    
    // Test hardfork descriptions
    const frontier_desc = hardfork_c.evm_hardfork_description(.FRONTIER);
    try testing.expect(std.mem.indexOf(u8, std.mem.span(frontier_desc), "Original") != null);
    
    const london_desc = hardfork_c.evm_hardfork_description(.LONDON);
    try testing.expect(std.mem.indexOf(u8, std.mem.span(london_desc), "EIP-1559") != null);
}

test "Hardfork C API: Hardfork validation and latest" {
    // Test hardfork validation
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_is_valid(@intFromEnum(hardfork_c.CHardfork.FRONTIER)));
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_is_valid(@intFromEnum(hardfork_c.CHardfork.LONDON)));
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_is_valid(@intFromEnum(hardfork_c.CHardfork.CANCUN)));
    try testing.expectEqual(@as(c_int, 0), hardfork_c.evm_hardfork_is_valid(999)); // Invalid value
    
    // Test latest hardfork
    const latest = hardfork_c.evm_hardfork_latest();
    try testing.expectEqual(hardfork_c.CHardfork.CANCUN, latest);
}

test "Hardfork C API: Hardfork comparison" {
    // Test greater than or equal comparison
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_gte(.LONDON, .BERLIN));
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_gte(.LONDON, .LONDON));
    try testing.expectEqual(@as(c_int, 0), hardfork_c.evm_hardfork_gte(.BERLIN, .LONDON));
    
    // Test less than comparison
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_lt(.BERLIN, .LONDON));
    try testing.expectEqual(@as(c_int, 0), hardfork_c.evm_hardfork_lt(.LONDON, .BERLIN));
    try testing.expectEqual(@as(c_int, 0), hardfork_c.evm_hardfork_lt(.LONDON, .LONDON));
    
    // Test equality comparison
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_eq(.LONDON, .LONDON));
    try testing.expectEqual(@as(c_int, 0), hardfork_c.evm_hardfork_eq(.LONDON, .BERLIN));
}

test "Hardfork C API: Feature support detection" {
    // Test EIP-1559 support (London+)
    try testing.expectEqual(@as(c_int, 0), hardfork_c.evm_hardfork_supports_eip1559(.BERLIN));
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_supports_eip1559(.LONDON));
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_supports_eip1559(.CANCUN));
    
    // Test access lists support (Berlin+)
    try testing.expectEqual(@as(c_int, 0), hardfork_c.evm_hardfork_supports_access_lists(.ISTANBUL));
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_supports_access_lists(.BERLIN));
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_supports_access_lists(.LONDON));
    
    // Test BASEFEE support (London+)
    try testing.expectEqual(@as(c_int, 0), hardfork_c.evm_hardfork_supports_basefee(.BERLIN));
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_supports_basefee(.LONDON));
    
    // Test selfdestruct refund removal (London+)
    try testing.expectEqual(@as(c_int, 0), hardfork_c.evm_hardfork_supports_selfdestruct_refund_removal(.BERLIN));
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_supports_selfdestruct_refund_removal(.LONDON));
    
    // Test EOF support (not yet activated)
    try testing.expectEqual(@as(c_int, 0), hardfork_c.evm_hardfork_supports_eof(.CANCUN));
    
    // Test blob support (Cancun+)
    try testing.expectEqual(@as(c_int, 0), hardfork_c.evm_hardfork_supports_blobs(.SHANGHAI));
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_supports_blobs(.CANCUN));
    
    // Test beacon block root support (Cancun+)
    try testing.expectEqual(@as(c_int, 0), hardfork_c.evm_hardfork_supports_beacon_block_root(.SHANGHAI));
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_supports_beacon_block_root(.CANCUN));
    
    // Test post-merge detection
    try testing.expectEqual(@as(c_int, 0), hardfork_c.evm_hardfork_is_post_merge(.LONDON));
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_is_post_merge(.MERGE));
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_is_post_merge(.SHANGHAI));
}

test "Hardfork C API: Opcode availability" {
    // Test CHAINID opcode (Istanbul+)
    try testing.expectEqual(@as(c_int, 0), hardfork_c.evm_hardfork_has_chainid_opcode(.PETERSBURG));
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_has_chainid_opcode(.ISTANBUL));
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_has_chainid_opcode(.BERLIN));
    
    // Test SELFBALANCE opcode (Istanbul+)
    try testing.expectEqual(@as(c_int, 0), hardfork_c.evm_hardfork_has_selfbalance_opcode(.PETERSBURG));
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_has_selfbalance_opcode(.ISTANBUL));
    
    // Test BASEFEE opcode (London+)
    try testing.expectEqual(@as(c_int, 0), hardfork_c.evm_hardfork_has_basefee_opcode(.BERLIN));
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_has_basefee_opcode(.LONDON));
    
    // Test PUSH0 opcode (Shanghai+)
    try testing.expectEqual(@as(c_int, 0), hardfork_c.evm_hardfork_has_push0_opcode(.LONDON));
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_has_push0_opcode(.SHANGHAI));
    
    // Test transient storage opcodes (Cancun+)
    try testing.expectEqual(@as(c_int, 0), hardfork_c.evm_hardfork_has_transient_storage(.SHANGHAI));
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_has_transient_storage(.CANCUN));
    
    // Test MCOPY opcode (Cancun+)
    try testing.expectEqual(@as(c_int, 0), hardfork_c.evm_hardfork_has_mcopy_opcode(.SHANGHAI));
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_has_mcopy_opcode(.CANCUN));
}

test "Hardfork C API: Hardfork information structure" {
    var info: hardfork_c.CHardforkInfo = undefined;
    
    // Test London hardfork info
    const result = hardfork_c.evm_hardfork_get_info(.LONDON, &info);
    try testing.expectEqual(@as(c_int, 1), result);
    try testing.expectEqual(hardfork_c.CHardfork.LONDON, info.hardfork);
    try testing.expectEqual(@as(u16, 2021), info.year);
    try testing.expectEqual(@as(u8, 8), info.month);
    try testing.expect(std.mem.indexOf(u8, std.mem.span(info.major_features), "EIP-1559") != null);
    
    // Test Cancun hardfork info
    const cancun_result = hardfork_c.evm_hardfork_get_info(.CANCUN, &info);
    try testing.expectEqual(@as(c_int, 1), cancun_result);
    try testing.expectEqual(hardfork_c.CHardfork.CANCUN, info.hardfork);
    try testing.expectEqual(@as(u16, 2024), info.year);
    try testing.expectEqual(@as(u8, 3), info.month);
}

test "Hardfork C API: All hardforks enumeration" {
    var hardforks: [20]hardfork_c.CHardfork = undefined;
    var count: u32 = 0;
    
    const result = hardfork_c.evm_hardfork_get_all(&hardforks, hardforks.len, &count);
    try testing.expectEqual(@as(c_int, 1), result);
    try testing.expect(count > 0);
    try testing.expect(count <= hardforks.len);
    
    // Verify that we get the expected hardforks in order
    try testing.expectEqual(hardfork_c.CHardfork.FRONTIER, hardforks[0]);
    try testing.expect(count >= 16); // Should have at least 16 hardforks
    
    // Last hardfork should be Cancun
    try testing.expectEqual(hardfork_c.CHardfork.CANCUN, hardforks[count - 1]);
}

test "Hardfork C API: Name parsing" {
    var hardfork: hardfork_c.CHardfork = undefined;
    
    // Test lowercase names
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_from_name("london", &hardfork));
    try testing.expectEqual(hardfork_c.CHardfork.LONDON, hardfork);
    
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_from_name("cancun", &hardfork));
    try testing.expectEqual(hardfork_c.CHardfork.CANCUN, hardfork);
    
    // Test mixed case names
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_from_name("London", &hardfork));
    try testing.expectEqual(hardfork_c.CHardfork.LONDON, hardfork);
    
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_from_name("BERLIN", &hardfork));
    try testing.expectEqual(hardfork_c.CHardfork.BERLIN, hardfork);
    
    // Test names with spaces and underscores
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_from_name("tangerine whistle", &hardfork));
    try testing.expectEqual(hardfork_c.CHardfork.TANGERINE_WHISTLE, hardfork);
    
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_from_name("tangerine_whistle", &hardfork));
    try testing.expectEqual(hardfork_c.CHardfork.TANGERINE_WHISTLE, hardfork);
    
    // Test alternative names
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_from_name("paris", &hardfork)); // Alternative for MERGE
    try testing.expectEqual(hardfork_c.CHardfork.MERGE, hardfork);
    
    try testing.expectEqual(@as(c_int, 1), hardfork_c.evm_hardfork_from_name("merge", &hardfork));
    try testing.expectEqual(hardfork_c.CHardfork.MERGE, hardfork);
    
    // Test invalid names
    try testing.expectEqual(@as(c_int, 0), hardfork_c.evm_hardfork_from_name("invalid_hardfork", &hardfork));
    try testing.expectEqual(@as(c_int, 0), hardfork_c.evm_hardfork_from_name("", &hardfork));
}

test "Hardfork C API: Built-in tests" {
    // Test the built-in C API tests
    try testing.expectEqual(@as(c_int, 0), hardfork_c.evm_hardfork_test_basic());
    try testing.expectEqual(@as(c_int, 0), hardfork_c.evm_hardfork_test_info());
}
