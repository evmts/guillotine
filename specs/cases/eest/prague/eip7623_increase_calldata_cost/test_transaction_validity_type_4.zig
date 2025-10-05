const std = @import("std");
const testing = std.testing;
const runner = @import("runner");


test "transaction validity type 4: type 4 multiple authorizations multiple access lists multiple storage keys exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-multiple_access_lists_multiple_storage_keys-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations multiple access lists multiple storage keys exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-multiple_access_lists_multiple_storage_keys-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations multiple access lists multiple storage keys extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-multiple_access_lists_multiple_storage_keys-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations multiple access lists multiple storage keys extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-multiple_access_lists_multiple_storage_keys-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations multiple access lists multiple storage keys insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-multiple_access_lists_multiple_storage_keys-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations multiple access lists multiple storage keys insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-multiple_access_lists_multiple_storage_keys-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations multiple access lists no storage keys exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-multiple_access_lists_no_storage_keys-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations multiple access lists no storage keys exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-multiple_access_lists_no_storage_keys-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations multiple access lists no storage keys extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-multiple_access_lists_no_storage_keys-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations multiple access lists no storage keys extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-multiple_access_lists_no_storage_keys-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations multiple access lists no storage keys insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-multiple_access_lists_no_storage_keys-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations multiple access lists no storage keys insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-multiple_access_lists_no_storage_keys-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations multiple access lists single storage key exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-multiple_access_lists_single_storage_key-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations multiple access lists single storage key exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-multiple_access_lists_single_storage_key-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations multiple access lists single storage key extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-multiple_access_lists_single_storage_key-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations multiple access lists single storage key extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-multiple_access_lists_single_storage_key-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations multiple access lists single storage key insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-multiple_access_lists_single_storage_key-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations multiple access lists single storage key insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-multiple_access_lists_single_storage_key-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations no access list exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-no_access_list-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations no access list exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-no_access_list-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations no access list extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-no_access_list-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations no access list extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-no_access_list-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations no access list insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-no_access_list-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations no access list insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-no_access_list-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations single access list multiple storage keys exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-single_access_list_multiple_storage_keys-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations single access list multiple storage keys exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-single_access_list_multiple_storage_keys-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations single access list multiple storage keys extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-single_access_list_multiple_storage_keys-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations single access list multiple storage keys extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-single_access_list_multiple_storage_keys-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations single access list multiple storage keys insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-single_access_list_multiple_storage_keys-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations single access list multiple storage keys insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-single_access_list_multiple_storage_keys-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations single access list no storage keys exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-single_access_list_no_storage_keys-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations single access list no storage keys exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-single_access_list_no_storage_keys-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations single access list no storage keys extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-single_access_list_no_storage_keys-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations single access list no storage keys extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-single_access_list_no_storage_keys-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations single access list no storage keys insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-single_access_list_no_storage_keys-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations single access list no storage keys insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-single_access_list_no_storage_keys-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations single access list single storage key exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-single_access_list_single_storage_key-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations single access list single storage key exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-single_access_list_single_storage_key-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations single access list single storage key extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-single_access_list_single_storage_key-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations single access list single storage key extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-single_access_list_single_storage_key-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations single access list single storage key insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-single_access_list_single_storage_key-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 multiple authorizations single access list single storage key insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-multiple_authorizations-single_access_list_single_storage_key-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization multiple access lists multiple storage keys exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-multiple_access_lists_multiple_storage_keys-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization multiple access lists multiple storage keys exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-multiple_access_lists_multiple_storage_keys-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization multiple access lists multiple storage keys extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-multiple_access_lists_multiple_storage_keys-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization multiple access lists multiple storage keys extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-multiple_access_lists_multiple_storage_keys-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization multiple access lists multiple storage keys insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-multiple_access_lists_multiple_storage_keys-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization multiple access lists multiple storage keys insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-multiple_access_lists_multiple_storage_keys-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization multiple access lists no storage keys exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-multiple_access_lists_no_storage_keys-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization multiple access lists no storage keys exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-multiple_access_lists_no_storage_keys-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization multiple access lists no storage keys extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-multiple_access_lists_no_storage_keys-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization multiple access lists no storage keys extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-multiple_access_lists_no_storage_keys-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization multiple access lists no storage keys insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-multiple_access_lists_no_storage_keys-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization multiple access lists no storage keys insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-multiple_access_lists_no_storage_keys-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization multiple access lists single storage key exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-multiple_access_lists_single_storage_key-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization multiple access lists single storage key exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-multiple_access_lists_single_storage_key-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization multiple access lists single storage key extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-multiple_access_lists_single_storage_key-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization multiple access lists single storage key extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-multiple_access_lists_single_storage_key-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization multiple access lists single storage key insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-multiple_access_lists_single_storage_key-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization multiple access lists single storage key insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-multiple_access_lists_single_storage_key-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization no access list exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-no_access_list-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization no access list exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-no_access_list-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization no access list extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-no_access_list-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization no access list extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-no_access_list-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization no access list insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-no_access_list-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization no access list insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-no_access_list-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization single access list multiple storage keys exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-single_access_list_multiple_storage_keys-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization single access list multiple storage keys exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-single_access_list_multiple_storage_keys-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization single access list multiple storage keys extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-single_access_list_multiple_storage_keys-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization single access list multiple storage keys extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-single_access_list_multiple_storage_keys-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization single access list multiple storage keys insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-single_access_list_multiple_storage_keys-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization single access list multiple storage keys insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-single_access_list_multiple_storage_keys-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization single access list no storage keys exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-single_access_list_no_storage_keys-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization single access list no storage keys exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-single_access_list_no_storage_keys-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization single access list no storage keys extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-single_access_list_no_storage_keys-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization single access list no storage keys extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-single_access_list_no_storage_keys-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization single access list no storage keys insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-single_access_list_no_storage_keys-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization single access list no storage keys insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-single_access_list_no_storage_keys-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization single access list single storage key exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-single_access_list_single_storage_key-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization single access list single storage key exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-single_access_list_single_storage_key-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization single access list single storage key extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-single_access_list_single_storage_key-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization single access list single storage key extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-single_access_list_single_storage_key-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization single access list single storage key insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-single_access_list_single_storage_key-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 4: type 4 single authorization single access list single storage key insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_4[fork_Prague-state_test-type_4-single_authorization-single_access_list_single_storage_key-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}
