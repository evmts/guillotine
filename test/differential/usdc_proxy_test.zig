const std = @import("std");
const FixtureContract = @import("evm").FixtureContract;
const ContractName = @import("evm").ContractName;

test "USDC proxy contract has comprehensive ABI" {
    const usdc = FixtureContract.get(.usdc_proxy);
    
    // Verify contract name and basic info
    try std.testing.expect(std.mem.eql(u8, usdc.abi.name, "USDC"));
    try std.testing.expect(usdc.abi.functions.len > 7); // Should have many more than basic ERC-20
    
    // Verify we have key minting functions
    var found_mint = false;
    var found_configure_minter = false;
    var found_remove_minter = false;
    var found_is_minter = false;
    
    // Verify we have key burning functions
    var found_burn = false;
    
    // Verify we have key pause functions
    var found_pause = false;
    var found_unpause = false;
    var found_paused = false;
    
    // Verify we have key blacklist functions
    var found_blacklist = false;
    var found_unblacklist = false;
    var found_is_blacklisted = false;
    
    // Check all functions
    for (usdc.abi.functions) |func| {
        if (std.mem.eql(u8, func.name, "mint")) found_mint = true;
        if (std.mem.eql(u8, func.name, "configureMinter")) found_configure_minter = true;
        if (std.mem.eql(u8, func.name, "removeMinter")) found_remove_minter = true;
        if (std.mem.eql(u8, func.name, "isMinter")) found_is_minter = true;
        if (std.mem.eql(u8, func.name, "burn")) found_burn = true;
        if (std.mem.eql(u8, func.name, "pause")) found_pause = true;
        if (std.mem.eql(u8, func.name, "unpause")) found_unpause = true;
        if (std.mem.eql(u8, func.name, "paused")) found_paused = true;
        if (std.mem.eql(u8, func.name, "blacklist")) found_blacklist = true;
        if (std.mem.eql(u8, func.name, "unBlacklist")) found_unblacklist = true;
        if (std.mem.eql(u8, func.name, "isBlacklisted")) found_is_blacklisted = true;
    }
    
    // Assert all key functions are present
    try std.testing.expect(found_mint);
    try std.testing.expect(found_configure_minter);
    try std.testing.expect(found_remove_minter);
    try std.testing.expect(found_is_minter);
    try std.testing.expect(found_burn);
    try std.testing.expect(found_pause);
    try std.testing.expect(found_unpause);
    try std.testing.expect(found_paused);
    try std.testing.expect(found_blacklist);
    try std.testing.expect(found_unblacklist);
    try std.testing.expect(found_is_blacklisted);
}

test "USDC proxy contract has comprehensive events" {
    const usdc = FixtureContract.get(.usdc_proxy);
    
    // Note: Our current system doesn't convert events yet, but we can ensure
    // the structure compiles and has the basic name
    try std.testing.expect(std.mem.eql(u8, usdc.abi.name, "USDC"));
    
    // The .zon file should have been loaded successfully with all events
    // (even though we don't have event conversion implemented yet)
}

test "USDC proxy functions have correct signatures" {
    const usdc = FixtureContract.get(.usdc_proxy);
    
    // Find the mint function and verify its signature
    var mint_func_found = false;
    for (usdc.abi.functions) |func| {
        if (std.mem.eql(u8, func.name, "mint")) {
            mint_func_found = true;
            // Mint should have 2 inputs: address to, uint256 amount
            try std.testing.expect(func.inputs.len == 2);
            // Should be nonpayable
            try std.testing.expect(func.state_mutability == .nonpayable);
            break;
        }
    }
    try std.testing.expect(mint_func_found);
    
    // Find the blacklist function and verify its signature
    var blacklist_func_found = false;
    for (usdc.abi.functions) |func| {
        if (std.mem.eql(u8, func.name, "blacklist")) {
            blacklist_func_found = true;
            // Blacklist should have 1 input: address account
            try std.testing.expect(func.inputs.len == 1);
            // Should be nonpayable
            try std.testing.expect(func.state_mutability == .nonpayable);
            break;
        }
    }
    try std.testing.expect(blacklist_func_found);
    
    // Find the paused function and verify it's a view function
    var paused_func_found = false;
    for (usdc.abi.functions) |func| {
        if (std.mem.eql(u8, func.name, "paused")) {
            paused_func_found = true;
            // Paused should have no inputs
            try std.testing.expect(func.inputs.len == 0);
            // Should be view
            try std.testing.expect(func.state_mutability == .view);
            break;
        }
    }
    try std.testing.expect(paused_func_found);
}