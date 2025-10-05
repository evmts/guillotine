const std = @import("std");
const testing = std.testing;
const runner = @import("runner");

test "gas consumption below data floor: exact gas, type 0 protected" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_gas_consumption_below_data_floor.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_execution_gas.py::TestGasConsumptionBelowDataFloor::test_gas_consumption_below_data_floor[fork_Prague-state_test-exact_gas-type_0_protected]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "gas consumption below data floor: exact gas, type 0 unprotected" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_gas_consumption_below_data_floor.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_execution_gas.py::TestGasConsumptionBelowDataFloor::test_gas_consumption_below_data_floor[fork_Prague-state_test-exact_gas-type_0_unprotected]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "gas consumption below data floor: exact gas, type 1" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_gas_consumption_below_data_floor.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_execution_gas.py::TestGasConsumptionBelowDataFloor::test_gas_consumption_below_data_floor[fork_Prague-state_test-exact_gas-type_1]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "gas consumption below data floor: exact gas, type 2" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_gas_consumption_below_data_floor.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_execution_gas.py::TestGasConsumptionBelowDataFloor::test_gas_consumption_below_data_floor[fork_Prague-state_test-exact_gas-type_2]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "gas consumption below data floor: exact gas, type 3" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_gas_consumption_below_data_floor.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_execution_gas.py::TestGasConsumptionBelowDataFloor::test_gas_consumption_below_data_floor[fork_Prague-state_test-exact_gas-type_3]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "gas consumption below data floor: exact gas, type 4" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_gas_consumption_below_data_floor.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_execution_gas.py::TestGasConsumptionBelowDataFloor::test_gas_consumption_below_data_floor[fork_Prague-state_test-exact_gas-type_4]").?;

    try runner.runJsonTest(allocator, test_case);
}
