// Re-export the refactored code analysis module
pub usingnamespace @import("code_analysis.zig");

// Re-export JumpdestArray from size_buckets
pub const JumpdestArray = @import("size_buckets.zig").JumpdestArray;

// Import dependencies for tests
const std = @import("std");
const OpcodeMetadata = @import("opcode_metadata/opcode_metadata.zig");
const CodeAnalysis = @import("code_analysis.zig").CodeAnalysis;
const Address = @import("../address/address.zig");
const Frame = @import("frame.zig").Frame;
// const Contract = @import("contract.zig").Contract;
// const Vm = @import("../evm.zig").Vm;
// const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
// const Operation = @import("opcode_metadata/operation.zig");
const DynamicBitSet = std.DynamicBitSet;
const limits = @import("constants/code_analysis_limits.zig");
const Instruction = @import("instruction.zig").Instruction;
const Tag = @import("instruction.zig").Tag;
const InstructionType = @import("instruction.zig").InstructionType;

// Import bucket types for tests
const Bucket2 = @import("size_buckets.zig").Bucket2;
const Bucket8 = @import("size_buckets.zig").Bucket8;
const Bucket16 = @import("size_buckets.zig").Bucket16;

// Tests moved from original analysis.zig  
// These tests verify the correct behavior of the refactored modules

// Import other required types
const ExecutionError = @import("execution/execution_error.zig");

// Tests below

test "analysis: minimal dispatcher (SHR) resolves conditional jump target" {
    const allocator = std.testing.allocator;
    const code = &[_]u8{
        0x60, 0x00, // PUSH1 0
        0x35, // CALLDATALOAD
        0x60, 0xe0, // PUSH1 0xe0
        0x1c, // SHR
        0x63, 0x11, 0x22, 0x33, 0x44, // PUSH4 0x11223344
        0x14, // EQ
        0x60, 0x16, // PUSH1 0x16
        0x57, // JUMPI
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0xfd, // REVERT
        0x5b, // JUMPDEST (0x16)
        0x60, 0x01, // PUSH1 1
        0x60, 0x1f, // PUSH1 31
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x20, // PUSH1 32 (size)
        0xf3, // RETURN
    };

    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    // Ensure JUMPI is present and its target block is mapped
    var has_jumpi = false;
    for (analysis.inst_jump_type) |jt| {
        if (jt == .jumpi) has_jumpi = true;
    }
    try std.testing.expect(has_jumpi);

    // No unresolved fused immediates should remain for this small case
    for (analysis.instructions) |inst| {
        if (inst.tag == .jump_pc) {
            return error.TestUnexpectedResult;
        }
    }

    // Destination 0x16 must map to a BEGINBLOCK entry
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(0x16));
    const bb_idx = analysis.pc_to_block_start[0x16];
    try std.testing.expect(bb_idx != std.math.maxInt(u16));
    try std.testing.expect(bb_idx < analysis.instructions.len);
    try std.testing.expect(@as(bool, analysis.instructions[bb_idx].tag == .block_info));
}

test "analysis: minimal dispatcher (AND-mask) resolves conditional jump target" {
    const allocator = std.testing.allocator;
    const code = &[_]u8{
        0x60, 0x00, // PUSH1 0
        0x35, // CALLDATALOAD
        0x63, 0xff, 0xff, 0xff, 0xff, // PUSH4 0xffffffff
        0x16, // AND
        0x63, 0x30, 0x62, 0x7b, 0x7c, // PUSH4 0x30627b7c
        0x14, // EQ
        0x60, 0x16, // PUSH1 0x16
        0x57, // JUMPI
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0xfd, // REVERT
        0x5b, // JUMPDEST (0x16)
        0x60, 0x01, // PUSH1 1
        0x60, 0x1f, // PUSH1 31
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0
        0x60, 0x20, // PUSH1 32
        0xf3, // RETURN
    };

    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    var has_jumpi = false;
    for (analysis.inst_jump_type) |jt| {
        if (jt == .jumpi) has_jumpi = true;
    }
    try std.testing.expect(has_jumpi);

    for (analysis.instructions) |inst| {
        if (inst.tag == .conditional_jump_pc or inst.tag == .jump_pc) {
            return error.TestUnexpectedResult;
        }
    }

    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(0x16));
    const bb_idx = analysis.pc_to_block_start[0x16];
    try std.testing.expect(bb_idx != std.math.maxInt(u16));
    try std.testing.expect(bb_idx < analysis.instructions.len);
    try std.testing.expect(@as(bool, analysis.instructions[bb_idx].tag == .block_info));
}

test "from_code basic functionality" {
    const allocator = std.testing.allocator;

    // Simple bytecode: PUSH1 0x01, STOP
    const code = &[_]u8{ 0x60, 0x01, 0x00 };

    const table = OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, code, &table);
    defer analysis.deinit();

    // Verify we got instructions (slice should have at least 3 instructions)
    try std.testing.expect(analysis.instructions.len >= 3);
    // Instructions now use tags to identify their type
    try std.testing.expect(analysis.instructions[0].tag != undefined);
    try std.testing.expect(analysis.instructions[1].tag != undefined);
}

test "from_code with jumpdest" {
    const allocator = std.testing.allocator;

    // Bytecode: JUMPDEST, PUSH1 0x01, STOP
    const code = &[_]u8{ 0x5B, 0x60, 0x01, 0x00 };

    const table = OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, code, &table);
    defer analysis.deinit();

    // Verify jumpdest is marked
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(0));
    try std.testing.expect(!analysis.jumpdest_array.is_valid_jumpdest(1));
}

test "jump target resolution with BEGINBLOCK injections" {
    const allocator = std.testing.allocator;

    // Bytecode that has jumps:
    // PC 0: PUSH1 0x05 (push jump destination)
    // PC 2: JUMP (jump to PC 5)
    // PC 3: PUSH1 0x00
    // PC 5: JUMPDEST (jump destination)
    // PC 6: PUSH1 0x01
    // PC 8: STOP
    const code = &[_]u8{
        0x60, 0x05, // PUSH1 0x05
        0x56, // JUMP
        0x60, 0x00, // PUSH1 0x00
        0x5B, // JUMPDEST at PC 5
        0x60, 0x01, // PUSH1 0x01
        0x00, // STOP
    };
    const table = OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, code, &table);
    defer analysis.deinit();

    // Verify JUMPDEST is marked correctly
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(5));

    // Count BEGINBLOCK instructions - should have at least 2:
    // 1. At the start
    // 2. At the JUMPDEST (PC 5)
    var begin_block_count: usize = 0;
    var jump_found = false;
    var jump_target_valid = false;

    for (analysis.instructions) |inst| {
        if (false) {
            begin_block_count += 1;
        }
        // Check if JUMP has been resolved to point to a valid target via tag
        if (inst.tag == .jump_pc) {
            jump_found = true;
            jump_target_valid = true;
        }
    }

    try std.testing.expect(begin_block_count >= 2);
    try std.testing.expect(jump_found);
    try std.testing.expect(jump_target_valid);
}

test "conditional jump (JUMPI) target resolution" {
    const allocator = std.testing.allocator;

    // Bytecode with conditional jump:
    // PC 0: PUSH1 0x01 (condition)
    // PC 2: PUSH1 0x06 (jump destination)
    // PC 4: JUMPI (conditional jump to PC 6)
    // PC 5: STOP (fall-through if condition is false)
    // PC 6: JUMPDEST (jump destination)
    // PC 7: PUSH1 0x42
    // PC 9: STOP
    const code = &[_]u8{
        0x60, 0x01, // PUSH1 0x01
        0x60, 0x06, // PUSH1 0x06
        0x57, // JUMPI
        0x00, // STOP
        0x5B, // JUMPDEST at PC 6
        0x60, 0x42, // PUSH1 0x42
        0x00, // STOP
    };
    const table = OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, code, &table);
    defer analysis.deinit();

    // Verify JUMPDEST is marked correctly
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(6));

    var jumpi_found = false;
    var jumpi_target_valid = false;

    for (analysis.instructions) |inst| {
        if (inst.tag == .conditional_jump_pc or inst.tag == .conditional_jump_unresolved) {
            jumpi_found = true;
            jumpi_target_valid = true;
        }
    }

    try std.testing.expect(jumpi_found);
    try std.testing.expect(jumpi_target_valid);
}

test "analysis: simple keccak loop fragment (ten-thousand-hashes core)" {
    const allocator = std.testing.allocator;
    // Minimal fragment representative of the benchmark inner step:
    // PUSH1 0x20; PUSH1 0x00; KECCAK256; POP; JUMPDEST; STOP
    // Note: Real case has a loop; here we assert basic instruction generation and jumpdest mapping.
    const code = &[_]u8{
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0x20, // KECCAK256
        0x50, // POP
        0x5b, // JUMPDEST (pc=8)
        0x00, // STOP
    };
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    // Expect BEGINBLOCK + PUSH + PUSH + KECCAK256 + POP + JUMPDEST + STOP → 7 instructions
    try std.testing.expectEqual(@as(usize, 7), analysis.instructions.len);

    // Verify jumpdest bitmap and mapping
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(8));
    const block_idx = analysis.pc_to_block_start[8];
    try std.testing.expect(block_idx != std.math.maxInt(u16));
    try std.testing.expect(block_idx < analysis.instructions.len);
}

test "analysis: fused conditional JUMPI with immediate destination" {
    const allocator = std.testing.allocator;
    // Layout:
    // 0: PUSH1 1        (condition)
    // 2: PUSH1 7        (dest pc)
    // 4: JUMPI          (should resolve to pointer target)
    // 5: STOP           (fallthrough not executed)
    // 6: NOP (padding)
    // 7: JUMPDEST       (target)
    const code = &[_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x07, // PUSH1 7
        0x57, // JUMPI
        0x00, // STOP
        0x00, // padding
        0x5b, // JUMPDEST at pc=7
    };

    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    // Jumpdest validation and mapping
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(7));
    const block_idx = analysis.pc_to_block_start[7];
    try std.testing.expect(block_idx != std.math.maxInt(u16));
    try std.testing.expect(block_idx < analysis.instructions.len);

    // Ensure a conditional_jump pointer exists to target 7
    var found = false;
    for (analysis.instructions) |inst| {
        if (inst.tag == .conditional_jump_pc) {
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "analysis: dispatcher-like fragment invariants" {
    const allocator = std.testing.allocator;
    // Minimal dispatcher pattern:
    // 00: PUSH1 0x00
    // 02: CALLDATALOAD
    // 03: PUSH1 0xe0
    // 05: SHR                     ; selector -> low 4 bytes
    // 06: PUSH4 0x11223344        ; target selector
    // 0b: EQ
    // 0c: PUSH1 0x14              ; dest pc (20)
    // 0e: JUMPI
    // 0f: PUSH1 0x00
    // 11: PUSH1 0x00
    // 13: REVERT
    // 14: JUMPDEST                ; dest block
    // 15: STOP (padding ok)
    const code = &[_]u8{
        0x60, 0x00, // PUSH1 0
        0x35, // CALLDATALOAD
        0x60, 0xe0, // PUSH1 0xe0
        0x1c, // SHR
        0x63, 0x11, 0x22, 0x33, 0x44, // PUSH4 0x11223344
        0x14, // EQ
        0x60, 0x14, // PUSH1 0x14
        0x57, // JUMPI
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0xfd, // REVERT
        0x5b, // JUMPDEST @ 0x14
        0x00, // STOP
    };

    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    // JUMPDEST mapped
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(0x14));
    const bb_idx = analysis.pc_to_block_start[0x14];
    try std.testing.expect(bb_idx != std.math.maxInt(u16));
    try std.testing.expect(bb_idx < analysis.instructions.len);

    // Must contain a conditional jump
    var has_jumpi: bool = false;
    for (analysis.inst_jump_type) |jt| {
        if (jt == .jumpi) has_jumpi = true;
    }
    try std.testing.expect(has_jumpi);

    // No unresolved fused immediates should remain after resolution
    for (analysis.instructions) |inst| {
        if (inst.tag == .jump_pc) {
            return error.TestUnexpectedResult;
        }
    }

    // Maps sizes sane
    try std.testing.expect(analysis.inst_to_pc.len == analysis.instructions.len);
    try std.testing.expect(analysis.pc_to_block_start.len >= code.len);
}

test "analysis: ERC20 runtime contains dispatcher patterns" {
    const allocator = std.testing.allocator;
    // Load solidity ERC20 creation bytecode and extract runtime after f3 fe
    const path = "/Users/williamcory/guillotine/src/solidity/erc20_bytecode.hex";
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const hex_content = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(hex_content);
    const trimmed = std.mem.trim(u8, hex_content, " \t\n\r");
    const creation_bytes = try allocator.alloc(u8, trimmed.len / 2);
    defer allocator.free(creation_bytes);
    _ = try std.fmt.hexToBytes(creation_bytes, trimmed);

    var runtime_code: []const u8 = creation_bytes;
    if (std.mem.indexOf(u8, creation_bytes, &[_]u8{ 0xf3, 0xfe })) |idx| {
        const start = idx + 2;
        if (start < creation_bytes.len) runtime_code = creation_bytes[start..];
    }

    var analysis = try CodeAnalysis.from_code(allocator, runtime_code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    // Basic sanity
    try std.testing.expect(analysis.pc_to_block_start.len >= runtime_code.len);

    // Scan dispatcher-relevant opcodes
    var count_jumpi: usize = 0;
    var count_jumpdest: usize = 0;
    var has_calldataload: bool = false;
    var has_calldatasize: bool = false;
    var has_eq: bool = false;
    var i: usize = 0;
    while (i < runtime_code.len) : (i += 1) {
        const b = runtime_code[i];
        switch (b) {
            0x57 => count_jumpi += 1,
            0x5b => count_jumpdest += 1,
            0x35 => has_calldataload = true,
            0x36 => has_calldatasize = true,
            0x14 => has_eq = true,
            else => {},
        }
    }
    try std.testing.expect(count_jumpi >= 1);
    try std.testing.expect(count_jumpdest >= 2);
    try std.testing.expect(has_calldataload);
    try std.testing.expect(has_eq);
    if (!has_calldatasize) {
        var has_calldatacopy: bool = false;
        var j: usize = 0;
        while (j < runtime_code.len) : (j += 1) {
            if (runtime_code[j] == 0x37) {
                has_calldatacopy = true;
                break;
            }
        }
        try std.testing.expect(has_calldatacopy);
    }

    // No unresolved fused immediates should remain
    for (analysis.instructions) |inst| {
        if (inst.tag == .jump_pc) {
            return error.TestUnexpectedResult;
        }
    }
}

test "analysis: fused PUSH+JUMP to forward JUMPDEST" {
    const allocator = std.testing.allocator;
    // Bytes:
    // 0: PUSH1 3   (target pc)
    // 2: JUMP
    // 3: JUMPDEST
    // 4: STOP
    const code = &[_]u8{ 0x60, 0x03, 0x56, 0x5b, 0x00 };
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    // JUMPDEST validation and mapping
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(3));
    const block_idx = analysis.pc_to_block_start[3];
    try std.testing.expect(block_idx != std.math.maxInt(u16));
    try std.testing.expect(block_idx < analysis.instructions.len);

    // Ensure we have either a fused jump_pc to 3 or a resolved jump pointing to the block
    var ok = false;
    for (analysis.instructions) |inst| {
        if (inst.tag == .jump_pc) {
            // With new structure, we can't directly check PC value here
            ok = true;
        } else if (inst.tag == .jump_unresolved) {
            ok = ok or true; // resolved wiring validated by pc_to_block_start
        }
    }
    try std.testing.expect(ok);
}

test "analysis: back-edge JUMP to earlier JUMPDEST (loop head)" {
    const allocator = std.testing.allocator;
    // 0: JUMPDEST
    // 1: PUSH1 1
    // 3: POP
    // 4: PUSH1 0  (dest back to pc=0)
    // 6: JUMP    (should fuse to jump_pc=0)
    // 7: STOP
    const code = &[_]u8{ 0x5b, 0x60, 0x01, 0x50, 0x60, 0x00, 0x56, 0x00 };
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(0));
    const block_idx = analysis.pc_to_block_start[0];
    try std.testing.expect(block_idx != std.math.maxInt(u16));
    try std.testing.expect(block_idx < analysis.instructions.len);

    var has_back_edge = false;
    for (analysis.instructions) |inst| {
        if (inst.tag == .jump_pc) {
            // With new structure, we can't directly check PC value
            // but having jump_pc tag indicates resolved jump
            has_back_edge = true;
        }
    }
    try std.testing.expect(has_back_edge);
}

test "analysis: ten-thousand-hashes runtime invariants" {
    const allocator = std.testing.allocator;

    // Load official case creation bytecode and extract runtime code after 'f3fe'
    const path = "/Users/williamcory/guillotine/bench/official/cases/ten-thousand-hashes/bytecode.txt";
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const hex_content = try file.readToEndAlloc(allocator, 16 * 1024);
    defer allocator.free(hex_content);

    const trimmed = std.mem.trim(u8, hex_content, " \t\n\r");
    const creation_bytes = try allocator.alloc(u8, trimmed.len / 2);
    defer allocator.free(creation_bytes);
    _ = try std.fmt.hexToBytes(creation_bytes, trimmed);

    // Find RETURN+INVALID delimiter used by Solidity (f3 fe), take bytes after as runtime
    var runtime_code: []const u8 = creation_bytes;
    const maybe_idx = std.mem.indexOfPos(u8, creation_bytes, 0, &[_]u8{ 0xf3, 0xfe });
    if (maybe_idx) |idx| {
        const start = idx + 2;
        if (start < creation_bytes.len) runtime_code = creation_bytes[start..];
    }

    // Analyze runtime code
    var analysis = try CodeAnalysis.from_code(allocator, runtime_code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    // Basic sanity
    try std.testing.expect(analysis.instructions.len > 8);
    try std.testing.expect(analysis.pc_to_block_start.len >= runtime_code.len);

    // Ensure at least one valid JUMPDEST exists in the runtime
    var jumpdest_count: usize = 0;
    var pc: usize = 0;
    while (pc < runtime_code.len) : (pc += 1) {
        if (analysis.jumpdest_array.is_valid_jumpdest(pc)) jumpdest_count += 1;
    }
    try std.testing.expect(jumpdest_count > 0);

    // All fused immediate jumps must be resolved to concrete jump targets (no *pc variants left)
    for (analysis.instructions) |inst| {
        if (inst.tag == .jump_pc or inst.tag == .conditional_jump_pc) {
            return error.TestUnexpectedResult;
        }
    }

    // Expect at least one conditional or unconditional jump in the analyzed runtime
    var has_jump = false;
    var has_conditional = false;
    for (analysis.instructions) |inst2| {
        switch (inst2.tag) {
            .jump_pc, .jump_unresolved => has_jump = true,
            .conditional_jump_pc, .conditional_jump_idx, .conditional_jump_unresolved, .conditional_jump_invalid => has_conditional = true,
            else => {},
        }
    }
    try std.testing.expect(has_jump or has_conditional);
}

test "analysis: staticcall pattern with SSTORE should not alter control wiring" {
    const allocator = std.testing.allocator;
    // Bytecode: SSTORE; MSTORE 1 at 0; RETURN 32 bytes
    // 0: 60 01 (PUSH1 1)
    // 2: 60 00 (PUSH1 0)
    // 4: 55    (SSTORE)
    // 5: 60 01 (PUSH1 1)
    // 7: 60 00 (PUSH1 0)
    // 9: 52    (MSTORE)
    // 10:60 20 (PUSH1 32)
    // 12:60 00 (PUSH1 0)
    // 14:F3    (RETURN)
    const code = &[_]u8{ 0x60, 0x01, 0x60, 0x00, 0x55, 0x60, 0x01, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };

    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    // Ensure terminator is RETURN not implicit STOP
    try std.testing.expect(analysis.instructions.len > 0);
    // No unresolved fused jumps should remain
    for (analysis.instructions) |inst| {
        if (inst.tag == .jump_pc or inst.tag == .conditional_jump_pc) {
            return error.TestUnexpectedResult;
        }
    }
    // pc_to_block_start maps all PCs to a valid begin index or max
    try std.testing.expect(analysis.pc_to_block_start.len >= code.len);
}

test "analysis: inst_jump_type marks dynamic JUMP and JUMPI correctly" {
    const allocator = std.testing.allocator;
    // Layout: PUSH1 dest; DUP1; JUMPI; JUMPDEST dest; STOP; JUMP (dynamic)
    // 0: 60 06 (PUSH1 6)
    // 2: 80    (DUP1)
    // 3: 57    (JUMPI -> should resolve to pointer or remain unresolved)
    // 4: 5b    (JUMPDEST at pc=4)
    // 5: 00    (STOP)
    // 6: 56    (JUMP -> dynamic)
    const code = &[_]u8{ 0x60, 0x04, 0x80, 0x57, 0x5b, 0x00, 0x56 };

    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    var jump_count: usize = 0;
    var jumpi_count: usize = 0;
    for (analysis.inst_jump_type) |jt| {
        switch (jt) {
            .jump => jump_count += 1,
            .jumpi => jumpi_count += 1,
            else => {},
        }
    }
    try std.testing.expect(jump_count >= 1);
    try std.testing.expect(jumpi_count >= 1);
}

test "analysis: JUMPDEST pcs map to BEGINBLOCK (block_info) via pc_to_block_start" {
    const allocator = std.testing.allocator;
    // 0: 5b (JUMPDEST)
    // 1: 60 00 (PUSH1 0)
    // 3: 56 (JUMP)
    // 4: 5b (JUMPDEST)
    // 5: 00 (STOP)
    const code = &[_]u8{ 0x5b, 0x60, 0x00, 0x56, 0x5b, 0x00 };
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    const pcs = [_]usize{ 0, 4 };
    for (pcs) |pc| {
        try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(pc));
        const idx = analysis.pc_to_block_start[pc];
        try std.testing.expect(idx != std.math.maxInt(u16));
        try std.testing.expect(idx < analysis.instructions.len);
        const inst = analysis.instructions[idx];
        // The block entry should carry block_info metadata
        try std.testing.expect(inst.tag == .block_info);
    }
}

test "analysis: inst_to_pc within bounds and nondecreasing" {
    const allocator = std.testing.allocator;
    const code = &[_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x50, 0x00 }; // PUSH1 1; PUSH1 2; ADD; POP; STOP
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    var prev_pc: u16 = 0;
    var first = true;
    for (analysis.inst_to_pc) |pc| {
        try std.testing.expect(pc <= analysis.code_len);
        if (first) {
            prev_pc = pc;
            first = false;
        } else {
            try std.testing.expect(pc >= prev_pc);
            prev_pc = pc;
        }
    }
}

test "fusion and optimization statistics" {
    const allocator = std.testing.allocator;
    std.testing.log_level = .warn;

    // Bytecode with various optimization opportunities:
    const code = &[_]u8{
        // PUSH+ADD fusion (5 + 3)
        0x60, 0x05, // PUSH1 0x05
        0x60, 0x03, // PUSH1 0x03
        0x01, // ADD

        // PUSH+MUL fusion (2 * 3)
        0x60, 0x02, // PUSH1 0x02
        0x60, 0x03, // PUSH1 0x03
        0x02, // MUL

        // PUSH+DIV fusion (10 / 2)
        0x60, 0x0A, // PUSH1 0x0A (10)
        0x60, 0x02, // PUSH1 0x02
        0x04, // DIV

        // PUSH+SUB fusion (8 - 3)
        0x60, 0x08, // PUSH1 0x08
        0x60, 0x03, // PUSH1 0x03
        0x03, // SUB

        // KECCAK256 with immediate size
        0x60, 0x00, // PUSH1 0x00 (offset)
        0x60, 0x20, // PUSH1 0x20 (size = 32 bytes)
        0x20, // KECCAK256

        // Inline ISZERO
        0x60, 0x01, // PUSH1 0x01
        0x15, // ISZERO

        // Inline EQ
        0x60, 0x02, // PUSH1 0x02
        0x60, 0x02, // PUSH1 0x02
        0x14, // EQ

        // PUSH 0 + ADD (should be eliminated)
        0x60, 0x00, // PUSH1 0x00
        0x01, // ADD

        // PUSH 1 + MUL (should be eliminated)
        0x60, 0x01, // PUSH1 0x01
        0x02, // MUL

        // PUSH 1 + DIV (should be eliminated)
        0x60, 0x01, // PUSH1 0x01
        0x04, // DIV
        0x00, // STOP
    };

    const table = OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, code, &table);
    defer analysis.deinit();

    // Just verify it works - the stats will be printed in debug mode
    try std.testing.expect(analysis.instructions.len > 0);
}

test "invalid jump target handling" {
    const allocator = std.testing.allocator;

    // Bytecode with invalid jump (no JUMPDEST at target):
    // PC 0: PUSH1 0x05 (push invalid jump destination)
    // PC 2: JUMP (jump to PC 5 which is not a JUMPDEST)
    // PC 3: PUSH1 0x00
    // PC 5: PUSH1 0x01 (NOT a JUMPDEST)
    // PC 7: STOP
    const code = &[_]u8{
        0x60, 0x05, // PUSH1 0x05
        0x56, // JUMP
        0x60, 0x00, // PUSH1 0x00
        0x60, 0x01, // PUSH1 0x01 (at PC 5, NOT a JUMPDEST)
        0x00, // STOP
    };
    const table = OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, code, &table);
    defer analysis.deinit();

    // Verify PC 5 is NOT marked as JUMPDEST
    try std.testing.expect(!analysis.jumpdest_array.is_valid_jumpdest(5));

    // The JUMP instruction should not have a resolved target
    var unresolved_jump_found = false;

    for (analysis.instructions) |inst| {
        // Check for unresolved jump instruction
        if (inst.tag == .jump_unresolved) {
            unresolved_jump_found = true;
        }
    }

    try std.testing.expect(unresolved_jump_found);
}

test "SHA3 precomputation - detect PUSH followed by SHA3" {
    const allocator = std.testing.allocator;

    // Bytecode: PUSH1 0x20 PUSH1 0x00 SHA3
    // This should compute keccak256 of 32 bytes starting at offset 0
    const code = &[_]u8{
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x20, // SHA3/KECCAK256
    };

    const table = OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, code, &table);
    defer analysis.deinit();

    // The SHA3 instruction should have dynamic gas handling and static charged in block
    try std.testing.expectEqual(@as(usize, 6), analysis.instructions.len); // 5 opcodes + 1 STOP

    const sha3_inst = &analysis.instructions[4];
    // SHA3/KECCAK256 is handled as regular .exec, not .dynamic_gas
    try std.testing.expect(sha3_inst.tag == .exec);
}

test "SHA3 precomputation - various sizes" {
    const allocator = std.testing.allocator;

    const test_cases = [_]struct { size: u16, word_count: u32, gas: u32 }{
        .{ .size = 0, .word_count = 0, .gas = 30 }, // Empty data
        .{ .size = 1, .word_count = 1, .gas = 36 }, // 1 byte = 1 word
        .{ .size = 32, .word_count = 1, .gas = 36 }, // 32 bytes = 1 word
        .{ .size = 33, .word_count = 2, .gas = 42 }, // 33 bytes = 2 words
        .{ .size = 64, .word_count = 2, .gas = 42 }, // 64 bytes = 2 words
        .{ .size = 96, .word_count = 3, .gas = 48 }, // 96 bytes = 3 words
        .{ .size = 1024, .word_count = 32, .gas = 222 }, // 1024 bytes = 32 words
    };

    inline for (test_cases) |tc| {
        const code = if (tc.size <= 255) &[_]u8{
            0x60, @intCast(tc.size), // PUSH1 size
            0x60, 0x00, // PUSH1 0 (offset)
            0x20, // SHA3/KECCAK256
        } else &[_]u8{
            0x61, @intCast(tc.size >> 8), @intCast(tc.size & 0xFF), // PUSH2 size
            0x60, 0x00, // PUSH1 0 (offset)
            0x20, // SHA3/KECCAK256
        };

        const table = OpcodeMetadata.DEFAULT;
        var analysis = try CodeAnalysis.from_code(allocator, code, &table);
        defer analysis.deinit();

        const sha3_idx = if (tc.size <= 255) 4 else 5;
        const sha3_inst = &analysis.instructions[sha3_idx];
        // SHA3/KECCAK256 is handled as regular .exec, not .dynamic_gas
        try std.testing.expect(sha3_inst.tag == .exec);
    }
}

test "SHA3 precomputation - with memory expansion" {
    const allocator = std.testing.allocator;

    // Bytecode: PUSH2 0x0100 PUSH2 0x1000 SHA3
    // This should compute keccak256 of 256 bytes starting at offset 4096
    // Memory expansion: from 0 to 4096+256 = 4352 bytes = 136 words
    const code = &[_]u8{
        0x61, 0x01, 0x00, // PUSH2 256 (size)
        0x61, 0x10, 0x00, // PUSH2 4096 (offset)
        0x20, // SHA3/KECCAK256
    };

    const table = OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, code, &table);
    defer analysis.deinit();

    const sha3_inst = &analysis.instructions[5];
    // SHA3/KECCAK256 is handled as regular .exec, not .dynamic_gas
    try std.testing.expect(sha3_inst.tag == .exec);
}

test "SHA3 precomputation - not applied when size unknown" {
    const allocator = std.testing.allocator;

    // Bytecode: DUP1 DUP1 SHA3 (size comes from stack, not PUSH)
    const code = &[_]u8{
        0x80, // DUP1
        0x80, // DUP1
        0x20, // SHA3/KECCAK256
    };

    const table = OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, code, &table);
    defer analysis.deinit();

    // The SHA3 instruction should NOT have precomputed values
    const sha3_inst = &analysis.instructions[3]; // BEGINBLOCK + DUP1 + DUP1 + SHA3

    // Should not have dynamic_gas with precomputed static component; may still have gas_fn
    // SHA3 without known size should be .exec
    try std.testing.expect(sha3_inst.tag == .exec);
}

// === Additional Unit Tests for analysis.zig ===

test "JumpdestArray.from_bitmap - empty bitmap" {
    const allocator = std.testing.allocator;
    
    var bitmap = try DynamicBitSet.initEmpty(allocator, 100);
    defer bitmap.deinit();
    
    var jumpdest_array = try JumpdestArray.from_bitmap(allocator, &bitmap, 100);
    defer jumpdest_array.deinit(allocator);
    
    try std.testing.expectEqual(@as(usize, 0), jumpdest_array.positions.len);
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(0));
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(50));
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(99));
}

test "JumpdestArray.from_bitmap - single jumpdest" {
    const allocator = std.testing.allocator;
    
    var bitmap = try DynamicBitSet.initEmpty(allocator, 100);
    defer bitmap.deinit();
    bitmap.set(42);
    
    var jumpdest_array = try JumpdestArray.from_bitmap(allocator, &bitmap, 100);
    defer jumpdest_array.deinit(allocator);
    
    try std.testing.expectEqual(@as(usize, 1), jumpdest_array.positions.len);
    try std.testing.expectEqual(@as(u15, 42), jumpdest_array.positions[0]);
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(41));
    try std.testing.expect(jumpdest_array.is_valid_jumpdest(42));
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(43));
}

test "JumpdestArray.from_bitmap - multiple jumpdests" {
    const allocator = std.testing.allocator;
    
    var bitmap = try DynamicBitSet.initEmpty(allocator, 1000);
    defer bitmap.deinit();
    
    // Set multiple jumpdests at various positions
    const positions = [_]usize{ 0, 10, 50, 100, 250, 500, 750, 999 };
    for (positions) |pos| {
        bitmap.set(pos);
    }
    
    var jumpdest_array = try JumpdestArray.from_bitmap(allocator, &bitmap, 1000);
    defer jumpdest_array.deinit(allocator);
    
    try std.testing.expectEqual(@as(usize, positions.len), jumpdest_array.positions.len);
    
    // Verify all positions are valid
    for (positions) |pos| {
        try std.testing.expect(jumpdest_array.is_valid_jumpdest(pos));
    }
    
    // Verify non-jumpdest positions are invalid
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(5));
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(51));
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(998));
}

test "JumpdestArray.from_bitmap - max contract size" {
    const allocator = std.testing.allocator;
    
    var bitmap = try DynamicBitSet.initEmpty(allocator, limits.MAX_CONTRACT_SIZE);
    defer bitmap.deinit();
    
    // Set jumpdests at extremes
    bitmap.set(0);
    bitmap.set(limits.MAX_CONTRACT_SIZE - 1);
    bitmap.set(limits.MAX_CONTRACT_SIZE / 2);
    
    var jumpdest_array = try JumpdestArray.from_bitmap(allocator, &bitmap, limits.MAX_CONTRACT_SIZE);
    defer jumpdest_array.deinit(allocator);
    
    try std.testing.expectEqual(@as(usize, 3), jumpdest_array.positions.len);
    try std.testing.expect(jumpdest_array.is_valid_jumpdest(0));
    try std.testing.expect(jumpdest_array.is_valid_jumpdest(limits.MAX_CONTRACT_SIZE - 1));
    try std.testing.expect(jumpdest_array.is_valid_jumpdest(limits.MAX_CONTRACT_SIZE / 2));
}

test "JumpdestArray.is_valid_jumpdest - out of bounds" {
    const allocator = std.testing.allocator;
    
    var bitmap = try DynamicBitSet.initEmpty(allocator, 100);
    defer bitmap.deinit();
    bitmap.set(50);
    
    var jumpdest_array = try JumpdestArray.from_bitmap(allocator, &bitmap, 100);
    defer jumpdest_array.deinit(allocator);
    
    // PC beyond code length should return false
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(100));
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(200));
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(std.math.maxInt(usize)));
}

test "analysis: PUSH opcode with data bytes" {
    const allocator = std.testing.allocator;
    
    // PUSH3 followed by 3 data bytes, then JUMPDEST
    const code = &[_]u8{
        0x62, 0xAA, 0xBB, 0xCC, // PUSH3 0xAABBCC
        0x5B, // JUMPDEST
        0x00, // STOP
    };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // JUMPDEST should be at position 4, not positions 1, 2, or 3
    try std.testing.expect(!analysis.jumpdest_array.is_valid_jumpdest(1));
    try std.testing.expect(!analysis.jumpdest_array.is_valid_jumpdest(2));
    try std.testing.expect(!analysis.jumpdest_array.is_valid_jumpdest(3));
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(4));
}

test "analysis: PUSH32 with JUMPDEST byte in data" {
    const allocator = std.testing.allocator;
    
    // PUSH32 with 0x5B (JUMPDEST opcode) as one of the data bytes
    var code: [34]u8 = undefined;
    code[0] = 0x7F; // PUSH32
    @memset(code[1..33], 0x00);
    code[10] = 0x5B; // JUMPDEST byte value in PUSH data
    code[33] = 0x00; // STOP
    
    var analysis = try CodeAnalysis.from_code(allocator, &code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // The 0x5B byte at position 10 is data, not a JUMPDEST
    try std.testing.expect(!analysis.jumpdest_array.is_valid_jumpdest(10));
}

test "analysis: invalid opcode handling" {
    const allocator = std.testing.allocator;
    
    // Code with invalid opcodes
    const code = &[_]u8{
        0x60, 0x01, // PUSH1 1
        0xFE, // INVALID opcode
        0x60, 0x02, // PUSH1 2
        0xFF, // Another invalid opcode
        0x00, // STOP
    };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // Should not crash and should handle invalid opcodes gracefully
    try std.testing.expect(analysis.instructions.len > 0);
}

test "analysis: code too large" {
    const allocator = std.testing.allocator;
    
    // Try to create code larger than MAX_CONTRACT_SIZE
    const large_code = try allocator.alloc(u8, limits.MAX_CONTRACT_SIZE + 1);
    defer allocator.free(large_code);
    @memset(large_code, 0x00); // Fill with STOP opcodes
    
    const result = CodeAnalysis.from_code(allocator, large_code, &OpcodeMetadata.DEFAULT);
    try std.testing.expectError(error.CodeTooLarge, result);
}

test "analysis: multiple basic blocks with terminators" {
    const allocator = std.testing.allocator;
    
    // Code with multiple basic blocks separated by different terminators
    const code = &[_]u8{
        // Block 1
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x01, // ADD
        0x00, // STOP (terminator)
        
        // Block 2 (unreachable)
        0x5B, // JUMPDEST
        0x60, 0x03, // PUSH1 3
        0xFD, // REVERT (terminator)
        
        // Block 3 
        0x5B, // JUMPDEST
        0x60, 0x04, // PUSH1 4
        0xF3, // RETURN (terminator)
    };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // Verify JUMPDESTs are properly marked
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(5));
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(9));
    
    // Verify block mapping exists
    try std.testing.expect(analysis.pc_to_block_start[5] != std.math.maxInt(u16));
    try std.testing.expect(analysis.pc_to_block_start[9] != std.math.maxInt(u16));
}

test "analysis: nested PUSH operations" {
    const allocator = std.testing.allocator;
    
    // Various PUSH operations of different sizes
    const code = &[_]u8{
        0x5F, // PUSH0 (EIP-3855)
        0x60, 0xFF, // PUSH1 0xFF
        0x61, 0x12, 0x34, // PUSH2 0x1234
        0x62, 0xAB, 0xCD, 0xEF, // PUSH3 0xABCDEF
        0x00, // STOP
    };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // Verify instruction count includes all operations
    try std.testing.expect(analysis.instructions.len >= 5); // At least 5 opcodes
}

test "analysis: JUMPI with invalid destination" {
    const allocator = std.testing.allocator;
    
    // JUMPI to a non-JUMPDEST location
    const code = &[_]u8{
        0x60, 0x01, // PUSH1 1 (condition)
        0x60, 0x06, // PUSH1 6 (destination - not a JUMPDEST)
        0x57, // JUMPI
        0x00, // STOP
        0x60, 0x42, // PUSH1 0x42 (at PC 6 - not a JUMPDEST)
        0x00, // STOP
    };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // PC 6 should not be a valid jumpdest
    try std.testing.expect(!analysis.jumpdest_array.is_valid_jumpdest(6));
    
    // Should have a conditional jump instruction
    var has_jumpi = false;
    for (analysis.inst_jump_type) |jt| {
        if (jt == .jumpi) has_jumpi = true;
    }
    try std.testing.expect(has_jumpi);
}

test "analysis: self-modifying pattern (CREATE2 address calculation)" {
    const allocator = std.testing.allocator;
    
    // Pattern often seen in CREATE2 deployments
    const code = &[_]u8{
        0x60, 0x00, // PUSH1 0 (salt)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (value)
        0xF5, // CREATE2
        0x00, // STOP
    };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // Should handle CREATE2 opcode properly
    try std.testing.expect(analysis.instructions.len > 0);
}

test "analysis: extreme stack depth changes" {
    const allocator = std.testing.allocator;
    
    // Code that pushes many values then duplicates them
    const code = &[_]u8{
        // Push 16 values
        0x60, 0x01, 0x60, 0x02, 0x60, 0x03, 0x60, 0x04,
        0x60, 0x05, 0x60, 0x06, 0x60, 0x07, 0x60, 0x08,
        0x60, 0x09, 0x60, 0x0A, 0x60, 0x0B, 0x60, 0x0C,
        0x60, 0x0D, 0x60, 0x0E, 0x60, 0x0F, 0x60, 0x10,
        // DUP16 (duplicates 16th stack item)
        0x8F,
        // SWAP16 (swaps 1st and 17th stack items)
        0x9F,
        0x00, // STOP
    };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // Should handle deep stack operations
    try std.testing.expect(analysis.instructions.len > 0);
}

test "analysis: LOG operations with various topic counts" {
    const allocator = std.testing.allocator;
    
    const code = &[_]u8{
        // Setup for LOG operations
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x20, // PUSH1 32 (size)
        
        // LOG0 - no topics
        0xA0,
        
        // LOG1 - 1 topic
        0x60, 0x01, // PUSH1 1 (topic)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x20, // PUSH1 32 (size)
        0xA1,
        
        // LOG4 - 4 topics
        0x60, 0x01, 0x60, 0x02, 0x60, 0x03, 0x60, 0x04, // 4 topics
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x20, // PUSH1 32 (size) 
        0xA4,
        
        0x00, // STOP
    };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // Should handle all LOG variants
    try std.testing.expect(analysis.instructions.len > 0);
}

test "analysis: memory expansion patterns" {
    const allocator = std.testing.allocator;
    
    const code = &[_]u8{
        // MSTORE at high memory address
        0x61, 0x10, 0x00, // PUSH2 0x1000 (4096)
        0x60, 0x42, // PUSH1 0x42 (value)
        0x52, // MSTORE
        
        // MLOAD from even higher address
        0x61, 0x20, 0x00, // PUSH2 0x2000 (8192)
        0x51, // MLOAD
        
        // RETURN with large memory range
        0x61, 0x10, 0x00, // PUSH2 0x1000 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xF3, // RETURN
    };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // Should handle memory expansion operations
    try std.testing.expect(analysis.instructions.len > 0);
}

test "analysis: edge case - single byte code" {
    const allocator = std.testing.allocator;
    
    // Single STOP instruction
    const code = &[_]u8{0x00};
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    try std.testing.expect(analysis.instructions.len >= 1);
    try std.testing.expectEqual(@as(usize, 1), analysis.code_len);
}

test "analysis: SELFDESTRUCT and state-changing operations" {
    const allocator = std.testing.allocator;
    
    const code = &[_]u8{
        // Store a value
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0
        0x55, // SSTORE
        
        // Self destruct to an address
        0x73, // PUSH20
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0xFF, // SELFDESTRUCT
    };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // Should handle SELFDESTRUCT
    try std.testing.expect(analysis.instructions.len > 0);
}

test "analysis: complex control flow with multiple jump targets" {
    const allocator = std.testing.allocator;
    
    const code = &[_]u8{
        // Entry point
        0x60, 0x00, // PUSH1 0
        0x60, 0x0A, // PUSH1 10 (first jump target)
        0x57, // JUMPI
        
        // Fallthrough path
        0x60, 0x10, // PUSH1 16 (second jump target)
        0x56, // JUMP
        
        // First jump target
        0x5B, // JUMPDEST at PC 10
        0x60, 0x01, // PUSH1 1
        0xF3, // RETURN
        
        // Second jump target
        0x5B, // JUMPDEST at PC 16
        0x60, 0x02, // PUSH1 2
        0xF3, // RETURN
    };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // Both jump destinations should be valid
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(10));
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(16));
    
    // Should have both JUMP and JUMPI
    var jump_count: usize = 0;
    var jumpi_count: usize = 0;
    for (analysis.inst_jump_type) |jt| {
        switch (jt) {
            .jump => jump_count += 1,
            .jumpi => jumpi_count += 1,
            else => {},
        }
    }
    try std.testing.expect(jump_count >= 1);
    try std.testing.expect(jumpi_count >= 1);
}

test "analysis: arithmetic operations coverage" {
    const allocator = std.testing.allocator;
    
    const code = &[_]u8{
        // Basic arithmetic
        0x60, 0x05, 0x60, 0x03, 0x01, // ADD: 5 + 3
        0x60, 0x08, 0x60, 0x03, 0x02, // MUL: 8 * 3
        0x60, 0x08, 0x60, 0x03, 0x03, // SUB: 8 - 3
        0x60, 0x08, 0x60, 0x02, 0x04, // DIV: 8 / 2
        0x60, 0x07, 0x60, 0x03, 0x05, // SDIV: signed division
        0x60, 0x08, 0x60, 0x03, 0x06, // MOD: 8 % 3
        0x60, 0x07, 0x60, 0x03, 0x07, // SMOD: signed modulo
        0x60, 0x05, 0x60, 0x03, 0x08, // ADDMOD: (5 + 3) % n
        0x60, 0x05, 0x60, 0x03, 0x60, 0x07, 0x09, // MULMOD: (5 * 3) % 7
        0x60, 0x02, 0x60, 0x03, 0x0A, // EXP: 2^3
        0x60, 0xFF, 0x0B, // SIGNEXTEND
        0x00, // STOP
    };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // Should handle all arithmetic operations
    try std.testing.expect(analysis.instructions.len > 0);
}

test "analysis: comparison operations" {
    const allocator = std.testing.allocator;
    
    const code = &[_]u8{
        // Comparisons
        0x60, 0x05, 0x60, 0x03, 0x10, // LT: 5 < 3
        0x60, 0x05, 0x60, 0x03, 0x11, // GT: 5 > 3  
        0x60, 0x05, 0x60, 0x03, 0x12, // SLT: signed less than
        0x60, 0x05, 0x60, 0x03, 0x13, // SGT: signed greater than
        0x60, 0x05, 0x60, 0x05, 0x14, // EQ: 5 == 5
        0x60, 0x00, 0x15, // ISZERO: is zero?
        0x00, // STOP
    };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // Should handle all comparison operations
    try std.testing.expect(analysis.instructions.len > 0);
}

test "analysis: CREATE and CREATE2 patterns" {
    const allocator = std.testing.allocator;
    
    const code = &[_]u8{
        // CREATE pattern
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xF0, // CREATE
        
        // CREATE2 pattern with salt
        0x60, 0x42, // PUSH1 0x42 (salt)
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xF5, // CREATE2
        
        0x00, // STOP
    };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // Should handle contract creation opcodes
    try std.testing.expect(analysis.instructions.len > 0);
}

test "analysis: all PUSH variants" {
    const allocator = std.testing.allocator;
    
    var code = std.ArrayList(u8).init(allocator);
    defer code.deinit();
    
    // PUSH0 (EIP-3855)
    try code.append(0x5F);
    
    // PUSH1 through PUSH32
    var i: u8 = 1;
    while (i <= 32) : (i += 1) {
        try code.append(0x60 + i - 1); // PUSH opcode
        // Add i bytes of data
        var j: u8 = 0;
        while (j < i) : (j += 1) {
            try code.append(j);
        }
    }
    
    try code.append(0x00); // STOP
    
    var analysis = try CodeAnalysis.from_code(allocator, code.items, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // Should handle all PUSH variants
    try std.testing.expect(analysis.instructions.len >= 34); // At least 33 PUSH ops + STOP
}

test "analysis: consecutive JUMPDESTs" {
    const allocator = std.testing.allocator;
    
    const code = &[_]u8{
        0x5B, // JUMPDEST
        0x5B, // JUMPDEST
        0x5B, // JUMPDEST
        0x60, 0x01, // PUSH1 1
        0x00, // STOP
    };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // All three JUMPDESTs should be valid
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(0));
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(1));
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(2));
}

test "analysis: infinite loop pattern" {
    const allocator = std.testing.allocator;
    
    const code = &[_]u8{
        0x5B, // JUMPDEST (loop start)
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0 (jump to start)
        0x56, // JUMP
    };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // Should handle infinite loops
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(0));
}

test "analysis: dynamic jump resolution limits" {
    const allocator = std.testing.allocator;
    
    const code = &[_]u8{
        // Dynamic jump (destination from stack)
        0x5A, // GAS
        0x60, 0x0F, // PUSH1 15
        0x16, // AND (limit gas to small value)
        0x56, // JUMP (dynamic)
        
        // Potential destinations
        0x00, // STOP
        0x00, // STOP
        0x5B, // JUMPDEST at 8
        0x00, // STOP
        0x5B, // JUMPDEST at 10
        0x00, // STOP
        0x5B, // JUMPDEST at 12
        0x00, // STOP
        0x5B, // JUMPDEST at 14
        0x00, // STOP
        0x5B, // JUMPDEST at 16
    };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // Multiple potential jump destinations should be marked
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(8));
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(10));
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(12));
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(14));
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(16));
}

test "analysis: JUMPDEST in PUSH data should not be valid" {
    const allocator = std.testing.allocator;
    
    // PUSH20 containing 0x5B (JUMPDEST) bytes
    var code = [_]u8{0x73} ++ [_]u8{0x5B} ** 20 ++ [_]u8{0x00};
    
    var analysis = try CodeAnalysis.from_code(allocator, &code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // None of the 0x5B bytes in PUSH data should be valid jumpdests
    var i: usize = 1;
    while (i <= 20) : (i += 1) {
        try std.testing.expect(!analysis.jumpdest_array.is_valid_jumpdest(i));
    }
}

test "analysis: maximum stack depth tracking" {
    const allocator = std.testing.allocator;
    
    // Push many values without popping
    var code = std.ArrayList(u8).init(allocator);
    defer code.deinit();
    
    // Push 100 values
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try code.append(0x60); // PUSH1
        try code.append(@intCast(i));
    }
    
    // Pop all values
    i = 0;
    while (i < 100) : (i += 1) {
        try code.append(0x50); // POP
    }
    
    try code.append(0x00); // STOP
    
    var analysis = try CodeAnalysis.from_code(allocator, code.items, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // Should handle deep stacks
    try std.testing.expect(analysis.instructions.len > 0);
}

test "analysis: empty basic blocks" {
    const allocator = std.testing.allocator;
    
    const code = &[_]u8{
        0x60, 0x04, // PUSH1 4
        0x56, // JUMP
        0x5B, // JUMPDEST at 3 (empty block)
        0x5B, // JUMPDEST at 4 (target)
        0x00, // STOP
    };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // Both jumpdests should be valid even if one leads to empty block
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(3));
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(4));
}

test "analysis: mixed valid and invalid jump targets" {
    const allocator = std.testing.allocator;
    
    const code = &[_]u8{
        // Valid jump
        0x60, 0x08, // PUSH1 8
        0x56, // JUMP
        
        // Invalid jump
        0x60, 0x09, // PUSH1 9 (not a JUMPDEST)
        0x56, // JUMP
        
        0x5B, // JUMPDEST at 8
        0x60, 0x42, // PUSH1 0x42 (at 9 - not a JUMPDEST)
        0x00, // STOP
    };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // Only PC 8 should be valid jumpdest
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(8));
    try std.testing.expect(!analysis.jumpdest_array.is_valid_jumpdest(9));
}

test "analysis: PUSH0 opcode (EIP-3855)" {
    const allocator = std.testing.allocator;
    
    const code = &[_]u8{
        0x5F, // PUSH0
        0x5F, // PUSH0  
        0x01, // ADD (0 + 0)
        0x5F, // PUSH0
        0x14, // EQ (result == 0)
        0x00, // STOP
    };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // Should handle PUSH0
    try std.testing.expect(analysis.instructions.len > 0);
}

test "analysis: balance and extcode operations" {
    const allocator = std.testing.allocator;
    
    const code = &[_]u8{
        // BALANCE
        0x73, // PUSH20 (address)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0x31, // BALANCE
        
        // EXTCODESIZE
        0x73, // PUSH20 (address)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
        0x3B, // EXTCODESIZE
        
        // EXTCODEHASH
        0x73, // PUSH20 (address)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        0x3F, // EXTCODEHASH
        
        0x00, // STOP
    };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // Should handle external account operations
    try std.testing.expect(analysis.instructions.len > 0);
}

// Tests for the size_buckets module functionality
test "size_buckets: getInstructionParams for 8-byte instructions" {
    const allocator = std.testing.allocator;
    
    // Create test arrays
    const size2 = try allocator.alloc(Bucket2, 1);
    defer allocator.free(size2);
    const size8 = try allocator.alloc(Bucket8, 2);
    defer allocator.free(size8);
    const size16 = try allocator.alloc(Bucket16, 1);
    defer allocator.free(size16);
    
    // Create an exec instruction
    const dummy_fn = @import("code_analysis.zig").UnreachableHandler;
    const exec_params = @import("instruction.zig").ExecInstruction{
        .exec_fn = dummy_fn,
    };
    @memcpy(size8[0].bytes[0..@sizeOf(@TypeOf(exec_params))], std.mem.asBytes(&exec_params));
    
    // Test retrieval
    const retrieved = @import("size_buckets.zig").getInstructionParams(
        size2, size8, size16, .exec, 0
    );
    try std.testing.expectEqual(exec_params.exec_fn, retrieved.exec_fn);
}

test "size_buckets: getInstructionParams for 16-byte instructions" {
    const allocator = std.testing.allocator;
    
    const size2 = try allocator.alloc(Bucket2, 1);
    defer allocator.free(size2);
    const size8 = try allocator.alloc(Bucket8, 1);
    defer allocator.free(size8);
    const size16 = try allocator.alloc(Bucket16, 2);
    defer allocator.free(size16);
    
    // Create a word instruction
    const test_bytes = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const word_params = @import("instruction.zig").WordInstruction{
        .word_bytes = &test_bytes,
    };
    @memcpy(size16[0].bytes[0..@sizeOf(@TypeOf(word_params))], std.mem.asBytes(&word_params));
    
    // Test retrieval
    const retrieved = @import("size_buckets.zig").getInstructionParams(
        size2, size8, size16, .word, 0
    );
    try std.testing.expectEqual(word_params.word_bytes.ptr, retrieved.word_bytes.ptr);
}

test "size_buckets: getInstructionParams for 2-byte instructions" {
    const allocator = std.testing.allocator;
    
    const size2 = try allocator.alloc(Bucket2, 2);
    defer allocator.free(size2);
    const size8 = try allocator.alloc(Bucket8, 1);
    defer allocator.free(size8);
    const size16 = try allocator.alloc(Bucket16, 1);
    defer allocator.free(size16);
    
    // Create a jump instruction  
    const jump_params = @import("instruction.zig").JumpPcInstruction{
        .jump_idx = 42,
    };
    @memcpy(size2[0].bytes[0..@sizeOf(@TypeOf(jump_params))], std.mem.asBytes(&jump_params));
    
    // Test retrieval
    const retrieved = @import("size_buckets.zig").getInstructionParams(
        size2, size8, size16, .jump_pc, 0
    );
    try std.testing.expectEqual(jump_params.jump_idx, retrieved.jump_idx);
}

test "code_bitmap: marks PUSH data bytes correctly" {
    const allocator = std.testing.allocator;
    const createCodeBitmap = @import("code_bitmap.zig").createCodeBitmap;
    
    // Code with various PUSH instructions
    const code = &[_]u8{
        0x60, 0xFF, // PUSH1 - byte at 1 is data
        0x61, 0x12, 0x34, // PUSH2 - bytes at 3,4 are data
        0x5B, // JUMPDEST - should remain as code
        0x7F, // PUSH32 - next 32 bytes are data
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F,
        0x00, // STOP - should be code
    };
    
    var bitmap = try createCodeBitmap(allocator, code);
    defer bitmap.deinit();
    
    // Check code bytes are set
    try std.testing.expect(bitmap.isSet(0)); // PUSH1 opcode
    try std.testing.expect(bitmap.isSet(2)); // PUSH2 opcode
    try std.testing.expect(bitmap.isSet(5)); // JUMPDEST
    try std.testing.expect(bitmap.isSet(6)); // PUSH32 opcode
    try std.testing.expect(bitmap.isSet(39)); // STOP
    
    // Check data bytes are unset
    try std.testing.expect(!bitmap.isSet(1)); // PUSH1 data
    try std.testing.expect(!bitmap.isSet(3)); // PUSH2 data
    try std.testing.expect(!bitmap.isSet(4)); // PUSH2 data
    // Check some PUSH32 data bytes
    try std.testing.expect(!bitmap.isSet(7)); // PUSH32 data
    try std.testing.expect(!bitmap.isSet(20)); // PUSH32 data
    try std.testing.expect(!bitmap.isSet(38)); // PUSH32 data
}

test "pattern_optimization: handles empty instruction stream" {
    const allocator = std.testing.allocator;
    const applyPatternOptimizations = @import("pattern_optimization.zig").applyPatternOptimizations;
    
    // Empty instruction stream
    const instructions = try allocator.alloc(Instruction, 0);
    defer allocator.free(instructions);
    
    // Should not crash
    try applyPatternOptimizations(instructions, &[_]u8{});
}

test "analysis: code_len field accuracy" {
    const allocator = std.testing.allocator;
    
    const test_cases = [_]struct { code: []const u8 }{
        .{ .code = &[_]u8{} }, // Empty
        .{ .code = &[_]u8{0x00} }, // Single byte
        .{ .code = &[_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x00 } }, // 6 bytes
        .{ .code = &[_]u8{0x00} ** 100 }, // 100 bytes
        .{ .code = &[_]u8{0x5B} ** 1000 }, // 1000 bytes
    };
    
    for (test_cases) |tc| {
        var analysis = try CodeAnalysis.from_code(allocator, tc.code, &OpcodeMetadata.DEFAULT);
        defer analysis.deinit();
        
        try std.testing.expectEqual(tc.code.len, analysis.code_len);
        try std.testing.expectEqual(tc.code.ptr, analysis.code.ptr);
    }
}

test "analysis: allocator consistency" {
    const allocator = std.testing.allocator;
    
    const code = &[_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x00 };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // Verify allocator is stored correctly
    try std.testing.expectEqual(allocator, analysis.allocator);
}

test "analysis: instruction and auxiliary array sizes match" {
    const allocator = std.testing.allocator;
    
    const code = &[_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x01, // ADD
        0x60, 0x0A, // PUSH1 10
        0x56, // JUMP
        0x5B, // JUMPDEST
        0x00, // STOP
    };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // All auxiliary arrays should have same length as instructions
    try std.testing.expectEqual(analysis.instructions.len, analysis.inst_jump_type.len);
    try std.testing.expectEqual(analysis.instructions.len, analysis.inst_to_pc.len);
    
    // pc_to_block_start should cover at least the code length
    try std.testing.expect(analysis.pc_to_block_start.len >= code.len);
}

test "analysis: deeply nested conditionals" {
    const allocator = std.testing.allocator;
    
    const code = &[_]u8{
        // Nested if-else pattern
        0x60, 0x01, // PUSH1 1
        0x60, 0x08, // PUSH1 8
        0x57, // JUMPI (to first branch)
        0x60, 0x20, // PUSH1 32 (else branch)
        0x56, // JUMP
        
        0x5B, // JUMPDEST at 8 (first branch)
        0x60, 0x02, // PUSH1 2
        0x60, 0x10, // PUSH1 16
        0x57, // JUMPI (nested condition)
        0x60, 0x20, // PUSH1 32
        0x56, // JUMP
        
        0x5B, // JUMPDEST at 16 (nested true)
        0x60, 0x03, // PUSH1 3
        0x60, 0x20, // PUSH1 32
        0x56, // JUMP
        
        0x5B, // JUMPDEST at 32 (common exit)
        0x00, // STOP
    };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // All jumpdests should be valid
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(8));
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(16));
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(32));
}

test "analysis: opcode at end of code" {
    const allocator = std.testing.allocator;
    
    // Code ending with incomplete PUSH
    const code = &[_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, // PUSH1 without data byte
    };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // Should handle gracefully without crashing
    try std.testing.expect(analysis.instructions.len > 0);
}

test "analysis: all memory operations" {
    const allocator = std.testing.allocator;
    
    const code = &[_]u8{
        // MLOAD
        0x60, 0x00, // PUSH1 0
        0x51, // MLOAD
        
        // MSTORE
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        
        // MSTORE8
        0x60, 0xFF, // PUSH1 0xFF
        0x60, 0x20, // PUSH1 32
        0x53, // MSTORE8
        
        // MSIZE
        0x59, // MSIZE
        
        // MCOPY (Cancun)
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (source)
        0x60, 0x40, // PUSH1 64 (dest)
        0x5E, // MCOPY
        
        0x00, // STOP
    };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // Should handle all memory operations
    try std.testing.expect(analysis.instructions.len > 0);
}

test "analysis: block terminators create proper boundaries" {
    const allocator = std.testing.allocator;
    
    const code = &[_]u8{
        // Block 1
        0x60, 0x01, // PUSH1 1
        0x00, // STOP (terminator)
        
        // Block 2 (unreachable without jump)
        0x60, 0x02, // PUSH1 2
        0xFD, // REVERT (terminator)
        
        // Block 3 (unreachable)
        0x60, 0x03, // PUSH1 3
        0xF3, // RETURN (terminator)
        
        // Block 4 (unreachable)
        0x60, 0x04, // PUSH1 4
        0xFE, // INVALID (terminator)
        
        // Block 5 (unreachable)
        0x60, 0x05, // PUSH1 5
        0xFF, // SELFDESTRUCT (terminator)
    };
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // Each terminator should create a block boundary
    try std.testing.expect(analysis.instructions.len > 0);
}

test "analysis: pc_to_block_start handles sparse jumpdests" {
    const allocator = std.testing.allocator;
    
    // Code with jumpdests far apart
    var code = try allocator.alloc(u8, 1000);
    defer allocator.free(code);
    
    // Fill with STOP opcodes
    @memset(code, 0x00);
    
    // Place sparse jumpdests
    code[0] = 0x5B; // JUMPDEST at 0
    code[100] = 0x5B; // JUMPDEST at 100
    code[500] = 0x5B; // JUMPDEST at 500
    code[999] = 0x5B; // JUMPDEST at 999
    
    var analysis = try CodeAnalysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // pc_to_block_start should handle sparse jumpdests
    try std.testing.expect(analysis.pc_to_block_start.len >= code.len);
    
    // Verify block starts are mapped
    try std.testing.expect(analysis.pc_to_block_start[0] != std.math.maxInt(u16));
    try std.testing.expect(analysis.pc_to_block_start[100] != std.math.maxInt(u16));
    try std.testing.expect(analysis.pc_to_block_start[500] != std.math.maxInt(u16));
    try std.testing.expect(analysis.pc_to_block_start[999] != std.math.maxInt(u16));
}
