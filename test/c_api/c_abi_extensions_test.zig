//! C ABI regression tests for the additive block and transaction setters, the
//! touched-set reset, bounded trace capture, `guillotine_simulate` isolation and
//! structLogs tracing.
//!
//! Every test goes through the exported `extern "C"` symbols, the way a host does.

const std = @import("std");
const testing = std.testing;
const c_api = @import("evm_c_api");

comptime {
    _ = c_api;
}

const EvmHandle = c_api.EvmHandle;
const BlockInfoFFI = c_api.BlockInfoFFI;
const CallParams = c_api.CallParams;
const EvmResult = c_api.EvmResult;
const StateDumpFFI = c_api.StateDumpFFI;
const AccessListEntryFFI = c_api.AccessListEntryFFI;
const AuthorizationFFI = c_api.AuthorizationFFI;

extern "c" fn guillotine_init() void;
extern "c" fn guillotine_evm_create(block_info: ?*const BlockInfoFFI) ?*EvmHandle;
extern "c" fn guillotine_evm_create_tracing(block_info: ?*const BlockInfoFFI) ?*EvmHandle;
extern "c" fn guillotine_evm_destroy(handle: ?*EvmHandle) void;
extern "c" fn guillotine_evm_destroy_tracing(handle: ?*EvmHandle) void;
extern "c" fn guillotine_set_block_info(handle: ?*EvmHandle, block_info: ?*const BlockInfoFFI) bool;
extern "c" fn guillotine_set_blob_base_fee(handle: ?*EvmHandle, blob_base_fee: ?*const [32]u8) bool;
extern "c" fn guillotine_set_block_hashes(handle: ?*EvmHandle, hashes: ?[*]const [32]u8, count: usize) bool;
extern "c" fn guillotine_set_block_hash(handle: ?*EvmHandle, block_number: u64, hash: ?*const [32]u8) bool;
extern "c" fn guillotine_set_blob_hashes(handle: ?*EvmHandle, hashes: ?[*]const [32]u8, count: usize) bool;
extern "c" fn guillotine_set_max_fee_per_blob_gas(handle: ?*EvmHandle, max_fee: ?*const [32]u8) bool;
extern "c" fn guillotine_set_access_list(handle: ?*EvmHandle, entries: ?[*]const AccessListEntryFFI, count: usize) bool;
extern "c" fn guillotine_set_authorization_list(
    handle: ?*EvmHandle,
    authorizations: ?[*]const AuthorizationFFI,
    count: usize,
) bool;
extern "c" fn guillotine_reset_touched(handle: ?*EvmHandle) bool;
extern "c" fn guillotine_set_trace_limits(handle: ?*EvmHandle, max_steps: u64, max_bytes: u64) bool;
extern "c" fn guillotine_set_code(handle: ?*EvmHandle, address: ?*const [20]u8, code: ?[*]const u8, code_len: usize) bool;
extern "c" fn guillotine_set_code_tracing(
    handle: ?*EvmHandle,
    address: ?*const [20]u8,
    code: ?[*]const u8,
    code_len: usize,
) bool;
extern "c" fn guillotine_get_nonce(handle: ?*EvmHandle, address: ?*const [20]u8, nonce_out: ?*u64) bool;
extern "c" fn guillotine_get_storage(
    handle: ?*EvmHandle,
    address: ?*const [20]u8,
    key: ?*const [32]u8,
    value_out: ?*[32]u8,
) bool;
extern "c" fn guillotine_call(handle: ?*EvmHandle, params: ?*const CallParams) ?*EvmResult;
extern "c" fn guillotine_call_tracing(handle: ?*EvmHandle, params: ?*const CallParams) ?*EvmResult;
extern "c" fn guillotine_simulate(handle: ?*EvmHandle, params: ?*const CallParams) ?*EvmResult;
extern "c" fn guillotine_free_result(result: ?*EvmResult) void;
extern "c" fn guillotine_dump_state(handle: ?*EvmHandle) ?*StateDumpFFI;
extern "c" fn guillotine_free_state_dump(dump: ?*StateDumpFFI) void;

const zero_word = @as([32]u8, @splat(0));
const caller = @as([19]u8, @splat(0)) ++ [_]u8{0x11};
const contract = @as([19]u8, @splat(0)) ++ [_]u8{0x42};

/// `<opcode>` on the calldata word, returned as one word:
/// PUSH1 0 CALLDATALOAD <opcode> PUSH1 0 MSTORE PUSH1 0x20 PUSH1 0 RETURN.
fn wordQueryCode(opcode: u8) [12]u8 {
    return .{ 0x60, 0x00, 0x35, opcode, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
}

fn blockAt(number: u64) BlockInfoFFI {
    return .{
        .number = number,
        .timestamp = 1_700_000_000,
        .gas_limit = 30_000_000,
        .coinbase = @as([19]u8, @splat(0)) ++ [_]u8{0xcc},
        .base_fee = 0,
        .chain_id = 1,
        .difficulty = 0,
        .prev_randao = zero_word,
    };
}

fn callParams(to: [20]u8, input: []const u8) CallParams {
    return .{
        .caller = caller,
        .to = to,
        .value = zero_word,
        .input = if (input.len == 0) null else input.ptr,
        .input_len = input.len,
        .gas = 1_000_000,
        .call_type = 0,
        .salt = zero_word,
    };
}

fn word(value: u64) [32]u8 {
    var bytes = zero_word;
    std.mem.writeInt(u64, bytes[24..32], value, .big);
    return bytes;
}

/// Run a committed call and return its 32-byte output.
fn callForWord(handle: *EvmHandle, to: [20]u8, input: []const u8) ![32]u8 {
    const params = callParams(to, input);
    const result = guillotine_call(handle, &params) orelse return error.CallReturnedNull;
    defer guillotine_free_result(result);
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 32), result.output_len);
    return result.output[0..32].*;
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, haystack, needle);
}

/// The text of the `"stack":[...]` array of the first trace step whose op is `op`.
fn stackOfStep(trace: []const u8, comptime op: []const u8) ![]const u8 {
    const step = std.mem.indexOf(u8, trace, "\"op\":\"" ++ op ++ "\"") orelse return error.StepMissingFromTrace;
    const marker = "\"stack\":[";
    const open = std.mem.indexOfPos(u8, trace, step, marker) orelse return error.StackMissingFromStep;
    const start = open + marker.len;
    const close = std.mem.indexOfScalarPos(u8, trace, start, ']') orelse return error.StackNotClosed;
    return trace[start..close];
}

test "W3-15: BLOBBASEFEE returns the fee set by guillotine_set_blob_base_fee" {
    guillotine_init();
    const block = blockAt(1000);
    const handle = guillotine_evm_create(&block) orelse return error.EvmCreateFailed;
    defer guillotine_evm_destroy(handle);

    // BLOBBASEFEE PUSH1 0 MSTORE PUSH1 0x20 PUSH1 0 RETURN
    const code = [_]u8{ 0x4a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    try testing.expect(guillotine_set_code(handle, &contract, &code, code.len));

    try testing.expectEqualSlices(u8, &zero_word, &try callForWord(handle, contract, &.{}));

    const fee = word(0x1234_5678_9abc);
    try testing.expect(guillotine_set_blob_base_fee(handle, &fee));
    try testing.expectEqualSlices(u8, &fee, &try callForWord(handle, contract, &.{}));

    // A NULL fee is refused and the fee already set stays.
    try testing.expect(!guillotine_set_blob_base_fee(handle, null));
    try testing.expect(!guillotine_set_blob_base_fee(null, &fee));
    try testing.expectEqualSlices(u8, &fee, &try callForWord(handle, contract, &.{}));

    // The fee belongs to its block: a new block starts at zero.
    try testing.expect(guillotine_set_block_info(handle, &block));
    try testing.expectEqualSlices(u8, &zero_word, &try callForWord(handle, contract, &.{}));
}

test "W3-15: BLOCKHASH returns the hashes set by guillotine_set_block_hash and guillotine_set_block_hashes" {
    guillotine_init();
    const block = blockAt(1000);
    const handle = guillotine_evm_create(&block) orelse return error.EvmCreateFailed;
    defer guillotine_evm_destroy(handle);

    const code = wordQueryCode(0x40);
    try testing.expect(guillotine_set_code(handle, &contract, &code, code.len));

    const hash_999 = @as([32]u8, @splat(0x99));
    const hash_990 = @as([32]u8, @splat(0x90));
    const hash_744 = @as([32]u8, @splat(0x44));

    // Nothing configured: every ancestor reads as zero.
    try testing.expectEqualSlices(u8, &zero_word, &try callForWord(handle, contract, &word(999)));

    try testing.expect(guillotine_set_block_hash(handle, 999, &hash_999));
    try testing.expect(guillotine_set_block_hash(handle, 990, &hash_990));
    try testing.expectEqualSlices(u8, &hash_999, &try callForWord(handle, contract, &word(999)));
    try testing.expectEqualSlices(u8, &hash_990, &try callForWord(handle, contract, &word(990)));
    // An ancestor between two configured ones was never set.
    try testing.expectEqualSlices(u8, &zero_word, &try callForWord(handle, contract, &word(995)));

    // The window is the 256 blocks before the current one.
    try testing.expect(guillotine_set_block_hash(handle, 744, &hash_744));
    try testing.expectEqualSlices(u8, &hash_744, &try callForWord(handle, contract, &word(744)));
    try testing.expect(!guillotine_set_block_hash(handle, 743, &hash_744));
    try testing.expect(!guillotine_set_block_hash(handle, 1000, &hash_744));
    try testing.expect(!guillotine_set_block_hash(handle, 1001, &hash_744));
    try testing.expect(!guillotine_set_block_hash(handle, 999, null));
    // The current block and later ones read as zero whatever is configured.
    try testing.expectEqualSlices(u8, &zero_word, &try callForWord(handle, contract, &word(1000)));
    try testing.expectEqualSlices(u8, &zero_word, &try callForWord(handle, contract, &word(1001)));

    // Replacing the list drops the hashes set one by one. Newest first.
    const list = [_][32]u8{ @as([32]u8, @splat(0xA1)), @as([32]u8, @splat(0xA2)) };
    try testing.expect(guillotine_set_block_hashes(handle, &list, list.len));
    try testing.expectEqualSlices(u8, &list[0], &try callForWord(handle, contract, &word(999)));
    try testing.expectEqualSlices(u8, &list[1], &try callForWord(handle, contract, &word(998)));
    try testing.expectEqualSlices(u8, &zero_word, &try callForWord(handle, contract, &word(990)));

    // A rejected list leaves the current one in place.
    try testing.expect(!guillotine_set_block_hashes(handle, null, 2));
    try testing.expect(!guillotine_set_block_hashes(handle, &list, c_api.max_block_hashes + 1));
    try testing.expectEqualSlices(u8, &list[0], &try callForWord(handle, contract, &word(999)));

    // Ancestor hashes are relative to the block number: a new block clears them.
    try testing.expect(guillotine_set_block_info(handle, &block));
    try testing.expectEqualSlices(u8, &zero_word, &try callForWord(handle, contract, &word(999)));

    try testing.expect(guillotine_set_block_hashes(handle, &list, list.len));
    try testing.expect(guillotine_set_block_hashes(handle, null, 0));
    try testing.expectEqualSlices(u8, &zero_word, &try callForWord(handle, contract, &word(999)));
}

test "W3-15: BLOBHASH returns the hashes set by guillotine_set_blob_hashes" {
    guillotine_init();
    const block = blockAt(1000);
    const handle = guillotine_evm_create(&block) orelse return error.EvmCreateFailed;
    defer guillotine_evm_destroy(handle);

    const code = wordQueryCode(0x49);
    try testing.expect(guillotine_set_code(handle, &contract, &code, code.len));

    try testing.expectEqualSlices(u8, &zero_word, &try callForWord(handle, contract, &word(0)));

    var first = @as([32]u8, @splat(0xB1));
    first[0] = 0x01;
    var second = @as([32]u8, @splat(0xB2));
    second[0] = 0x01;
    const hashes = [_][32]u8{ first, second };
    try testing.expect(guillotine_set_blob_hashes(handle, &hashes, hashes.len));
    try testing.expectEqualSlices(u8, &first, &try callForWord(handle, contract, &word(0)));
    try testing.expectEqualSlices(u8, &second, &try callForWord(handle, contract, &word(1)));
    try testing.expectEqualSlices(u8, &zero_word, &try callForWord(handle, contract, &word(2)));

    // The library copied the hashes; a simulation reads the same ones.
    const index_one = word(1);
    const params = callParams(contract, &index_one);
    const simulated = guillotine_simulate(handle, &params) orelse return error.SimulateReturnedNull;
    defer guillotine_free_result(simulated);
    try testing.expect(simulated.success);
    try testing.expectEqualSlices(u8, &second, simulated.output[0..32]);

    try testing.expect(!guillotine_set_blob_hashes(handle, null, 1));
    try testing.expectEqualSlices(u8, &first, &try callForWord(handle, contract, &word(0)));

    try testing.expect(guillotine_set_blob_hashes(handle, null, 0));
    try testing.expectEqualSlices(u8, &zero_word, &try callForWord(handle, contract, &word(0)));
}

test "W3-15: the access list, authorization list and blob fee cap setters validate their input" {
    guillotine_init();
    const block = blockAt(1000);
    const handle = guillotine_evm_create(&block) orelse return error.EvmCreateFailed;
    defer guillotine_evm_destroy(handle);

    const code = [_]u8{0x00};
    try testing.expect(guillotine_set_code(handle, &contract, &code, code.len));
    const params = callParams(contract, &.{});

    const plain = guillotine_call(handle, &params) orelse return error.CallReturnedNull;
    const plain_gas_left = plain.gas_left;
    try testing.expect(plain.success);
    guillotine_free_result(plain);

    // One address and one storage key cost 2,400 + 1,900 intrinsic gas (EIP-2930).
    const keys = [_][32]u8{word(7)};
    const entries = [_]AccessListEntryFFI{.{
        .address = @as([19]u8, @splat(0)) ++ [_]u8{0x77},
        .storage_keys = &keys,
        .storage_keys_len = keys.len,
    }};
    try testing.expect(guillotine_set_access_list(handle, &entries, entries.len));
    const listed = guillotine_call(handle, &params) orelse return error.CallReturnedNull;
    const listed_gas_left = listed.gas_left;
    try testing.expect(listed.success);
    guillotine_free_result(listed);
    try testing.expectEqual(@as(u64, 4300), plain_gas_left - listed_gas_left);

    // A rejected list leaves the current one in place.
    try testing.expect(!guillotine_set_access_list(handle, null, 1));
    const missing_keys = [_]AccessListEntryFFI{.{
        .address = @as([19]u8, @splat(0)) ++ [_]u8{0x78},
        .storage_keys = null,
        .storage_keys_len = 3,
    }};
    try testing.expect(!guillotine_set_access_list(handle, &missing_keys, missing_keys.len));
    const kept = guillotine_call(handle, &params) orelse return error.CallReturnedNull;
    const kept_gas_left = kept.gas_left;
    guillotine_free_result(kept);
    try testing.expectEqual(listed_gas_left, kept_gas_left);

    try testing.expect(guillotine_set_access_list(handle, null, 0));
    const cleared = guillotine_call(handle, &params) orelse return error.CallReturnedNull;
    const cleared_gas_left = cleared.gas_left;
    guillotine_free_result(cleared);
    try testing.expectEqual(plain_gas_left, cleared_gas_left);

    try testing.expect(!guillotine_set_authorization_list(handle, null, 1));
    try testing.expect(guillotine_set_authorization_list(handle, null, 0));

    const cap = word(1_000_000_000);
    try testing.expect(guillotine_set_max_fee_per_blob_gas(handle, &cap));
    try testing.expect(guillotine_set_max_fee_per_blob_gas(handle, null));
    try testing.expect(!guillotine_set_max_fee_per_blob_gas(null, &cap));
}

test "W3-15: guillotine_reset_touched forgets what calls touched and changes no state" {
    guillotine_init();
    const block = blockAt(1000);
    const handle = guillotine_evm_create(&block) orelse return error.EvmCreateFailed;
    defer guillotine_evm_destroy(handle);

    // PUSH1 0x42 PUSH1 1 SSTORE STOP
    const code = [_]u8{ 0x60, 0x42, 0x60, 0x01, 0x55, 0x00 };
    try testing.expect(guillotine_set_code(handle, &contract, &code, code.len));
    const configured = c_api.test_hooks.observe(handle) orelse return error.HandleNotObservable;
    try testing.expectEqual(@as(usize, 0), configured.transaction_touched);

    const params = callParams(contract, &.{});
    const first = guillotine_call(handle, &params) orelse return error.CallReturnedNull;
    try testing.expect(first.success);
    try testing.expect(first.accessed_storage_len >= 1);
    guillotine_free_result(first);

    const touched = c_api.test_hooks.observe(handle) orelse return error.HandleNotObservable;
    try testing.expect(touched.transaction_touched >= 1);
    try testing.expect(touched.touched_addresses > configured.touched_addresses);
    try testing.expect(touched.touched_storage_slots >= 1);

    try testing.expect(guillotine_reset_touched(handle));
    try testing.expect(!guillotine_reset_touched(null));

    const reset = c_api.test_hooks.observe(handle) orelse return error.HandleNotObservable;
    try testing.expectEqual(@as(usize, 0), reset.transaction_touched);
    try testing.expectEqual(@as(usize, 0), reset.touched_storage_addresses);
    try testing.expectEqual(@as(usize, 0), reset.touched_storage_slots);
    // The account the host configured is still tracked for the state dump.
    try testing.expectEqual(configured.touched_addresses, reset.touched_addresses);

    // No state changed: the stored value and the code are still there.
    var stored = zero_word;
    try testing.expect(guillotine_get_storage(handle, &contract, &word(1), &stored));
    try testing.expectEqualSlices(u8, &word(0x42), &stored);
    const dump = guillotine_dump_state(handle) orelse return error.DumpReturnedNull;
    defer guillotine_free_state_dump(dump);
    var found = false;
    for (dump.accounts[0..dump.accounts_count]) |account| {
        if (!std.mem.eql(u8, &account.address, &contract)) continue;
        found = true;
        try testing.expectEqualSlices(u8, &code, account.code[0..account.code_len]);
    }
    try testing.expect(found);

    // The next call reports its accesses again instead of treating them as known.
    const second = guillotine_call(handle, &params) orelse return error.CallReturnedNull;
    defer guillotine_free_result(second);
    try testing.expect(second.success);
    try testing.expect(second.accessed_storage_len >= 1);
    const again = c_api.test_hooks.observe(handle) orelse return error.HandleNotObservable;
    try testing.expect(again.transaction_touched >= 1);
    try testing.expect(again.touched_storage_slots >= 1);
}

test "W3-15: trace limits truncate the structLogs and leave the execution result unchanged" {
    guillotine_init();
    const block = blockAt(1000);
    const handle = guillotine_evm_create_tracing(&block) orelse return error.EvmCreateFailed;
    defer guillotine_evm_destroy_tracing(handle);

    // PUSH1 2 PUSH1 3 ADD PUSH1 0 MSTORE PUSH1 0x20 PUSH1 0 RETURN: eight instructions.
    const code = [_]u8{ 0x60, 0x02, 0x60, 0x03, 0x01, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    try testing.expect(guillotine_set_code_tracing(handle, &contract, &code, code.len));
    const params = callParams(contract, &.{});

    const full = guillotine_call_tracing(handle, &params) orelse return error.CallReturnedNull;
    defer guillotine_free_result(full);
    try testing.expect(full.success);
    const full_trace = full.trace_json[0..full.trace_json_len];
    try testing.expectEqual(@as(usize, 8), countOccurrences(full_trace, "\"pc\":"));
    try testing.expect(std.mem.endsWith(u8, full_trace, "],\"truncated\":false,\"truncationReason\":\"none\"}"));

    const Limit = struct { max_steps: u64, max_bytes: u64, kept: ?usize, reason: []const u8 };
    const limits = [_]Limit{
        .{ .max_steps = 3, .max_bytes = c_api.trace_unlimited, .kept = 3, .reason = "max_steps" },
        .{ .max_steps = 1, .max_bytes = c_api.trace_unlimited, .kept = 1, .reason = "max_steps" },
        .{ .max_steps = 0, .max_bytes = c_api.trace_unlimited, .kept = 0, .reason = "max_steps" },
        .{ .max_steps = c_api.trace_unlimited, .max_bytes = 1, .kept = 0, .reason = "max_bytes" },
        .{ .max_steps = c_api.trace_unlimited, .max_bytes = 0, .kept = 0, .reason = "max_bytes" },
    };
    for (limits) |limit| {
        try testing.expect(guillotine_set_trace_limits(handle, limit.max_steps, limit.max_bytes));
        const cut = guillotine_call_tracing(handle, &params) orelse return error.CallReturnedNull;
        defer guillotine_free_result(cut);

        // Truncation never reaches the execution result.
        try testing.expect(cut.success);
        try testing.expectEqual(full.gas_left, cut.gas_left);
        try testing.expectEqualSlices(u8, full.output[0..full.output_len], cut.output[0..cut.output_len]);

        const trace = cut.trace_json[0..cut.trace_json_len];
        try testing.expect(std.mem.startsWith(u8, trace, "{\"structLogs\":["));
        var suffix_buffer: [96]u8 = undefined;
        const suffix = try std.fmt.bufPrint(
            &suffix_buffer,
            "],\"truncated\":true,\"truncationReason\":\"{s}\"}}",
            .{limit.reason},
        );
        try testing.expect(std.mem.endsWith(u8, trace, suffix));
        if (limit.kept) |kept| try testing.expectEqual(kept, countOccurrences(trace, "\"pc\":"));
        // The kept steps are a prefix of the full trace.
        const body = trace[0 .. trace.len - suffix.len];
        try testing.expect(std.mem.startsWith(u8, full_trace, body));
    }

    // Lifting both bounds captures the whole execution again.
    try testing.expect(guillotine_set_trace_limits(handle, c_api.trace_unlimited, c_api.trace_unlimited));
    const lifted = guillotine_call_tracing(handle, &params) orelse return error.CallReturnedNull;
    defer guillotine_free_result(lifted);
    try testing.expectEqualSlices(u8, full_trace, lifted.trace_json[0..lifted.trace_json_len]);

    // Only a structLogs handle has a capture budget.
    const plain = guillotine_evm_create(&block) orelse return error.EvmCreateFailed;
    defer guillotine_evm_destroy(plain);
    try testing.expect(!guillotine_set_trace_limits(plain, 1, 1));
    try testing.expect(!guillotine_set_trace_limits(null, 1, 1));
}

test "W3-4: guillotine_simulate leaves origin, return data, touched sets, state and the dump unchanged" {
    guillotine_init();
    const block = blockAt(1000);
    const handle = guillotine_evm_create(&block) orelse return error.EvmCreateFailed;
    defer guillotine_evm_destroy(handle);

    // CALLER PUSH1 1 SSTORE PUSH1 0x20 PUSH1 0 RETURN: stores the caller, returns a word.
    const code = [_]u8{ 0x33, 0x60, 0x01, 0x55, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    try testing.expect(guillotine_set_code(handle, &contract, &code, code.len));

    // A committed call first, so that return data and the touched sets are not empty.
    const params = callParams(contract, &.{});
    const committed = guillotine_call(handle, &params) orelse return error.CallReturnedNull;
    try testing.expect(committed.success);
    guillotine_free_result(committed);

    const before = c_api.test_hooks.observe(handle) orelse return error.HandleNotObservable;
    const dump_before = guillotine_dump_state(handle) orelse return error.DumpReturnedNull;
    defer guillotine_free_state_dump(dump_before);

    // The same call from another sender would overwrite the slot and bump a nonce.
    const other = @as([19]u8, @splat(0)) ++ [_]u8{0x33};
    var simulated_params = params;
    simulated_params.caller = other;
    for (0..3) |_| {
        const simulated = guillotine_simulate(handle, &simulated_params) orelse return error.SimulateReturnedNull;
        defer guillotine_free_result(simulated);
        try testing.expect(simulated.success);
        try testing.expectEqual(@as(usize, 32), simulated.output_len);
    }

    const after = c_api.test_hooks.observe(handle) orelse return error.HandleNotObservable;
    try testing.expectEqualDeep(before, after);

    var stored = zero_word;
    try testing.expect(guillotine_get_storage(handle, &contract, &word(1), &stored));
    try testing.expectEqualSlices(u8, &word(0x11), &stored);
    var nonce: u64 = 99;
    try testing.expect(guillotine_get_nonce(handle, &other, &nonce));
    try testing.expectEqual(@as(u64, 0), nonce);

    const dump_after = guillotine_dump_state(handle) orelse return error.DumpReturnedNull;
    defer guillotine_free_state_dump(dump_after);
    try testing.expectEqual(dump_before.accounts_count, dump_after.accounts_count);
    for (dump_before.accounts[0..dump_before.accounts_count]) |expected| {
        var matched = false;
        for (dump_after.accounts[0..dump_after.accounts_count]) |actual| {
            if (!std.mem.eql(u8, &expected.address, &actual.address)) continue;
            matched = true;
            try testing.expectEqualSlices(u8, &expected.balance, &actual.balance);
            try testing.expectEqual(expected.nonce, actual.nonce);
            try testing.expectEqualSlices(u8, expected.code[0..expected.code_len], actual.code[0..actual.code_len]);
            try testing.expectEqual(expected.storage_count, actual.storage_count);
        }
        try testing.expect(matched);
    }
}

test "C ABI tracing: a tracing handle returns structLogs and a plain handle returns none" {
    guillotine_init();
    const block = blockAt(1000);
    // PUSH1 2 PUSH1 3 ADD STOP
    const code = [_]u8{ 0x60, 0x02, 0x60, 0x03, 0x01, 0x00 };
    const params = callParams(contract, &.{});

    const plain = guillotine_evm_create(&block) orelse return error.EvmCreateFailed;
    defer guillotine_evm_destroy(plain);
    try testing.expect(guillotine_set_code(plain, &contract, &code, code.len));
    const untraced = guillotine_call(plain, &params) orelse return error.CallReturnedNull;
    defer guillotine_free_result(untraced);
    try testing.expect(untraced.success);
    try testing.expectEqual(@as(usize, 0), untraced.trace_json_len);

    const tracing = guillotine_evm_create_tracing(&block) orelse return error.EvmCreateFailed;
    defer guillotine_evm_destroy_tracing(tracing);
    try testing.expect(guillotine_set_code_tracing(tracing, &contract, &code, code.len));
    const traced = guillotine_call_tracing(tracing, &params) orelse return error.CallReturnedNull;
    defer guillotine_free_result(traced);
    try testing.expect(traced.success);
    try testing.expectEqual(untraced.gas_left, traced.gas_left);

    const trace = traced.trace_json[0..traced.trace_json_len];
    try testing.expect(std.mem.startsWith(u8, trace, "{\"structLogs\":[{\"pc\":0,\"op\":\"PUSH1\""));
    try testing.expectEqual(@as(usize, 4), countOccurrences(trace, "\"pc\":"));
    try testing.expectEqual(@as(usize, 2), countOccurrences(trace, "\"op\":\"PUSH1\""));
    try testing.expectEqual(@as(usize, 1), countOccurrences(trace, "\"op\":\"ADD\""));
    try testing.expectEqual(@as(usize, 1), countOccurrences(trace, "\"op\":\"STOP\""));
    // ADD sees both operands, top first.
    try testing.expectEqualStrings("\"0x3\",\"0x2\"", try stackOfStep(trace, "ADD"));
    try testing.expectEqualStrings("\"0x5\"", try stackOfStep(trace, "STOP"));
    try testing.expect(std.mem.endsWith(u8, trace, "],\"truncated\":false,\"truncationReason\":\"none\"}"));
}

test "C ABI tracing: a reverting call still returns its trace" {
    guillotine_init();
    const block = blockAt(1000);
    const tracing = guillotine_evm_create_tracing(&block) orelse return error.EvmCreateFailed;
    defer guillotine_evm_destroy_tracing(tracing);

    // PUSH1 0xAA PUSH1 0 MSTORE8 PUSH1 1 PUSH1 0 REVERT: reverts with one byte.
    const code = [_]u8{ 0x60, 0xaa, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xfd };
    try testing.expect(guillotine_set_code_tracing(tracing, &contract, &code, code.len));
    const params = callParams(contract, &.{});
    const result = guillotine_call_tracing(tracing, &params) orelse return error.CallReturnedNull;
    defer guillotine_free_result(result);

    try testing.expect(!result.success);
    try testing.expectEqualSlices(u8, &.{0xaa}, result.output[0..result.output_len]);
    const trace = result.trace_json[0..result.trace_json_len];
    try testing.expectEqual(@as(usize, 6), countOccurrences(trace, "\"pc\":"));
    try testing.expectEqual(@as(usize, 1), countOccurrences(trace, "\"op\":\"REVERT\""));
    try testing.expectEqualStrings("\"0x0\",\"0x1\"", try stackOfStep(trace, "REVERT"));
    try testing.expect(std.mem.endsWith(u8, trace, "],\"truncated\":false,\"truncationReason\":\"none\"}"));
}

test "C ABI tracing: a CREATE returns the new address and the init code's trace" {
    guillotine_init();
    const block = blockAt(1000);
    const tracing = guillotine_evm_create_tracing(&block) orelse return error.EvmCreateFailed;
    defer guillotine_evm_destroy_tracing(tracing);

    // Init code PUSH1 0 PUSH1 0 RETURN: deploys empty runtime code.
    const init_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xf3 };
    var params = callParams(contract, &init_code);
    params.call_type = 4;
    const result = guillotine_call_tracing(tracing, &params) orelse return error.CallReturnedNull;
    defer guillotine_free_result(result);

    try testing.expect(result.success);
    try testing.expect(result.has_created_address);
    try testing.expect(!std.mem.eql(u8, &result.created_address, &@as([20]u8, @splat(0))));
    const trace = result.trace_json[0..result.trace_json_len];
    try testing.expectEqual(@as(usize, 3), countOccurrences(trace, "\"pc\":"));
    try testing.expectEqual(@as(usize, 1), countOccurrences(trace, "\"op\":\"RETURN\""));
    try testing.expect(std.mem.endsWith(u8, trace, "],\"truncated\":false,\"truncationReason\":\"none\"}"));

    // The sender's nonce moved, so the same CREATE now lands on another address.
    const again = guillotine_call_tracing(tracing, &params) orelse return error.CallReturnedNull;
    defer guillotine_free_result(again);
    try testing.expect(again.success);
    try testing.expect(!std.mem.eql(u8, &result.created_address, &again.created_address));
}

test "C ABI tracing: DUP, SWAP and POP steps report the exact stack" {
    guillotine_init();
    const block = blockAt(1000);
    const tracing = guillotine_evm_create_tracing(&block) orelse return error.EvmCreateFailed;
    defer guillotine_evm_destroy_tracing(tracing);

    // PUSH1 1 PUSH1 2 PUSH1 3 DUP3 SWAP1 POP STOP
    const code = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x60, 0x03, 0x82, 0x90, 0x50, 0x00 };
    try testing.expect(guillotine_set_code_tracing(tracing, &contract, &code, code.len));
    const params = callParams(contract, &.{});
    const result = guillotine_call_tracing(tracing, &params) orelse return error.CallReturnedNull;
    defer guillotine_free_result(result);

    try testing.expect(result.success);
    const trace = result.trace_json[0..result.trace_json_len];
    try testing.expectEqual(@as(usize, 7), countOccurrences(trace, "\"pc\":"));
    // Each stack is the one before its instruction runs, top first.
    try testing.expectEqualStrings("\"0x3\",\"0x2\",\"0x1\"", try stackOfStep(trace, "DUP3"));
    try testing.expectEqualStrings("\"0x1\",\"0x3\",\"0x2\",\"0x1\"", try stackOfStep(trace, "SWAP1"));
    try testing.expectEqualStrings("\"0x3\",\"0x1\",\"0x2\",\"0x1\"", try stackOfStep(trace, "POP"));
    try testing.expectEqualStrings("\"0x1\",\"0x2\",\"0x1\"", try stackOfStep(trace, "STOP"));
}
