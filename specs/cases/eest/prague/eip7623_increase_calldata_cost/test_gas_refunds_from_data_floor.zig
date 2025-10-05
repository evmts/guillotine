const std = @import("std");
const testing = std.testing;
const runner = @import("runner");


test "gas refunds from data floor: AUTHORIZATION EXISTING AUTHORITY EXECUTION GAS MINUS REFUND EQUAL TO DATA FLOOR" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_gas_refunds_from_data_floor.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_refunds.py::test_gas_refunds_from_data_floor[fork_Prague-state_test-refund_type_RefundType.AUTHORIZATION_EXISTING_AUTHORITY-refund_test_type_RefundTestType.EXECUTION_GAS_MINUS_REFUND_EQUAL_TO_DATA_FLOOR]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "gas refunds from data floor: AUTHORIZATION EXISTING AUTHORITY EXECUTION GAS MINUS REFUND GREATER THAN DATA FLOOR" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_gas_refunds_from_data_floor.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_refunds.py::test_gas_refunds_from_data_floor[fork_Prague-state_test-refund_type_RefundType.AUTHORIZATION_EXISTING_AUTHORITY-refund_test_type_RefundTestType.EXECUTION_GAS_MINUS_REFUND_GREATER_THAN_DATA_FLOOR]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "gas refunds from data floor: AUTHORIZATION EXISTING AUTHORITY EXECUTION GAS MINUS REFUND LESS THAN DATA FLOOR" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_gas_refunds_from_data_floor.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_refunds.py::test_gas_refunds_from_data_floor[fork_Prague-state_test-refund_type_RefundType.AUTHORIZATION_EXISTING_AUTHORITY-refund_test_type_RefundTestType.EXECUTION_GAS_MINUS_REFUND_LESS_THAN_DATA_FLOOR]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "gas refunds from data floor: STORAGE CLEAR EXECUTION GAS MINUS REFUND EQUAL TO DATA FLOOR" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_gas_refunds_from_data_floor.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_refunds.py::test_gas_refunds_from_data_floor[fork_Prague-state_test-refund_type_RefundType.STORAGE_CLEAR-refund_test_type_RefundTestType.EXECUTION_GAS_MINUS_REFUND_EQUAL_TO_DATA_FLOOR]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "gas refunds from data floor: STORAGE CLEAR EXECUTION GAS MINUS REFUND GREATER THAN DATA FLOOR" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_gas_refunds_from_data_floor.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_refunds.py::test_gas_refunds_from_data_floor[fork_Prague-state_test-refund_type_RefundType.STORAGE_CLEAR-refund_test_type_RefundTestType.EXECUTION_GAS_MINUS_REFUND_GREATER_THAN_DATA_FLOOR]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "gas refunds from data floor: STORAGE CLEAR EXECUTION GAS MINUS REFUND LESS THAN DATA FLOOR" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_gas_refunds_from_data_floor.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_refunds.py::test_gas_refunds_from_data_floor[fork_Prague-state_test-refund_type_RefundType.STORAGE_CLEAR-refund_test_type_RefundTestType.EXECUTION_GAS_MINUS_REFUND_LESS_THAN_DATA_FLOOR]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "gas refunds from data floor: STORAGE CLEAR and AUTHORIZATION EXISTING AUTHORITY EXECUTION GAS MINUS REFUND EQUAL TO DATA FLOOR" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_gas_refunds_from_data_floor.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_refunds.py::test_gas_refunds_from_data_floor[fork_Prague-state_test-refund_type_RefundType.STORAGE_CLEAR|AUTHORIZATION_EXISTING_AUTHORITY-refund_test_type_RefundTestType.EXECUTION_GAS_MINUS_REFUND_EQUAL_TO_DATA_FLOOR]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "gas refunds from data floor: STORAGE CLEAR and AUTHORIZATION EXISTING AUTHORITY EXECUTION GAS MINUS REFUND GREATER THAN DATA FLOOR" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_gas_refunds_from_data_floor.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_refunds.py::test_gas_refunds_from_data_floor[fork_Prague-state_test-refund_type_RefundType.STORAGE_CLEAR|AUTHORIZATION_EXISTING_AUTHORITY-refund_test_type_RefundTestType.EXECUTION_GAS_MINUS_REFUND_GREATER_THAN_DATA_FLOOR]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "gas refunds from data floor: STORAGE CLEAR and AUTHORIZATION EXISTING AUTHORITY EXECUTION GAS MINUS REFUND LESS THAN DATA FLOOR" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_gas_refunds_from_data_floor.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_refunds.py::test_gas_refunds_from_data_floor[fork_Prague-state_test-refund_type_RefundType.STORAGE_CLEAR|AUTHORIZATION_EXISTING_AUTHORITY-refund_test_type_RefundTestType.EXECUTION_GAS_MINUS_REFUND_LESS_THAN_DATA_FLOOR]").?;

    try runner.runJsonTest(allocator, test_case);
}
