const std = @import("std");
const Evm = @import("evm.zig");
const JumpTable = @import("jump_table/jump_table.zig");
const ChainRules = @import("hardforks/chain_rules.zig");
const Hardfork = @import("hardforks/hardfork.zig").Hardfork;
const Context = @import("access_list/context.zig");
const DatabaseInterface = @import("state/database_interface.zig").DatabaseInterface;
const Tracer = @import("tracer.zig").Tracer;

/// Builder pattern for constructing EVM instances with fluent API.
///
/// Example usage:
/// ```zig
/// var builder = EvmBuilder.init(allocator, database);
/// const evm = try builder
///     .with_hardfork(.LONDON)
///     .with_depth(5)
///     .with_read_only(true)
///     .with_context(custom_context)
///     .build();
/// defer evm.deinit();
/// ```
pub const EvmBuilder = struct {
    allocator: std.mem.Allocator,
    database: DatabaseInterface,
    table: ?JumpTable = null,
    chain_rules: ?ChainRules = null,
    context: ?Context = null,
    depth: u16 = 0,
    read_only: bool = false,
    tracer: ?std.io.AnyWriter = null,

    /// Initialize a new EVM builder.
    pub fn init(allocator: std.mem.Allocator, database: DatabaseInterface) EvmBuilder {
        return .{
            .allocator = allocator,
            .database = database,
        };
    }

    /// Set a custom jump table.
    pub fn with_jump_table(self: *EvmBuilder, table: JumpTable) *EvmBuilder {
        self.table = table;
        return self;
    }

    /// Set custom chain rules.
    pub fn with_chain_rules(self: *EvmBuilder, rules: ChainRules) *EvmBuilder {
        self.chain_rules = rules;
        return self;
    }

    /// Configure for a specific hardfork (sets both jump table and chain rules).
    pub fn with_hardfork(self: *EvmBuilder, hardfork: Hardfork) *EvmBuilder {
        self.table = JumpTable.init_from_hardfork(hardfork);
        self.chain_rules = ChainRules.for_hardfork(hardfork);
        return self;
    }

    /// Set the execution context.
    pub fn with_context(self: *EvmBuilder, context: Context) *EvmBuilder {
        self.context = context;
        return self;
    }

    /// Set the initial call depth.
    pub fn with_depth(self: *EvmBuilder, depth: u16) *EvmBuilder {
        self.depth = depth;
        return self;
    }

    /// Set read-only mode (for STATICCALL contexts).
    pub fn with_read_only(self: *EvmBuilder, read_only: bool) *EvmBuilder {
        self.read_only = read_only;
        return self;
    }
    
    /// Set a tracer for capturing execution traces.
    pub fn withTracer(self: *EvmBuilder, writer: std.io.AnyWriter) *EvmBuilder {
        self.tracer = writer;
        return self;
    }

    /// Build the EVM instance with all configured options.
    pub fn build(self: *const EvmBuilder) !Evm {
        return try Evm.init(
            self.allocator,
            self.database,
            self.table,
            self.chain_rules,
            self.context,
            self.depth,
            self.read_only,
            self.tracer,
        );
    }
};

const testing = std.testing;
const MemoryDatabase = @import("state/memory_database.zig");

test "EvmBuilder basic usage" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    var builder = EvmBuilder.init(allocator, db_interface);
    var evm = try builder.build();
    defer evm.deinit();

    try testing.expectEqual(@as(u16, 0), evm.depth);
    try testing.expectEqual(false, evm.read_only);
}

test "EvmBuilder with all options" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    var builder = EvmBuilder.init(allocator, db_interface);
    var evm = try builder
        .with_hardfork(.LONDON)
        .with_depth(10)
        .with_read_only(true)
        .build();
    defer evm.deinit();

    try testing.expectEqual(@as(u16, 10), evm.depth);
    try testing.expectEqual(true, evm.read_only);
}

test "EvmBuilder fluent API" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    var builder = EvmBuilder.init(allocator, db_interface);
    var evm = try builder
        .with_depth(5)
        .with_read_only(true)
        .with_hardfork(.BERLIN)
        .build();
    defer evm.deinit();

    try testing.expectEqual(@as(u16, 5), evm.depth);
    try testing.expectEqual(true, evm.read_only);
}

test "EvmBuilder custom jump table and chain rules" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const custom_table = JumpTable.init_from_hardfork(.ISTANBUL);
    const custom_rules = ChainRules.for_hardfork(.ISTANBUL);

    var builder = EvmBuilder.init(allocator, db_interface);
    var evm = try builder
        .with_jump_table(custom_table)
        .with_chain_rules(custom_rules)
        .build();
    defer evm.deinit();

    try testing.expect(evm.chain_rules.hardfork() == .ISTANBUL);
}

test "EvmBuilder context configuration" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    var custom_context = Context.init();
    custom_context.block.number = 12345;
    custom_context.block.timestamp = 1234567890;

    var builder = EvmBuilder.init(allocator, db_interface);
    var evm = try builder
        .with_context(custom_context)
        .build();
    defer evm.deinit();

    try testing.expectEqual(@as(u256, 12345), evm.context.block.number);
    try testing.expectEqual(@as(u64, 1234567890), evm.context.block.timestamp);
}

test "EvmBuilder multiple configurations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    const hardforks = [_]Hardfork{ .FRONTIER, .HOMESTEAD, .BYZANTIUM, .LONDON };

    for (hardforks) |hardfork| {
        var builder = EvmBuilder.init(allocator, db_interface);
        var evm = try builder
            .with_hardfork(hardfork)
            .with_depth(10)
            .build();
        defer evm.deinit();

        try testing.expectEqual(@as(u16, 10), evm.depth);
        try testing.expect(evm.chain_rules.hardfork() == hardfork);
    }
}
