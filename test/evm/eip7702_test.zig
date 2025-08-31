const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const evm = @import("evm");
const Address = primitives.Address.Address;
const Authorization = primitives.Authorization.Authorization;
const Hash = @import("crypto").Hash.Hash;

// ============================================================================
// EIP-7702 Test-Driven Development Specification
// ============================================================================
//
// This comprehensive test suite defines the complete EIP-7702 behavior
// following the production-ready specification. All tests are written
// first to drive the implementation using TDD methodology.
//
// Specification: https://eips.ethereum.org/EIPS/eip-7702

// ============================================================================
// TEST 1: Authorization Tuple Structure and Validation
// ============================================================================

test "EIP-7702: Authorization tuple must have correct structure" {
    const auth = Authorization{
        .chain_id = 1,
        .address = try Address.from_hex("0x1234567890123456789012345678901234567890"),
        .nonce = 42,
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = [_]u8{0x34} ** 32,
    };

    // Validate all fields are present
    try testing.expectEqual(@as(u64, 1), auth.chain_id);
    try testing.expectEqual(@as(u64, 42), auth.nonce);
    try testing.expectEqual(@as(u64, 27), auth.v);
}

test "EIP-7702: Authorization validation rejects invalid chain_id" {
    var auth = Authorization{
        .chain_id = 0, // Invalid: must be non-zero
        .address = try Address.from_hex("0x1234567890123456789012345678901234567890"),
        .nonce = 0,
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = [_]u8{0x34} ** 32,
    };

    try testing.expectError(primitives.Authorization.AuthorizationError.InvalidChainId, auth.validate());
}

test "EIP-7702: Authorization validation rejects zero address" {
    var auth = Authorization{
        .chain_id = 1,
        .address = Address.ZERO, // Invalid: cannot delegate to zero address
        .nonce = 0,
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = [_]u8{0x34} ** 32,
    };

    try testing.expectError(primitives.Authorization.AuthorizationError.ZeroAddress, auth.validate());
}

// ============================================================================
// TEST 2: Delegation Designator Format (0xef0100 || address)
// ============================================================================

test "EIP-7702: Delegation designator format must be 0xef0100 + address" {
    const allocator = testing.allocator;
    const delegate_address = try Address.from_hex("0x1234567890123456789012345678901234567890");
    
    // Create delegation designator
    const designator = try createDelegationDesignator(allocator, delegate_address);
    defer allocator.free(designator);
    
    // Verify format: 0xef0100 (3 bytes) + address (20 bytes) = 23 bytes total
    try testing.expectEqual(@as(usize, 23), designator.len);
    try testing.expectEqual(@as(u8, 0xef), designator[0]);
    try testing.expectEqual(@as(u8, 0x01), designator[1]);
    try testing.expectEqual(@as(u8, 0x00), designator[2]);
    try testing.expectEqualSlices(u8, &delegate_address.bytes, designator[3..23]);
}

test "EIP-7702: Parse delegation designator correctly" {
    const delegate_address = try Address.from_hex("0x1234567890123456789012345678901234567890");
    
    // Create valid designator
    var designator = [_]u8{0xef, 0x01, 0x00} ++ delegate_address.bytes;
    
    // Parse it
    const parsed_address = try parseDelegationDesignator(&designator);
    try testing.expectEqual(delegate_address, parsed_address);
    
    // Invalid designator (wrong prefix)
    var invalid_designator = [_]u8{0xef, 0x02, 0x00} ++ delegate_address.bytes;
    try testing.expectError(EIP7702Error.InvalidDesignator, parseDelegationDesignator(&invalid_designator));
}

// ============================================================================
// TEST 3: Transaction Type 0x04 Structure
// ============================================================================

test "EIP-7702: Transaction type 0x04 must include authorization_list" {
    
    const auth1 = Authorization{
        .chain_id = 1,
        .address = try Address.from_hex("0x1111111111111111111111111111111111111111"),
        .nonce = 0,
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = [_]u8{0x34} ** 32,
    };
    
    const auth2 = Authorization{
        .chain_id = 1,
        .address = try Address.from_hex("0x2222222222222222222222222222222222222222"),
        .nonce = 1,
        .v = 28,
        .r = [_]u8{0x56} ** 32,
        .s = [_]u8{0x78} ** 32,
    };
    
    const tx = Eip7702Transaction{
        .chain_id = 1,
        .nonce = 42,
        .max_priority_fee_per_gas = 1_000_000_000,
        .max_fee_per_gas = 20_000_000_000,
        .gas_limit = 100_000,
        .to = try Address.from_hex("0x3333333333333333333333333333333333333333"),
        .value = 1_000_000_000_000_000_000,
        .data = &[_]u8{},
        .access_list = &[_]primitives.Transaction.AccessListItem{},
        .authorization_list = &[_]Authorization{auth1, auth2},
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };
    
    try testing.expectEqual(@as(usize, 2), tx.authorization_list.len);
    try testing.expectEqual(auth1.address, tx.authorization_list[0].address);
    try testing.expectEqual(auth2.address, tx.authorization_list[1].address);
}

test "EIP-7702: Transaction type 0x04 RLP encoding" {
    const allocator = testing.allocator;
    
    const auth = Authorization{
        .chain_id = 1,
        .address = try Address.from_hex("0x1111111111111111111111111111111111111111"),
        .nonce = 0,
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = [_]u8{0x34} ** 32,
    };
    
    const tx = Eip7702Transaction{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 1_000_000_000,
        .max_fee_per_gas = 20_000_000_000,
        .gas_limit = 100_000,
        .to = try Address.from_hex("0x2222222222222222222222222222222222222222"),
        .value = 0,
        .data = &[_]u8{},
        .access_list = &[_]primitives.Transaction.AccessListItem{},
        .authorization_list = &[_]Authorization{auth},
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };
    
    const encoded = try encodeEip7702Transaction(allocator, tx);
    defer allocator.free(encoded);
    
    // Must start with transaction type 0x04
    try testing.expectEqual(@as(u8, 0x04), encoded[0]);
    
    // Must be valid RLP after type byte
    try testing.expect(encoded[1] >= 0xc0); // RLP list prefix
}

// ============================================================================
// TEST 4: Authorization Processing During Transaction Execution
// ============================================================================

test "EIP-7702: Process authorizations before transaction execution" {
    const allocator = testing.allocator;
    
    // Create test database
    var db = evm.MemoryDatabase.init(allocator);
    defer db.deinit();
    
    // Create EOA that will delegate
    const eoa_address = try Address.from_hex("0x1111111111111111111111111111111111111111");
    var eoa_account = evm.Account.zero();
    eoa_account.balance = 1_000_000_000_000_000_000; // 1 ETH
    eoa_account.nonce = 5;
    try db.set_account(eoa_address.bytes, eoa_account);
    
    // Create contract to delegate to
    const contract_address = try Address.from_hex("0x2222222222222222222222222222222222222222");
    const contract_code = [_]u8{0x60, 0x42, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}; // PUSH1 0x42, PUSH1 0x00, MSTORE, PUSH1 0x20, PUSH1 0x00, RETURN
    // Set the contract code - get code hash and set up account
    const code_hash = try db.set_code(&contract_code);
    var contract_account = evm.Account.zero();
    contract_account.code_hash = code_hash;
    try db.set_account(contract_address.bytes, contract_account);
    
    // Create authorization
    const auth = Authorization{
        .chain_id = 1,
        .address = contract_address,
        .nonce = 5, // Must match EOA nonce
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = [_]u8{0x34} ** 32,
    };
    
    // Process authorization
    const processor = AuthorizationProcessor.init(allocator, &db);
    try processor.processAuthorization(auth, eoa_address);
    
    // Verify delegation was set
    const updated_account = try db.get_account(eoa_address.bytes);
    try testing.expect(updated_account.?.has_delegation());
    try testing.expectEqual(contract_address, updated_account.?.get_effective_code_address().?);
    
    // Verify nonce was incremented
    try testing.expectEqual(@as(u64, 6), updated_account.?.nonce);
}

test "EIP-7702: Authorization with wrong nonce is rejected" {
    const allocator = testing.allocator;
    
    var db = evm.MemoryDatabase.init(allocator);
    defer db.deinit();
    
    const eoa_address = try Address.from_hex("0x1111111111111111111111111111111111111111");
    var eoa_account = evm.Account.zero();
    eoa_account.nonce = 5;
    try db.set_account(eoa_address.bytes, eoa_account);
    
    const auth = Authorization{
        .chain_id = 1,
        .address = try Address.from_hex("0x2222222222222222222222222222222222222222"),
        .nonce = 10, // Wrong nonce
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = [_]u8{0x34} ** 32,
    };
    
    const processor = AuthorizationProcessor.init(allocator, &db);
    var mutable_processor = processor.*;
    try testing.expectError(EIP7702Error.NonceMismatch, mutable_processor.processAuthorization(auth, eoa_address));
}

test "EIP-7702: Authorization with wrong chain_id is rejected" {
    const allocator = testing.allocator;
    
    var db = evm.MemoryDatabase.init(allocator);
    defer db.deinit();
    
    const auth = Authorization{
        .chain_id = 999, // Wrong chain
        .address = try Address.from_hex("0x2222222222222222222222222222222222222222"),
        .nonce = 0,
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = [_]u8{0x34} ** 32,
    };
    
    var processor = AuthorizationProcessor.init(allocator, &db);
    processor.chain_id = 1; // Current chain is 1
    try testing.expectError(EIP7702Error.ChainIdMismatch, processor.processAuthorization(auth, try Address.from_hex("0x1111111111111111111111111111111111111111")));
}

// ============================================================================
// TEST 5: Code Execution Redirection
// ============================================================================

test "EIP-7702: EOA with delegation executes delegated contract code" {
    const allocator = testing.allocator;
    
    var db = evm.MemoryDatabase.init(allocator);
    defer db.deinit();
    
    // Setup EOA with delegation
    const eoa_address = try Address.from_hex("0x1111111111111111111111111111111111111111");
    var eoa_account = evm.Account.zero();
    eoa_account.balance = 1_000_000_000_000_000_000;
    const delegated_addr = try Address.from_hex("0x2222222222222222222222222222222222222222");
    eoa_account.delegated_address = .{ .bytes = delegated_addr.bytes };
    try db.set_account(eoa_address.bytes, eoa_account);
    
    // Setup contract code
    const contract_address = try Address.from_hex("0x2222222222222222222222222222222222222222");
    const contract_code = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0x00  
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x00, // PUSH1 0x00
        0xf3,       // RETURN
    };
    // Set the contract code - get code hash and set up account
    const code_hash = try db.set_code(&contract_code);
    var contract_account = evm.Account.zero();
    contract_account.code_hash = code_hash;
    try db.set_account(contract_address.bytes, contract_account);
    
    // Call EOA (should execute contract code)
    const call_params = evm.CallParams{
        .caller = try Address.from_hex("0x3333333333333333333333333333333333333333"),
        .target = eoa_address,
        .value = 0,
        .data = &[_]u8{},
        .gas_limit = 100_000,
    };
    
    var evm_instance = try evm.Evm.init(allocator, &db.to_database_interface());
    defer evm_instance.deinit();
    
    const result = try evm_instance.call(call_params);
    defer allocator.free(result.output);
    
    // Should return 0x42
    try testing.expectEqual(@as(usize, 32), result.output.len);
    try testing.expectEqual(@as(u8, 0x42), result.output[31]);
}

test "EIP-7702: ADDRESS opcode returns EOA address, not delegated address" {
    const allocator = testing.allocator;
    
    var db = evm.MemoryDatabase.init(allocator);
    defer db.deinit();
    
    const eoa_address = try Address.from_hex("0x1111111111111111111111111111111111111111");
    var eoa_account = evm.Account.zero();
    eoa_account.balance = 1_000_000_000_000_000_000;
    const delegated_addr = try Address.from_hex("0x2222222222222222222222222222222222222222");
    eoa_account.delegated_address = .{ .bytes = delegated_addr.bytes };
    try db.set_account(eoa_address.bytes, eoa_account);
    
    // Contract code that returns ADDRESS
    const contract_code = [_]u8{
        0x30,       // ADDRESS
        0x60, 0x00, // PUSH1 0x00
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x00, // PUSH1 0x00
        0xf3,       // RETURN
    };
    try db.set_code(try Address.from_hex("0x2222222222222222222222222222222222222222").bytes, &contract_code);
    
    const call_params = evm.CallParams{
        .caller = try Address.from_hex("0x3333333333333333333333333333333333333333"),
        .target = eoa_address,
        .value = 0,
        .data = &[_]u8{},
        .gas_limit = 100_000,
    };
    
    var evm_instance = try evm.Evm.init(allocator, &db.to_database_interface());
    defer evm_instance.deinit();
    
    const result = try evm_instance.call(call_params);
    defer allocator.free(result.output);
    
    // Should return EOA address, not contract address
    try testing.expectEqual(@as(usize, 32), result.output.len);
    const returned_address = Address{ .bytes = result.output[12..32].* };
    try testing.expectEqual(eoa_address, returned_address);
}

// ============================================================================
// TEST 6: Gas Cost Calculations
// ============================================================================

test "EIP-7702: Gas cost for authorization processing" {
    
    // Test with 3 authorizations, 2 of which are for empty accounts
    const auth1 = Authorization{
        .chain_id = 1,
        .address = try Address.from_hex("0x1111111111111111111111111111111111111111"),
        .nonce = 0,
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = [_]u8{0x34} ** 32,
    };
    
    const auth2 = Authorization{
        .chain_id = 1,
        .address = try Address.from_hex("0x2222222222222222222222222222222222222222"),
        .nonce = 0,
        .v = 27,
        .r = [_]u8{0x56} ** 32,
        .s = [_]u8{0x78} ** 32,
    };
    
    const auth3 = Authorization{
        .chain_id = 1,
        .address = try Address.from_hex("0x3333333333333333333333333333333333333333"),
        .nonce = 0,
        .v = 27,
        .r = [_]u8{0x9a} ** 32,
        .s = [_]u8{0xbc} ** 32,
    };
    
    const auth_list = [_]Authorization{auth1, auth2, auth3};
    
    // Calculate gas cost
    const gas_cost = primitives.Authorization.calculate_authorization_gas_cost(&auth_list, 2);
    
    // Expected: 3 * PER_AUTH_BASE_COST + 2 * PER_EMPTY_ACCOUNT_COST
    // = 3 * 12500 + 2 * 25000 = 37500 + 50000 = 87500
    try testing.expectEqual(@as(u64, 87500), gas_cost);
}

test "EIP-7702: Transaction intrinsic gas includes authorization costs" {
    
    const auth = Authorization{
        .chain_id = 1,
        .address = try Address.from_hex("0x1111111111111111111111111111111111111111"),
        .nonce = 0,
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = [_]u8{0x34} ** 32,
    };
    
    const tx = Eip7702Transaction{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 1_000_000_000,
        .max_fee_per_gas = 20_000_000_000,
        .gas_limit = 100_000,
        .to = try Address.from_hex("0x2222222222222222222222222222222222222222"),
        .value = 0,
        .data = &[_]u8{},
        .access_list = &[_]primitives.Transaction.AccessListItem{},
        .authorization_list = &[_]Authorization{auth},
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };
    
    const intrinsic_gas = try calculateIntrinsicGas(tx);
    
    // Should include base transaction cost (21000) + authorization cost (12500 minimum)
    try testing.expect(intrinsic_gas >= 21000 + 12500);
}

// ============================================================================
// TEST 7: Security Validations
// ============================================================================

test "EIP-7702: Cannot delegate from contract account" {
    const allocator = testing.allocator;
    
    var db = evm.MemoryDatabase.init(allocator);
    defer db.deinit();
    
    // Create contract account (has code)
    const contract_address = try Address.from_hex("0x1111111111111111111111111111111111111111");
    // Set some dummy code for the contract
    const dummy_code = [_]u8{0x00};
    const code_hash = try db.set_code(&dummy_code);
    var contract_account = evm.Account.zero();
    contract_account.code_hash = code_hash;
    try db.set_account(contract_address.bytes, contract_account);
    
    const auth = Authorization{
        .chain_id = 1,
        .address = try Address.from_hex("0x2222222222222222222222222222222222222222"),
        .nonce = 0,
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = [_]u8{0x34} ** 32,
    };
    
    const processor = AuthorizationProcessor.init(allocator, &db);
    try testing.expectError(EIP7702Error.NotEOA, processor.processAuthorization(auth, contract_address));
}

test "EIP-7702: Signature recovery validates authority" {
    const allocator = testing.allocator;
    const crypto = @import("crypto").Crypto;
    
    // Create a real authorization with valid signature
    const private_key: crypto.PrivateKey = [_]u8{0x42} ** 32;
    
    const public_key = try crypto.unaudited_getPublicKey(private_key);
    const signer_address = public_key.to_address();
    const target_address = try Address.from_hex("0x1111111111111111111111111111111111111111");
    
    const auth = try primitives.Authorization.create_authorization(
        allocator,
        1, // chain_id
        target_address,
        0, // nonce
        private_key
    );
    
    // Recover authority
    const recovered_authority = try auth.authority();
    try testing.expectEqual(signer_address, recovered_authority);
    
    // Authority must match the signer, not the target
    try testing.expect(!recovered_authority.equals(target_address));
}

test "EIP-7702: Authorization revocation (nonce = 2^64 - 1)" {
    const allocator = testing.allocator;
    
    var db = evm.MemoryDatabase.init(allocator);
    defer db.deinit();
    
    // Setup EOA with existing delegation
    const eoa_address = try Address.from_hex("0x1111111111111111111111111111111111111111");
    var eoa_account = evm.Account.zero();
    eoa_account.nonce = 5;
    const delegated_addr = try Address.from_hex("0x2222222222222222222222222222222222222222");
    eoa_account.delegated_address = .{ .bytes = delegated_addr.bytes };
    try db.set_account(eoa_address.bytes, eoa_account);
    
    // Create revocation authorization (nonce = max u64)
    const auth = Authorization{
        .chain_id = 1,
        .address = Address.ZERO, // Revoke by setting to zero
        .nonce = std.math.maxInt(u64), // Special revocation nonce
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = [_]u8{0x34} ** 32,
    };
    
    const processor = AuthorizationProcessor.init(allocator, &db);
    try processor.processAuthorization(auth, eoa_address);
    
    // Verify delegation was removed
    const updated_account = try db.get_account(eoa_address.bytes);
    try testing.expect(!updated_account.?.has_delegation());
    try testing.expect(updated_account.?.get_effective_code_address() == null);
}

// ============================================================================
// TEST 8: Integration with EVM Execution
// ============================================================================

test "EIP-7702: Full transaction execution with authorization list" {
    const allocator = testing.allocator;
    
    // Setup database
    var db = evm.MemoryDatabase.init(allocator);
    defer db.deinit();
    
    // Create sender account
    const sender_address = try Address.from_hex("0x9999999999999999999999999999999999999999");
    var sender_account = evm.Account.zero();
    sender_account.balance = 10_000_000_000_000_000_000; // 10 ETH
    try db.set_account(sender_address.bytes, sender_account);
    
    // Create EOA that will delegate
    const eoa_address = try Address.from_hex("0x1111111111111111111111111111111111111111");
    var eoa_account = evm.Account.zero();
    eoa_account.balance = 1_000_000_000_000_000_000; // 1 ETH
    eoa_account.nonce = 0;
    try db.set_account(eoa_address.bytes, eoa_account);
    
    // Create contract to delegate to
    const contract_address = try Address.from_hex("0x2222222222222222222222222222222222222222");
    const contract_code = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0x00
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x00, // PUSH1 0x00
        0xf3,       // RETURN
    };
    // Set the contract code - get code hash and set up account
    const code_hash = try db.set_code(&contract_code);
    var contract_account = evm.Account.zero();
    contract_account.code_hash = code_hash;
    try db.set_account(contract_address.bytes, contract_account);
    
    // Create authorization
    const auth = Authorization{
        .chain_id = 1,
        .address = contract_address,
        .nonce = 0,
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = [_]u8{0x34} ** 32,
    };
    
    // Create transaction with authorization list
    const tx = Eip7702Transaction{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 1_000_000_000,
        .max_fee_per_gas = 20_000_000_000,
        .gas_limit = 200_000,
        .to = eoa_address, // Call the EOA after delegation
        .value = 0,
        .data = &[_]u8{},
        .access_list = &[_]primitives.Transaction.AccessListItem{},
        .authorization_list = &[_]Authorization{auth},
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };
    
    // Execute transaction
    var evm_instance = try evm.Evm.init(allocator, &db.to_database_interface());
    defer evm_instance.deinit();
    
    const result = try evm_instance.executeTransaction(tx, sender_address);
    defer if (result.output) |output| allocator.free(output);
    
    // Transaction should succeed
    try testing.expect(result.success);
    
    // EOA should now have delegation
    const updated_eoa = try db.get_account(eoa_address.bytes);
    try testing.expect(updated_eoa.?.has_delegation());
    try testing.expectEqual(contract_address, updated_eoa.?.get_effective_code_address().?);
    
    // Should have executed contract code and returned 0x42
    try testing.expect(result.output != null);
    try testing.expectEqual(@as(usize, 32), result.output.?.len);
    try testing.expectEqual(@as(u8, 0x42), result.output.?[31]);
}

// ============================================================================
// Helper Functions (to be implemented)
// ============================================================================

const EIP7702Error = error{
    InvalidDesignator,
    NonceMismatch,
    ChainIdMismatch,
    NotEOA,
    InvalidSignature,
    OutOfGas,
};

fn createDelegationDesignator(allocator: std.mem.Allocator, address: Address) ![]u8 {
    var designator = try allocator.alloc(u8, 23);
    designator[0] = 0xef;
    designator[1] = 0x01;
    designator[2] = 0x00;
    @memcpy(designator[3..23], &address.bytes);
    return designator;
}

fn parseDelegationDesignator(designator: []const u8) !Address {
    if (designator.len != 23) return EIP7702Error.InvalidDesignator;
    if (designator[0] != 0xef or designator[1] != 0x01 or designator[2] != 0x00) {
        return EIP7702Error.InvalidDesignator;
    }
    return Address{ .bytes = designator[3..23].* };
}

// Transaction type for EIP-7702
const Eip7702Transaction = struct {
    chain_id: u64,
    nonce: u64,
    max_priority_fee_per_gas: u256,
    max_fee_per_gas: u256,
    gas_limit: u64,
    to: ?Address,
    value: u256,
    data: []const u8,
    access_list: []const primitives.Transaction.AccessListItem,
    authorization_list: []const Authorization,
    v: u64,
    r: [32]u8,
    s: [32]u8,
};

fn encodeEip7702Transaction(allocator: std.mem.Allocator, tx: Eip7702Transaction) ![]u8 {
    _ = tx;
    // TODO: Implement RLP encoding for type 0x04 transaction
    var result = try allocator.alloc(u8, 100);
    result[0] = 0x04;
    return result;
}

fn calculateIntrinsicGas(tx: Eip7702Transaction) !u64 {
    var gas: u64 = 21000; // Base transaction cost
    
    // Add authorization costs
    const auth_gas = primitives.Authorization.calculate_authorization_gas_cost(
        tx.authorization_list,
        0 // TODO: Count empty accounts
    );
    gas += auth_gas;
    
    // Add data costs
    for (tx.data) |byte| {
        if (byte == 0) {
            gas += 4;
        } else {
            gas += 16;
        }
    }
    
    return gas;
}

// Authorization processor (to be implemented)
const AuthorizationProcessor = struct {
    allocator: std.mem.Allocator,
    db: *evm.MemoryDatabase,
    chain_id: u64 = 1,
    
    pub fn init(allocator: std.mem.Allocator, db: *evm.MemoryDatabase) AuthorizationProcessor {
        return .{
            .allocator = allocator,
            .db = db,
            .chain_id = 1,
        };
    }
    
    pub fn processAuthorization(self: *AuthorizationProcessor, auth: Authorization, authority: Address) !void {
        _ = self;
        _ = auth;
        _ = authority;
        // TODO: Implement authorization processing logic
        return error.NotImplemented;
    }
};