const std = @import("std");

pub const Options = struct {
    json: []const u8 = "bench/results/latest.json",
    filter: []const u8 = "",
    iterations: usize = 100,
    warmup: usize = 10,
    compare: bool = false,
    help: bool = false,
};

pub const usage =
    \\Usage: guillotine-bench [--json <path>] [--filter <substring>]
    \\                        [--iterations <N>] [--warmup <N>] [--compare] [--help]
    \\
    \\Defaults: 100 samples, 10 warmups, JSON at bench/results/latest.json.
    \\--compare runs fused and unfused EVMs and records loop availability.
    \\Filter is a case-insensitive substring; no matches is an error.
    \\Timing includes simulate() and result copying, excludes setup/validation.
    \\
;

pub fn parse(args: []const []const u8) !Options {
    var options = Options{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--compare")) {
            options.compare = true;
            continue;
        }
        const json = std.mem.eql(u8, arg, "--json");
        const filter = std.mem.eql(u8, arg, "--filter");
        const iterations = std.mem.eql(u8, arg, "--iterations");
        const warmup = std.mem.eql(u8, arg, "--warmup");
        if (!json and !filter and !iterations and !warmup) return error.UnknownArgument;
        index += 1;
        if (index == args.len or std.mem.startsWith(u8, args[index], "--")) return error.MissingArgument;
        const value = args[index];
        if (json) {
            if (value.len == 0) return error.EmptyPath;
            options.json = value;
        } else if (filter) {
            options.filter = value;
        } else {
            const count = std.fmt.parseUnsigned(usize, value, 10) catch return error.InvalidCount;
            if (count > 1_000_000 or (iterations and count == 0)) return error.InvalidCount;
            if (iterations) options.iterations = count;
            if (warmup) options.warmup = count;
        }
    }
    return options;
}

pub fn matches(name: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return true;
    if (pattern.len > name.len) return false;
    for (0..name.len - pattern.len + 1) |index| {
        if (std.ascii.eqlIgnoreCase(name[index..][0..pattern.len], pattern)) return true;
    }
    return false;
}

test "CLI rejects malformed counts and missing values" {
    try std.testing.expectError(error.InvalidCount, parse(&.{ "--iterations", "0" }));
    try std.testing.expectError(error.InvalidCount, parse(&.{ "--warmup", "-1" }));
    try std.testing.expectError(error.InvalidCount, parse(&.{ "--iterations", "1000001" }));
    try std.testing.expectError(error.UnknownArgument, parse(&.{"--unknown"}));
    try std.testing.expectError(error.MissingArgument, parse(&.{"--json"}));
    try std.testing.expectError(error.MissingArgument, parse(&.{ "--filter", "--compare" }));
    const options = try parse(&.{ "--iterations", "3", "--warmup", "0", "--compare", "--filter", "ADD" });
    try std.testing.expectEqual(@as(usize, 3), options.iterations);
    try std.testing.expectEqual(@as(usize, 0), options.warmup);
    try std.testing.expect(options.compare);
    try std.testing.expect(matches("opcode/add", options.filter));
    try std.testing.expect(!matches("opcode/mul", options.filter));
}
