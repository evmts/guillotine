const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("voltaire");
const runner = @import("runner.zig");

// Import the manifest at comptime if it exists
const manifest = if (@hasDecl(@This(), "cases")) @import("cases/manifest.zon") else struct {
    test_cases: []const void = &[_]void{},
};

fn runStateTest(allocator: std.mem.Allocator, comptime zon_file_path: []const u8) !void {
    // Import the test data at comptime using the zon file path
    const test_data = @import(zon_file_path);
    
    // Run the test using the runner
    try runner.runTest(allocator, test_data);
}

// Generate a test for each test case if manifest exists
test "state tests" {
    if (manifest.test_cases.len > 0) {
        inline for (manifest.test_cases) |test_case| {
            try runStateTest(testing.allocator, "cases/" ++ test_case.zon_file);
        }
    } else {
        // No test cases yet - skip
        try testing.expect(true);
    }
}