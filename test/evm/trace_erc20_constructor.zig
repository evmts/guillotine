const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");

const Address = primitives.Address;
const Evm = evm.Evm;
const MemoryDatabase = evm.MemoryDatabase;

test "trace ERC20 constructor execution" {
    const allocator = testing.allocator;

    // ERC20 constructor bytecode from the benchmark
    const bytecode_hex = @embedFile("erc20_constructor_bytecode.bin");

    // Convert hex string to bytes
    var bytecode_buf: [10000]u8 = undefined;
    const bytecode = try std.fmt.hexToBytes(&bytecode_buf, bytecode_hex);

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    // Run with trace enabled
    var trace_buffer = std.ArrayList(u8).init(allocator);
    defer trace_buffer.deinit();

    const config = evm.EvmConfig.init(.CANCUN);
    const EvmType = evm.Evm(config);
    var vm = try EvmType.init(allocator, db_interface, null, 0, false, trace_buffer.writer().any());
    defer vm.deinit();

    const caller = Address.from_u256(0x1000000000000000000000000000000000000001);
    try vm.state.set_balance(caller, std.math.maxInt(u256));

    // Create contract (deploy)
    const result = try vm.create_contract(caller, 0, bytecode, 1_000_000_000);
    defer if (result.output) |output| allocator.free(output);

    std.debug.print("\nERC20 Constructor result: success={}, gas_left={}\n", .{
        result.success,
        result.gas_left,
    });

    // Write trace to file for analysis
    const trace_file = try std.fs.cwd().createFile("zig_erc20_constructor_trace.json", .{});
    defer trace_file.close();
    try trace_file.writeAll(trace_buffer.items);

    std.debug.print("Trace written to: zig_erc20_constructor_trace.json\n", .{});

    // Parse and analyze key points
    var lines = std.mem.tokenizeScalar(u8, trace_buffer.items, '\n');
    var line_num: usize = 0;
    var last_pc: usize = 0;
    var found_gt = false;
    var gt_line_num: usize = 0;

    while (lines.next()) |line| {
        line_num += 1;

        const parsed = try std.json.parseFromSlice(TraceEntry, allocator, line, .{});
        defer parsed.deinit();

        const entry = parsed.value;
        last_pc = entry.pc;

        // Look for GT opcode (0x11)
        if (entry.op == 0x11 and !found_gt) {
            found_gt = true;
            gt_line_num = line_num;
            std.debug.print("\nFound first GT at line {} (pc={}):\n", .{ line_num, entry.pc });
            std.debug.print("  Stack before GT: {s}\n", .{line});

            // Print next few lines to see what happens
            var context_lines: usize = 0;
            while (lines.next()) |next_line| {
                line_num += 1;
                context_lines += 1;
                std.debug.print("  Line {}: {s}\n", .{ line_num, next_line });
                if (context_lines >= 10) break;
            }
            break;
        }
    }

    if (!found_gt) {
        std.debug.print("\nNo GT opcode found in trace!\n", .{});
    }

    std.debug.print("\nTotal lines in trace: {}\n", .{line_num});
    std.debug.print("Last PC: {}\n", .{last_pc});
}

const TraceEntry = struct {
    pc: usize,
    op: u8,
    gas: ?[]const u8 = null,
    gasCost: ?[]const u8 = null,
    stack: []const []const u8,
    depth: ?u32 = null,
    returnData: ?[]const u8 = null,
    refund: ?[]const u8 = null,
    memSize: ?usize = null,
    opName: ?[]const u8 = null,
};
