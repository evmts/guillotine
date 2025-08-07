const std = @import("std");
const Evm = @import("evm.zig");
const JumpTable = @import("jump_table/jump_table.zig");
const Frame = @import("frame.zig");
const ExecutionContext = @import("frame.zig").ExecutionContext;
const ChainRules = Frame.ChainRules;
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
        self.chain_rules = Frame.chainRulesForHardfork(hardfork);
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

test "Evm basic initialization" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    var evm = try Evm.init(
        allocator,
        db_interface,
        null,
        null,
        null,
        0,
        false,
        null,
    );
    defer evm.deinit();

    try testing.expectEqual(@as(u11, 0), evm.depth);
    try testing.expectEqual(false, evm.read_only);
}

test "Evm with all options" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    const table = JumpTable.init_from_hardfork(.LONDON);
    const chain_rules = Frame.chainRulesForHardfork(.LONDON);

    var evm = try Evm.init(
        allocator,
        db_interface,
        table,
        chain_rules,
        null,
        10,
        true,
        null,
    );
    defer evm.deinit();

    try testing.expectEqual(@as(u11, 10), evm.depth);
    try testing.expectEqual(true, evm.read_only);
}

test "Evm with hardfork configuration" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    const table = JumpTable.init_from_hardfork(.BERLIN);
    const chain_rules = Frame.chainRulesForHardfork(.BERLIN);

    var evm = try Evm.init(
        allocator,
        db_interface,
        table,
        chain_rules,
        null,
        5,
        true,
        null,
    );
    defer evm.deinit();

    try testing.expectEqual(@as(u11, 5), evm.depth);
    try testing.expectEqual(true, evm.read_only);
}

test "Evm custom jump table and chain rules" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const custom_table = JumpTable.init_from_hardfork(.ISTANBUL);
    const custom_rules = Frame.chainRulesForHardfork(.ISTANBUL);

    var evm = try Evm.init(
        allocator,
        db_interface,
        custom_table,
        custom_rules,
        null,
        0,
        false,
        null,
    );
    defer evm.deinit();

    // Test that the chain rules were set correctly
    try testing.expect(evm.chain_rules.is_istanbul);
    try testing.expect(evm.chain_rules.is_berlin);
    try testing.expect(evm.chain_rules.is_london);
}

test "Evm context configuration" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    var custom_context = Context.init();
    custom_context.block.number = 12345;
    custom_context.block.timestamp = 1234567890;

    var evm = try Evm.init(
        allocator,
        db_interface,
        null,
        null,
        custom_context,
        0,
        false,
        null,
    );
    defer evm.deinit();

    try testing.expectEqual(@as(u256, 12345), evm.context.block.number);
    try testing.expectEqual(@as(u64, 1234567890), evm.context.block.timestamp);
}

test "Evm multiple hardfork configurations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    const hardforks = [_]Hardfork{ .FRONTIER, .HOMESTEAD, .BYZANTIUM, .LONDON };

    for (hardforks) |hardfork| {
        const table = JumpTable.init_from_hardfork(hardfork);
        const chain_rules = Frame.chainRulesForHardfork(hardfork);

        var evm = try Evm.init(
            allocator,
            db_interface,
            table,
            chain_rules,
            null,
            10,
            false,
            null,
        );
        defer evm.deinit();

        try testing.expectEqual(@as(u11, 10), evm.depth);
        // Test that the chain rules correspond to the hardfork by checking specific features
        switch (hardfork) {
            .FRONTIER => {
                try testing.expect(!evm.chain_rules.is_homestead);
            },
            .HOMESTEAD => {
                try testing.expect(evm.chain_rules.is_homestead);
                try testing.expect(!evm.chain_rules.is_byzantium);
            },
            .BYZANTIUM => {
                try testing.expect(evm.chain_rules.is_byzantium);
                try testing.expect(!evm.chain_rules.is_london);
            },
            .LONDON => {
                try testing.expect(evm.chain_rules.is_london);
            },
            else => {},
        }
    }
}
