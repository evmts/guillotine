const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;
const testing = std.testing;

// Test that STATICCALL properly prevents state modifications (EIP-214)
// This test creates a contract and makes a STATICCALL to it that attempts SSTORE
test "differential: STATICCALL should prevent state modifications" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Contract that will attempt SSTORE when called
    // Runtime bytecode: SSTORE then RETURN data
    const target_contract_code = [_]u8{
        0x60, 0x2a,        // PUSH1 42 (value to store)
        0x60, 0x00,        // PUSH1 0 (storage key)
        0x55,              // SSTORE (should fail in static context due to EIP-214!)
        0x60, 0x63,        // PUSH1 99 (return value indicating "success")
        0x60, 0x00,        // PUSH1 0 (memory offset)
        0x52,              // MSTORE
        0x60, 0x20,        // PUSH1 32 (return size)
        0x60, 0x00,        // PUSH1 0 (return offset)
        0xf3,              // RETURN
    };
    
    // Deployment bytecode that returns the target contract code
    var deployment_bytecode: [32 + target_contract_code.len]u8 = undefined;
    
    // CODECOPY to memory then RETURN  
    deployment_bytecode[0] = 0x60; // PUSH1
    deployment_bytecode[1] = @intCast(target_contract_code.len); // code length
    deployment_bytecode[2] = 0x60; // PUSH1
    deployment_bytecode[3] = 32;   // source offset (skip this deployment code)
    deployment_bytecode[4] = 0x60; // PUSH1  
    deployment_bytecode[5] = 0x00; // dest offset
    deployment_bytecode[6] = 0x39; // CODECOPY
    deployment_bytecode[7] = 0x60; // PUSH1
    deployment_bytecode[8] = @intCast(target_contract_code.len); // return length
    deployment_bytecode[9] = 0x60; // PUSH1
    deployment_bytecode[10] = 0x00; // return offset
    deployment_bytecode[11] = 0xf3; // RETURN
    
    // Fill remaining deployment bytecode with padding
    for (12..32) |i| {
        deployment_bytecode[i] = 0x00;
    }
    
    // Append the target contract code
    for (target_contract_code, 0..) |byte, i| {
        deployment_bytecode[32 + i] = byte;
    }
    
    // Main contract that deploys target and makes STATICCALL to it
    var main_contract: [512]u8 = undefined;
    var pos: usize = 0;
    
    // Store deployment bytecode in memory
    for (deployment_bytecode, 0..) |byte, i| {
        main_contract[pos] = 0x60; pos += 1;         // PUSH1
        main_contract[pos] = byte; pos += 1;         // byte value
        main_contract[pos] = 0x60; pos += 1;         // PUSH1  
        main_contract[pos] = @intCast(i); pos += 1;  // memory offset
        main_contract[pos] = 0x52; pos += 1;         // MSTORE
    }
    
    // CREATE the target contract
    main_contract[pos] = 0x60; pos += 1; // PUSH1
    main_contract[pos] = @intCast(deployment_bytecode.len); pos += 1; // code size
    main_contract[pos] = 0x60; pos += 1; // PUSH1
    main_contract[pos] = 0x00; pos += 1; // code offset
    main_contract[pos] = 0x60; pos += 1; // PUSH1
    main_contract[pos] = 0x00; pos += 1; // value
    main_contract[pos] = 0xf0; pos += 1; // CREATE
    
    // STATICCALL to the created contract
    main_contract[pos] = 0x60; pos += 1; // PUSH1
    main_contract[pos] = 0x20; pos += 1; // return data size (32)
    main_contract[pos] = 0x60; pos += 1; // PUSH1
    main_contract[pos] = 0x00; pos += 1; // return data offset
    main_contract[pos] = 0x60; pos += 1; // PUSH1
    main_contract[pos] = 0x00; pos += 1; // input size
    main_contract[pos] = 0x60; pos += 1; // PUSH1
    main_contract[pos] = 0x00; pos += 1; // input offset
    // Contract address from CREATE is already on stack
    main_contract[pos] = 0x5a; pos += 1; // GAS
    main_contract[pos] = 0xfa; pos += 1; // STATICCALL - This should prevent SSTORE!
    
    // Return the STATICCALL result
    main_contract[pos] = 0x60; pos += 1; // PUSH1
    main_contract[pos] = 0x20; pos += 1; // return size
    main_contract[pos] = 0x60; pos += 1; // PUSH1
    main_contract[pos] = 0x00; pos += 1; // return offset
    main_contract[pos] = 0xf3; pos += 1; // RETURN
    
    const final_bytecode = main_contract[0..pos];
    
    // This should show different behavior:
    // - revm: STATICCALL fails because SSTORE is attempted in static context
    // - guillotine (buggy): STATICCALL succeeds because static protection isn't applied
    try testor.test_bytecode(final_bytecode);
}