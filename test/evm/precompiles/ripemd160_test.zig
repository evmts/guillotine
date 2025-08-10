const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
// Skip tests when precompiles are disabled - access through evm module
const no_precompiles = false; // Default to false, let individual tests handle this

// Convenience aliases
const ripemd160 = Evm.precompiles.ripemd160;
const precompiles = Evm.precompiles.precompiles;
const PrecompileOutput = Evm.precompiles.precompile_result.PrecompileOutput;
const PrecompileError = Evm.precompiles.precompile_result.PrecompileError;
const ChainRules = Evm.hardforks.HardforkChainRules;

// Known RIPEMD160 test vectors from official specification
// and Bitcoin Core implementation
const EMPTY_HASH = [_]u8{ 0x9c, 0x11, 0x85, 0xa5, 0xc5, 0xe9, 0xfc, 0x54, 0x61, 0x28, 0x08, 0x97, 0x7e, 0xe8, 0xf5, 0x48, 0xb2, 0x25, 0x8d, 0x31 };

const ABC_HASH = [_]u8{ 0x8e, 0xb2, 0x08, 0xf7, 0xe0, 0x5d, 0x98, 0x7a, 0x9b, 0x04, 0x4a, 0x8e, 0x98, 0xc6, 0xb0, 0x87, 0xf1, 0x5a, 0x0b, 0xfc };

const MESSAGE_DIGEST_HASH = [_]u8{ 0x5d, 0x06, 0x89, 0xef, 0x49, 0xd2, 0xfa, 0xe5, 0x72, 0xb8, 0x81, 0xb1, 0x23, 0xa8, 0x5f, 0xfa, 0x21, 0x59, 0x5f, 0x36 };

const ALPHABET_HASH = [_]u8{ 0xf7, 0x1c, 0x27, 0x10, 0x9c, 0x69, 0x2c, 0x1b, 0x56, 0xbb, 0xdc, 0xeb, 0x5b, 0x9d, 0x28, 0x65, 0xb3, 0x70, 0x8d, 0xbc };

const LONG_STRING_HASH = [_]u8{ 0x12, 0xa0, 0x53, 0x38, 0x4a, 0x9c, 0x0c, 0x88, 0xe4, 0x05, 0xa0, 0x6c, 0x27, 0xdc, 0xf4, 0x9a, 0xda, 0x62, 0xeb, 0x2b };

const ALPHANUM_HASH = [_]u8{ 0xb0, 0xe2, 0x0b, 0x6e, 0x31, 0x16, 0x64, 0x02, 0x86, 0xed, 0x3a, 0x87, 0xa5, 0x71, 0x30, 0x79, 0xb2, 0x1f, 0x51, 0x89 };

const REPEATED_DIGITS_HASH = [_]u8{ 0x9b, 0x75, 0x2e, 0x45, 0x57, 0x3d, 0x4b, 0x39, 0xf4, 0xdb, 0xd3, 0x32, 0x3c, 0xab, 0x82, 0xbf, 0x63, 0x32, 0x6b, 0xfb };

const MILLION_A_HASH = [_]u8{ 0x52, 0x78, 0x32, 0x43, 0xc1, 0x69, 0x7b, 0xdb, 0xe1, 0x6d, 0x37, 0xf9, 0x7f, 0x68, 0xf0, 0x83, 0x25, 0xdc, 0x15, 0x28 };

test "RIPEMD160 gas calculation matches Ethereum specification" {
    // Empty input: 600 base gas
    try testing.expectEqual(@as(u64, 600), ripemd160.calculate_gas(0));

    // 1 byte: 600 + 120 * 1 = 720
    try testing.expectEqual(@as(u64, 720), ripemd160.calculate_gas(1));

    // 32 bytes: 600 + 120 * 1 = 720
    try testing.expectEqual(@as(u64, 720), ripemd160.calculate_gas(32));

    // 33 bytes: 600 + 120 * 2 = 840
    try testing.expectEqual(@as(u64, 840), ripemd160.calculate_gas(33));

    // 64 bytes: 600 + 120 * 2 = 840
    try testing.expectEqual(@as(u64, 840), ripemd160.calculate_gas(64));

    // 65 bytes: 600 + 120 * 3 = 960
    try testing.expectEqual(@as(u64, 960), ripemd160.calculate_gas(65));
}

test "RIPEMD160 gas calculation overflow protection" {
    // Should handle normal sizes without error
    try testing.expectEqual(@as(u64, 600), try ripemd160.calculate_gas_checked(0));
    try testing.expectEqual(@as(u64, 720), try ripemd160.calculate_gas_checked(1));

    // Test with large but valid input size
    const large_size = 1024 * 1024; // 1MB
    const expected_gas = 600 + 120 * ((large_size + 31) / 32);
    try testing.expectEqual(expected_gas, try ripemd160.calculate_gas_checked(large_size));
}

test "RIPEMD160 output size is always 32 bytes" {
    try testing.expectEqual(@as(usize, 32), ripemd160.get_output_size(0));
    try testing.expectEqual(@as(usize, 32), ripemd160.get_output_size(1));
    try testing.expectEqual(@as(usize, 32), ripemd160.get_output_size(100));
    try testing.expectEqual(@as(usize, 32), ripemd160.get_output_size(1000));
}

test "RIPEMD160 call validation" {
    // Should succeed with sufficient gas
    try testing.expect(ripemd160.validate_call(0, 600));
    try testing.expect(ripemd160.validate_call(1, 720));
    try testing.expect(ripemd160.validate_call(32, 720));

    // Should fail with insufficient gas
    try testing.expect(!ripemd160.validate_call(0, 599));
    try testing.expect(!ripemd160.validate_call(1, 719));
    try testing.expect(!ripemd160.validate_call(33, 839));
}

test "ripemd160 execute empty input" {
    var output_buffer: [32]u8 = undefined;
    const result = ripemd160.execute(&[_]u8{}, &output_buffer, 700);

    try testing.expect(result.is_success());
    try testing.expectEqual(@as(u64, 600), result.get_gas_used());
    try testing.expectEqual(@as(usize, 32), result.get_output_size());

    // Verify hash matches known empty string hash
    // First 12 bytes should be zeros (padding)
    try testing.expectEqualSlices(u8, &[_]u8{0} ** 12, output_buffer[0..12]);
    // Next 20 bytes should be the hash
    try testing.expectEqualSlices(u8, &EMPTY_HASH, output_buffer[12..32]);
}

test "ripemd160 execute 'abc'" {
    var output_buffer: [32]u8 = undefined;
    const result = ripemd160.execute("abc", &output_buffer, 800);

    try testing.expect(result.is_success());
    try testing.expectEqual(@as(u64, 720), result.get_gas_used());
    try testing.expectEqual(@as(usize, 32), result.get_output_size());

    // Verify output format and hash
    try testing.expectEqualSlices(u8, &[_]u8{0} ** 12, output_buffer[0..12]);
    try testing.expectEqualSlices(u8, &ABC_HASH, output_buffer[12..32]);
}

test "ripemd160 execute 'message digest'" {
    var output_buffer: [32]u8 = undefined;
    const result = ripemd160.execute("message digest", &output_buffer, 800);

    try testing.expect(result.is_success());
    try testing.expectEqual(@as(u64, 720), result.get_gas_used());
    try testing.expectEqual(@as(usize, 32), result.get_output_size());

    // Verify output format and hash
    try testing.expectEqualSlices(u8, &[_]u8{0} ** 12, output_buffer[0..12]);
    try testing.expectEqualSlices(u8, &MESSAGE_DIGEST_HASH, output_buffer[12..32]);
}

test "ripemd160 execute alphabet" {
    var output_buffer: [32]u8 = undefined;
    const input = "abcdefghijklmnopqrstuvwxyz";
    const result = ripemd160.execute(input, &output_buffer, 800);

    try testing.expect(result.is_success());
    try testing.expectEqual(@as(u64, 720), result.get_gas_used());
    try testing.expectEqual(@as(usize, 32), result.get_output_size());

    // Verify output format and hash
    try testing.expectEqualSlices(u8, &[_]u8{0} ** 12, output_buffer[0..12]);
    try testing.expectEqualSlices(u8, &ALPHABET_HASH, output_buffer[12..32]);
}

test "ripemd160 execute long string" {
    var output_buffer: [32]u8 = undefined;
    const input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
    const result = ripemd160.execute(input, &output_buffer, 1000);

    try testing.expect(result.is_success());
    try testing.expectEqual(@as(u64, 840), result.get_gas_used()); // 2 words
    try testing.expectEqual(@as(usize, 32), result.get_output_size());

    // Verify output format and hash
    try testing.expectEqualSlices(u8, &[_]u8{0} ** 12, output_buffer[0..12]);
    try testing.expectEqualSlices(u8, &LONG_STRING_HASH, output_buffer[12..32]);
}

test "ripemd160 execute alphanumeric" {
    var output_buffer: [32]u8 = undefined;
    const input = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    const result = ripemd160.execute(input, &output_buffer, 1000);

    try testing.expect(result.is_success());
    try testing.expectEqual(@as(u64, 840), result.get_gas_used()); // 2 words
    try testing.expectEqual(@as(usize, 32), result.get_output_size());

    // Verify output format and hash
    try testing.expectEqualSlices(u8, &[_]u8{0} ** 12, output_buffer[0..12]);
    try testing.expectEqualSlices(u8, &ALPHANUM_HASH, output_buffer[12..32]);
}

test "ripemd160 execute repeated digits" {
    var output_buffer: [32]u8 = undefined;
    const input = "12345678901234567890123456789012345678901234567890123456789012345678901234567890";
    const result = ripemd160.execute(input, &output_buffer, 1000);

    try testing.expect(result.is_success());
    try testing.expectEqual(@as(u64, 960), result.get_gas_used()); // 3 words
    try testing.expectEqual(@as(usize, 32), result.get_output_size());

    // Verify output format and hash
    try testing.expectEqualSlices(u8, &[_]u8{0} ** 12, output_buffer[0..12]);
    try testing.expectEqualSlices(u8, &REPEATED_DIGITS_HASH, output_buffer[12..32]);
}

test "ripemd160 execute out of gas" {
    const input_data = "abc";
    var output_buffer: [32]u8 = undefined;

    // Provide insufficient gas (need 720, only provide 719)
    const result = ripemd160.execute(input_data, &output_buffer, 719);

    try testing.expect(result.is_failure());
    try testing.expectEqual(PrecompileError.OutOfGas, result.get_error().?);
    try testing.expectEqual(@as(u64, 0), result.get_gas_used());
}

test "ripemd160 execute insufficient output buffer" {
    const input_data = "abc";
    var output_buffer: [31]u8 = undefined; // Too small for 32-byte output

    const result = ripemd160.execute(input_data, &output_buffer, 800);

    try testing.expect(result.is_failure());
    try testing.expectEqual(PrecompileError.ExecutionFailed, result.get_error().?);
}

test "precompile dispatcher ripemd160 integration" {
    if (comptime no_precompiles) return testing.skip("precompiles disabled");
    const ripemd160_address: Address = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x03 };

    // Check address detection
    try testing.expect(precompiles.is_precompile(ripemd160_address));

    // Check availability with default chain rules
    const chain_rules = ChainRules.DEFAULT;
    try testing.expect(precompiles.is_available(ripemd160_address, chain_rules));
}

test "precompile dispatcher execute ripemd160" {
    if (comptime no_precompiles) return testing.skip("precompiles disabled");
    const ripemd160_address: Address = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x03 };

    var output_buffer: [32]u8 = undefined;

    const chain_rules = ChainRules.DEFAULT;
    const result = precompiles.execute_precompile(ripemd160_address, "abc", &output_buffer, 800, chain_rules);

    try testing.expect(result.is_success());
    try testing.expectEqual(@as(u64, 720), result.get_gas_used());
    try testing.expectEqual(@as(usize, 32), result.get_output_size());

    // Verify output format
    try testing.expectEqualSlices(u8, &[_]u8{0} ** 12, output_buffer[0..12]);
    try testing.expectEqualSlices(u8, &ABC_HASH, output_buffer[12..32]);
}

test "ripemd160 large input stress test" {
    const allocator = testing.allocator;

    // Test with 1KB of data
    const input_size = 1024;
    const input_data = try allocator.alloc(u8, input_size);
    defer allocator.free(input_data);

    var output_buffer: [32]u8 = undefined;

    // Fill with test pattern
    for (input_data, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    const result = ripemd160.execute(input_data, &output_buffer, 5000);
    try testing.expect(result.is_success());
    // 1024 bytes = 32 words, so 600 + 120*32 = 4440 gas
    try testing.expectEqual(@as(u64, 4440), result.get_gas_used());
    try testing.expectEqual(@as(usize, 32), result.get_output_size());
}

test "ripemd160 million 'a' test" {
    const allocator = testing.allocator;

    // This is a standard test vector but requires significant memory
    // Only run if we have enough memory available
    const million = 1_000_000;
    const input_data = allocator.alloc(u8, million) catch |err| {
        if (err == error.OutOfMemory) {
            // Skip test if we can't allocate
            return;
        }
        return err;
    };
    defer allocator.free(input_data);

    // Fill with 'a'
    @memset(input_data, 'a');

    var output_buffer: [32]u8 = undefined;

    // Calculate required gas: 600 + 120 * ceil(1000000/32) = 600 + 120 * 31250 = 3,750,600
    const required_gas = ripemd160.calculate_gas(million);
    const result = ripemd160.execute(input_data, &output_buffer, required_gas);

    try testing.expect(result.is_success());
    try testing.expectEqual(required_gas, result.get_gas_used());
    try testing.expectEqual(@as(usize, 32), result.get_output_size());

    // Verify output format and hash
    try testing.expectEqualSlices(u8, &[_]u8{0} ** 12, output_buffer[0..12]);
    try testing.expectEqualSlices(u8, &MILLION_A_HASH, output_buffer[12..32]);
}
