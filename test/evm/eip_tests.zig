const std = @import("std");
const testing = std.testing;
const evm_mod = @import("evm.zig");
const primitives = @import("primitives");
const Hardfork = @import("hardfork.zig").Hardfork;

// Test EIP-3541: Reject new contract code starting with the 0xEF byte
test "EIP-3541: reject contracts starting with 0xEF after London" {
    const allocator = testing.allocator;
    
    // Test with pre-London hardfork (should allow 0xEF)
    {
        var evm = try evm_mod.DefaultEvm.init(allocator, .{
            .hardfork_config = Hardfork.BERLIN,
        });
        defer evm.deinit();
        
        // Deploy contract with 0xEF prefix - should succeed
        const init_code = [_]u8{
            // Constructor that returns code starting with 0xEF
            0x60, 0x03, // PUSH1 0x03 (length)
            0x60, 0x00, // PUSH1 0x00 (offset)
            0xF3,       // RETURN
            0xEF, 0x00, 0x00, // Code to deploy (starts with 0xEF)
        };
        
        const result = try evm.transact(.{
            .to = null, // Contract creation
            .input = &init_code,
            .gas_limit = 100000,
            .gas_price = 1,
        });
        
        // Should succeed in Berlin
        try testing.expect(result.success);
    }
    
    // Test with London hardfork (should reject 0xEF)
    {
        var evm = try evm_mod.DefaultEvm.init(allocator, .{
            .hardfork_config = Hardfork.LONDON,
        });
        defer evm.deinit();
        
        // Deploy contract with 0xEF prefix - should fail
        const init_code = [_]u8{
            // Constructor that returns code starting with 0xEF
            0x60, 0x03, // PUSH1 0x03 (length)
            0x60, 0x00, // PUSH1 0x00 (offset)
            0xF3,       // RETURN
            0xEF, 0x00, 0x00, // Code to deploy (starts with 0xEF)
        };
        
        const result = try evm.transact(.{
            .to = null, // Contract creation
            .input = &init_code,
            .gas_limit = 100000,
            .gas_price = 1,
        });
        
        // Should fail in London
        try testing.expect(!result.success);
    }
    
    // Test with valid bytecode (not starting with 0xEF)
    {
        var evm = try evm_mod.DefaultEvm.init(allocator, .{
            .hardfork_config = Hardfork.LONDON,
        });
        defer evm.deinit();
        
        // Deploy contract with valid bytecode
        const init_code = [_]u8{
            // Constructor that returns valid code
            0x60, 0x03, // PUSH1 0x03 (length)
            0x60, 0x00, // PUSH1 0x00 (offset)
            0xF3,       // RETURN
            0x60, 0x42, 0x00, // Valid code (PUSH1 0x42, STOP)
        };
        
        const result = try evm.transact(.{
            .to = null, // Contract creation
            .input = &init_code,
            .gas_limit = 100000,
            .gas_price = 1,
        });
        
        // Should succeed with valid bytecode
        try testing.expect(result.success);
    }
}

// Test EIP-6780: SELFDESTRUCT only in same transaction
test "EIP-6780: SELFDESTRUCT restrictions after Cancun" {
    const allocator = testing.allocator;
    const Address = primitives.Address.Address;
    
    // Test with pre-Cancun hardfork (full SELFDESTRUCT)
    {
        var evm = try evm_mod.DefaultEvm.init(allocator, .{
            .hardfork_config = Hardfork.SHANGHAI,
        });
        defer evm.deinit();
        
        // Deploy a contract
        const contract_addr = Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;
        const beneficiary = Address.fromHex("0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB") catch unreachable;
        
        // Set up contract with balance
        try evm.database.set_account(contract_addr.bytes, .{
            .balance = 1000,
            .nonce = 1,
            .code_hash = [_]u8{0} ** 32,
        });
        
        // SELFDESTRUCT bytecode
        const bytecode = [_]u8{
            0x73, // PUSH20
        } ++ beneficiary.bytes ++ [_]u8{
            0xFF, // SELFDESTRUCT
        };
        
        const code_hash = try evm.database.set_code(&bytecode);
        var account = (try evm.database.get_account(contract_addr.bytes)).?;
        account.code_hash = code_hash;
        try evm.database.set_account(contract_addr.bytes, account);
        
        // Execute SELFDESTRUCT
        _ = try evm.call(.{
            .to = contract_addr,
            .gas_limit = 50000,
        });
        
        // Contract should be destroyed (pre-Cancun)
        const post_account = try evm.database.get_account(contract_addr.bytes);
        try testing.expect(post_account == null or post_account.?.balance == 0);
        
        // Beneficiary should receive balance
        const beneficiary_account = try evm.database.get_account(beneficiary.bytes);
        try testing.expect(beneficiary_account != null);
        try testing.expectEqual(@as(u256, 1000), beneficiary_account.?.balance);
    }
    
    // Test with Cancun hardfork (restricted SELFDESTRUCT)
    {
        var evm = try evm_mod.DefaultEvm.init(allocator, .{
            .hardfork_config = Hardfork.CANCUN,
        });
        defer evm.deinit();
        
        // Deploy a pre-existing contract
        const contract_addr = Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;
        const beneficiary = Address.fromHex("0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB") catch unreachable;
        
        // Set up contract with balance
        try evm.database.set_account(contract_addr.bytes, .{
            .balance = 1000,
            .nonce = 1,
            .code_hash = [_]u8{0} ** 32,
        });
        
        // SELFDESTRUCT bytecode
        const bytecode = [_]u8{
            0x73, // PUSH20
        } ++ beneficiary.bytes ++ [_]u8{
            0xFF, // SELFDESTRUCT
        };
        
        const code_hash = try evm.database.set_code(&bytecode);
        var account = (try evm.database.get_account(contract_addr.bytes)).?;
        account.code_hash = code_hash;
        try evm.database.set_account(contract_addr.bytes, account);
        
        // Execute SELFDESTRUCT (not created in same tx)
        _ = try evm.call(.{
            .to = contract_addr,
            .gas_limit = 50000,
        });
        
        // Contract should NOT be destroyed (Cancun restriction)
        const post_account = try evm.database.get_account(contract_addr.bytes);
        try testing.expect(post_account != null);
        try testing.expectEqual(@as(u256, 0), post_account.?.balance); // Balance transferred
        try testing.expect(!std.mem.eql(u8, &post_account.?.code_hash, &([_]u8{0} ** 32))); // Code remains
        
        // Beneficiary should still receive balance
        const beneficiary_account = try evm.database.get_account(beneficiary.bytes);
        try testing.expect(beneficiary_account != null);
        try testing.expectEqual(@as(u256, 1000), beneficiary_account.?.balance);
    }
    
    // Test SELFDESTRUCT in same transaction (should work even in Cancun)
    {
        var evm = try evm_mod.DefaultEvm.init(allocator, .{
            .hardfork_config = Hardfork.CANCUN,
        });
        defer evm.deinit();
        
        const beneficiary = Address.fromHex("0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB") catch unreachable;
        
        // Deploy and SELFDESTRUCT in same transaction
        // Init code that creates a contract and immediately self-destructs
        const init_code = [_]u8{
            // Deploy code that self-destructs
            0x73, // PUSH20
        } ++ beneficiary.bytes ++ [_]u8{
            0xFF, // SELFDESTRUCT
        };
        
        const result = try evm.transact(.{
            .to = null, // Contract creation
            .input = &init_code,
            .gas_limit = 100000,
            .gas_price = 1,
            .value = 1000, // Send value to contract
        });
        
        // Should succeed and contract should be destroyed
        try testing.expect(result.success);
        
        // Beneficiary should receive the value
        const beneficiary_account = try evm.database.get_account(beneficiary.bytes);
        try testing.expect(beneficiary_account != null);
        try testing.expectEqual(@as(u256, 1000), beneficiary_account.?.balance);
    }
}

// Test that opcodes are properly wired
test "New opcodes are available in correct hardforks" {
    const allocator = testing.allocator;
    
    // Test PUSH0 (EIP-3855) - available from Shanghai
    {
        // Pre-Shanghai: PUSH0 should be invalid
        var evm_berlin = try evm_mod.DefaultEvm.init(allocator, .{
            .hardfork_config = Hardfork.LONDON,
        });
        defer evm_berlin.deinit();
        
        const push0_code = [_]u8{ 0x5F, 0x00 }; // PUSH0, STOP
        const result_berlin = try evm_berlin.call(.{
            .input = &push0_code,
            .gas_limit = 10000,
        });
        try testing.expect(!result_berlin.success); // Should fail
        
        // Shanghai+: PUSH0 should work
        var evm_shanghai = try evm_mod.DefaultEvm.init(allocator, .{
            .hardfork_config = Hardfork.SHANGHAI,
        });
        defer evm_shanghai.deinit();
        
        const result_shanghai = try evm_shanghai.call(.{
            .input = &push0_code,
            .gas_limit = 10000,
        });
        try testing.expect(result_shanghai.success); // Should succeed
    }
    
    // Test MCOPY (EIP-5656) - available from Cancun
    {
        // Pre-Cancun: MCOPY should be invalid
        var evm_shanghai = try evm_mod.DefaultEvm.init(allocator, .{
            .hardfork_config = Hardfork.SHANGHAI,
        });
        defer evm_shanghai.deinit();
        
        const mcopy_code = [_]u8{
            0x60, 0x20, // PUSH1 0x20 (size)
            0x60, 0x00, // PUSH1 0x00 (source)
            0x60, 0x40, // PUSH1 0x40 (dest)
            0x5E,       // MCOPY
            0x00,       // STOP
        };
        
        const result_shanghai = try evm_shanghai.call(.{
            .input = &mcopy_code,
            .gas_limit = 10000,
        });
        try testing.expect(!result_shanghai.success); // Should fail
        
        // Cancun+: MCOPY should work
        var evm_cancun = try evm_mod.DefaultEvm.init(allocator, .{
            .hardfork_config = Hardfork.CANCUN,
        });
        defer evm_cancun.deinit();
        
        const result_cancun = try evm_cancun.call(.{
            .input = &mcopy_code,
            .gas_limit = 10000,
        });
        try testing.expect(result_cancun.success); // Should succeed
    }
}