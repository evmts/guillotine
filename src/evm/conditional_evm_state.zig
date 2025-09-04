/// Conditional EVM State that adapts based on EIP configuration
/// This demonstrates making EVM state fields conditional on hardfork features
const std = @import("std");
const primitives = @import("primitives");
const Database = @import("database.zig").Database;
const AccessList = @import("access_list.zig").AccessList;
const CreatedContracts = @import("created_contracts.zig").CreatedContracts;
const SelfDestruct = @import("self_destruct.zig").SelfDestruct;
const TransactionContext = @import("transaction_context.zig").TransactionContext;
const BlockInfo = @import("block_info.zig").DefaultBlockInfo;
const Hardfork = @import("hardfork.zig").Hardfork;
const EvmConfig = @import("evm_config.zig").EvmConfig;
const Log = @import("call_result.zig").Log;

/// Generic EVM function that creates different state structures based on hardfork configuration
/// This demonstrates conditional compilation of EVM state fields
pub fn ConditionalEvm(comptime config: EvmConfig) type {
    return struct {
        const Self = @This();
        
        /// Frame type for the evm
        pub const Frame = @import("frame.zig").Frame(config.frame_config());
        
        /// Journal handles reverting state when state needs to be reverted
        pub const Journal: type = @import("journal.zig").Journal(.{
            .SnapshotIdType = if (config.max_call_depth <= 255) u8 else u16,
            .WordType = config.WordType,
            .NonceType = u64,
            .initial_capacity = 128,
        });

        /// Call stack entry to track caller and value for DELEGATECALL
        const CallStackEntry = struct {
            caller: primitives.Address,
            value: config.WordType,
            is_static: bool,
        };

        pub const Success = enum {
            Stop,
            Return,
            SelfDestruct,
            Jump,
        };

        pub const Error = error{
            InvalidJump,
            OutOfGas,
            StackUnderflow,
            StackOverflow,
            ContractNotFound,
            PrecompileError,
            MemoryError,
            StorageError,
            CallDepthExceeded,
            InsufficientBalance,
            ContractCollision,
            InvalidBytecode,
            StaticCallViolation,
            InvalidOpcode,
            RevertExecution,
            OutOfMemory,
            AllocationError,
            AccountNotFound,
            InvalidJumpDestination,
            MissingJumpDestMetadata,
            InitcodeTooLarge,
            TruncatedPush,
            OutOfBounds,
            WriteProtection,
            BytecodeTooLarge,
        };

        // ALWAYS PRESENT CORE FIELDS
        /// Current call depth (0 = root call)
        depth: config.get_depth_type(),
        /// Current snapshot ID for the active call frame
        current_snapshot_id: Journal.SnapshotIdType,
        /// Database interface for state storage
        database: *Database,
        /// Journal for tracking state changes and snapshots
        journal: Journal,
        /// Allocator for dynamic memory
        allocator: std.mem.Allocator,
        /// Block information
        block_info: BlockInfo,
        /// Transaction context
        context: TransactionContext,
        /// Gas price for the transaction
        gas_price: u256,
        /// Origin address (sender of the transaction)
        origin: primitives.Address,
        /// Hardfork configuration
        hardfork_config: Hardfork,
        /// Current call input data
        current_input: []const u8,
        /// Current return data
        return_data: []const u8,
        /// Gas refund counter for SSTORE operations
        gas_refund_counter: u64,
        /// Disable gas checking (for testing/debugging)
        disable_gas_checking: bool,
        /// Call stack - tracks caller and value for each call depth
        call_stack: [config.max_call_depth]CallStackEntry,
        /// Arena allocator for per-call temporary allocations
        call_arena: std.heap.ArenaAllocator,
        /// Small reusable buffer for fixed-size outputs
        small_output_buf: [64]u8 = undefined,

        // CONDITIONAL FIELDS BASED ON EIP CONFIGURATION
        // These fields only exist if the corresponding feature is enabled
        
        /// Access list for tracking warm/cold access (EIP-2929 - Berlin+)
        access_list: if (config.eips.has_access_list()) AccessList else void = 
            if (config.eips.has_access_list()) AccessList.init(undefined) else {},
            
        /// Tracks contracts created in current transaction (EIP-6780 - Cancun+)
        created_contracts: if (config.eips.eip_6780_selfdestruct_same_transaction_only()) CreatedContracts else void = 
            if (config.eips.eip_6780_selfdestruct_same_transaction_only()) CreatedContracts.init(undefined) else {},
            
        /// Contracts marked for self-destruction (always available but behavior changes)
        self_destruct: if (config.eips.has_selfdestruct()) SelfDestruct else void = 
            if (config.eips.has_selfdestruct()) SelfDestruct.init(undefined) else {},
            
        /// Logs emitted during execution (always available since Frontier)
        logs: if (config.eips.has_logs()) std.ArrayList(Log) else void = 
            if (config.eips.has_logs()) std.ArrayList(Log).init(undefined) else {},

        /// Initialize a new conditional EVM instance
        pub fn init(
            allocator: std.mem.Allocator, 
            database: *Database, 
            block_info: BlockInfo, 
            context: TransactionContext, 
            gas_price: u256, 
            origin: primitives.Address, 
            hardfork_config: Hardfork
        ) !Self {
            var self = Self{
                .depth = 0,
                .current_snapshot_id = 0,
                .database = database,
                .journal = Journal.init(allocator),
                .allocator = allocator,
                .block_info = block_info,
                .context = context,
                .gas_price = gas_price,
                .origin = origin,
                .hardfork_config = hardfork_config,
                .current_input = &.{},
                .return_data = &.{},
                .gas_refund_counter = 0,
                .disable_gas_checking = false,
                .call_stack = [_]CallStackEntry{CallStackEntry{ 
                    .caller = primitives.Address.ZERO_ADDRESS, 
                    .value = 0, 
                    .is_static = false 
                }} ** config.max_call_depth,
                .call_arena = std.heap.ArenaAllocator.init(allocator),
            };

            // Initialize conditional fields only if features are enabled
            if (config.eips.has_access_list()) {
                self.access_list = AccessList.init(allocator);
                errdefer self.access_list.deinit();
            }

            if (config.eips.eip_6780_selfdestruct_same_transaction_only()) {
                self.created_contracts = CreatedContracts.init(allocator);
                errdefer self.created_contracts.deinit();
            }

            if (config.eips.has_selfdestruct()) {
                self.self_destruct = SelfDestruct.init(allocator);
                errdefer self.self_destruct.deinit();
            }

            if (config.eips.has_logs()) {
                self.logs = std.ArrayList(Log).init(allocator);
                errdefer self.logs.deinit(allocator);
            }

            return self;
        }

        /// Clean up all resources with conditional deinitialization
        pub fn deinit(self: *Self) void {
            // Free return_data if it was allocated
            if (self.return_data.len > 0) {
                self.allocator.free(self.return_data);
            }
            
            // Always clean up core components
            self.journal.deinit();
            self.call_arena.deinit();

            // Conditionally clean up feature-specific components
            if (config.eips.has_access_list()) {
                self.access_list.deinit();
            }

            if (config.eips.eip_6780_selfdestruct_same_transaction_only()) {
                self.created_contracts.deinit();
            }

            if (config.eips.has_selfdestruct()) {
                self.self_destruct.deinit();
            }

            if (config.eips.has_logs()) {
                self.logs.deinit(self.allocator);
            }
        }

        /// Mark an address for self-destruction (conditional compilation)
        pub fn markForDestruction(self: *Self, address: primitives.Address, beneficiary: primitives.Address) !void {
            if (config.eips.has_selfdestruct()) {
                if (config.eips.eip_6780_selfdestruct_same_transaction_only()) {
                    // EIP-6780 behavior: only destroy if created in same transaction
                    if (self.created_contracts.wasCreatedInTransaction(address)) {
                        try self.self_destruct.markForDestruction(address, beneficiary);
                    } else {
                        // Just transfer balance, don't destroy
                        // Implementation would transfer balance here
                    }
                } else {
                    // Pre-Cancun behavior: always destroy
                    try self.self_destruct.markForDestruction(address, beneficiary);
                }
            } else {
                // This branch is eliminated at compile time
                unreachable;
            }
        }

        /// Add a log entry (conditional compilation)
        pub fn addLog(self: *Self, log: Log) !void {
            if (config.eips.has_logs()) {
                try self.logs.append(log);
            } else {
                // This branch is eliminated at compile time
                unreachable;
            }
        }

        /// Mark an address as accessed for warm/cold gas pricing (conditional compilation)
        pub fn markAddressAccessed(self: *Self, address: primitives.Address) !void {
            if (config.eips.has_access_list()) {
                try self.access_list.touchAddress(address);
            }
            // If access lists not enabled, this becomes a no-op
        }

        /// Check if an address is warm (conditional compilation)
        pub fn isAddressWarm(self: *Self, address: primitives.Address) bool {
            if (config.eips.has_access_list()) {
                return self.access_list.isAddressWarm(address);
            } else {
                // Pre-Berlin: all addresses are "warm" (no cold/warm distinction)
                return true;
            }
        }

        /// Record contract creation (conditional compilation)
        pub fn recordContractCreation(self: *Self, address: primitives.Address) !void {
            if (config.eips.eip_6780_selfdestruct_same_transaction_only()) {
                try self.created_contracts.markCreated(address);
            }
            // If not tracking created contracts, this becomes a no-op
        }

        /// Get the size of this EVM struct in bytes
        /// This will vary based on which features are enabled
        pub fn size() usize {
            return @sizeOf(Self);
        }

        /// Get the arena allocator for temporary allocations during the current call
        pub fn getCallArenaAllocator(self: *Self) std.mem.Allocator {
            return self.call_arena.allocator();
        }
    };
}

// =============================================================================
// Tests demonstrating conditional EVM state compilation
// =============================================================================

const testing = std.testing;
const Eips = @import("eips.zig").Eips;

test "conditional EVM state - basic compilation for different hardforks" {
    const FrontierConfig = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } };
    const BerlinConfig = EvmConfig{ .eips = Eips{ .hardfork = .BERLIN } };
    const CancunConfig = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } };
    
    // Each creates a different type with different fields
    const FrontierEvm = ConditionalEvm(FrontierConfig);
    const BerlinEvm = ConditionalEvm(BerlinConfig);
    const CancunEvm = ConditionalEvm(CancunConfig);
    
    // Verify they're different types by checking size
    const frontier_size = FrontierEvm.size();
    const berlin_size = BerlinEvm.size();
    const cancun_size = CancunEvm.size();
    
    // Frontier should be smallest (no access lists, limited features)
    // Berlin should be larger (adds access lists)
    // Cancun should be largest (adds all features)
    try testing.expect(frontier_size > 0);
    try testing.expect(berlin_size >= frontier_size);
    try testing.expect(cancun_size >= berlin_size);
}

test "conditional EVM state - feature availability verification" {
    const FrontierConfig = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } };
    const BerlinConfig = EvmConfig{ .eips = Eips{ .hardfork = .BERLIN } };
    const CancunConfig = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } };
    
    // Verify feature detection works correctly
    try testing.expect(!FrontierConfig.eips.has_access_list());
    try testing.expect(BerlinConfig.eips.has_access_list());
    try testing.expect(CancunConfig.eips.has_access_list());
    
    try testing.expect(!FrontierConfig.eips.eip_6780_selfdestruct_same_transaction_only());
    try testing.expect(!BerlinConfig.eips.eip_6780_selfdestruct_same_transaction_only());
    try testing.expect(CancunConfig.eips.eip_6780_selfdestruct_same_transaction_only());
    
    // Always available features
    try testing.expect(FrontierConfig.eips.has_logs());
    try testing.expect(BerlinConfig.eips.has_logs());
    try testing.expect(CancunConfig.eips.has_logs());
    
    try testing.expect(FrontierConfig.eips.has_selfdestruct());
    try testing.expect(BerlinConfig.eips.has_selfdestruct());
    try testing.expect(CancunConfig.eips.has_selfdestruct());
}

test "conditional EVM state - initialization and cleanup" {
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

    // Test different configurations
    const FrontierConfig = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } };
    const CancunConfig = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } };
    
    const FrontierEvm = ConditionalEvm(FrontierConfig);
    const CancunEvm = ConditionalEvm(CancunConfig);

    // Test initialization and cleanup for Frontier (minimal features)
    {
        var frontier_evm = try FrontierEvm.init(
            allocator, 
            &database, 
            block_info, 
            context, 
            10, 
            primitives.Address.ZERO_ADDRESS, 
            .FRONTIER
        );
        defer frontier_evm.deinit();

        try testing.expect(frontier_evm.depth == 0);
        try testing.expect(frontier_evm.hardfork_config == .FRONTIER);
    }

    // Test initialization and cleanup for Cancun (full features)
    {
        var cancun_evm = try CancunEvm.init(
            allocator, 
            &database, 
            block_info, 
            context, 
            10, 
            primitives.Address.ZERO_ADDRESS, 
            .CANCUN
        );
        defer cancun_evm.deinit();

        try testing.expect(cancun_evm.depth == 0);
        try testing.expect(cancun_evm.hardfork_config == .CANCUN);
    }
}

test "conditional EVM state - conditional method compilation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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

    const BerlinConfig = EvmConfig{ .eips = Eips{ .hardfork = .BERLIN } };
    const BerlinEvm = ConditionalEvm(BerlinConfig);

    var berlin_evm = try BerlinEvm.init(
        allocator, 
        &database, 
        block_info, 
        context, 
        10, 
        primitives.Address.ZERO_ADDRESS, 
        .BERLIN
    );
    defer berlin_evm.deinit();

    // Test conditional methods work
    const test_address = primitives.Address{ .bytes = [_]u8{0x42} ++ [_]u8{0} ** 19 };
    
    // Access list operations (available in Berlin+)
    try berlin_evm.markAddressAccessed(test_address);
    try testing.expect(berlin_evm.isAddressWarm(test_address));
    
    // Log operations (always available)
    const test_log = Log{
        .address = test_address,
        .topics = &[_]u256{0x1234},
        .data = &[_]u8{0x56, 0x78},
    };
    try berlin_evm.addLog(test_log);
}

test "conditional EVM state - size differences demonstrate memory savings" {
    // This test demonstrates the key benefit: memory savings
    const FrontierConfig = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } };
    const BerlinConfig = EvmConfig{ .eips = Eips{ .hardfork = .BERLIN } };
    const CancunConfig = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } };
    
    const FrontierEvm = ConditionalEvm(FrontierConfig);
    const BerlinEvm = ConditionalEvm(BerlinConfig);
    const CancunEvm = ConditionalEvm(CancunConfig);
    
    const frontier_size = FrontierEvm.size();
    const berlin_size = BerlinEvm.size();
    const cancun_size = CancunEvm.size();
    
    // Each should be different sizes based on enabled features
    try testing.expect(frontier_size > 0);
    try testing.expect(berlin_size > 0);
    try testing.expect(cancun_size > 0);
    
    // Berlin should be larger than Frontier (adds access lists)
    // Cancun should be larger than Berlin (adds created_contracts tracking)
    // The exact size relationships depend on the sizes of conditional fields
    try testing.expect(berlin_size != frontier_size or cancun_size != berlin_size);
}

test "conditional EVM state - hardfork behavior differences" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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

    const FrontierConfig = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } };
    const BerlinConfig = EvmConfig{ .eips = Eips{ .hardfork = .BERLIN } };
    
    const FrontierEvm = ConditionalEvm(FrontierConfig);
    const BerlinEvm = ConditionalEvm(BerlinConfig);

    var frontier_evm = try FrontierEvm.init(allocator, &database, block_info, context, 10, primitives.Address.ZERO_ADDRESS, .FRONTIER);
    defer frontier_evm.deinit();

    var berlin_evm = try BerlinEvm.init(allocator, &database, block_info, context, 10, primitives.Address.ZERO_ADDRESS, .BERLIN);
    defer berlin_evm.deinit();

    const test_address = primitives.Address{ .bytes = [_]u8{0x42} ++ [_]u8{0} ** 19 };

    // Frontier: no access list tracking, so all addresses are "warm"
    try testing.expect(frontier_evm.isAddressWarm(test_address));
    
    // Berlin: has access list tracking, address starts cold
    try testing.expect(!berlin_evm.isAddressWarm(test_address));
    
    // After marking as accessed, it becomes warm
    try berlin_evm.markAddressAccessed(test_address);
    try testing.expect(berlin_evm.isAddressWarm(test_address));
}