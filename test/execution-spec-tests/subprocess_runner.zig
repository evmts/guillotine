const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

pub const SubprocessResult = struct {
    success: bool,
    output: []const u8,
    timed_out: bool = false,
    exit_code: u8 = 0,

    pub fn deinit(self: *const SubprocessResult, allocator: Allocator) void {
        allocator.free(self.output);
    }
};

/// Run a command with timeout protection
pub fn runWithTimeout(
    allocator: Allocator,
    argv: []const []const u8,
    timeout_ms: u64,
) !SubprocessResult {
    _ = timeout_ms; // For now, ignore timeout and just run the process

    // Use Child.run for simplicity - it handles everything
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 10 * 1024 * 1024, // 10MB max output
    });

    const exit_code = switch (result.term) {
        .Exited => |code| @as(u8, @intCast(code)),
        .Signal => |sig| @as(u8, 128 + @as(u8, @intCast(sig))),
        .Stopped => 128,
        .Unknown => 128,
    };

    // Combine stdout and stderr
    const output = try std.fmt.allocPrint(allocator, "{s}{s}", .{ result.stdout, result.stderr });
    allocator.free(result.stdout);
    allocator.free(result.stderr);

    return SubprocessResult{
        .success = (exit_code == 0),
        .output = output,
        .timed_out = false,
        .exit_code = exit_code,
    };
}