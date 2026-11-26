const std = @import("std");
const testing = std.testing;
const runner = @import("runner");

test "RevertPrecompiledTouch_nonce" {
    const allocator = testing.allocator;
    
    // Read and parse the JSON test file
    const json_path = "specs/execution-specs/tests/eest/static/state_tests/stRevertTest/RevertPrecompiledTouch_nonceFiller.json";
    const json_content = try std.Io.Dir.cwd().readFileAlloc(testing.io, json_path, allocator, .limited(100 * 1024 * 1024));
    defer allocator.free(json_content);
    
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();
    
    // Get the specific test case
    const test_case = parsed.value.object.get("RevertPrecompiledTouch_nonce").?;
    
    // Run the test
    try runner.runJsonTest(allocator, test_case);
}
