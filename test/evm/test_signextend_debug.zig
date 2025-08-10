const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");
const Operation = Evm.Operation;
const arithmetic = Evm.opcodes.arithmetic;

test "SIGNEXTEND direct test" {
    const allocator = testing.allocator;

    // Create minimal EVM setup
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    // Create contract and frame
    const code_hash: [32]u8 = [_]u8{0} ** 32;
    var contract = Evm.Contract.init(
        primitives.Address.ZERO,
        primitives.Address.ZERO,
        0,
        10000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const frame_ptr = try allocator.create(Evm.Frame);
    defer allocator.destroy(frame_ptr);

    var frame_builder = Evm.Frame.builder(allocator);
    frame_ptr.* = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame_ptr.deinit();

    // Push test values: [0xFF, 0]
    // SIGNEXTEND pops byte_index first, then value
    // So value (0xFF) goes on bottom, byte_index (0) goes on top
    try frame_ptr.stack.append(0xFF); // value
    try frame_ptr.stack.append(0); // byte_index

    std.debug.print("\nBefore SIGNEXTEND: stack size={}, values=[{}, {}]\n", .{
        frame_ptr.stack.size,
        if (frame_ptr.stack.size > 0) frame_ptr.stack.data[0] else 0,
        if (frame_ptr.stack.size > 1) frame_ptr.stack.data[1] else 0,
    });

    // Execute SIGNEXTEND
    const interpreter: Operation.Interpreter = &evm;
    const state: Operation.State = frame_ptr;
    _ = try arithmetic.op_signextend(0, interpreter, state);

    std.debug.print("After SIGNEXTEND: stack size={}, top=0x{x}\n", .{
        frame_ptr.stack.size,
        if (frame_ptr.stack.size > 0) frame_ptr.stack.peek_n(0) catch 0 else 0,
    });

    // Check result
    try testing.expectEqual(@as(usize, 1), frame_ptr.stack.size);
    const result = try frame_ptr.stack.peek_n(0);
    try testing.expectEqual(std.math.maxInt(u256), result);
}
