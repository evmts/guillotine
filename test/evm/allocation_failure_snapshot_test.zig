const std = @import("std");
const evm = @import("evm");
const testing = std.testing;
const primitives = @import("primitives");
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

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.allocation_count += 1;
        
        if (self.should_fail or self.allocation_count > self.fail_after_n) {
            return null;
        }
        
        return self.parent_allocator.rawAlloc(len, ptr_align, ret_addr);
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.parent_allocator.rawResize(buf, buf_align, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.parent_allocator.rawFree(buf, buf_align, ret_addr);
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .free = free,
    };
};

test "snapshot should be reverted on allocation failure during self-destruct extraction" {
    const base_allocator = testing.allocator;
    
    // Set up addresses
    const contract_addr = Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;
    const beneficiary = Address.fromHex("0xabcdefabcdefabcdefabcdefabcdefabcdefabcd") catch unreachable;
    const caller_address = Address.fromHex("0x1111111111111111111111111111111111111111") catch unreachable;

    // Create EVM database
    var database = evm.Database.init(base_allocator);
    defer database.deinit();
    
    // Create block info and transaction context
    const block_info = evm.BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1_000_000_000,
        .prev_randao = [_]u8{0} ** 32,
        .chain_id = 1,
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };

    // Create transaction context
    const tx_context = evm.TransactionContext{
        .gas_limit = 100_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    // Create failing allocator
    var failing_alloc = FailingAllocator.init(base_allocator);
    const allocator = failing_alloc.allocator();
    
    // Create EVM instance with CANCUN hardfork (with EIP-6780)
    var evm_instance = try evm.Evm(.{}).init(
        allocator,
        &database,
        block_info,
        tx_context,
        0,
        caller_address,
        .CANCUN
    );
    defer evm_instance.deinit();
    
    // Create bytecode: PUSH20 beneficiary, SELFDESTRUCT
    const bytecode = [_]u8{0x73} ++ beneficiary.bytes ++ [_]u8{0xff};
    
    // Store bytecode and get code hash
    const code_hash = try database.set_code(&bytecode);
    
    // Deploy contract with balance and the bytecode
    try database.set_account(contract_addr.bytes, .{
        .balance = 1000,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Create caller account with balance
    const caller_account = evm.Account{
        .balance = 1_000_000_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
        .delegated_address = null,
    };
    try database.set_account(caller_address.bytes, caller_account);
    
    // Store initial storage value to verify snapshot reversion
    const storage_key = [_]u8{0x01} ** 32;
    const initial_value = [_]u8{0x42} ** 32;
    try database.set_storage(contract_addr.bytes, storage_key, initial_value);
    
    // Get initial balance
    const initial_balance = (try database.get_account(contract_addr.bytes)).?.balance;
    
    // Set up allocator to fail during self-destruct extraction
    // We need enough allocations to succeed for the call setup, but fail on self-destruct extraction
    failing_alloc.fail_after_n = 100; // This number may need adjustment
    
    // Execute call to trigger SELFDESTRUCT
    const call_params = evm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100_000,
        },
    };
    
    const result = evm_instance.call(call_params);
    defer if (result.selfdestructs.len > 0) base_allocator.free(result.selfdestructs);
    
    // The call should fail due to allocation failure
    try testing.expect(!result.success);
    
    // Verify that the snapshot was reverted:
    // 1. Contract should still exist
    const account_after = try database.get_account(contract_addr.bytes);
    try testing.expect(account_after != null);
    
    // 2. Balance should be unchanged
    try testing.expect(account_after.?.balance == initial_balance);
    
    // 3. Storage should be unchanged
    const storage_after = try database.get_storage(contract_addr.bytes, storage_key);
    try testing.expect(std.mem.eql(u8, &storage_after, &initial_value));
    
    // 4. No self-destructs should be recorded
    try testing.expect(result.selfdestructs.len == 0);
}

test "snapshot should be reverted on allocation failure during log extraction" {
    const base_allocator = testing.allocator;
    
    // Set up addresses
    const contract_addr = Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;
    const caller_address = Address.fromHex("0x1111111111111111111111111111111111111111") catch unreachable;

    // Create EVM database
    var database = evm.Database.init(base_allocator);
    defer database.deinit();
    
    // Create block info and transaction context
    const block_info = evm.BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1_000_000_000,
        .prev_randao = [_]u8{0} ** 32,
        .chain_id = 1,
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };

    // Create transaction context
    const tx_context = evm.TransactionContext{
        .gas_limit = 100_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    // Create failing allocator
    var failing_alloc = FailingAllocator.init(base_allocator);
    const allocator = failing_alloc.allocator();
    
    // Create EVM instance
    var evm_instance = try evm.Evm(.{}).init(
        allocator,
        &database,
        block_info,
        tx_context,
        0,
        caller_address,
        .CANCUN
    );
    defer evm_instance.deinit();
    
    // Create bytecode that emits a log: LOG0 with some data
    const log_data = [_]u8{0x12, 0x34, 0x56, 0x78};
    const bytecode = [_]u8{
        // PUSH4 data
        0x63, 0x12, 0x34, 0x56, 0x78,
        // PUSH1 0 (memory offset)
        0x60, 0x00,
        // MSTORE
        0x52,
        // PUSH1 4 (size)
        0x60, 0x04,
        // PUSH1 0 (offset)
        0x60, 0x00,
        // LOG0
        0xA0,
        // STOP
        0x00,
    };
    
    // Store bytecode and get code hash
    const code_hash = try database.set_code(&bytecode);
    
    // Deploy contract
    try database.set_account(contract_addr.bytes, .{
        .balance = 1000,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Create caller account with balance
    const caller_account = evm.Account{
        .balance = 1_000_000_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
        .delegated_address = null,
    };
    try database.set_account(caller_address.bytes, caller_account);
    
    // Store initial storage value to verify snapshot reversion
    const storage_key = [_]u8{0x01} ** 32;
    const initial_value = [_]u8{0x42} ** 32;
    try database.set_storage(contract_addr.bytes, storage_key, initial_value);
    
    // Get initial nonce
    const initial_nonce = (try database.get_account(contract_addr.bytes)).?.nonce;
    
    // Set up allocator to fail during log extraction
    failing_alloc.fail_after_n = 100; // This number may need adjustment
    
    // Execute call to trigger LOG
    const call_params = evm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100_000,
        },
    };
    
    const result = evm_instance.call(call_params);
    defer if (result.logs.len > 0) base_allocator.free(result.logs);
    
    // The call should fail due to allocation failure
    try testing.expect(!result.success);
    
    // Verify that the snapshot was reverted:
    // 1. Contract should still exist with unchanged state
    const account_after = try database.get_account(contract_addr.bytes);
    try testing.expect(account_after != null);
    
    // 2. Nonce should be unchanged
    try testing.expect(account_after.?.nonce == initial_nonce);
    
    // 3. Storage should be unchanged
    const storage_after = try database.get_storage(contract_addr.bytes, storage_key);
    try testing.expect(std.mem.eql(u8, &storage_after, &initial_value));
    
    // 4. No logs should be recorded
    try testing.expect(result.logs.len == 0);
}