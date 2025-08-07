const std = @import("std");
const ExecutionError = @import("execution_error.zig");
const ExecutionContext = @import("../frame.zig").ExecutionContext;
const primitives = @import("primitives");

pub fn op_blockhash(context_ptr: *anyopaque) ExecutionError.Error!void {
    const context: *ExecutionContext = @ptrCast(@alignCast(context_ptr));
    const block_number = try context.stack.pop();

    // TODO: Need block_number field in ExecutionContext
    // const current_block = context.block_number;
    const current_block: u64 = 1000; // Placeholder

    if (block_number >= current_block) {
        @branchHint(.unlikely);
        try context.stack.append(0);
    } else if (current_block > block_number + 256) {
        @branchHint(.unlikely);
        try context.stack.append(0);
    } else if (block_number == 0) {
        @branchHint(.unlikely);
        try context.stack.append(0);
    } else {
        // Return a pseudo-hash based on block number for testing
        // In production, this would retrieve the actual block hash from chain history
        const hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&block_number));
        try context.stack.append(hash);
    }
}

pub fn op_coinbase(context_ptr: *anyopaque) ExecutionError.Error!void {
    const context: *ExecutionContext = @ptrCast(@alignCast(context_ptr));
    
    // EIP-3651 (Shanghai) COINBASE warming should be handled during pre-execution setup,
    // not at runtime. The coinbase address should be pre-warmed in the access list
    // before execution begins if EIP-3651 is enabled.
    
    // TODO: Need block_coinbase field in ExecutionContext
    // try context.stack.append(primitives.Address.to_u256(context.block_coinbase));
    
    // Placeholder implementation - push zero for now
    try context.stack.append(0);
}

pub fn op_timestamp(context_ptr: *anyopaque) ExecutionError.Error!void {
    const context: *ExecutionContext = @ptrCast(@alignCast(context_ptr));
    // TODO: Need block_timestamp field in ExecutionContext
    // try context.stack.append(@as(u256, @intCast(context.block_timestamp)));
    
    // Placeholder implementation - push zero for now
    try context.stack.append(0);
}

pub fn op_number(context_ptr: *anyopaque) ExecutionError.Error!void {
    const context: *ExecutionContext = @ptrCast(@alignCast(context_ptr));
    // TODO: Need block_number field in ExecutionContext
    // try context.stack.append(@as(u256, @intCast(context.block_number)));
    
    // Placeholder implementation - push zero for now
    try context.stack.append(0);
}

pub fn op_difficulty(context_ptr: *anyopaque) ExecutionError.Error!void {
    const context: *ExecutionContext = @ptrCast(@alignCast(context_ptr));
    // TODO: Need block_difficulty field in ExecutionContext
    // Get difficulty/prevrandao from block context
    // Post-merge this returns PREVRANDAO
    // try context.stack.append(context.block_difficulty);
    
    // Placeholder implementation - push zero for now
    try context.stack.append(0);
}

pub fn op_prevrandao(context_ptr: *anyopaque) ExecutionError.Error!void {
    // Same as difficulty post-merge
    return op_difficulty(context_ptr);
}

pub fn op_gaslimit(context_ptr: *anyopaque) ExecutionError.Error!void {
    const context: *ExecutionContext = @ptrCast(@alignCast(context_ptr));
    // TODO: Need block_gas_limit field in ExecutionContext
    // try context.stack.append(@as(u256, @intCast(context.block_gas_limit)));
    
    // Placeholder implementation - push zero for now
    try context.stack.append(0);
}

pub fn op_basefee(context_ptr: *anyopaque) ExecutionError.Error!void {
    const context: *ExecutionContext = @ptrCast(@alignCast(context_ptr));
    
    // EIP-3198 validation should be handled during bytecode analysis phase,
    // not at runtime. Invalid BASEFEE opcodes should be rejected during code analysis.
    
    // NOTE: BASEFEE opcode (EIP-3198) returns the base fee from the block header.
    // This is separate from EIP-1559 fee market logic, which is handled at the 
    // transaction/client layer, not in the EVM interpreter itself.
    // The EVM only needs to expose the base fee value via this opcode.
    
    // TODO: Need block_base_fee field in ExecutionContext or pass via block context
    // The base fee should be provided by the client/block processing layer
    // try context.stack.append(context.block_base_fee);
    
    // Placeholder implementation - push zero for now
    try context.stack.append(0);
}

pub fn op_blobhash(context_ptr: *anyopaque) ExecutionError.Error!void {
    const context: *ExecutionContext = @ptrCast(@alignCast(context_ptr));
    const index = try context.stack.pop();

    // TODO: Need blob_hashes field in ExecutionContext
    // EIP-4844: Get blob hash at index
    // if (index >= context.blob_hashes.len) {
    //     @branchHint(.unlikely);
    //     try context.stack.append(0);
    // } else {
    //     const idx = @as(usize, @intCast(index));
    //     try context.stack.append(context.blob_hashes[idx]);
    // }
    
    // Placeholder implementation - always return zero
    _ = index;
    try context.stack.append(0);
}

pub fn op_blobbasefee(context_ptr: *anyopaque) ExecutionError.Error!void {
    const context: *ExecutionContext = @ptrCast(@alignCast(context_ptr));
    // TODO: Need blob_base_fee field in ExecutionContext
    // Get blob base fee from block context
    // Push blob base fee (EIP-4844)
    // try context.stack.append(context.blob_base_fee);
    
    // Placeholder implementation - push zero for now
    try context.stack.append(0);
}

// Tests
const testing = std.testing;
const Address = primitives.Address;
const Stack = @import("../stack/stack.zig");
const Memory = @import("../memory/memory.zig");
const CodeAnalysis = @import("../analysis.zig");
const AccessList = @import("../access_list.zig").AccessList;
const SelfDestruct = @import("../self_destruct.zig").SelfDestruct;
const DatabaseInterface = @import("../state/database_interface.zig").DatabaseInterface;
const MemoryDatabase = @import("../state/memory_database.zig");

// FIXME: All test functions that used Frame/Contract have been removed
// They need to be rewritten to use ExecutionContext when the migration is complete

// TODO: Convert all tests to ExecutionContext after VM refactor complete
// All block opcode tests have been temporarily disabled due to Frame/Contract refactor
