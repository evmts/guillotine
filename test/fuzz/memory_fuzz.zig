//! Stateful Memory & Quadratic Gas Expansion Model-Checking Fuzz Tests
//!
//! Verifies:
//! 1. Byte-for-byte equivalence against a flat reference byte array across
//!    set_data_evm, set_u256_evm, set_byte_evm, get_u256_evm, get_slice, copy_within (overlapping).
//! 2. Exact Yellow Paper memory expansion gas formula:
//!    C_mem(a) = 3*a + floor(a^2 / 512), where a = ceil(size / 32)
//!    including gas cache invalidation when child frames expand the shared buffer!
//! 3. Nested child frame checkpoint isolation (`init_child`) and parent integrity.
//! 4. Memory limit enforcement (`MemoryOverflow`) and `OutOfBounds` on unallocated reads.
//! 5. Expansion costs of any size up to 2^64 - 1 bytes, and the overflow-safe gas charge
//!    (`verified_ops.chargeGasChecked`) for `i32` and `i64` gas, against wide integers.

const std = @import("std");
const evm = @import("evm");
const fuzz_alloc = @import("fuzz_alloc.zig");

const TestMemory = evm.Memory(.{
    .initial_capacity = 64,
    .memory_limit = 64 * 1024,
    .owned = true,
});

fn wordAlign(n: usize) usize {
    return ((n + 31) / 32) * 32;
}

fn referenceMemoryCost(byte_size: u64) u64 {
    const words = (byte_size + 31) / 32;
    return 3 * words + (words * words) / 512;
}

fn ensureRefCapacity(model: *std.ArrayList(u8), allocator: std.mem.Allocator, new_size: usize) !void {
    if (new_size <= model.items.len) return;
    const old_len = model.items.len;
    try model.resize(allocator, new_size);
    @memset(model.items[old_len..new_size], 0);
}

pub fn fuzzMemoryModel(_: void, input: []const u8) !void {
    const allocator = fuzz_alloc.get();
    var mem = try TestMemory.init(allocator);
    defer mem.deinit(allocator);

    var model = std.ArrayList(u8).empty;
    defer model.deinit(allocator);

    var i: usize = 0;
    while (i + 3 <= input.len) : (i += 3) {
        const op = input[i];
        const raw_off: u32 = (@as(u32, input[i + 1]) << 4) | (@as(u32, input[i + 2]) & 0x0f);
        const param = input[i + 2];

        switch (op % 9) {
            0 => { // set_byte_evm + expansion gas check
                const off = raw_off % 4096;
                const aligned_end = wordAlign(@as(usize, off) + 1);
                const expected_gas = if (aligned_end > model.items.len)
                    referenceMemoryCost(aligned_end) - referenceMemoryCost(model.items.len)
                else
                    0;
                const actual_gas = mem.get_expansion_cost(@intCast(aligned_end));
                try std.testing.expectEqual(expected_gas, actual_gas);

                try mem.set_byte_evm(allocator, off, param);
                try ensureRefCapacity(&model, allocator, aligned_end);
                model.items[off] = param;
            },
            1 => { // set_u256_evm + expansion gas check
                const off = raw_off % 4096;
                const aligned_end = wordAlign(@as(usize, off) + 32);
                const expected_gas = if (aligned_end > model.items.len)
                    referenceMemoryCost(aligned_end) - referenceMemoryCost(model.items.len)
                else
                    0;
                try std.testing.expectEqual(expected_gas, mem.get_expansion_cost(@intCast(aligned_end)));

                const val: u256 = (@as(u256, param) << 248) | (@as(u256, op) << 128) | @as(u256, off);
                try mem.set_u256_evm(allocator, off, val);
                try ensureRefCapacity(&model, allocator, aligned_end);
                std.mem.writeInt(u256, model.items[off..][0..32], val, .big);
            },
            2 => { // get_u256_evm
                const off = raw_off % 4096;
                const aligned_end = wordAlign(@as(usize, off) + 32);
                const actual = try mem.get_u256_evm(allocator, off);
                try ensureRefCapacity(&model, allocator, aligned_end);
                const expected = std.mem.readInt(u256, model.items[off..][0..32], .big);
                try std.testing.expectEqual(expected, actual);
            },
            3 => { // set_data_evm (variable length, exercises SIMD & scalar paths)
                const off = raw_off % 2048;
                const data_len: usize = @as(usize, param % 96) + 1;
                var data_buf: [96]u8 = undefined;
                for (0..data_len) |k| {
                    data_buf[k] = param ^ @as(u8, @truncate(k *% 31 +% op));
                }
                const aligned_end = wordAlign(@as(usize, off) + data_len);
                try mem.set_data_evm(allocator, off, data_buf[0..data_len]);
                try ensureRefCapacity(&model, allocator, aligned_end);
                @memcpy(model.items[off .. off + data_len], data_buf[0..data_len]);
            },
            4 => { // Overlapping MCOPY-style read+write or clear()
                if (param < 4) {
                    mem.clear();
                    model.clearRetainingCapacity();
                } else {
                    const dst = raw_off % 1024;
                    const src = (@as(u32, param) * 7) % 1024;
                    const copy_len: usize = @as(usize, (op >> 3) % 64) + 1;
                    const max_end = wordAlign(@max(@as(usize, dst) + copy_len, @as(usize, src) + copy_len));
                    try mem.ensure_capacity(allocator, @intCast(max_end));
                    try ensureRefCapacity(&model, allocator, max_end);

                    // Copy via temp buffer (matches handlers_memory MCOPY pattern)
                    var tmp: [64]u8 = undefined;
                    const src_slice = try mem.get_slice(src, @intCast(copy_len));
                    @memcpy(tmp[0..copy_len], src_slice);
                    try mem.set_data_evm(allocator, dst, tmp[0..copy_len]);

                    var ref_tmp: [64]u8 = undefined;
                    @memcpy(ref_tmp[0..copy_len], model.items[src .. src + copy_len]);
                    @memcpy(model.items[dst .. dst + copy_len], ref_tmp[0..copy_len]);
                }
            },
            5 => { // get_slice in-bounds and out-of-bounds
                const off = raw_off % 2048;
                const req_len: u32 = @as(u32, param % 64);
                if (@as(usize, off) + @as(usize, req_len) > model.items.len) {
                    try std.testing.expectError(evm.MemoryError.OutOfBounds, mem.get_slice(off, req_len));
                } else {
                    const actual = try mem.get_slice(off, req_len);
                    try std.testing.expectEqualSlices(u8, model.items[off .. off + req_len], actual);
                }
            },
            6 => { // Child frame checkpoint isolation!
                const saved_parent_len = model.items.len;
                var child = try mem.init_child();
                defer child.deinit(allocator);
                try std.testing.expectEqual(@as(usize, 0), child.size());

                const child_off: u32 = (param % 128);
                const child_val: u256 = (@as(u256, param) << 120) ^ 0xdeadbeef;
                try child.set_u256_evm(allocator, child_off, child_val);
                try std.testing.expectEqual(child_val, try child.get_u256_evm(allocator, child_off));

                // Restore shared buffer length as EVM frame teardown does
                mem.buffer_ptr.items.len = saved_parent_len;

                // Parent's memory contents and expansion gas must remain 100% intact!
                try std.testing.expectEqual(saved_parent_len, mem.size());
                if (saved_parent_len > 0) {
                    const parent_slice = try mem.get_slice(0, @intCast(saved_parent_len));
                    try std.testing.expectEqualSlices(u8, model.items, parent_slice);
                }
            },
            7 => { // Memory limit enforcement
                const over_limit: u32 = @intCast(TestMemory.MEMORY_LIMIT + 32);
                try std.testing.expectError(evm.MemoryError.MemoryOverflow, mem.ensure_capacity(allocator, over_limit));
            },
            else => { // clear for reuse (occasional)
                if (param < 12) {
                    mem.clear();
                    model.clearRetainingCapacity();
                }
            },
        }

        // Global invariant: size and every byte match reference model
        try std.testing.expectEqual(model.items.len, mem.size());
        if (model.items.len > 0) {
            const full_slice = try mem.get_slice(0, @intCast(model.items.len));
            try std.testing.expectEqualSlices(u8, model.items, full_slice);
        }
    }
}

pub fn fuzzMemoryGasFormula(_: void, input: []const u8) !void {
    if (input.len < 8) return;
    const allocator = fuzz_alloc.get();
    var mem = try TestMemory.init(allocator);
    defer mem.deinit(allocator);

    const a = std.mem.readInt(u32, input[0..4], .little) % 32768;
    const b = std.mem.readInt(u32, input[4..8], .little) % 32768;

    // Monotonicity & exactness of two-step expansion: cost(0->a) + cost(a->max(a,b)) == cost(0->max(a,b))
    const a_aligned: u32 = @intCast(wordAlign(a));
    const b_aligned: u32 = @intCast(wordAlign(b));
    const max_aligned = @max(a_aligned, b_aligned);

    const cost_a = mem.get_expansion_cost(a_aligned);
    try std.testing.expectEqual(referenceMemoryCost(a_aligned), cost_a);

    try mem.ensure_capacity(allocator, a_aligned);
    const cost_b_after_a = mem.get_expansion_cost(b_aligned);
    try std.testing.expectEqual(referenceMemoryCost(max_aligned) - referenceMemoryCost(a_aligned), cost_b_after_a);
    try std.testing.expectEqual(referenceMemoryCost(max_aligned), cost_a + cost_b_after_a);
}

/// A memory whose limit is the largest the configuration allows, so expansion costs
/// range from 0 to far above what any gas type holds.
const HugeMemory = evm.Memory(.{ .initial_capacity = 64, .memory_limit = std.math.maxInt(u32) });

/// Expansion cost of `byte_size` bytes from empty memory, in integers that cannot
/// overflow. Memory.get_expansion_cost reports `maxInt(u64)` when the size is past
/// 134,217,727 words or cannot be rounded up to a word.
fn referenceExpansionCost(byte_size: u64) u64 {
    const words: u128 = (@as(u128, byte_size) + 31) / 32;
    if (words > 134_217_727) return std.math.maxInt(u64);
    return @intCast(3 * words + (words * words) / 512);
}

/// `chargeGasChecked` in integers wide enough for every input.
fn referenceCharge(gas: i128, cost: u64) ?i128 {
    if (gas < 0 or @as(i128, cost) > gas) return null;
    return gas - cost;
}

/// Huge memory expansion against `i32` and `i64` gas. The input picks a size up to
/// 2^64 - 1, a second cost and a gas balance for each gas type; every result is
/// compared with wide-integer arithmetic. A cost above `maxInt(GasType)` must be
/// refused, never narrowed.
pub fn fuzzHugeExpansionAndGasCharge(_: void, input: []const u8) !void {
    if (input.len < 32) return;
    const allocator = fuzz_alloc.get();
    var mem = try HugeMemory.init(allocator);
    defer mem.deinit(allocator);

    const raw_size = std.mem.readInt(u64, input[0..8], .little);
    // Half of the inputs land in the range the EVM can address (up to 4 GiB), where
    // the cost crosses maxInt(i32) at about 32 MiB; the rest go anywhere in u64.
    const size: u64 = if (input[31] & 1 == 0) raw_size % (@as(u64, 1) << 33) else raw_size;
    const extra = std.mem.readInt(u64, input[8..16], .little) >> @intCast(input[30] & 63);
    const gas64: i64 = @bitCast(std.mem.readInt(u64, input[16..24], .little));
    const gas32: i32 = @bitCast(std.mem.readInt(u32, input[24..28], .little));

    const cost = mem.get_expansion_cost(std.math.cast(usize, size) orelse std.math.maxInt(usize));
    try std.testing.expectEqual(referenceExpansionCost(size), cost);

    // Composite cost, as RETURN/REVERT/*COPY/LOG/MCOPY/CALL build it.
    const total = evm.verified_ops.saturatingGasSum(cost, extra);
    const wide_total: u128 = @as(u128, cost) + extra;
    try std.testing.expectEqual(@as(u64, @intCast(@min(wide_total, std.math.maxInt(u64)))), total);

    for ([_]u64{ cost, extra, total }) |charge| {
        const paid64 = evm.verified_ops.chargeGasChecked(i64, gas64, charge);
        const want64 = referenceCharge(gas64, charge);
        try std.testing.expectEqual(want64 == null, paid64 == null);
        if (paid64) |left| {
            try std.testing.expectEqual(want64.?, @as(i128, left));
            try std.testing.expect(left >= 0 and left <= gas64);
        }
        const paid32 = evm.verified_ops.chargeGasChecked(i32, gas32, charge);
        const want32 = referenceCharge(gas32, charge);
        try std.testing.expectEqual(want32 == null, paid32 == null);
        if (paid32) |left| {
            try std.testing.expectEqual(want32.?, @as(i128, left));
            try std.testing.expect(left >= 0 and left <= gas32);
        }
        // A frame holding the most gas its type allows pays exactly when the cost fits.
        try std.testing.expectEqual(charge <= std.math.maxInt(i32), evm.verified_ops.chargeGasChecked(i32, std.math.maxInt(i32), charge) != null);
        try std.testing.expectEqual(charge <= std.math.maxInt(i64), evm.verified_ops.chargeGasChecked(i64, std.math.maxInt(i64), charge) != null);
    }
}

const gas_charge_corpus: []const []const u8 = &.{
    // 32 MiB: 2,150,629,376 gas, the first cost above maxInt(i32), against full i32 gas.
    &([_]u8{ 0x00, 0x00, 0x00, 0x02, 0, 0, 0, 0 } ++ @as([8]u8, @splat(0)) ++ @as([8]u8, @splat(0x7f)) ++ [_]u8{ 0xff, 0xff, 0xff, 0x7f } ++ [_]u8{ 0, 0, 0, 0 }),
    // 64 MiB with a 34,600 gas extra.
    &([_]u8{ 0x00, 0x00, 0x00, 0x04, 0, 0, 0, 0 } ++ [_]u8{ 0x28, 0x87, 0, 0, 0, 0, 0, 0 } ++ @as([8]u8, @splat(0x7f)) ++ [_]u8{ 0xff, 0xff, 0xff, 0x7f } ++ [_]u8{ 0, 0, 0, 0 }),
    // 2^64 - 1 bytes: the cost saturates, and so does every sum with it.
    &(@as([8]u8, @splat(0xff)) ++ @as([8]u8, @splat(0xff)) ++ @as([8]u8, @splat(0x7f)) ++ [_]u8{ 0xff, 0xff, 0xff, 0x7f } ++ [_]u8{ 0, 0, 0, 1 }),
    // 4 GiB exactly, the largest addressable size.
    &([_]u8{ 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0 } ++ @as([8]u8, @splat(1)) ++ @as([8]u8, @splat(0x10)) ++ [_]u8{ 1, 0, 0, 0 } ++ [_]u8{ 0, 0, 3, 0 }),
    // Negative gas of both types.
    &([_]u8{ 0x20, 0, 0, 0, 0, 0, 0, 0 } ++ @as([8]u8, @splat(0)) ++ @as([8]u8, @splat(0xff)) ++ [_]u8{ 0xff, 0xff, 0xff, 0xff } ++ [_]u8{ 0, 0, 0, 0 }),
    // A small expansion a small balance pays for exactly: 32 bytes cost 3 gas.
    &([_]u8{ 0x20, 0, 0, 0, 0, 0, 0, 0 } ++ @as([8]u8, @splat(0)) ++ [_]u8{ 3, 0, 0, 0, 0, 0, 0, 0 } ++ [_]u8{ 3, 0, 0, 0 } ++ [_]u8{ 0, 0, 0, 0 }),
};

const seed_corpus: []const []const u8 = &.{
    &.{},
    &.{ 0, 0, 0xaa, 1, 2, 0xbb, 2, 0, 0, 4, 1, 5, 6, 0, 0x33 },
    &.{ 3, 0, 64, 4, 1, 2, 4, 2, 1, 5, 0, 32, 7, 0, 0 },
    &.{ 1, 0, 1, 6, 0, 0x20, 1, 4, 2, 8, 0, 0, 2, 0, 0 },
    &.{ 0x00, 0x01, 0x00, 0x00, 0x20, 0x02, 0x00, 0x00 },
};

test "fuzz memory stateful model checker and child checkpoints" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzMemoryModel), .{ .corpus = seed_corpus });
}

test "fuzz huge memory expansion and overflow-safe gas charging for i32 and i64 gas" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzHugeExpansionAndGasCharge), .{ .corpus = gas_charge_corpus });
}

test "fuzz memory quadratic gas expansion exactness and monotonicity" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzMemoryGasFormula), .{ .corpus = seed_corpus });
}
