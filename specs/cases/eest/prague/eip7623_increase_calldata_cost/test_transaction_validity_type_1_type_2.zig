const std = @import("std");
const testing = std.testing;
const runner = @import("runner");


test "transaction validity type 1 type 2: type 1 multiple access lists multiple storage keys exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_multiple_storage_keys--exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists multiple storage keys exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_multiple_storage_keys--exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists multiple storage keys extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_multiple_storage_keys--extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists multiple storage keys extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_multiple_storage_keys--extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists multiple storage keys insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_multiple_storage_keys--insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists multiple storage keys insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_multiple_storage_keys--insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists multiple storage keys contract creating exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_multiple_storage_keys-contract_creating-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists multiple storage keys contract creating exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_multiple_storage_keys-contract_creating-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists multiple storage keys contract creating extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_multiple_storage_keys-contract_creating-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists multiple storage keys contract creating extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_multiple_storage_keys-contract_creating-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists multiple storage keys contract creating insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_multiple_storage_keys-contract_creating-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists multiple storage keys contract creating insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_multiple_storage_keys-contract_creating-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists multiple storage keys to eoa exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_multiple_storage_keys-to_eoa-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists multiple storage keys to eoa exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_multiple_storage_keys-to_eoa-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists multiple storage keys to eoa extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_multiple_storage_keys-to_eoa-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists multiple storage keys to eoa extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_multiple_storage_keys-to_eoa-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists multiple storage keys to eoa insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_multiple_storage_keys-to_eoa-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists multiple storage keys to eoa insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_multiple_storage_keys-to_eoa-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists no storage keys exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_no_storage_keys--exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists no storage keys exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_no_storage_keys--exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists no storage keys extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_no_storage_keys--extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists no storage keys extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_no_storage_keys--extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists no storage keys insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_no_storage_keys--insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists no storage keys insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_no_storage_keys--insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists no storage keys contract creating exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_no_storage_keys-contract_creating-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists no storage keys contract creating exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_no_storage_keys-contract_creating-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists no storage keys contract creating extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_no_storage_keys-contract_creating-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists no storage keys contract creating extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_no_storage_keys-contract_creating-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists no storage keys contract creating insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_no_storage_keys-contract_creating-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists no storage keys contract creating insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_no_storage_keys-contract_creating-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists no storage keys to eoa exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_no_storage_keys-to_eoa-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists no storage keys to eoa exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_no_storage_keys-to_eoa-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists no storage keys to eoa extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_no_storage_keys-to_eoa-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists no storage keys to eoa extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_no_storage_keys-to_eoa-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists no storage keys to eoa insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_no_storage_keys-to_eoa-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists no storage keys to eoa insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_no_storage_keys-to_eoa-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists single storage key exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_single_storage_key--exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists single storage key exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_single_storage_key--exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists single storage key extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_single_storage_key--extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists single storage key extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_single_storage_key--extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists single storage key insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_single_storage_key--insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists single storage key insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_single_storage_key--insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists single storage key contract creating exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_single_storage_key-contract_creating-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists single storage key contract creating exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_single_storage_key-contract_creating-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists single storage key contract creating extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_single_storage_key-contract_creating-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists single storage key contract creating extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_single_storage_key-contract_creating-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists single storage key contract creating insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_single_storage_key-contract_creating-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists single storage key contract creating insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_single_storage_key-contract_creating-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists single storage key to eoa exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_single_storage_key-to_eoa-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists single storage key to eoa exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_single_storage_key-to_eoa-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists single storage key to eoa extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_single_storage_key-to_eoa-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists single storage key to eoa extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_single_storage_key-to_eoa-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists single storage key to eoa insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_single_storage_key-to_eoa-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 multiple access lists single storage key to eoa insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-multiple_access_lists_single_storage_key-to_eoa-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 no access list exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-no_access_list--exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 no access list exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-no_access_list--exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 no access list extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-no_access_list--extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 no access list extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-no_access_list--extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 no access list insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-no_access_list--insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 no access list insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-no_access_list--insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 no access list contract creating exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-no_access_list-contract_creating-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 no access list contract creating exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-no_access_list-contract_creating-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 no access list contract creating extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-no_access_list-contract_creating-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 no access list contract creating extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-no_access_list-contract_creating-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 no access list contract creating insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-no_access_list-contract_creating-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 no access list contract creating insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-no_access_list-contract_creating-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 no access list to eoa exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-no_access_list-to_eoa-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 no access list to eoa exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-no_access_list-to_eoa-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 no access list to eoa extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-no_access_list-to_eoa-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 no access list to eoa extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-no_access_list-to_eoa-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 no access list to eoa insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-no_access_list-to_eoa-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 no access list to eoa insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-no_access_list-to_eoa-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list multiple storage keys exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_multiple_storage_keys--exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list multiple storage keys exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_multiple_storage_keys--exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list multiple storage keys extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_multiple_storage_keys--extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list multiple storage keys extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_multiple_storage_keys--extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list multiple storage keys insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_multiple_storage_keys--insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list multiple storage keys insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_multiple_storage_keys--insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list multiple storage keys contract creating exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_multiple_storage_keys-contract_creating-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list multiple storage keys contract creating exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_multiple_storage_keys-contract_creating-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list multiple storage keys contract creating extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_multiple_storage_keys-contract_creating-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list multiple storage keys contract creating extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_multiple_storage_keys-contract_creating-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list multiple storage keys contract creating insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_multiple_storage_keys-contract_creating-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list multiple storage keys contract creating insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_multiple_storage_keys-contract_creating-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list multiple storage keys to eoa exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_multiple_storage_keys-to_eoa-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list multiple storage keys to eoa exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_multiple_storage_keys-to_eoa-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list multiple storage keys to eoa extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_multiple_storage_keys-to_eoa-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list multiple storage keys to eoa extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_multiple_storage_keys-to_eoa-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list multiple storage keys to eoa insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_multiple_storage_keys-to_eoa-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list multiple storage keys to eoa insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_multiple_storage_keys-to_eoa-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list no storage keys exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_no_storage_keys--exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list no storage keys exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_no_storage_keys--exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list no storage keys extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_no_storage_keys--extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list no storage keys extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_no_storage_keys--extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list no storage keys insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_no_storage_keys--insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list no storage keys insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_no_storage_keys--insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list no storage keys contract creating exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_no_storage_keys-contract_creating-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list no storage keys contract creating exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_no_storage_keys-contract_creating-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list no storage keys contract creating extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_no_storage_keys-contract_creating-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list no storage keys contract creating extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_no_storage_keys-contract_creating-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list no storage keys contract creating insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_no_storage_keys-contract_creating-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list no storage keys contract creating insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_no_storage_keys-contract_creating-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list no storage keys to eoa exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_no_storage_keys-to_eoa-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list no storage keys to eoa exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_no_storage_keys-to_eoa-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list no storage keys to eoa extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_no_storage_keys-to_eoa-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list no storage keys to eoa extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_no_storage_keys-to_eoa-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list no storage keys to eoa insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_no_storage_keys-to_eoa-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list no storage keys to eoa insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_no_storage_keys-to_eoa-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list single storage key exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_single_storage_key--exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list single storage key exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_single_storage_key--exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list single storage key extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_single_storage_key--extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list single storage key extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_single_storage_key--extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list single storage key insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_single_storage_key--insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list single storage key insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_single_storage_key--insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list single storage key contract creating exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_single_storage_key-contract_creating-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list single storage key contract creating exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_single_storage_key-contract_creating-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list single storage key contract creating extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_single_storage_key-contract_creating-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list single storage key contract creating extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_single_storage_key-contract_creating-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list single storage key contract creating insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_single_storage_key-contract_creating-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list single storage key contract creating insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_single_storage_key-contract_creating-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list single storage key to eoa exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_single_storage_key-to_eoa-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list single storage key to eoa exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_single_storage_key-to_eoa-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list single storage key to eoa extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_single_storage_key-to_eoa-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list single storage key to eoa extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_single_storage_key-to_eoa-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list single storage key to eoa insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_single_storage_key-to_eoa-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 1 single access list single storage key to eoa insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_1-single_access_list_single_storage_key-to_eoa-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists multiple storage keys exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_multiple_storage_keys--exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists multiple storage keys exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_multiple_storage_keys--exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists multiple storage keys extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_multiple_storage_keys--extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists multiple storage keys extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_multiple_storage_keys--extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists multiple storage keys insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_multiple_storage_keys--insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists multiple storage keys insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_multiple_storage_keys--insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists multiple storage keys contract creating exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_multiple_storage_keys-contract_creating-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists multiple storage keys contract creating exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_multiple_storage_keys-contract_creating-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists multiple storage keys contract creating extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_multiple_storage_keys-contract_creating-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists multiple storage keys contract creating extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_multiple_storage_keys-contract_creating-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists multiple storage keys contract creating insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_multiple_storage_keys-contract_creating-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists multiple storage keys contract creating insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_multiple_storage_keys-contract_creating-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists multiple storage keys to eoa exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_multiple_storage_keys-to_eoa-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists multiple storage keys to eoa exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_multiple_storage_keys-to_eoa-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists multiple storage keys to eoa extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_multiple_storage_keys-to_eoa-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists multiple storage keys to eoa extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_multiple_storage_keys-to_eoa-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists multiple storage keys to eoa insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_multiple_storage_keys-to_eoa-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists multiple storage keys to eoa insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_multiple_storage_keys-to_eoa-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists no storage keys exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_no_storage_keys--exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists no storage keys exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_no_storage_keys--exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists no storage keys extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_no_storage_keys--extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists no storage keys extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_no_storage_keys--extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists no storage keys insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_no_storage_keys--insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists no storage keys insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_no_storage_keys--insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists no storage keys contract creating exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_no_storage_keys-contract_creating-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists no storage keys contract creating exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_no_storage_keys-contract_creating-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists no storage keys contract creating extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_no_storage_keys-contract_creating-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists no storage keys contract creating extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_no_storage_keys-contract_creating-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists no storage keys contract creating insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_no_storage_keys-contract_creating-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists no storage keys contract creating insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_no_storage_keys-contract_creating-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists no storage keys to eoa exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_no_storage_keys-to_eoa-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists no storage keys to eoa exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_no_storage_keys-to_eoa-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists no storage keys to eoa extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_no_storage_keys-to_eoa-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists no storage keys to eoa extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_no_storage_keys-to_eoa-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists no storage keys to eoa insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_no_storage_keys-to_eoa-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists no storage keys to eoa insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_no_storage_keys-to_eoa-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists single storage key exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_single_storage_key--exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists single storage key exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_single_storage_key--exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists single storage key extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_single_storage_key--extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists single storage key extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_single_storage_key--extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists single storage key insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_single_storage_key--insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists single storage key insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_single_storage_key--insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists single storage key contract creating exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_single_storage_key-contract_creating-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists single storage key contract creating exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_single_storage_key-contract_creating-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists single storage key contract creating extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_single_storage_key-contract_creating-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists single storage key contract creating extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_single_storage_key-contract_creating-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists single storage key contract creating insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_single_storage_key-contract_creating-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists single storage key contract creating insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_single_storage_key-contract_creating-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists single storage key to eoa exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_single_storage_key-to_eoa-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists single storage key to eoa exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_single_storage_key-to_eoa-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists single storage key to eoa extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_single_storage_key-to_eoa-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists single storage key to eoa extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_single_storage_key-to_eoa-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists single storage key to eoa insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_single_storage_key-to_eoa-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 multiple access lists single storage key to eoa insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-multiple_access_lists_single_storage_key-to_eoa-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 no access list exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-no_access_list--exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 no access list exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-no_access_list--exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 no access list extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-no_access_list--extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 no access list extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-no_access_list--extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 no access list insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-no_access_list--insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 no access list insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-no_access_list--insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 no access list contract creating exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-no_access_list-contract_creating-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 no access list contract creating exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-no_access_list-contract_creating-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 no access list contract creating extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-no_access_list-contract_creating-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 no access list contract creating extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-no_access_list-contract_creating-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 no access list contract creating insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-no_access_list-contract_creating-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 no access list contract creating insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-no_access_list-contract_creating-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 no access list to eoa exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-no_access_list-to_eoa-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 no access list to eoa exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-no_access_list-to_eoa-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 no access list to eoa extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-no_access_list-to_eoa-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 no access list to eoa extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-no_access_list-to_eoa-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 no access list to eoa insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-no_access_list-to_eoa-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 no access list to eoa insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-no_access_list-to_eoa-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list multiple storage keys exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_multiple_storage_keys--exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list multiple storage keys exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_multiple_storage_keys--exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list multiple storage keys extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_multiple_storage_keys--extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list multiple storage keys extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_multiple_storage_keys--extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list multiple storage keys insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_multiple_storage_keys--insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list multiple storage keys insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_multiple_storage_keys--insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list multiple storage keys contract creating exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_multiple_storage_keys-contract_creating-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list multiple storage keys contract creating exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_multiple_storage_keys-contract_creating-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list multiple storage keys contract creating extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_multiple_storage_keys-contract_creating-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list multiple storage keys contract creating extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_multiple_storage_keys-contract_creating-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list multiple storage keys contract creating insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_multiple_storage_keys-contract_creating-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list multiple storage keys contract creating insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_multiple_storage_keys-contract_creating-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list multiple storage keys to eoa exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_multiple_storage_keys-to_eoa-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list multiple storage keys to eoa exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_multiple_storage_keys-to_eoa-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list multiple storage keys to eoa extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_multiple_storage_keys-to_eoa-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list multiple storage keys to eoa extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_multiple_storage_keys-to_eoa-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list multiple storage keys to eoa insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_multiple_storage_keys-to_eoa-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list multiple storage keys to eoa insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_multiple_storage_keys-to_eoa-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list no storage keys exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_no_storage_keys--exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list no storage keys exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_no_storage_keys--exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list no storage keys extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_no_storage_keys--extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list no storage keys extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_no_storage_keys--extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list no storage keys insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_no_storage_keys--insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list no storage keys insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_no_storage_keys--insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list no storage keys contract creating exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_no_storage_keys-contract_creating-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list no storage keys contract creating exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_no_storage_keys-contract_creating-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list no storage keys contract creating extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_no_storage_keys-contract_creating-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list no storage keys contract creating extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_no_storage_keys-contract_creating-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list no storage keys contract creating insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_no_storage_keys-contract_creating-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list no storage keys contract creating insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_no_storage_keys-contract_creating-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list no storage keys to eoa exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_no_storage_keys-to_eoa-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list no storage keys to eoa exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_no_storage_keys-to_eoa-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list no storage keys to eoa extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_no_storage_keys-to_eoa-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list no storage keys to eoa extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_no_storage_keys-to_eoa-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list no storage keys to eoa insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_no_storage_keys-to_eoa-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list no storage keys to eoa insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_no_storage_keys-to_eoa-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list single storage key exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_single_storage_key--exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list single storage key exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_single_storage_key--exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list single storage key extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_single_storage_key--extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list single storage key extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_single_storage_key--extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list single storage key insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_single_storage_key--insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list single storage key insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_single_storage_key--insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list single storage key contract creating exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_single_storage_key-contract_creating-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list single storage key contract creating exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_single_storage_key-contract_creating-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list single storage key contract creating extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_single_storage_key-contract_creating-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list single storage key contract creating extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_single_storage_key-contract_creating-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list single storage key contract creating insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_single_storage_key-contract_creating-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list single storage key contract creating insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_single_storage_key-contract_creating-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list single storage key to eoa exact gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_single_storage_key-to_eoa-exact_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list single storage key to eoa exact gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_single_storage_key-to_eoa-exact_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list single storage key to eoa extra gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_single_storage_key-to_eoa-extra_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list single storage key to eoa extra gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_single_storage_key-to_eoa-extra_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list single storage key to eoa insufficient gas floor gas greater than intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_single_storage_key-to_eoa-insufficient_gas-floor_gas_greater_than_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}

test "transaction validity type 1 type 2: type 2 single access list single storage key to eoa insufficient gas floor gas less than or equal to intrinsic gas" {
    const allocator = testing.allocator;

    const json_path = "specs/cases/eest/prague/eip7623_increase_calldata_cost/test_transaction_validity_type_1_type_2.json";
    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const test_case = parsed.value.object.get("tests/prague/eip7623_increase_calldata_cost/test_transaction_validity.py::test_transaction_validity_type_1_type_2[fork_Prague-state_test-type_2-single_access_list_single_storage_key-to_eoa-insufficient_gas-floor_gas_less_than_or_equal_to_intrinsic_gas]").?;

    try runner.runJsonTest(allocator, test_case);
}
