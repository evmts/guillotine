const std = @import("std");
const testing = std.testing;
const runner = @import("runner");

test "ecmul_0-3_340282366920938463463374607431768211456_28000_80" {
    const allocator = testing.allocator;
    
    // Read and parse the JSON test file
    const json_path = "specs/execution-specs/tests/eest/static/state_tests/stZeroKnowledge2/ecmul_0-3_340282366920938463463374607431768211456_28000_80Filler.json";
    const json_content = try std.Io.Dir.cwd().readFileAlloc(testing.io, json_path, allocator, .limited(100 * 1024 * 1024));
    defer allocator.free(json_content);
    
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();
    
    // Get the specific test case
    const test_case = parsed.value.object.get("ecmul_0-3_340282366920938463463374607431768211456_28000_80").?;
    
    // Run the test
    try runner.runJsonTest(allocator, test_case);
}
