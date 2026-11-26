const std = @import("std");
const evm = @import("evm");
const testing = std.testing;
const primitives = @import("voltaire");
const Address = primitives.Address;

// Custom allocator that can simulate allocation failures
const FailingAllocator = struct {
    parent_allocator: std.mem.Allocator,
    should_fail: bool,
    allocation_count: usize,
    fail_after_n: usize,

    const Self = @This();

    pub fn init(parent: std.mem.Allocator) Self {
        return .{
            .parent_allocator = parent,
            .should_fail = false,
            .allocation_count = 0,
            .fail_after_n = std.math.maxInt(usize),
        };
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.allocation_count += 1;

        if (self.should_fail or self.allocation_count > self.fail_after_n) {
            return null;
        }

        return self.parent_allocator.rawAlloc(len, ptr_align, ret_addr);
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.parent_allocator.rawResize(buf, buf_align, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.parent_allocator.rawFree(buf, buf_align, ret_addr);
    }

    fn remap(ctx: *anyopaque, old_mem: []align(1) u8, old_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]align(1) u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.parent_allocator.rawRemap(old_mem, old_align, new_len, ret_addr);
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .free = free,
        .remap = remap,
    };
};

// Each test fails the n-th allocation of the call for n = 0, 1, 2, ... until the
// call no longer runs out of memory. Every failing run must leave the
// pre-call state untouched and report no side effects.
const max_failure_points = 10_000;

test "snapshot should be reverted on allocation failure during self-destruct extraction" {
    const base_allocator = testing.allocator;
    const contract_addr = try Address.fromHex("0x1234567890123456789012345678901234567890");
    const beneficiary = try Address.fromHex("0xabcdefabcdefabcdefabcdefabcdefabcdefabcd");
    const caller_address = try Address.fromHex("0x1111111111111111111111111111111111111111");
    const block_info = evm.BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1_000_000_000,
        .prev_randao = @as([32]u8, @splat(0)),
        .chain_id = 1,
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };
    const tx_context = evm.TransactionContext{
        .gas_limit = 100_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    const storage_key: u256 = 0x0101010101010101010101010101010101010101010101010101010101010101;
    const initial_value: u256 = 0x4242424242424242424242424242424242424242424242424242424242424242;
    // PUSH20 beneficiary, SELFDESTRUCT
    const bytecode = [_]u8{0x73} ++ beneficiary.bytes ++ [_]u8{0xff};

    var failures: usize = 0;
    var n: usize = 0;
    while (n < max_failure_points) : (n += 1) {
        var database = evm.Database.init(base_allocator);
        defer database.deinit();
        const code_hash = try database.set_code(&bytecode);
        try database.set_account(contract_addr.bytes, .{
            .balance = 1000,
            .nonce = 0,
            .code_hash = code_hash,
            .storage_root = @as([32]u8, @splat(0)),
        });
        try database.set_account(caller_address.bytes, .{
            .balance = 1_000_000_000,
            .nonce = 0,
            .code_hash = @as([32]u8, @splat(0)),
            .storage_root = @as([32]u8, @splat(0)),
            .delegated_address = null,
        });
        try database.set_storage(contract_addr.bytes, storage_key, initial_value);

        var failing_alloc = FailingAllocator.init(base_allocator);
        // LONDON: SELFDESTRUCT destroys a pre-existing contract (no EIP-6780).
        var evm_instance = try evm.Evm(.{ .eips = .{ .hardfork = .LONDON } }).init(failing_alloc.allocator(), &database, block_info, tx_context, 0, caller_address);
        defer evm_instance.deinit();

        failing_alloc.allocation_count = 0;
        failing_alloc.fail_after_n = n;
        var result = evm_instance.call(.{ .call = .{
            .caller = caller_address,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100_000,
        } });
        defer result.deinit(base_allocator);
        const exhausted = failing_alloc.allocation_count > n;
        failing_alloc.fail_after_n = std.math.maxInt(usize);

        if (!exhausted) {
            // Allocation n was never requested: the call ran to completion.
            try testing.expect(result.success);
            try testing.expectEqual(@as(usize, 1), result.selfdestructs.len);
            break;
        }
        if (result.success) continue;
        failures += 1;

        const account_after = (try database.get_account(contract_addr.bytes)).?;
        try testing.expectEqual(@as(u256, 1000), account_after.balance);
        try testing.expectEqual(initial_value, try database.get_storage(contract_addr.bytes, storage_key));
        try testing.expectEqual(@as(usize, 0), result.selfdestructs.len);
    }
    try testing.expect(n < max_failure_points);
    try testing.expect(failures > 0);
}

test "snapshot should be reverted on allocation failure during log extraction" {
    const base_allocator = testing.allocator;
    const contract_addr = try Address.fromHex("0x1234567890123456789012345678901234567890");
    const caller_address = try Address.fromHex("0x1111111111111111111111111111111111111111");
    const block_info = evm.BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1_000_000_000,
        .prev_randao = @as([32]u8, @splat(0)),
        .chain_id = 1,
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };
    const tx_context = evm.TransactionContext{
        .gas_limit = 100_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    const storage_key: u256 = 0x0101010101010101010101010101010101010101010101010101010101010101;
    const initial_value: u256 = 0x4242424242424242424242424242424242424242424242424242424242424242;
    // PUSH4 0x12345678, PUSH1 0, MSTORE, PUSH1 4, PUSH1 0, LOG0, STOP
    const bytecode = [_]u8{ 0x63, 0x12, 0x34, 0x56, 0x78, 0x60, 0x00, 0x52, 0x60, 0x04, 0x60, 0x00, 0xA0, 0x00 };

    var failures: usize = 0;
    var n: usize = 0;
    while (n < max_failure_points) : (n += 1) {
        var database = evm.Database.init(base_allocator);
        defer database.deinit();
        const code_hash = try database.set_code(&bytecode);
        try database.set_account(contract_addr.bytes, .{
            .balance = 1000,
            .nonce = 0,
            .code_hash = code_hash,
            .storage_root = @as([32]u8, @splat(0)),
        });
        try database.set_account(caller_address.bytes, .{
            .balance = 1_000_000_000,
            .nonce = 0,
            .code_hash = @as([32]u8, @splat(0)),
            .storage_root = @as([32]u8, @splat(0)),
            .delegated_address = null,
        });
        try database.set_storage(contract_addr.bytes, storage_key, initial_value);

        var failing_alloc = FailingAllocator.init(base_allocator);
        var evm_instance = try evm.Evm(.{}).init(failing_alloc.allocator(), &database, block_info, tx_context, 0, caller_address);
        defer evm_instance.deinit();

        failing_alloc.allocation_count = 0;
        failing_alloc.fail_after_n = n;
        var result = evm_instance.call(.{ .call = .{
            .caller = caller_address,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100_000,
        } });
        defer result.deinit(base_allocator);
        const exhausted = failing_alloc.allocation_count > n;
        failing_alloc.fail_after_n = std.math.maxInt(usize);

        if (!exhausted) {
            try testing.expect(result.success);
            try testing.expectEqual(@as(usize, 1), result.logs.len);
            break;
        }
        if (result.success) continue;
        failures += 1;

        const account_after = (try database.get_account(contract_addr.bytes)).?;
        try testing.expectEqual(@as(u64, 0), account_after.nonce);
        try testing.expectEqual(initial_value, try database.get_storage(contract_addr.bytes, storage_key));
        try testing.expectEqual(@as(usize, 0), result.logs.len);
    }
    try testing.expect(n < max_failure_points);
    try testing.expect(failures > 0);
}
