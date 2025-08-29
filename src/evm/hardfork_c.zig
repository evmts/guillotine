// ============================================================================
// HARDFORK C API - FFI interface for Ethereum hardfork configuration
// ============================================================================

const std = @import("std");
const evm = @import("evm");
const Hardfork = evm.Hardfork;

// ============================================================================
// C HARDFORK ENUMERATION
// ============================================================================

/// C-compatible hardfork enumeration
pub const CHardfork = enum(c_int) {
    FRONTIER = @intFromEnum(Hardfork.FRONTIER),
    HOMESTEAD = @intFromEnum(Hardfork.HOMESTEAD),
    TANGERINE_WHISTLE = @intFromEnum(Hardfork.TANGERINE_WHISTLE),
    SPURIOUS_DRAGON = @intFromEnum(Hardfork.SPURIOUS_DRAGON),
    BYZANTIUM = @intFromEnum(Hardfork.BYZANTIUM),
    CONSTANTINOPLE = @intFromEnum(Hardfork.CONSTANTINOPLE),
    PETERSBURG = @intFromEnum(Hardfork.PETERSBURG),
    ISTANBUL = @intFromEnum(Hardfork.ISTANBUL),
    MUIR_GLACIER = @intFromEnum(Hardfork.MUIR_GLACIER),
    BERLIN = @intFromEnum(Hardfork.BERLIN),
    LONDON = @intFromEnum(Hardfork.LONDON),
    ARROW_GLACIER = @intFromEnum(Hardfork.ARROW_GLACIER),
    GRAY_GLACIER = @intFromEnum(Hardfork.GRAY_GLACIER),
    MERGE = @intFromEnum(Hardfork.MERGE),
    SHANGHAI = @intFromEnum(Hardfork.SHANGHAI),
    CANCUN = @intFromEnum(Hardfork.CANCUN),
};

/// Convert C hardfork to native hardfork
fn c_to_native_hardfork(c_hardfork: CHardfork) Hardfork {
    return @enumFromInt(@intFromEnum(c_hardfork));
}

/// Convert native hardfork to C hardfork
fn native_to_c_hardfork(hardfork: Hardfork) CHardfork {
    return @enumFromInt(@intFromEnum(hardfork));
}

// ============================================================================
// HARDFORK INFORMATION
// ============================================================================

/// Get hardfork name as string
/// @param hardfork Hardfork enum value
/// @return Hardfork name
pub export fn evm_hardfork_name(hardfork: CHardfork) [*:0]const u8 {
    return switch (hardfork) {
        .FRONTIER => "Frontier",
        .HOMESTEAD => "Homestead",
        .TANGERINE_WHISTLE => "Tangerine Whistle",
        .SPURIOUS_DRAGON => "Spurious Dragon",
        .BYZANTIUM => "Byzantium",
        .CONSTANTINOPLE => "Constantinople",
        .PETERSBURG => "Petersburg",
        .ISTANBUL => "Istanbul",
        .MUIR_GLACIER => "Muir Glacier",
        .BERLIN => "Berlin",
        .LONDON => "London",
        .ARROW_GLACIER => "Arrow Glacier",
        .GRAY_GLACIER => "Gray Glacier",
        .MERGE => "Merge",
        .SHANGHAI => "Shanghai",
        .CANCUN => "Cancun",
    };
}

/// Get hardfork description
/// @param hardfork Hardfork enum value
/// @return Hardfork description
pub export fn evm_hardfork_description(hardfork: CHardfork) [*:0]const u8 {
    return switch (hardfork) {
        .FRONTIER => "Original Ethereum launch (July 2015)",
        .HOMESTEAD => "First planned hardfork (March 2016)",
        .TANGERINE_WHISTLE => "Gas cost adjustments after DoS attacks (October 2016)",
        .SPURIOUS_DRAGON => "Additional security fixes (November 2016)",
        .BYZANTIUM => "Privacy and scalability improvements (October 2017)",
        .CONSTANTINOPLE => "Performance optimizations (February 2019)",
        .PETERSBURG => "Constantinople fix (February 2019)",
        .ISTANBUL => "Security improvements and gas optimizations (December 2019)",
        .MUIR_GLACIER => "Difficulty bomb delay (January 2020)",
        .BERLIN => "Gas cost adjustments and new opcodes (April 2021)",
        .LONDON => "EIP-1559 fee market reform (August 2021)",
        .ARROW_GLACIER => "Difficulty bomb delay (December 2021)",
        .GRAY_GLACIER => "Difficulty bomb delay (June 2022)",
        .MERGE => "Ethereum merge to proof-of-stake (September 2022)",
        .SHANGHAI => "Staking withdrawals and optimizations (April 2023)",
        .CANCUN => "Proto-danksharding and blob transactions (March 2024)",
    };
}

/// Check if a hardfork is valid
/// @param hardfork Hardfork enum value
/// @return 1 if valid, 0 otherwise
pub export fn evm_hardfork_is_valid(hardfork: c_int) c_int {
    return switch (hardfork) {
        @intFromEnum(CHardfork.FRONTIER)...@intFromEnum(CHardfork.CANCUN) => 1,
        else => 0,
    };
}

/// Get the latest hardfork
/// @return Latest hardfork enum value
pub export fn evm_hardfork_latest() CHardfork {
    return .CANCUN;
}

// ============================================================================
// HARDFORK COMPARISON
// ============================================================================

/// Check if one hardfork is greater than or equal to another
/// @param a First hardfork
/// @param b Second hardfork
/// @return 1 if a >= b, 0 otherwise
pub export fn evm_hardfork_gte(a: CHardfork, b: CHardfork) c_int {
    return if (@intFromEnum(a) >= @intFromEnum(b)) 1 else 0;
}

/// Check if one hardfork is less than another
/// @param a First hardfork
/// @param b Second hardfork
/// @return 1 if a < b, 0 otherwise
pub export fn evm_hardfork_lt(a: CHardfork, b: CHardfork) c_int {
    return if (@intFromEnum(a) < @intFromEnum(b)) 1 else 0;
}

/// Check if two hardforks are equal
/// @param a First hardfork
/// @param b Second hardfork
/// @return 1 if equal, 0 otherwise
pub export fn evm_hardfork_eq(a: CHardfork, b: CHardfork) c_int {
    return if (a == b) 1 else 0;
}

// ============================================================================
// HARDFORK FEATURES
// ============================================================================

/// Check if hardfork supports EIP-1559 (London fee market)
/// @param hardfork Hardfork to check
/// @return 1 if supported, 0 otherwise
pub export fn evm_hardfork_supports_eip1559(hardfork: CHardfork) c_int {
    return if (@intFromEnum(hardfork) >= @intFromEnum(CHardfork.LONDON)) 1 else 0;
}

/// Check if hardfork supports EIP-2930 (access lists)
/// @param hardfork Hardfork to check
/// @return 1 if supported, 0 otherwise
pub export fn evm_hardfork_supports_access_lists(hardfork: CHardfork) c_int {
    return if (@intFromEnum(hardfork) >= @intFromEnum(CHardfork.BERLIN)) 1 else 0;
}

/// Check if hardfork supports EIP-3198 (BASEFEE opcode)
/// @param hardfork Hardfork to check
/// @return 1 if supported, 0 otherwise
pub export fn evm_hardfork_supports_basefee(hardfork: CHardfork) c_int {
    return if (@intFromEnum(hardfork) >= @intFromEnum(CHardfork.LONDON)) 1 else 0;
}

/// Check if hardfork supports EIP-3529 (SELFDESTRUT gas refund changes)
/// @param hardfork Hardfork to check
/// @return 1 if supported, 0 otherwise
pub export fn evm_hardfork_supports_selfdestruct_refund_removal(hardfork: CHardfork) c_int {
    return if (@intFromEnum(hardfork) >= @intFromEnum(CHardfork.LONDON)) 1 else 0;
}

/// Check if hardfork supports EIP-3540 (EOF validation)
/// @param hardfork Hardfork to check
/// @return 1 if supported, 0 otherwise
pub export fn evm_hardfork_supports_eof(hardfork: CHardfork) c_int {
    // EOF is not yet activated in any hardfork
    _ = hardfork;
    return 0;
}

/// Check if hardfork supports EIP-4844 (blob transactions)
/// @param hardfork Hardfork to check
/// @return 1 if supported, 0 otherwise
pub export fn evm_hardfork_supports_blobs(hardfork: CHardfork) c_int {
    return if (@intFromEnum(hardfork) >= @intFromEnum(CHardfork.CANCUN)) 1 else 0;
}

/// Check if hardfork supports EIP-4788 (beacon block root)
/// @param hardfork Hardfork to check
/// @return 1 if supported, 0 otherwise
pub export fn evm_hardfork_supports_beacon_block_root(hardfork: CHardfork) c_int {
    return if (@intFromEnum(hardfork) >= @intFromEnum(CHardfork.CANCUN)) 1 else 0;
}

/// Check if hardfork is post-merge (proof-of-stake)
/// @param hardfork Hardfork to check
/// @return 1 if post-merge, 0 otherwise
pub export fn evm_hardfork_is_post_merge(hardfork: CHardfork) c_int {
    return if (@intFromEnum(hardfork) >= @intFromEnum(CHardfork.MERGE)) 1 else 0;
}

// ============================================================================
// OPCODE AVAILABILITY
// ============================================================================

/// Check if CHAINID opcode is available (Istanbul+)
/// @param hardfork Hardfork to check
/// @return 1 if available, 0 otherwise
pub export fn evm_hardfork_has_chainid_opcode(hardfork: CHardfork) c_int {
    return if (@intFromEnum(hardfork) >= @intFromEnum(CHardfork.ISTANBUL)) 1 else 0;
}

/// Check if SELFBALANCE opcode is available (Istanbul+)
/// @param hardfork Hardfork to check
/// @return 1 if available, 0 otherwise
pub export fn evm_hardfork_has_selfbalance_opcode(hardfork: CHardfork) c_int {
    return if (@intFromEnum(hardfork) >= @intFromEnum(CHardfork.ISTANBUL)) 1 else 0;
}

/// Check if BASEFEE opcode is available (London+)
/// @param hardfork Hardfork to check
/// @return 1 if available, 0 otherwise
pub export fn evm_hardfork_has_basefee_opcode(hardfork: CHardfork) c_int {
    return if (@intFromEnum(hardfork) >= @intFromEnum(CHardfork.LONDON)) 1 else 0;
}

/// Check if PUSH0 opcode is available (Shanghai+)
/// @param hardfork Hardfork to check
/// @return 1 if available, 0 otherwise
pub export fn evm_hardfork_has_push0_opcode(hardfork: CHardfork) c_int {
    return if (@intFromEnum(hardfork) >= @intFromEnum(CHardfork.SHANGHAI)) 1 else 0;
}

/// Check if transient storage opcodes are available (Cancun+)
/// @param hardfork Hardfork to check
/// @return 1 if available, 0 otherwise
pub export fn evm_hardfork_has_transient_storage(hardfork: CHardfork) c_int {
    return if (@intFromEnum(hardfork) >= @intFromEnum(CHardfork.CANCUN)) 1 else 0;
}

/// Check if MCOPY opcode is available (Cancun+)
/// @param hardfork Hardfork to check
/// @return 1 if available, 0 otherwise
pub export fn evm_hardfork_has_mcopy_opcode(hardfork: CHardfork) c_int {
    return if (@intFromEnum(hardfork) >= @intFromEnum(CHardfork.CANCUN)) 1 else 0;
}

// ============================================================================
// HARDFORK TIMELINE
// ============================================================================

/// C structure for hardfork timeline information
pub const CHardforkInfo = extern struct {
    hardfork: CHardfork,
    name: [*:0]const u8,
    description: [*:0]const u8,
    year: u16,
    month: u8,
    major_features: [*:0]const u8,
};

/// Get information about a specific hardfork
/// @param hardfork Hardfork to get info for
/// @param info_out Output info structure
/// @return 1 if successful, 0 if invalid hardfork
pub export fn evm_hardfork_get_info(hardfork: CHardfork, info_out: *CHardforkInfo) c_int {
    if (evm_hardfork_is_valid(@intFromEnum(hardfork)) == 0) return 0;
    
    info_out.hardfork = hardfork;
    info_out.name = evm_hardfork_name(hardfork);
    info_out.description = evm_hardfork_description(hardfork);
    
    // Set timeline and major features
    switch (hardfork) {
        .FRONTIER => {
            info_out.year = 2015;
            info_out.month = 7;
            info_out.major_features = "Initial Ethereum launch";
        },
        .HOMESTEAD => {
            info_out.year = 2016;
            info_out.month = 3;
            info_out.major_features = "Difficulty adjustment, gas cost changes";
        },
        .TANGERINE_WHISTLE => {
            info_out.year = 2016;
            info_out.month = 10;
            info_out.major_features = "Gas cost increases after DoS attacks";
        },
        .SPURIOUS_DRAGON => {
            info_out.year = 2016;
            info_out.month = 11;
            info_out.major_features = "Empty account cleanup, max code size";
        },
        .BYZANTIUM => {
            info_out.year = 2017;
            info_out.month = 10;
            info_out.major_features = "zk-SNARKs support, difficulty bomb delay";
        },
        .CONSTANTINOPLE => {
            info_out.year = 2019;
            info_out.month = 2;
            info_out.major_features = "CREATE2, EXTCODEHASH, cheaper operations";
        },
        .PETERSBURG => {
            info_out.year = 2019;
            info_out.month = 2;
            info_out.major_features = "Constantinople fix";
        },
        .ISTANBUL => {
            info_out.year = 2019;
            info_out.month = 12;
            info_out.major_features = "CHAINID, SELFBALANCE, cheaper gas costs";
        },
        .MUIR_GLACIER => {
            info_out.year = 2020;
            info_out.month = 1;
            info_out.major_features = "Difficulty bomb delay";
        },
        .BERLIN => {
            info_out.year = 2021;
            info_out.month = 4;
            info_out.major_features = "Access lists, gas cost changes";
        },
        .LONDON => {
            info_out.year = 2021;
            info_out.month = 8;
            info_out.major_features = "EIP-1559 fee market, BASEFEE opcode";
        },
        .ARROW_GLACIER => {
            info_out.year = 2021;
            info_out.month = 12;
            info_out.major_features = "Difficulty bomb delay";
        },
        .GRAY_GLACIER => {
            info_out.year = 2022;
            info_out.month = 6;
            info_out.major_features = "Difficulty bomb delay";
        },
        .MERGE => {
            info_out.year = 2022;
            info_out.month = 9;
            info_out.major_features = "Proof-of-stake transition (The Merge)";
        },
        .SHANGHAI => {
            info_out.year = 2023;
            info_out.month = 4;
            info_out.major_features = "Staking withdrawals, PUSH0 opcode";
        },
        .CANCUN => {
            info_out.year = 2024;
            info_out.month = 3;
            info_out.major_features = "Blob transactions, transient storage";
        },
    }
    
    return 1;
}

/// Get all available hardforks
/// @param hardforks_out Output array of hardforks
/// @param max_count Maximum number of hardforks to return
/// @param count_out Actual number of hardforks returned
/// @return 1 if successful, 0 otherwise
pub export fn evm_hardfork_get_all(hardforks_out: [*]CHardfork, max_count: u32, count_out: *u32) c_int {
    const all_hardforks = [_]CHardfork{
        .FRONTIER,
        .HOMESTEAD,
        .TANGERINE_WHISTLE,
        .SPURIOUS_DRAGON,
        .BYZANTIUM,
        .CONSTANTINOPLE,
        .PETERSBURG,
        .ISTANBUL,
        .MUIR_GLACIER,
        .BERLIN,
        .LONDON,
        .ARROW_GLACIER,
        .GRAY_GLACIER,
        .MERGE,
        .SHANGHAI,
        .CANCUN,
    };
    
    const count = @min(all_hardforks.len, max_count);
    @memcpy(hardforks_out[0..count], all_hardforks[0..count]);
    count_out.* = @intCast(count);
    
    return 1;
}

// ============================================================================
// HARDFORK PARSING
// ============================================================================

/// Parse hardfork from string name
/// @param name Hardfork name (case insensitive)
/// @param hardfork_out Output hardfork
/// @return 1 if successfully parsed, 0 otherwise
pub export fn evm_hardfork_from_name(name: [*:0]const u8, hardfork_out: *CHardfork) c_int {
    const name_str = std.mem.span(name);
    
    // Convert to lowercase for case-insensitive comparison
    var lowercase_buf: [32]u8 = undefined;
    if (name_str.len >= lowercase_buf.len) return 0;
    
    for (name_str, 0..) |c, i| {
        lowercase_buf[i] = std.ascii.toLower(c);
    }
    const lowercase_name = lowercase_buf[0..name_str.len];
    
    if (std.mem.eql(u8, lowercase_name, "frontier")) {
        hardfork_out.* = .FRONTIER;
    } else if (std.mem.eql(u8, lowercase_name, "homestead")) {
        hardfork_out.* = .HOMESTEAD;
    } else if (std.mem.eql(u8, lowercase_name, "tangerine whistle") or std.mem.eql(u8, lowercase_name, "tangerine_whistle")) {
        hardfork_out.* = .TANGERINE_WHISTLE;
    } else if (std.mem.eql(u8, lowercase_name, "spurious dragon") or std.mem.eql(u8, lowercase_name, "spurious_dragon")) {
        hardfork_out.* = .SPURIOUS_DRAGON;
    } else if (std.mem.eql(u8, lowercase_name, "byzantium")) {
        hardfork_out.* = .BYZANTIUM;
    } else if (std.mem.eql(u8, lowercase_name, "constantinople")) {
        hardfork_out.* = .CONSTANTINOPLE;
    } else if (std.mem.eql(u8, lowercase_name, "petersburg")) {
        hardfork_out.* = .PETERSBURG;
    } else if (std.mem.eql(u8, lowercase_name, "istanbul")) {
        hardfork_out.* = .ISTANBUL;
    } else if (std.mem.eql(u8, lowercase_name, "muir glacier") or std.mem.eql(u8, lowercase_name, "muir_glacier")) {
        hardfork_out.* = .MUIR_GLACIER;
    } else if (std.mem.eql(u8, lowercase_name, "berlin")) {
        hardfork_out.* = .BERLIN;
    } else if (std.mem.eql(u8, lowercase_name, "london")) {
        hardfork_out.* = .LONDON;
    } else if (std.mem.eql(u8, lowercase_name, "arrow glacier") or std.mem.eql(u8, lowercase_name, "arrow_glacier")) {
        hardfork_out.* = .ARROW_GLACIER;
    } else if (std.mem.eql(u8, lowercase_name, "gray glacier") or std.mem.eql(u8, lowercase_name, "gray_glacier")) {
        hardfork_out.* = .GRAY_GLACIER;
    } else if (std.mem.eql(u8, lowercase_name, "merge") or std.mem.eql(u8, lowercase_name, "paris")) {
        hardfork_out.* = .MERGE;
    } else if (std.mem.eql(u8, lowercase_name, "shanghai")) {
        hardfork_out.* = .SHANGHAI;
    } else if (std.mem.eql(u8, lowercase_name, "cancun")) {
        hardfork_out.* = .CANCUN;
    } else {
        return 0; // Unknown hardfork
    }
    
    return 1;
}

// ============================================================================
// TESTING
// ============================================================================

/// Test hardfork utilities
pub export fn evm_hardfork_test_basic() c_int {
    // Test hardfork comparison
    if (evm_hardfork_gte(.LONDON, .BERLIN) != 1) return -1;
    if (evm_hardfork_lt(.BERLIN, .LONDON) != 1) return -2;
    if (evm_hardfork_eq(.CANCUN, .CANCUN) != 1) return -3;
    
    // Test feature detection
    if (evm_hardfork_supports_eip1559(.LONDON) != 1) return -4;
    if (evm_hardfork_supports_eip1559(.BERLIN) != 0) return -5;
    
    // Test opcode availability
    if (evm_hardfork_has_push0_opcode(.SHANGHAI) != 1) return -6;
    if (evm_hardfork_has_push0_opcode(.LONDON) != 0) return -7;
    
    // Test name parsing
    var hardfork: CHardfork = undefined;
    if (evm_hardfork_from_name("london", &hardfork) != 1) return -8;
    if (hardfork != .LONDON) return -9;
    
    return 0;
}

/// Test hardfork information
pub export fn evm_hardfork_test_info() c_int {
    var info: CHardforkInfo = undefined;
    
    // Test valid hardfork info
    if (evm_hardfork_get_info(.LONDON, &info) != 1) return -1;
    if (info.hardfork != .LONDON) return -2;
    if (info.year != 2021) return -3;
    
    // Test all hardforks enumeration
    var hardforks: [20]CHardfork = undefined;
    var count: u32 = 0;
    
    if (evm_hardfork_get_all(&hardforks, hardforks.len, &count) != 1) return -4;
    if (count == 0) return -5;
    
    return 0;
}

test "Hardfork C API compilation" {
    std.testing.refAllDecls(@This());
}
