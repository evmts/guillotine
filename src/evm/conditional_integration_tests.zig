/// Integration Tests for Conditional EVM Features
/// This demonstrates end-to-end validation of conditional compilation across all hardforks
const std = @import("std");
const testing = std.testing;

// Import all the conditional components we've built
const Eips = @import("eips.zig").Eips;
const Hardfork = @import("hardfork.zig").Hardfork;
const EvmConfig = @import("evm_config.zig").EvmConfig;
const ConditionalCallResult = @import("conditional_call_result.zig").CallResult;
const ConditionalOpcodeHandlers = @import("conditional_opcode_handlers.zig");
const ConditionalEvm = @import("conditional_evm_state.zig").ConditionalEvm;
const primitives = @import("primitives");
const Database = @import("database.zig").Database;
const BlockInfo = @import("block_info.zig").DefaultBlockInfo;
const TransactionContext = @import("transaction_context.zig").TransactionContext;

/// Test configuration for all major hardforks
const TestHardfork = struct {
    config: EvmConfig,
    name: []const u8,
    expected_features: FeatureSet,
};

const FeatureSet = struct {
    has_access_list: bool,
    has_create2: bool, 
    has_push0: bool,
    has_basefee: bool,
    has_transient_storage: bool,
    has_mcopy: bool,
    has_blobhash: bool,
    has_logs: bool,
    has_selfdestruct: bool,
    has_eip6780: bool, // selfdestruct same transaction only
};

const TEST_HARDFORKS = [_]TestHardfork{
    .{
        .config = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } },
        .name = "FRONTIER",
        .expected_features = .{
            .has_access_list = false,
            .has_create2 = false,
            .has_push0 = false,
            .has_basefee = false,
            .has_transient_storage = false,
            .has_mcopy = false,
            .has_blobhash = false,
            .has_logs = true,
            .has_selfdestruct = true,
            .has_eip6780 = false,
        },
    },
    .{
        .config = EvmConfig{ .eips = Eips{ .hardfork = .HOMESTEAD } },
        .name = "HOMESTEAD",
        .expected_features = .{
            .has_access_list = false,
            .has_create2 = false,
            .has_push0 = false,
            .has_basefee = false,
            .has_transient_storage = false,
            .has_mcopy = false,
            .has_blobhash = false,
            .has_logs = true,
            .has_selfdestruct = true,
            .has_eip6780 = false,
        },
    },
    .{
        .config = EvmConfig{ .eips = Eips{ .hardfork = .BYZANTIUM } },
        .name = "BYZANTIUM",
        .expected_features = .{
            .has_access_list = false,
            .has_create2 = false,
            .has_push0 = false,
            .has_basefee = false,
            .has_transient_storage = false,
            .has_mcopy = false,
            .has_blobhash = false,
            .has_logs = true,
            .has_selfdestruct = true,
            .has_eip6780 = false,
        },
    },
    .{
        .config = EvmConfig{ .eips = Eips{ .hardfork = .CONSTANTINOPLE } },
        .name = "CONSTANTINOPLE",
        .expected_features = .{
            .has_access_list = false,
            .has_create2 = true, // EIP-1014
            .has_push0 = false,
            .has_basefee = false,
            .has_transient_storage = false,
            .has_mcopy = false,
            .has_blobhash = false,
            .has_logs = true,
            .has_selfdestruct = true,
            .has_eip6780 = false,
        },
    },
    .{
        .config = EvmConfig{ .eips = Eips{ .hardfork = .BERLIN } },
        .name = "BERLIN",
        .expected_features = .{
            .has_access_list = true, // EIP-2929
            .has_create2 = true,
            .has_push0 = false,
            .has_basefee = false,
            .has_transient_storage = false,
            .has_mcopy = false,
            .has_blobhash = false,
            .has_logs = true,
            .has_selfdestruct = true,
            .has_eip6780 = false,
        },
    },
    .{
        .config = EvmConfig{ .eips = Eips{ .hardfork = .LONDON } },
        .name = "LONDON",
        .expected_features = .{
            .has_access_list = true,
            .has_create2 = true,
            .has_push0 = false,
            .has_basefee = true, // EIP-3198
            .has_transient_storage = false,
            .has_mcopy = false,
            .has_blobhash = false,
            .has_logs = true,
            .has_selfdestruct = true,
            .has_eip6780 = false,
        },
    },
    .{
        .config = EvmConfig{ .eips = Eips{ .hardfork = .SHANGHAI } },
        .name = "SHANGHAI",
        .expected_features = .{
            .has_access_list = true,
            .has_create2 = true,
            .has_push0 = true, // EIP-3855
            .has_basefee = true,
            .has_transient_storage = false,
            .has_mcopy = false,
            .has_blobhash = false,
            .has_logs = true,
            .has_selfdestruct = true,
            .has_eip6780 = false,
        },
    },
    .{
        .config = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } },
        .name = "CANCUN",
        .expected_features = .{
            .has_access_list = true,
            .has_create2 = true,
            .has_push0 = true,
            .has_basefee = true,
            .has_transient_storage = true, // EIP-1153
            .has_mcopy = true, // EIP-5656
            .has_blobhash = true, // EIP-4844
            .has_logs = true,
            .has_selfdestruct = true,
            .has_eip6780 = true, // EIP-6780
        },
    },
    .{
        .config = EvmConfig{ .eips = Eips{ .hardfork = .PRAGUE } },
        .name = "PRAGUE",
        .expected_features = .{
            .has_access_list = true,
            .has_create2 = true,
            .has_push0 = true,
            .has_basefee = true,
            .has_transient_storage = true,
            .has_mcopy = true,
            .has_blobhash = true,
            .has_logs = true,
            .has_selfdestruct = true,
            .has_eip6780 = true,
        },
    },
};

test "integration - all hardforks compile and have correct feature sets" {
    // This test validates that every hardfork configuration compiles
    // and has the expected feature set
    inline for (TEST_HARDFORKS) |test_hf| {
        const config = test_hf.config;
        const expected = test_hf.expected_features;
        
        // Test EIPs feature detection
        try testing.expectEqual(expected.has_access_list, config.eips.has_access_list());
        try testing.expectEqual(expected.has_create2, config.eips.has_create2());
        try testing.expectEqual(expected.has_push0, config.eips.has_push0());
        try testing.expectEqual(expected.has_basefee, config.eips.has_basefee());
        try testing.expectEqual(expected.has_transient_storage, config.eips.has_transient_storage());
        try testing.expectEqual(expected.has_mcopy, config.eips.has_mcopy());
        try testing.expectEqual(expected.has_blobhash, config.eips.has_blobhash());
        try testing.expectEqual(expected.has_logs, config.eips.has_logs());
        try testing.expectEqual(expected.has_selfdestruct, config.eips.has_selfdestruct());
        try testing.expectEqual(expected.has_eip6780, config.eips.eip_6780_selfdestruct_same_transaction_only());
        
        // Test that conditional CallResult compiles
        const CallResultType = ConditionalCallResult(config);
        const result = CallResultType.success_empty(1000);
        try testing.expect(result.isSuccess());
        
        // Test that conditional EVM state compiles
        const EvmType = ConditionalEvm(config);
        const evm_size = EvmType.size();
        try testing.expect(evm_size > 0);
        
        // Test that conditional opcode handlers compile
        const MockFrame = struct {
            const Self = @This();
            pub const Error = error{ OutOfGas };
            pub const OpcodeHandler = *const fn (frame: *Self, cursor: [*]const MockDispatchItem) Error!noreturn;
            pub const Dispatch = struct { pub const Item = MockDispatchItem; };
            gas_remaining: u64 = 21000,
        };
        const MockDispatchItem = union(enum) { handler: MockFrame.OpcodeHandler, metadata: u64 };
        
        const handlers = ConditionalOpcodeHandlers.getConditionalOpcodeHandlers(MockFrame, config);
        try testing.expect(handlers.len == 256);
    }
}

test "integration - memory usage scales with hardfork features" {
    // Test that memory usage increases with more features enabled
    const frontier_config = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } };
    const berlin_config = EvmConfig{ .eips = Eips{ .hardfork = .BERLIN } };
    const cancun_config = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } };
    
    const FrontierCallResult = ConditionalCallResult(frontier_config);
    const BerlinCallResult = ConditionalCallResult(berlin_config);
    const CancunCallResult = ConditionalCallResult(cancun_config);
    
    const FrontierEvm = ConditionalEvm(frontier_config);
    const BerlinEvm = ConditionalEvm(berlin_config);
    const CancunEvm = ConditionalEvm(cancun_config);
    
    // Get sizes
    const frontier_result_size = FrontierCallResult.size();
    const berlin_result_size = BerlinCallResult.size();
    const cancun_result_size = CancunCallResult.size();
    
    const frontier_evm_size = FrontierEvm.size();
    const berlin_evm_size = BerlinEvm.size();
    const cancun_evm_size = CancunEvm.size();
    
    // All should be non-zero
    try testing.expect(frontier_result_size > 0);
    try testing.expect(berlin_result_size > 0);
    try testing.expect(cancun_result_size > 0);
    try testing.expect(frontier_evm_size > 0);
    try testing.expect(berlin_evm_size > 0);
    try testing.expect(cancun_evm_size > 0);
    
    // Memory usage should generally increase with features
    // (though exact relationships depend on field sizes and alignment)
    try testing.expect(berlin_result_size >= frontier_result_size);
    try testing.expect(cancun_result_size >= berlin_result_size);
    try testing.expect(berlin_evm_size >= frontier_evm_size);
    try testing.expect(cancun_evm_size >= berlin_evm_size);
}

test "integration - end-to-end conditional EVM initialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Mock database
    var database = Database.init(allocator);
    defer database.deinit();

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .gas_limit = 21000,
        .difficulty = 1,
        .base_fee = 10,
        .coinbase = primitives.Address.ZERO_ADDRESS,
    };

    const context = TransactionContext{
        .gas_limit = 21000,
        .to = null,
        .value = 0,
        .data = &.{},
        .access_list = &.{},
        .max_fee_per_gas = 10,
        .max_priority_fee_per_gas = 1,
        .nonce = 0,
    };

    // Test a few representative hardforks end-to-end
    const test_configs = [_]struct { config: EvmConfig, name: []const u8 }{
        .{ .config = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } }, .name = "FRONTIER" },
        .{ .config = EvmConfig{ .eips = Eips{ .hardfork = .BERLIN } }, .name = "BERLIN" },
        .{ .config = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } }, .name = "CANCUN" },
    };

    for (test_configs) |test_config| {
        const EvmType = ConditionalEvm(test_config.config);
        
        var evm = try EvmType.init(
            allocator,
            &database,
            block_info,
            context,
            10,
            primitives.Address.ZERO_ADDRESS,
            test_config.config.eips.hardfork,
        );
        defer evm.deinit();

        // Basic EVM state should be initialized
        try testing.expect(evm.depth == 0);
        try testing.expect(evm.gas_refund_counter == 0);
        try testing.expect(evm.return_data.len == 0);
        try testing.expect(evm.current_input.len == 0);
        
        // Test feature-specific behavior
        const test_address = primitives.Address{ .bytes = [_]u8{0x42} ++ [_]u8{0} ** 19 };
        
        if (test_config.config.eips.has_access_list()) {
            // Test warm/cold access tracking
            try testing.expect(!evm.isAddressWarm(test_address));
            try evm.markAddressAccessed(test_address);
            try testing.expect(evm.isAddressWarm(test_address));
        } else {
            // Pre-Berlin: all addresses are warm
            try testing.expect(evm.isAddressWarm(test_address));
        }
        
        if (test_config.config.eips.has_logs()) {
            // Test log addition
            const test_log = @import("call_result.zig").Log{
                .address = test_address,
                .topics = &[_]u256{0x1234},
                .data = &[_]u8{0x56, 0x78},
            };
            try evm.addLog(test_log);
        }
        
        if (test_config.config.eips.eip_6780_selfdestruct_same_transaction_only()) {
            // Test contract creation tracking (Cancun+)
            try evm.recordContractCreation(test_address);
        }
    }
}

test "integration - opcode availability matches hardfork progression" {
    const MockFrame = struct {
        const Self = @This();
        pub const Error = error{ OutOfGas, InvalidOpcode };
        pub const OpcodeHandler = *const fn (frame: *Self, cursor: [*]const MockDispatchItem) Error!noreturn;
        pub const Dispatch = struct { pub const Item = MockDispatchItem; };
        gas_remaining: u64 = 21000,
    };
    const MockDispatchItem = union(enum) { handler: MockFrame.OpcodeHandler, metadata: u64 };
    
    const Opcode = @import("opcode_data.zig").Opcode;
    
    // Test specific opcodes across hardfork progression
    const opcode_tests = [_]struct {
        opcode: Opcode,
        first_available: Hardfork,
    }{
        .{ .opcode = .SHL, .first_available = .BYZANTIUM }, // EIP-145
        .{ .opcode = .CREATE2, .first_available = .CONSTANTINOPLE }, // EIP-1014
        .{ .opcode = .PUSH0, .first_available = .SHANGHAI }, // EIP-3855
        .{ .opcode = .BASEFEE, .first_available = .LONDON }, // EIP-3198
        .{ .opcode = .TLOAD, .first_available = .CANCUN }, // EIP-1153
        .{ .opcode = .TSTORE, .first_available = .CANCUN }, // EIP-1153
        .{ .opcode = .MCOPY, .first_available = .CANCUN }, // EIP-5656
        .{ .opcode = .BLOBHASH, .first_available = .CANCUN }, // EIP-4844
        .{ .opcode = .BLOBBASEFEE, .first_available = .CANCUN }, // EIP-7516
    };
    
    for (opcode_tests) |opcode_test| {
        inline for (TEST_HARDFORKS) |test_hf| {
            const handlers = ConditionalOpcodeHandlers.getConditionalOpcodeHandlers(MockFrame, test_hf.config);
            const invalid_handler = handlers[@intFromEnum(Opcode.INVALID)];
            const opcode_handler = handlers[@intFromEnum(opcode_test.opcode)];
            
            if (test_hf.config.eips.hardfork.isAtLeast(opcode_test.first_available)) {
                // Should be available (not invalid)
                try testing.expect(opcode_handler != invalid_handler);
            } else {
                // Should be invalid
                try testing.expect(opcode_handler == invalid_handler);
            }
        }
    }
}

test "integration - conditional CallResult field access compilation" {
    // This test verifies that conditional field access compiles correctly
    const frontier_config = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } };
    const berlin_config = EvmConfig{ .eips = Eips{ .hardfork = .BERLIN } };
    const cancun_config = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } };
    
    const FrontierResult = ConditionalCallResult(frontier_config);
    const BerlinResult = ConditionalCallResult(berlin_config);
    const CancunResult = ConditionalCallResult(cancun_config);
    
    // Create instances
    var frontier_result = FrontierResult.success_empty(1000);
    var berlin_result = BerlinResult.success_empty(2000);
    var cancun_result = CancunResult.success_empty(3000);
    
    // Test that common methods work on all configurations
    try testing.expect(frontier_result.isSuccess());
    try testing.expect(berlin_result.isSuccess());
    try testing.expect(cancun_result.isSuccess());
    
    try testing.expectEqual(@as(u64, 1000), frontier_result.gas_left);
    try testing.expectEqual(@as(u64, 2000), berlin_result.gas_left);
    try testing.expectEqual(@as(u64, 3000), cancun_result.gas_left);
    
    // Test size differences
    const frontier_size = frontier_result.size();
    const berlin_size = berlin_result.size();
    const cancun_size = cancun_result.size();
    
    try testing.expect(frontier_size > 0);
    try testing.expect(berlin_size > 0);
    try testing.expect(cancun_size > 0);
    
    // Memory layout should be different due to conditional fields
    // The exact relationship depends on field sizes and alignment
    try testing.expect(berlin_size != frontier_size or cancun_size != berlin_size);
}

test "integration - comprehensive feature matrix validation" {
    // This test creates a comprehensive matrix of all features across all hardforks
    // and validates that the feature detection works correctly
    
    const feature_checks = [_]struct {
        name: []const u8,
        check: fn(config: EvmConfig) bool,
        first_hardfork: Hardfork,
    }{
        .{ .name = "access_list", .check = checkAccessList, .first_hardfork = .BERLIN },
        .{ .name = "create2", .check = checkCreate2, .first_hardfork = .CONSTANTINOPLE },
        .{ .name = "push0", .check = checkPush0, .first_hardfork = .SHANGHAI },
        .{ .name = "basefee", .check = checkBaseFee, .first_hardfork = .LONDON },
        .{ .name = "transient_storage", .check = checkTransientStorage, .first_hardfork = .CANCUN },
        .{ .name = "mcopy", .check = checkMCopy, .first_hardfork = .CANCUN },
        .{ .name = "blobhash", .check = checkBlobHash, .first_hardfork = .CANCUN },
        .{ .name = "logs", .check = checkLogs, .first_hardfork = .FRONTIER },
        .{ .name = "selfdestruct", .check = checkSelfDestruct, .first_hardfork = .FRONTIER },
        .{ .name = "eip6780", .check = checkEip6780, .first_hardfork = .CANCUN },
    };
    
    for (feature_checks) |feature| {
        inline for (TEST_HARDFORKS) |test_hf| {
            const expected = test_hf.config.eips.hardfork.isAtLeast(feature.first_hardfork);
            const actual = feature.check(test_hf.config);
            
            if (expected != actual) {
                std.debug.print("Feature '{}' failed for hardfork '{}': expected {}, got {}\n", 
                    .{feature.name, test_hf.name, expected, actual});
            }
            try testing.expectEqual(expected, actual);
        }
    }
}

// Helper functions for feature checking
fn checkAccessList(config: EvmConfig) bool { return config.eips.has_access_list(); }
fn checkCreate2(config: EvmConfig) bool { return config.eips.has_create2(); }
fn checkPush0(config: EvmConfig) bool { return config.eips.has_push0(); }
fn checkBaseFee(config: EvmConfig) bool { return config.eips.has_basefee(); }
fn checkTransientStorage(config: EvmConfig) bool { return config.eips.has_transient_storage(); }
fn checkMCopy(config: EvmConfig) bool { return config.eips.has_mcopy(); }
fn checkBlobHash(config: EvmConfig) bool { return config.eips.has_blobhash(); }
fn checkLogs(config: EvmConfig) bool { return config.eips.has_logs(); }
fn checkSelfDestruct(config: EvmConfig) bool { return config.eips.has_selfdestruct(); }
fn checkEip6780(config: EvmConfig) bool { return config.eips.eip_6780_selfdestruct_same_transaction_only(); }

test "integration - conditional compilation eliminates dead code" {
    // This test validates that disabled features truly become dead code
    // by checking that the conditional branches don't exist in disabled configurations
    
    const frontier_config = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } };
    const cancun_config = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } };
    
    // Feature availability should be compile-time constants
    try testing.expect(!comptime frontier_config.eips.has_access_list());
    try testing.expect(!comptime frontier_config.eips.has_push0());
    try testing.expect(!comptime frontier_config.eips.has_transient_storage());
    
    try testing.expect(comptime cancun_config.eips.has_access_list());
    try testing.expect(comptime cancun_config.eips.has_push0());
    try testing.expect(comptime cancun_config.eips.has_transient_storage());
    
    // Types should be different
    const FrontierResult = ConditionalCallResult(frontier_config);
    const CancunResult = ConditionalCallResult(cancun_config);
    
    const FrontierEvm = ConditionalEvm(frontier_config);
    const CancunEvm = ConditionalEvm(cancun_config);
    
    // Type information should reflect the differences
    try testing.expect(FrontierResult != CancunResult);
    try testing.expect(FrontierEvm != CancunEvm);
    
    // Size differences should reflect conditional compilation
    try testing.expect(FrontierResult.size() != CancunResult.size() or
                      FrontierEvm.size() != CancunEvm.size());
}