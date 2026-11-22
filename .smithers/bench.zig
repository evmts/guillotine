const std = @import("std");
const modexp = @import("modexp");

pub fn main() !void {
    const count = 1_000_000;
    var base = [_]u8{42};
    var exponent = [_]u8{ 1, 0, 1 };
    var modulus = [_]u8{ 0x3b, 0x9a, 0xca, 0x07 };
    var output: [4]u8 = undefined;
    var timer = try std.time.Timer.start();
    for (0..count) |_| {
        std.mem.doNotOptimizeAway(&base);
        std.mem.doNotOptimizeAway(&exponent);
        std.mem.doNotOptimizeAway(&modulus);
        try modexp.unauditedModexp(std.heap.page_allocator, &base, &exponent, &modulus, &output);
        std.mem.doNotOptimizeAway(&output);
    }
    const elapsed = timer.read();
    // Validate each benchmark's workload before accepting its measurement.
    if (std.mem.readInt(u32, &output, .big) != 115812009) return error.InvalidBenchmarkResult;
    var buffer: [256]u8 = undefined;
    const result = try std.fmt.bufPrint(
        &buffer,
        "{{\"benchmark\":\"modexp-42-pow-65537\",\"iterations\":{d},\"elapsed_ns\":{d},\"ns_per_op\":{d}}}\n",
        .{ count, elapsed, elapsed / count },
    );
    try std.fs.File.stdout().writeAll(result);
}
