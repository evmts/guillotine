const std = @import("std");
const testing = std.testing;
const runner = @import("runner");


test "transaction validity type 0:  type 0 protected exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test--type_0-protected-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0:  type 0 protected exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test--type_0-protected-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0:  type 0 protected extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test--type_0-protected-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0:  type 0 protected extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test--type_0-protected-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0:  type 0 protected insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test--type_0-protected-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0:  type 0 protected insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test--type_0-protected-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0:  type 0 unprotected exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test--type_0-unprotected-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0:  type 0 unprotected exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test--type_0-unprotected-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0:  type 0 unprotected extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test--type_0-unprotected-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0:  type 0 unprotected extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test--type_0-unprotected-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0:  type 0 unprotected insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test--type_0-unprotected-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0:  type 0 unprotected insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test--type_0-unprotected-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0: contract creating type 0 protected exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test-contract_creating-type_0-protected-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0: contract creating type 0 protected exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test-contract_creating-type_0-protected-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0: contract creating type 0 protected extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test-contract_creating-type_0-protected-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0: contract creating type 0 protected extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test-contract_creating-type_0-protected-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0: contract creating type 0 protected insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test-contract_creating-type_0-protected-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0: contract creating type 0 protected insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test-contract_creating-type_0-protected-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0: contract creating type 0 unprotected exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test-contract_creating-type_0-unprotected-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0: contract creating type 0 unprotected exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test-contract_creating-type_0-unprotected-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0: contract creating type 0 unprotected extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test-contract_creating-type_0-unprotected-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0: contract creating type 0 unprotected extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test-contract_creating-type_0-unprotected-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0: contract creating type 0 unprotected insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test-contract_creating-type_0-unprotected-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0: contract creating type 0 unprotected insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test-contract_creating-type_0-unprotected-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0: to eoa type 0 protected exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test-to_eoa-type_0-protected-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0: to eoa type 0 protected exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test-to_eoa-type_0-protected-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0: to eoa type 0 protected extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test-to_eoa-type_0-protected-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0: to eoa type 0 protected extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test-to_eoa-type_0-protected-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0: to eoa type 0 protected insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test-to_eoa-type_0-protected-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0: to eoa type 0 protected insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test-to_eoa-type_0-protected-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0: to eoa type 0 unprotected exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test-to_eoa-type_0-unprotected-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0: to eoa type 0 unprotected exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test-to_eoa-type_0-unprotected-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0: to eoa type 0 unprotected extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test-to_eoa-type_0-unprotected-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0: to eoa type 0 unprotected extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test-to_eoa-type_0-unprotected-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0: to eoa type 0 unprotected insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test-to_eoa-type_0-unprotected-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 0: to eoa type 0 unprotected insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_0.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_0[fork_Prague-state_test-to_eoa-type_0-unprotected-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}
