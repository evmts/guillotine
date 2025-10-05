const std = @import("std");
const testing = std.testing;
const runner = @import("runner");

test "full gas consumption: exact gas, type 0 protected" {
    const allocator = testing.allocator;

    // Read and parse the JSON test file
    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_full_gas_consumption.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    // Get the specific test case
    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_execution_gas.py::TestGasConsumption::test_full_gas_consumption[fork_Prague-state_test-exact_gas-type_0_protected]").?;

    // Run the test
    try runner.runJsonTest(allocator, test_case);
}

test "full gas consumption: exact gas, type 0 unprotected" {
    const allocator = testing.allocator;

    // Read and parse the JSON test file
    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_full_gas_consumption.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    // Get the specific test case
    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_execution_gas.py::TestGasConsumption::test_full_gas_consumption[fork_Prague-state_test-exact_gas-type_0_unprotected]").?;

    // Run the test
    try runner.runJsonTest(allocator, test_case);
}

test "full gas consumption: exact gas, type 1" {
    const allocator = testing.allocator;

    // Read and parse the JSON test file
    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_full_gas_consumption.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    // Get the specific test case
    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_execution_gas.py::TestGasConsumption::test_full_gas_consumption[fork_Prague-state_test-exact_gas-type_1]").?;

    // Run the test
    try runner.runJsonTest(allocator, test_case);
}

test "full gas consumption: exact gas, type 2" {
    const allocator = testing.allocator;

    // Read and parse the JSON test file
    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_full_gas_consumption.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    // Get the specific test case
    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_execution_gas.py::TestGasConsumption::test_full_gas_consumption[fork_Prague-state_test-exact_gas-type_2]").?;

    // Run the test
    try runner.runJsonTest(allocator, test_case);
}

test "full gas consumption: exact gas, type 3" {
    const allocator = testing.allocator;

    // Read and parse the JSON test file
    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_full_gas_consumption.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    // Get the specific test case
    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_execution_gas.py::TestGasConsumption::test_full_gas_consumption[fork_Prague-state_test-exact_gas-type_3]").?;

    // Run the test
    try runner.runJsonTest(allocator, test_case);
}

test "full gas consumption: exact gas, type 4" {
    const allocator = testing.allocator;

    // Read and parse the JSON test file
    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_full_gas_consumption.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    // Get the specific test case
    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_execution_gas.py::TestGasConsumption::test_full_gas_consumption[fork_Prague-state_test-exact_gas-type_4]").?;

    // Run the test
    try runner.runJsonTest(allocator, test_case);
}

test "full gas consumption: extra gas, type 0 protected" {
    const allocator = testing.allocator;

    // Read and parse the JSON test file
    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_full_gas_consumption.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    // Get the specific test case
    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_execution_gas.py::TestGasConsumption::test_full_gas_consumption[fork_Prague-state_test-extra_gas-type_0_protected]").?;

    // Run the test
    try runner.runJsonTest(allocator, test_case);
}

test "full gas consumption: extra gas, type 0 unprotected" {
    const allocator = testing.allocator;

    // Read and parse the JSON test file
    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_full_gas_consumption.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    // Get the specific test case
    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_execution_gas.py::TestGasConsumption::test_full_gas_consumption[fork_Prague-state_test-extra_gas-type_0_unprotected]").?;

    // Run the test
    try runner.runJsonTest(allocator, test_case);
}

test "full gas consumption: extra gas, type 1" {
    const allocator = testing.allocator;

    // Read and parse the JSON test file
    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_full_gas_consumption.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    // Get the specific test case
    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_execution_gas.py::TestGasConsumption::test_full_gas_consumption[fork_Prague-state_test-extra_gas-type_1]").?;

    // Run the test
    try runner.runJsonTest(allocator, test_case);
}

test "full gas consumption: extra gas, type 2" {
    const allocator = testing.allocator;

    // Read and parse the JSON test file
    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_full_gas_consumption.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    // Get the specific test case
    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_execution_gas.py::TestGasConsumption::test_full_gas_consumption[fork_Prague-state_test-extra_gas-type_2]").?;

    // Run the test
    try runner.runJsonTest(allocator, test_case);
}

test "full gas consumption: extra gas, type 3" {
    const allocator = testing.allocator;

    // Read and parse the JSON test file
    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_full_gas_consumption.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    // Get the specific test case
    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_execution_gas.py::TestGasConsumption::test_full_gas_consumption[fork_Prague-state_test-extra_gas-type_3]").?;

    // Run the test
    try runner.runJsonTest(allocator, test_case);
}

test "full gas consumption: extra gas, type 4" {
    const allocator = testing.allocator;

    // Read and parse the JSON test file
    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_full_gas_consumption.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    // Get the specific test case
    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_execution_gas.py::TestGasConsumption::test_full_gas_consumption[fork_Prague-state_test-extra_gas-type_4]").?;

    // Run the test
    try runner.runJsonTest(allocator, test_case);
}
