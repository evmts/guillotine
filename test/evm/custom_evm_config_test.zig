// Test for issue #852: Frame coupled to DefaultEvm type breaks custom configs
//
// This test verifies that Frame correctly uses the EVM type it was created with,
// rather than always casting to DefaultEvm.
//
// The bug: Frame.getEvm() hardcodes a cast to DefaultEvm, which breaks when
// using custom EVM configurations.

const std = @import("std");
const testing = std.testing;
const evm_mod = @import("evm");
const EvmConfig = evm_mod.EvmConfig;
const primitives = @import("voltaire");

// Test 1: Verify that custom EVM types have different type identities
test "custom EVM types should have distinct Frame types" {
    // Create two different EVM configurations
    const DefaultEvm = evm_mod.Evm(.{});
    const CustomEvm = evm_mod.Evm(.{
        .max_call_depth = 512, // Different from default 1024
        .disable_gas_checks = true,
    });

    // The Frame types should be different because they're created from different configs
    const DefaultFrame = DefaultEvm.Frame;
    const CustomFrame = CustomEvm.Frame;

    // These should be different types (same config = same type, different config = different type)
    // This is a compile-time check
    const default_is_custom = DefaultFrame == CustomFrame;

    // With the bug, getEvm() always returns *DefaultEvm regardless of which Frame type
    // is actually being used. This test documents that Frame types are indeed different.
    try testing.expect(!default_is_custom);
}

// Test 2: Verify getEvm returns the correct type
// This test demonstrates the bug: Frame.getEvm() returns *DefaultEvm even when
// the Frame was created from a CustomEvm.
test "Frame.getEvm should return correct EVM type" {
    // Create a custom EVM configuration
    const CustomConfig = EvmConfig{
        .max_call_depth = 256,
        .disable_gas_checks = true,
    };
    const CustomEvm = evm_mod.Evm(CustomConfig);

    // For this test, we need to verify that getEvm() returns the correct type.
    // Currently, getEvm() is hardcoded to return *DefaultEvm, which is wrong.
    //
    // The proper fix is to make Frame generic over the EVM type so that
    // getEvm() returns the correct type.

    // Get the return type of getEvm
    const GetEvmReturnType = @typeInfo(@TypeOf(CustomEvm.Frame.getEvm)).@"fn".return_type.?;

    // The bug: getEvm returns *DefaultEvm instead of *CustomEvm
    // After the fix, this should be *CustomEvm
    const DefaultEvm = evm_mod.Evm(.{});

    // This assertion PASSES with the bug (proving the bug exists)
    // After the fix, this should FAIL because getEvm should return *CustomEvm
    const returns_default_evm = GetEvmReturnType == *DefaultEvm;
    const returns_custom_evm = GetEvmReturnType == *CustomEvm;

    // BEFORE FIX: returns_default_evm = true, returns_custom_evm = false
    // AFTER FIX: returns_default_evm = false, returns_custom_evm = true

    // This is the EXPECTED behavior after the fix:
    // getEvm() should return *CustomEvm, not *DefaultEvm
    try testing.expect(returns_custom_evm);
    try testing.expect(!returns_default_evm);
}

// Test 3: Memory layout safety - verify that casting between EVM types is unsafe
test "different EVM configs should have different memory layouts" {
    // Create EVM with different call_stack size (affects struct layout)
    const SmallStackEvm = evm_mod.Evm(.{ .max_call_depth = 16 });
    const LargeStackEvm = evm_mod.Evm(.{ .max_call_depth = 1024 });

    // The call_stack array size is part of the EVM struct, so different
    // max_call_depth values create different struct sizes
    const small_size = @sizeOf(SmallStackEvm);
    const large_size = @sizeOf(LargeStackEvm);

    // Different configs = different struct sizes (usually)
    // If call_stack is [config.max_call_depth]CallStackEntry, sizes will differ
    // This proves that blindly casting between EVM types is unsafe
    try testing.expect(small_size != large_size);
}

// Test 4: Verify that EVM types with same config are identical
test "same EVM configs should produce identical types" {
    const Config1 = EvmConfig{};
    const Config2 = EvmConfig{};

    const Evm1 = evm_mod.Evm(Config1);
    const Evm2 = evm_mod.Evm(Config2);

    // Same config should produce same type
    try testing.expect(Evm1 == Evm2);
    try testing.expect(Evm1.Frame == Evm2.Frame);
}

// Test 5: Verify Frame.Evm type is correctly set
test "Frame.Evm should be the correct EVM type" {
    // Create a custom EVM with a distinctive configuration
    const CustomEvm = evm_mod.Evm(.{
        .max_call_depth = 256,
        .disable_gas_checks = true,
    });

    // The Frame should have the correct EVM type set
    // This is the key fix for issue #852
    const FrameEvmType = CustomEvm.Frame.Evm;

    // The Frame's Evm type should be CustomEvm, not DefaultEvm
    try testing.expect(FrameEvmType == CustomEvm);

    // Verify it's different from the default EVM
    const DefaultEvm = evm_mod.Evm(.{});
    try testing.expect(FrameEvmType != DefaultEvm);
}
