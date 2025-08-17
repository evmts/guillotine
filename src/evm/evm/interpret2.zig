const std = @import("std");
const builtin = @import("builtin");
const ExecutionError = @import("../execution/execution_error.zig");
const frame_mod = @import("../frame.zig");
const Frame = frame_mod.Frame;
const Opcode = @import("../opcodes/opcode.zig").Enum;
const Stack = @import("../stack/stack.zig");
const Memory = @import("../memory/memory.zig");
const execution = @import("../execution/package.zig");
const primitives = @import("primitives");
const tailcalls = @import("tailcalls.zig");

pub const Error = ExecutionError.Error;

// Function pointer type for tailcall dispatch - use the same type as Frame
const TailcallFunc = frame_mod.TailcallFunc;

// Simple analysis result for tailcall dispatch
const SimpleAnalysis = struct {
    jumpdest_bitvec: []bool, // True if position is valid JUMPDEST
    opcodes: []Opcode, // Opcode at each position (0xFF for data bytes)
    jump_table: []JumpEntry, // Sorted list of jump destinations to function pointers
    push_values: []u256, // Values for PUSH operations (indexed by instruction)

    const JumpEntry = struct {
        dest: usize,
        fn_index: usize, // Index into ops array
    };
};

// Helper function to check if a byte is a valid opcode
fn isValidOpcode(byte: u8) bool {
    // Valid opcodes are:
    // 0x00-0x0b: STOP to SIGNEXTEND
    // 0x10-0x1d: LT to SAR
    // 0x20: KECCAK256
    // 0x30-0x3f: ADDRESS to EXTCODECOPY
    // 0x40-0x48: BLOCKHASH to BASEFEE
    // 0x50-0x5b: POP to JUMPDEST
    // 0x5f-0x7f: PUSH0 to PUSH32
    // 0x80-0x8f: DUP1 to DUP16
    // 0x90-0x9f: SWAP1 to SWAP16
    // 0xa0-0xa4: LOG0 to LOG4
    // 0xf0-0xff: CREATE to SELFDESTRUCT
    
    return switch (byte) {
        0x00...0x0b => true,
        0x10...0x1d => true,
        0x20 => true,
        0x30...0x3f => true,
        0x40...0x48 => true,
        0x50...0x5b => true,
        0x5f...0x7f => true,
        0x80...0x8f => true,
        0x90...0x9f => true,
        0xa0...0xa4 => true,
        0xf0...0xff => true,
        else => false,
    };
}

// Main interpret function
pub fn interpret2(frame: *Frame, code: []const u8) Error!void {
    // Pre-allocate a fixed buffer for all memory needs
    // Estimate:
    // - jumpdest_bitvec: code.len * 1 byte (bool)
    // - opcodes: code.len * 1 byte (u8 enum)
    // - jump_dests: up to code.len/2 * 16 bytes (JumpEntry is ~16 bytes)
    // - push_values: up to code.len/2 * 32 bytes (u256 is 32 bytes)
    // - ops: code.len * 8 bytes (function pointer)
    // Total rough estimate: code.len * (1 + 1 + 8 + 16 + 32) = code.len * 58
    // Add 50% safety margin: code.len * 87
    const estimated_size = code.len * 87 + 4096; // Extra 4KB for overhead

    const buffer = try std.heap.page_allocator.alloc(u8, estimated_size);
    defer std.heap.page_allocator.free(buffer);

    var fba = std.heap.FixedBufferAllocator.init(buffer);
    const allocator = fba.allocator();

    var jumpdest_bitvec = try allocator.alloc(bool, code.len);
    @memset(jumpdest_bitvec, false);

    var opcodes = try allocator.alloc(Opcode, code.len);
    @memset(opcodes, @enumFromInt(0xFF));

    var jump_dests = std.ArrayList(SimpleAnalysis.JumpEntry).init(allocator);
    defer jump_dests.deinit();

    var push_values = std.ArrayList(u256).init(allocator);
    defer push_values.deinit();

    var pc: usize = 0;
    var instruction_index: usize = 0;
    while (pc < code.len) : (instruction_index += 1) {
        const byte = code[pc];
        
        // For the initial analysis, we need to check if this is a valid opcode
        // But we need to handle PUSH instructions specially since they have data bytes
        const is_push = (byte >= 0x60 and byte <= 0x7F) or byte == 0x5F;
        
        if (!is_push and !isValidOpcode(byte)) {
            // This might be data from a previous PUSH instruction that we missed
            // For now, treat it as invalid data (0xFF is commonly used for invalid)
            opcodes[pc] = @as(Opcode, @enumFromInt(0xFF));
            pc += 1;
            continue;
        }
        
        const opcode = if (isValidOpcode(byte)) 
            @as(Opcode, @enumFromInt(byte))
        else 
            @as(Opcode, @enumFromInt(0xFF)); // Invalid/data byte
            
        opcodes[pc] = opcode;

        if (opcode == .JUMPDEST) {
            jumpdest_bitvec[pc] = true;
            try jump_dests.append(.{
                .dest = pc,
                .fn_index = instruction_index,
            });
        }

        if (byte >= 0x60 and byte <= 0x7F) {
            const push_size = byte - 0x5F;
            pc += 1;

            var value: u256 = 0;
            var i: usize = 0;
            while (i < push_size and pc + i < code.len) : (i += 1) {
                value = (value << 8) | code[pc + i];
                // Mark these bytes as data, not opcodes
                if (pc + i < code.len) {
                    opcodes[pc + i] = @as(Opcode, @enumFromInt(0xFF));
                }
            }
            try push_values.append(value);

            const end = @min(pc + push_size, code.len);
            pc = end;
        } else if (byte == 0x5F) {
            try push_values.append(0);
            pc += 1;
        } else {
            pc += 1;
        }
    }

    // Store analysis data for potential future use
    _ = SimpleAnalysis{
        .jumpdest_bitvec = jumpdest_bitvec,
        .opcodes = opcodes,
        .jump_table = try jump_dests.toOwnedSlice(),
        .push_values = try push_values.toOwnedSlice(),
    };

    var ops = std.ArrayList(TailcallFunc).init(allocator);
    defer ops.deinit();

    pc = 0;
    while (pc < code.len) {
        const byte = code[pc];
        
        // Skip invalid opcodes (data bytes)
        if (!isValidOpcode(byte)) {
            // This is a data byte from a PUSH instruction, skip it
            pc += 1;
            continue;
        }
        
        const opcode = @as(Opcode, @enumFromInt(byte));

        const fn_ptr = switch (opcode) {
            .STOP => &tailcalls.op_stop,
            .ADD => &tailcalls.op_add,
            .MUL => &tailcalls.op_mul,
            .SUB => &tailcalls.op_sub,
            .DIV => &tailcalls.op_div,
            .SDIV => &tailcalls.op_sdiv,
            .MOD => &tailcalls.op_mod,
            .SMOD => &tailcalls.op_smod,
            .ADDMOD => &tailcalls.op_addmod,
            .MULMOD => &tailcalls.op_mulmod,
            .EXP => &tailcalls.op_exp,
            .SIGNEXTEND => &tailcalls.op_signextend,
            .LT => &tailcalls.op_lt,
            .GT => &tailcalls.op_gt,
            .SLT => &tailcalls.op_slt,
            .SGT => &tailcalls.op_sgt,
            .EQ => &tailcalls.op_eq,
            .ISZERO => &tailcalls.op_iszero,
            .AND => &tailcalls.op_and,
            .OR => &tailcalls.op_or,
            .XOR => &tailcalls.op_xor,
            .NOT => &tailcalls.op_not,
            .BYTE => &tailcalls.op_byte,
            .SHL => &tailcalls.op_shl,
            .SHR => &tailcalls.op_shr,
            .SAR => &tailcalls.op_sar,
            .KECCAK256 => &tailcalls.op_keccak256,
            .ADDRESS => &tailcalls.op_address,
            .BALANCE => &tailcalls.op_balance,
            .ORIGIN => &tailcalls.op_origin,
            .CALLER => &tailcalls.op_caller,
            .CALLVALUE => &tailcalls.op_callvalue,
            .CALLDATALOAD => &tailcalls.op_calldataload,
            .CALLDATASIZE => &tailcalls.op_calldatasize,
            .CALLDATACOPY => &tailcalls.op_calldatacopy,
            .CODESIZE => &tailcalls.op_codesize,
            .CODECOPY => &tailcalls.op_codecopy,
            .GASPRICE => &tailcalls.op_gasprice,
            .EXTCODESIZE => &tailcalls.op_extcodesize,
            .EXTCODECOPY => &tailcalls.op_extcodecopy,
            .RETURNDATASIZE => &tailcalls.op_returndatasize,
            .RETURNDATACOPY => &tailcalls.op_returndatacopy,
            .EXTCODEHASH => &tailcalls.op_extcodehash,
            .BLOCKHASH => &tailcalls.op_blockhash,
            .COINBASE => &tailcalls.op_coinbase,
            .TIMESTAMP => &tailcalls.op_timestamp,
            .NUMBER => &tailcalls.op_number,
            .PREVRANDAO => &tailcalls.op_difficulty, // PREVRANDAO replaced DIFFICULTY
            .GASLIMIT => &tailcalls.op_gaslimit,
            .CHAINID => &tailcalls.op_chainid,
            .SELFBALANCE => &tailcalls.op_selfbalance,
            .BASEFEE => &tailcalls.op_basefee,
            .BLOBHASH => &tailcalls.op_blobhash,
            .BLOBBASEFEE => &tailcalls.op_blobbasefee,
            .POP => &tailcalls.op_pop,
            .MLOAD => &tailcalls.op_mload,
            .MSTORE => &tailcalls.op_mstore,
            .MSTORE8 => &tailcalls.op_mstore8,
            .SLOAD => &tailcalls.op_sload,
            .SSTORE => &tailcalls.op_sstore,
            .JUMP => &tailcalls.op_jump,
            .JUMPI => &tailcalls.op_jumpi,
            .PC => &tailcalls.op_pc,
            .MSIZE => &tailcalls.op_msize,
            .GAS => &tailcalls.op_gas,
            .JUMPDEST => &tailcalls.op_jumpdest,
            .TLOAD => &tailcalls.op_tload,
            .TSTORE => &tailcalls.op_tstore,
            .MCOPY => &tailcalls.op_mcopy,
            .PUSH0 => &tailcalls.op_push0,
            .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8, .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16, .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24, .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => &tailcalls.op_push,
            .DUP1 => &tailcalls.op_dup1,
            .DUP2 => &tailcalls.op_dup2,
            .DUP3 => &tailcalls.op_dup3,
            .DUP4 => &tailcalls.op_dup4,
            .DUP5 => &tailcalls.op_dup5,
            .DUP6 => &tailcalls.op_dup6,
            .DUP7 => &tailcalls.op_dup7,
            .DUP8 => &tailcalls.op_dup8,
            .DUP9 => &tailcalls.op_dup9,
            .DUP10 => &tailcalls.op_dup10,
            .DUP11 => &tailcalls.op_dup11,
            .DUP12 => &tailcalls.op_dup12,
            .DUP13 => &tailcalls.op_dup13,
            .DUP14 => &tailcalls.op_dup14,
            .DUP15 => &tailcalls.op_dup15,
            .DUP16 => &tailcalls.op_dup16,
            .SWAP1 => &tailcalls.op_swap1,
            .SWAP2 => &tailcalls.op_swap2,
            .SWAP3 => &tailcalls.op_swap3,
            .SWAP4 => &tailcalls.op_swap4,
            .SWAP5 => &tailcalls.op_swap5,
            .SWAP6 => &tailcalls.op_swap6,
            .SWAP7 => &tailcalls.op_swap7,
            .SWAP8 => &tailcalls.op_swap8,
            .SWAP9 => &tailcalls.op_swap9,
            .SWAP10 => &tailcalls.op_swap10,
            .SWAP11 => &tailcalls.op_swap11,
            .SWAP12 => &tailcalls.op_swap12,
            .SWAP13 => &tailcalls.op_swap13,
            .SWAP14 => &tailcalls.op_swap14,
            .SWAP15 => &tailcalls.op_swap15,
            .SWAP16 => &tailcalls.op_swap16,
            .LOG0 => &tailcalls.op_log0,
            .LOG1 => &tailcalls.op_log1,
            .LOG2 => &tailcalls.op_log2,
            .LOG3 => &tailcalls.op_log3,
            .LOG4 => &tailcalls.op_log4,
            .CREATE => &tailcalls.op_create,
            .CALL => &tailcalls.op_call,
            .CALLCODE => &tailcalls.op_callcode,
            .RETURN => &tailcalls.op_return,
            .DELEGATECALL => &tailcalls.op_delegatecall,
            .CREATE2 => &tailcalls.op_create2,
            .STATICCALL => &tailcalls.op_staticcall,
            .REVERT => &tailcalls.op_revert,
            .INVALID => &tailcalls.op_invalid,
            .SELFDESTRUCT => &tailcalls.op_selfdestruct,
            else => &tailcalls.op_invalid,
        };

        try ops.append(fn_ptr);

        // Skip PUSH data bytes
        if (byte >= 0x60 and byte <= 0x7F) {
            const push_size = byte - 0x5F;
            pc += 1 + push_size;
        } else {
            pc += 1;
        }
    }

    // Always append a STOP at the end to ensure proper termination
    // This handles both empty code and code that doesn't end with STOP
    try ops.append(&tailcalls.op_stop);

    const ops_slice = try ops.toOwnedSlice();

    frame.tailcall_ops = @ptrCast(ops_slice.ptr);
    frame.tailcall_index = 0;

    var ip: usize = 0;
    const ops_ptr = @as([*]const *const anyopaque, @ptrCast(ops_slice.ptr));
    const first_op = ops_slice[0];
    _ = first_op(frame, ops_ptr, &ip) catch |err| return err;
    unreachable;
}
