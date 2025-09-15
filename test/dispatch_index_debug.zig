const std = @import("std");

test "dispatch index mapping issue" {
    std.debug.print("\n=== Dispatch Index Mapping Debug ===\n", .{});

    // The bytecode iterator will produce operations in order
    // For the CALL test bytecode:
    std.debug.print("\nExpected bytecode iterator output:\n", .{});
    std.debug.print("  Op 0: PC=0  -> PUSH0 (regular)\n", .{});
    std.debug.print("  Op 1: PC=1  -> PUSH0 (regular)\n", .{});
    std.debug.print("  Op 2: PC=2  -> PUSH0 (regular)\n", .{});
    std.debug.print("  Op 3: PC=3  -> PUSH0 (regular)\n", .{});
    std.debug.print("  Op 4: PC=4  -> PUSH0 (regular)\n", .{});
    std.debug.print("  Op 5: PC=5  -> ADDRESS (regular)\n", .{});
    std.debug.print("  Op 6: PC=6  -> PUSH2 (push)\n", .{});
    std.debug.print("  Op 7: PC=9  -> CALL (regular)\n", .{});
    std.debug.print("  Op 8: PC=10 -> PUSH1+MSTORE fusion\n", .{});
    std.debug.print("  Op 9: PC=13 -> PUSH1 (push)\n", .{});
    std.debug.print("  Op 10: PC=15 -> PUSH1 (push)\n", .{});
    std.debug.print("  Op 11: PC=17 -> RETURN (regular)\n", .{});

    std.debug.print("\nThe problem:\n", .{});
    std.debug.print("  Frame is executing PUSH_MSTORE_INLINE at PC=0\n", .{});
    std.debug.print("  But PC=0 should be PUSH0, not a fusion\n", .{});
    std.debug.print("  The fusion should be at PC=10\n", .{});

    std.debug.print("\nHypothesis:\n", .{});
    std.debug.print("  The dispatch schedule is built correctly\n", .{});
    std.debug.print("  But the PC->schedule index mapping is wrong\n", .{});
    std.debug.print("  Frame starts at schedule[0] thinking it's PC=0\n", .{});
    std.debug.print("  But schedule[0] might contain a different handler\n", .{});
}