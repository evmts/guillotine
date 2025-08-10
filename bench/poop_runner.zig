const std = @import("std");
const builtin = @import("builtin");
const process = std.process;
const print = std.debug.print;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);

    // Check if we're on Linux
    if (builtin.os.tag != .linux) {
        print("Error: poop benchmarking tool only works on Linux (uses perf_event_open).\n", .{});
        print("Please run this benchmark on a Linux system or in a Linux container.\n", .{});
        print("\nYou can use Docker:\n", .{});
        print("  docker run --rm -it -v $PWD:/workspace -w /workspace ubuntu:latest\n", .{});
        print("  # Then inside the container, install Zig and run: zig build poop\n\n", .{});
        std.process.exit(1);
    }

    // Get the directory where the binary is located
    const self_exe_path = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(self_exe_path);

    // Construct path to evm-runner
    const evm_runner_path = try std.fs.path.join(allocator, &.{ self_exe_path, "evm-runner" });
    defer allocator.free(evm_runner_path);

    // Get the project root directory (assuming we're in zig-out/bin)
    const project_root = try std.fs.path.resolve(allocator, &.{ self_exe_path, "..", ".." });
    defer allocator.free(project_root);

    // Construct paths to snailtracer files
    const bytecode_path = try std.fs.path.join(allocator, &.{ project_root, "bench", "official", "cases", "snailtracer", "bytecode.txt" });
    defer allocator.free(bytecode_path);

    // For snailtracer, we know the calldata is 0x30627b7c
    const calldata = "0x30627b7c";

    // Construct poop arguments
    var poop_args = std.ArrayList([]const u8).init(allocator);
    defer poop_args.deinit();

    try poop_args.append("poop");

    // Add any additional poop options from command line
    for (args[1..]) |arg| {
        try poop_args.append(arg);
    }

    // Add our benchmark command
    try poop_args.append(evm_runner_path);
    try poop_args.append("--contract-code-path");
    try poop_args.append(bytecode_path);
    try poop_args.append("--calldata");
    try poop_args.append(calldata);

    // Print the command we're running
    print("Running poop with snailtracer benchmark:\n", .{});
    print("Command: ", .{});
    for (poop_args.items) |arg| {
        print("{s} ", .{arg});
    }
    print("\n\n", .{});

    // Execute poop
    var child = std.process.Child.init(poop_args.items, allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const result = try child.spawnAndWait();

    // Exit with the same code as poop
    switch (result) {
        .Exited => |code| {
            if (code != 0) {
                std.process.exit(code);
            }
        },
        else => std.process.exit(1),
    }
}

test "poop runner basic functionality" {
    // Basic sanity test
    const allocator = std.testing.allocator;
    const args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);

    try std.testing.expect(args.len >= 1);
}
