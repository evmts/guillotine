const std = @import("std");

// Root fuzz implementation required by std.testing.fuzz
pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), input: []const u8) anyerror!void,
    options: std.testing.FuzzInputOptions,
) anyerror!void {
    _ = options;

    // For now, just run with a fixed input to test compilation
    // In a real implementation, this would integrate with libFuzzer
    const test_inputs = [_][]const u8{
        &[_]u8{0} ** 32,
        &[_]u8{0xFF} ** 32,
        &[_]u8{0x01} ** 96,
        &[_]u8{0x00} ** 192,
    };

    for (test_inputs) |input| {
        try testOne(context, input);
    }
}
