const std = @import("std");
const primitives = @import("primitives");
const MinimalEvm = @import("evm").tracer.MinimalEvm;
const types = @import("types.zig");
const Account = @import("evm").Account;

const Address = primitives.Address;
const Allocator = std.mem.Allocator;

/// Result of comparing states
pub const ComparisonResult = struct {
    const Self = @This();

    success: bool,
    mismatches: []const Mismatch,

    pub fn deinit(self: *Self, allocator: Allocator) void {
        allocator.free(self.mismatches);
    }
};

/// Description of a state mismatch
pub const Mismatch = struct {
    address: Address,
    field: Field,
    expected: []const u8,
    actual: []const u8,

    pub const Field = enum {
        balance,
        nonce,
        code,
        storage_slot,
    };
};

/// Compare EVM state with expected post state
pub fn compareState(
    allocator: Allocator,
    evm: anytype,
    expected_state: std.json.Value,
) !ComparisonResult {
    var mismatches = try std.ArrayList(Mismatch).initCapacity(allocator, 10);
    defer mismatches.deinit(allocator);

    const state_obj = expected_state.object;
    var it = state_obj.iterator();
    while (it.next()) |entry| {
        const address_str = entry.key_ptr.*;
        const address = try primitives.Address.from_hex(address_str);
        const expected_account = entry.value_ptr.*.object;

        // Compare balance
        if (expected_account.get("balance")) |expected_balance_val| {
            const expected_balance = try primitives.Hex.hex_to_u256(expected_balance_val.string);
            const actual_balance = evm.get_balance(address);

            if (expected_balance != actual_balance) {
                var expected_buf: [78]u8 = undefined;
                var actual_buf: [78]u8 = undefined;
                const expected_str = try std.fmt.bufPrint(&expected_buf, "0x{x}", .{expected_balance});
                const actual_str = try std.fmt.bufPrint(&actual_buf, "0x{x}", .{actual_balance});

                try mismatches.append(allocator, .{
                    .address = address,
                    .field = .balance,
                    .expected = try allocator.dupe(u8, expected_str),
                    .actual = try allocator.dupe(u8, actual_str),
                });
            }
        }

        // Compare nonce
        if (expected_account.get("nonce")) |expected_nonce_val| {
            const expected_nonce = try primitives.Hex.hex_to_u64(expected_nonce_val.string);
            const actual_nonce = getNonce(evm, address);

            if (expected_nonce != actual_nonce) {
                var expected_buf: [20]u8 = undefined;
                var actual_buf: [20]u8 = undefined;
                const expected_str = try std.fmt.bufPrint(&expected_buf, "0x{x}", .{expected_nonce});
                const actual_str = try std.fmt.bufPrint(&actual_buf, "0x{x}", .{actual_nonce});

                try mismatches.append(allocator, .{
                    .address = address,
                    .field = .nonce,
                    .expected = try allocator.dupe(u8, expected_str),
                    .actual = try allocator.dupe(u8, actual_str),
                });
            }
        }

        // Compare code
        if (expected_account.get("code")) |expected_code_val| {
            const expected_code = try primitives.Hex.from_hex(allocator, expected_code_val.string);
            defer allocator.free(expected_code);

            const actual_code = evm.get_code(address);

            if (!std.mem.eql(u8, expected_code, actual_code)) {
                var expected_buf = try std.ArrayList(u8).initCapacity(allocator, expected_code.len * 2 + 2);
                defer expected_buf.deinit(allocator);
                var actual_buf = try std.ArrayList(u8).initCapacity(allocator, actual_code.len * 2 + 2);
                defer actual_buf.deinit(allocator);

                try expected_buf.appendSlice(allocator, "0x");
                for (expected_code) |b| {
                    try std.fmt.format(expected_buf.writer(allocator), "{x:0>2}", .{b});
                }
                try actual_buf.appendSlice(allocator, "0x");
                for (actual_code) |b| {
                    try std.fmt.format(actual_buf.writer(allocator), "{x:0>2}", .{b});
                }

                try mismatches.append(allocator, .{
                    .address = address,
                    .field = .code,
                    .expected = try allocator.dupe(u8, expected_buf.items),
                    .actual = try allocator.dupe(u8, actual_buf.items),
                });
            }
        }

        // Compare storage
        if (expected_account.get("storage")) |expected_storage_val| {
            const expected_storage = expected_storage_val.object;
            var storage_it = expected_storage.iterator();
            while (storage_it.next()) |storage_entry| {
                const slot_str = storage_entry.key_ptr.*;
                const expected_value_str = storage_entry.value_ptr.*.string;

                const slot = try primitives.Hex.hex_to_u256(slot_str);
                const expected_value = try primitives.Hex.hex_to_u256(expected_value_str);
                const actual_value = evm.get_storage(address, slot);

                if (expected_value != actual_value) {
                    var expected_buf: [78]u8 = undefined;
                    var actual_buf: [78]u8 = undefined;
                    const expected_formatted = try std.fmt.bufPrint(&expected_buf, "slot 0x{x}: 0x{x}", .{ slot, expected_value });
                    const actual_formatted = try std.fmt.bufPrint(&actual_buf, "slot 0x{x}: 0x{x}", .{ slot, actual_value });

                    try mismatches.append(allocator, .{
                        .address = address,
                        .field = .storage_slot,
                        .expected = try allocator.dupe(u8, expected_formatted),
                        .actual = try allocator.dupe(u8, actual_formatted),
                    });
                }
            }
        }
    }

    const mismatch_slice = try mismatches.toOwnedSlice(allocator);
    return ComparisonResult{
        .success = mismatch_slice.len == 0,
        .mismatches = mismatch_slice,
    };
}

/// Get nonce from EVM (handles both MinimalEvm and MainEvm)
fn getNonce(evm: anytype, address: Address) u64 {
    const PtrType = @TypeOf(evm);
    const EvmType = switch (@typeInfo(PtrType)) {
        .pointer => |ptr_info| ptr_info.child,
        else => PtrType,
    };
    if (@hasDecl(EvmType, "get_nonce")) {
        // MinimalEvm has get_nonce method
        return evm.get_nonce(address);
    } else {
        // MainEvm (Guillotine) - get account from database and extract nonce
        const account = evm.database.get_account(address.bytes) catch {
            return 0;
        } orelse Account.zero();

        return account.nonce;
    }
}
