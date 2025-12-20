const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("voltaire");
const log = evm.log;

const Evm = evm.Evm;
const Database = evm.Database;
const CallParams = evm.CallParams;
const Address = primitives.Address.Address;
const BlockInfo = evm.BlockInfo;
const TransactionContext = evm.TransactionContext;
const Bytecode = evm.Bytecode;
const Frame = evm.Frame;
const Dispatch = evm.FrameDispatch;
const Opcode = evm.Opcode;

test "Jump table should contain JUMPDEST at 0x0f in ERC20 bytecode" {
    const allocator = testing.allocator;

    // First 17 bytes of ERC20 bytecode - exactly to position 0x10
    const bytecode_data = [_]u8{
        0x60, 0x80, // PUSH1 0x80 (PC 0-1)
        0x60, 0x40, // PUSH1 0x40 (PC 2-3)
        0x52, // MSTORE     (PC 4)
        0x34, // CALLVALUE  (PC 5)
        0x80, // DUP1       (PC 6)
        0x15, // ISZERO     (PC 7)
        0x61, 0x00, 0x0f, // PUSH2 0x000f (PC 8-10)
        0x57, // JUMPI      (PC 11)
        0x5f, // PUSH0      (PC 12)
        0x5f, // PUSH0      (PC 13)
        0xfd, // REVERT     (PC 14)
        0x5b, // JUMPDEST   (PC 15 = 0x0f)
        0x50, // POP        (PC 16 = 0x10)
    };

    log.info("Testing jump table with ERC20 bytecode snippet", .{});

    // Create bytecode
    var bytecode = try Bytecode(.{ .max_bytecode_size = 1024 }).init(allocator, &bytecode_data);
    defer bytecode.deinit();

    // Verify bytecode at position 0x0f
    try testing.expectEqual(@as(u8, 0x5b), bytecode.runtime_code[0x0f]);
    log.info("Confirmed: Bytecode at position 0x0f is 0x{x:0>2} (JUMPDEST)", .{bytecode.runtime_code[0x0f]});

    // Create frame config
    const frame_config = evm.FrameConfig{
        .stack_size = 1024,
        .WordType = u256,
        .max_bytecode_size = 24576, // Standard max contract size
        .block_gas_limit = 30_000_000,
        .DatabaseType = Database,
        .memory_initial_capacity = 4096,
        .memory_limit = 0xFFFFFF,
    };

    const TestFrame = Frame(frame_config);
    const TestDispatch = TestFrame.Dispatch;

    // Get opcode handlers
    const opcode_handlers = &TestFrame.opcode_handlers;

    // Create dispatch schedule (need to add tracer parameter)
    var tracer = @import("evm").Tracer.init(allocator, .{});
    defer tracer.deinit();
    var schedule = try TestDispatch.DispatchSchedule.init(allocator, &bytecode, opcode_handlers, @as(?*@import("evm").Tracer, &tracer));
    defer schedule.deinit();

    log.info("Created dispatch schedule with {} items", .{schedule.items.len});

    // Pretty print the dispatch to see what's happening
    const pretty = try TestDispatch.pretty_print(allocator, schedule.items, &bytecode);
    defer allocator.free(pretty);
    log.info("\nDispatch Schedule:\n{s}", .{pretty});

    // Create jump table
    const jump_table = try TestDispatch.createJumpTable(allocator, schedule.items, &bytecode);
    defer allocator.free(jump_table.entries);

    log.info("Created jump table with {} entries", .{jump_table.entries.len});

    // Test if PC 0x0f is in the jump table
    const target = jump_table.findJumpTarget(0x0f);

    if (target) |_| {
        log.info("✓ SUCCESS: Jump table correctly contains PC 0x0f", .{});
    } else {
        log.warn("✗ FAILURE: Jump table does NOT contain PC 0x0f", .{});
        log.warn("  This is the bug - JUMPDEST at 0x0f is not recognized!", .{});
    }

    // This should pass but currently fails due to the bug
    try testing.expect(target != null);
}
