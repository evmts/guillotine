pub fn main(init: std.process.Init) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help         Display this help and exit.
        \\-v, --version      Output version information and exit.
        \\    --value <str>  An option parameter, which takes a value.
        \\
    );

    var res = try clap.parse(clap.Help, &params, clap.parsers.default, init.minimal.args, .{ .allocator = init.gpa });
    defer res.deinit();

    // `clap.usageToFile` is a function that can print a simple usage string. It can print any
    // `Param` where `Id` has a `value` method (`Param(Help)` is one such parameter).
    if (res.args.help != 0)
        return clap.usageToFile(init.io, .stdout(), clap.Help, &params);
}

const clap = @import("clap");
const std = @import("std");
