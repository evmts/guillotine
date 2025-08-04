const std = @import("std");
const Frame = @import("frame_fat.zig");
const opcode = @import("../opcodes/opcode.zig");
const Contract = @import("contract.zig");
const StoragePool = @import("storage_pool.zig");
const Log = @import("../log.zig");

/// Error types for contract operations
pub const ContractError = error{
    OutOfAllocatorMemory,
    InvalidStorageOperation,
};

// ============================================================================
// GAS OPERATIONS
// ============================================================================

/// Attempts to consume gas from the frame's available gas.
///
/// This is the primary gas accounting method, called before every
/// operation to ensure sufficient gas remains.
///
/// @param self The frame to consume gas from
/// @param amount Gas units to consume
/// @return true if gas successfully deducted, false if insufficient
pub fn use_gas(self: *Frame, amount: u64) bool {
    if (self.gas_remaining < amount) return false;
    self.gas_remaining -= amount;
    return true;
}

/// Use gas without checking (when known safe).
///
/// @param self The frame to consume gas from
/// @param amount Gas units to consume
pub fn use_gas_unchecked(self: *Frame, amount: u64) void {
    self.gas_remaining -= amount;
}

/// Refund gas to frame.
///
/// @param self The frame to refund gas to
/// @param amount Gas units to refund
pub fn refund_gas(self: *Frame, amount: u64) void {
    self.gas_remaining += amount;
}

/// Add to gas refund counter with clamping.
///
/// Limited to gas_used / 5 by EIP-3529.
///
/// @param self The frame to add refund to
/// @param amount Gas units to add to refund
pub fn add_gas_refund(self: *Frame, amount: u64) void {
    const max_refund = self.gas_remaining / 5;
    self.gas_refund = @min(self.gas_refund + amount, max_refund);
}

/// Subtract from gas refund counter with clamping.
///
/// @param self The frame to subtract refund from
/// @param amount Gas units to subtract from refund
pub fn sub_gas_refund(self: *Frame, amount: u64) void {
    self.gas_refund = if (self.gas_refund > amount) self.gas_refund - amount else 0;
}

// ============================================================================
// CODE OPERATIONS
// ============================================================================

/// Get opcode at position with bounds checking.
///
/// @param self The frame containing the code
/// @param n Position in bytecode
/// @return Opcode at position or STOP if out of bounds
pub fn get_op(self: *const Frame, n: u64) u8 {
    return if (n < self.code_size) self.code[@intCast(n)] else @intFromEnum(opcode.Enum.STOP);
}

/// Get opcode at position without bounds check.
///
/// Caller must ensure n < code_size.
///
/// @param self The frame containing the code
/// @param n Position in bytecode
/// @return Opcode at position
pub fn get_op_unchecked(self: *const Frame, n: u64) u8 {
    return self.code[n];
}

/// Check if position is code (not data).
///
/// @param self The frame containing the code
/// @param pos Position to check
/// @return true if position contains executable code
pub fn is_code(self: *const Frame, pos: u64) bool {
    if (self.analysis) |analysis| {
        return analysis.code_segments.isSetUnchecked(@intCast(pos));
    }
    return true;
}

/// Validates if a jump destination is valid within the contract bytecode.
///
/// A valid jump destination must:
/// 1. Be within code bounds (< code_size)
/// 2. Point to a JUMPDEST opcode (0x5B)
/// 3. Not be inside PUSH data (validated by code analysis)
///
/// @param self The frame containing the code
/// @param allocator Allocator for lazy code analysis
/// @param dest Target program counter from JUMP/JUMPI
/// @return true if valid JUMPDEST at target position
pub fn valid_jumpdest(self: *Frame, allocator: std.mem.Allocator, dest: u256) bool {
    // Fast path: empty code or out of bounds
    if (self.is_empty or dest >= self.code_size) return false;
    
    // Fast path: no JUMPDESTs in code
    if (!self.has_jumpdests) return false;
    const pos: u32 = @intCast(@min(dest, std.math.maxInt(u32)));
    
    // Perform analysis if not already done
    if (self.analysis == null) {
        self.analysis = Contract.analyze_code(allocator, self.code, self.code_hash) catch return false;
    }
    
    const analysis = self.analysis orelse return false;
    
    // O(1) lookup in the JUMPDEST bitmap
    return analysis.jumpdest_bitmap.isSetUnchecked(pos);
}

// ============================================================================
// STORAGE ACCESS TRACKING (EIP-2929)
// ============================================================================

/// Mark storage slot as warm with pool support.
///
/// @param self The frame tracking storage access
/// @param allocator Memory allocator
/// @param slot Storage slot to mark
/// @param pool Optional storage pool for efficiency
/// @return true if slot was cold (first access)
/// @throws OutOfAllocatorMemory if allocation fails
pub fn mark_storage_slot_warm(
    self: *Frame,
    allocator: std.mem.Allocator,
    slot: u256,
    pool: ?*StoragePool,
) ContractError!bool {
    if (self.storage_access == null) {
        if (pool) |p| {
            self.storage_access = p.borrow_access_map() catch |err| switch (err) {
                StoragePool.BorrowAccessMapError.OutOfAllocatorMemory => {
                    Log.debug("Frame.mark_storage_slot_warm: failed to borrow access map", .{});
                    return ContractError.OutOfAllocatorMemory;
                },
            };
        } else {
            const map = allocator.create(std.AutoHashMap(u256, bool)) catch {
                return ContractError.OutOfAllocatorMemory;
            };
            map.* = std.AutoHashMap(u256, bool).init(allocator);
            self.storage_access = map;
        }
    }
    
    const map = self.storage_access.?;
    const was_cold = !map.contains(slot);
    if (was_cold) {
        map.put(slot, true) catch {
            return ContractError.OutOfAllocatorMemory;
        };
    }
    return was_cold;
}

/// Check if storage slot is cold.
///
/// @param self The frame tracking storage access
/// @param slot Storage slot to check
/// @return true if slot has not been accessed yet
pub fn is_storage_slot_cold(self: *const Frame, slot: u256) bool {
    if (self.storage_access) |map| {
        return !map.contains(slot);
    }
    return true;
}

/// Store original storage value.
///
/// Used for gas refund calculations in SSTORE.
///
/// @param self The frame tracking storage
/// @param allocator Memory allocator
/// @param slot Storage slot
/// @param value Original value at transaction start
/// @param pool Optional storage pool for efficiency
/// @throws OutOfAllocatorMemory if allocation fails
pub fn set_original_storage_value(
    self: *Frame,
    allocator: std.mem.Allocator,
    slot: u256,
    value: u256,
    pool: ?*StoragePool,
) ContractError!void {
    if (self.original_storage == null) {
        if (pool) |p| {
            self.original_storage = p.borrow_storage_map() catch |err| switch (err) {
                StoragePool.BorrowStorageMapError.OutOfAllocatorMemory => {
                    Log.debug("Frame.set_original_storage_value: failed to borrow storage map", .{});
                    return ContractError.OutOfAllocatorMemory;
                },
            };
        } else {
            const map = allocator.create(std.AutoHashMap(u256, u256)) catch {
                return ContractError.OutOfAllocatorMemory;
            };
            map.* = std.AutoHashMap(u256, u256).init(allocator);
            self.original_storage = map;
        }
    }
    
    self.original_storage.?.put(slot, value) catch {
        return ContractError.OutOfAllocatorMemory;
    };
}

/// Get original storage value.
///
/// @param self The frame tracking storage
/// @param slot Storage slot
/// @return Original value or null if not tracked
pub fn get_original_storage_value(self: *const Frame, slot: u256) ?u256 {
    if (self.original_storage) |map| {
        return map.get(slot);
    }
    return null;
}