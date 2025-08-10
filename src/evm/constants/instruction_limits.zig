const std = @import("std");

/// Maximum number of instructions in the translated instruction stream.
///
/// This limits the size of pre-allocated instruction arrays to avoid
/// unbounded memory usage. The value is chosen to accommodate:
/// - Maximum contract size (24KB) translates to roughly 24K instructions worst-case
/// - Each bytecode instruction can expand to at most 2 instructions (opcode + OPX_BEGINBLOCK)
/// - Additional overhead for pattern compression
///
/// 64K instructions * 24 bytes/instruction = 1.5MB maximum memory per contract
pub const MAX_INSTRUCTIONS: usize = 65536;

/// Maximum contract size in bytes (EIP-170)
pub const MAX_CONTRACT_SIZE: usize = 24576;

test "instruction limits are reasonable" {
    // Verify MAX_INSTRUCTIONS can handle maximum contract size
    // Worst case: every byte is a separate instruction
    try std.testing.expect(MAX_INSTRUCTIONS >= MAX_CONTRACT_SIZE);

    // Verify it leaves room for expansion (2x for block markers, etc)
    try std.testing.expect(MAX_INSTRUCTIONS >= MAX_CONTRACT_SIZE * 2);

    // Verify memory usage is bounded
    const instruction_size = 24; // Approximate size of Instruction struct
    const max_memory = MAX_INSTRUCTIONS * instruction_size;
    try std.testing.expect(max_memory <= 2 * 1024 * 1024); // Max 2MB
}

test "contract size limit matches EIP-170" {
    // EIP-170 specifies 24KB maximum contract size
    try std.testing.expectEqual(@as(usize, 24576), MAX_CONTRACT_SIZE);
    try std.testing.expectEqual(@as(usize, 0x6000), MAX_CONTRACT_SIZE);
}
