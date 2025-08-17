const std = @import("std");
const builtin = @import("builtin");
const ExecutionError = @import("../execution/execution_error.zig");
const Frame = @import("../frame.zig").Frame;
const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
const Opcode = @import("../opcodes/opcode.zig").Opcode;
const Stack = @import("../stack/stack.zig");
const Memory = @import("../memory/memory.zig");
const execution = @import("../execution/package.zig");
const primitives = @import("primitives");

const Error = ExecutionError.Error;

// Simple analysis result for tailcall dispatch
const SimpleAnalysis = struct {
    jumpdest_bitvec: []bool,  // True if position is valid JUMPDEST
    opcodes: []Opcode,        // Opcode at each position (0xFF for data bytes)
    jump_table: []JumpEntry,  // Sorted list of jump destinations to function pointers
    allocator: std.mem.Allocator,
    
    const JumpEntry = struct {
        dest: usize,
        fn_index: usize,  // Index into ops array
    };
    
    pub fn deinit(self: *SimpleAnalysis) void {
        self.allocator.free(self.jumpdest_bitvec);
        self.allocator.free(self.opcodes);
        self.allocator.free(self.jump_table);
    }
};

// Function pointer type for tailcall dispatch
const TailcallFunc = *const fn (frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void;

// Perform simple analysis on bytecode
fn analyzeCode(allocator: std.mem.Allocator, code: []const u8) !SimpleAnalysis {
    var jumpdest_bitvec = try allocator.alloc(bool, code.len);
    errdefer allocator.free(jumpdest_bitvec);
    @memset(jumpdest_bitvec, false);
    
    var opcodes = try allocator.alloc(Opcode, code.len);
    errdefer allocator.free(opcodes);
    @memset(opcodes, @enumFromInt(0xFF)); // Invalid opcode for data bytes
    
    var jump_dests = std.ArrayList(SimpleAnalysis.JumpEntry).init(allocator);
    defer jump_dests.deinit();
    
    // First pass: identify opcodes and jump destinations
    var pc: usize = 0;
    var instruction_index: usize = 0;
    while (pc < code.len) : (instruction_index += 1) {
        const byte = code[pc];
        const opcode = @as(Opcode, @enumFromInt(byte));
        opcodes[pc] = opcode;
        
        // Check if this is a JUMPDEST
        if (opcode == .JUMPDEST) {
            jumpdest_bitvec[pc] = true;
            try jump_dests.append(.{
                .dest = pc,
                .fn_index = instruction_index,
            });
        }
        
        // Skip PUSH data bytes
        if (byte >= 0x60 and byte <= 0x7F) {
            const push_size = byte - 0x5F; // PUSH1 = 0x60, so size = 1
            pc += 1;
            // Mark data bytes as invalid
            const end = @min(pc + push_size, code.len);
            pc = end;
        } else {
            pc += 1;
        }
    }
    
    return SimpleAnalysis{
        .jumpdest_bitvec = jumpdest_bitvec,
        .opcodes = opcodes,
        .jump_table = try jump_dests.toOwnedSlice(),
        .allocator = allocator,
    };
}

// Build ops array of tailcall functions
fn buildOpsArray(allocator: std.mem.Allocator, code: []const u8) ![]TailcallFunc {
    var ops = std.ArrayList(TailcallFunc).init(allocator);
    defer ops.deinit();
    
    var pc: usize = 0;
    while (pc < code.len) {
        const byte = code[pc];
        const opcode = @as(Opcode, @enumFromInt(byte));
        
        // Map opcode to tailcall function
        const fn_ptr = switch (opcode) {
            .STOP => &op_stop,
            .ADD => &op_add,
            .MUL => &op_mul,
            .SUB => &op_sub,
            .DIV => &op_div,
            .SDIV => &op_sdiv,
            .MOD => &op_mod,
            .SMOD => &op_smod,
            .ADDMOD => &op_addmod,
            .MULMOD => &op_mulmod,
            .EXP => &op_exp,
            .SIGNEXTEND => &op_signextend,
            .LT => &op_lt,
            .GT => &op_gt,
            .SLT => &op_slt,
            .SGT => &op_sgt,
            .EQ => &op_eq,
            .ISZERO => &op_iszero,
            .AND => &op_and,
            .OR => &op_or,
            .XOR => &op_xor,
            .NOT => &op_not,
            .BYTE => &op_byte,
            .SHL => &op_shl,
            .SHR => &op_shr,
            .SAR => &op_sar,
            .KECCAK256 => &op_keccak256,
            .ADDRESS => &op_address,
            .BALANCE => &op_balance,
            .ORIGIN => &op_origin,
            .CALLER => &op_caller,
            .CALLVALUE => &op_callvalue,
            .CALLDATALOAD => &op_calldataload,
            .CALLDATASIZE => &op_calldatasize,
            .CALLDATACOPY => &op_calldatacopy,
            .CODESIZE => &op_codesize,
            .CODECOPY => &op_codecopy,
            .GASPRICE => &op_gasprice,
            .EXTCODESIZE => &op_extcodesize,
            .EXTCODECOPY => &op_extcodecopy,
            .RETURNDATASIZE => &op_returndatasize,
            .RETURNDATACOPY => &op_returndatacopy,
            .EXTCODEHASH => &op_extcodehash,
            .BLOCKHASH => &op_blockhash,
            .COINBASE => &op_coinbase,
            .TIMESTAMP => &op_timestamp,
            .NUMBER => &op_number,
            .DIFFICULTY => &op_difficulty,
            .GASLIMIT => &op_gaslimit,
            .CHAINID => &op_chainid,
            .SELFBALANCE => &op_selfbalance,
            .BASEFEE => &op_basefee,
            .BLOBHASH => &op_blobhash,
            .BLOBBASEFEE => &op_blobbasefee,
            .POP => &op_pop,
            .MLOAD => &op_mload,
            .MSTORE => &op_mstore,
            .MSTORE8 => &op_mstore8,
            .SLOAD => &op_sload,
            .SSTORE => &op_sstore,
            .JUMP => &op_jump,
            .JUMPI => &op_jumpi,
            .PC => &op_pc,
            .MSIZE => &op_msize,
            .GAS => &op_gas,
            .JUMPDEST => &op_jumpdest,
            .TLOAD => &op_tload,
            .TSTORE => &op_tstore,
            .MCOPY => &op_mcopy,
            .PUSH0 => &op_push0,
            .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8,
            .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16,
            .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24,
            .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => &op_push,
            .DUP1 => &op_dup1,
            .DUP2 => &op_dup2,
            .DUP3 => &op_dup3,
            .DUP4 => &op_dup4,
            .DUP5 => &op_dup5,
            .DUP6 => &op_dup6,
            .DUP7 => &op_dup7,
            .DUP8 => &op_dup8,
            .DUP9 => &op_dup9,
            .DUP10 => &op_dup10,
            .DUP11 => &op_dup11,
            .DUP12 => &op_dup12,
            .DUP13 => &op_dup13,
            .DUP14 => &op_dup14,
            .DUP15 => &op_dup15,
            .DUP16 => &op_dup16,
            .SWAP1 => &op_swap1,
            .SWAP2 => &op_swap2,
            .SWAP3 => &op_swap3,
            .SWAP4 => &op_swap4,
            .SWAP5 => &op_swap5,
            .SWAP6 => &op_swap6,
            .SWAP7 => &op_swap7,
            .SWAP8 => &op_swap8,
            .SWAP9 => &op_swap9,
            .SWAP10 => &op_swap10,
            .SWAP11 => &op_swap11,
            .SWAP12 => &op_swap12,
            .SWAP13 => &op_swap13,
            .SWAP14 => &op_swap14,
            .SWAP15 => &op_swap15,
            .SWAP16 => &op_swap16,
            .LOG0 => &op_log0,
            .LOG1 => &op_log1,
            .LOG2 => &op_log2,
            .LOG3 => &op_log3,
            .LOG4 => &op_log4,
            .CREATE => &op_create,
            .CALL => &op_call,
            .CALLCODE => &op_callcode,
            .RETURN => &op_return,
            .DELEGATECALL => &op_delegatecall,
            .CREATE2 => &op_create2,
            .STATICCALL => &op_staticcall,
            .REVERT => &op_revert,
            .INVALID => &op_invalid,
            .SELFDESTRUCT => &op_selfdestruct,
            _ => &op_invalid, // Unknown opcodes are invalid
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
    
    return ops.toOwnedSlice();
}

// Main interpret function
pub fn interpret2(frame: *Frame, code: []const u8) Error!void {
    // Set analysis to null to ensure we don't use it
    frame.analysis = undefined;
    
    // Perform simple analysis
    var analysis = analyzeCode(frame.stack.allocator, code) catch return Error.OutOfMemory;
    defer analysis.deinit();
    
    // Build ops array
    const ops = buildOpsArray(frame.stack.allocator, code) catch return Error.OutOfMemory;
    defer frame.stack.allocator.free(ops);
    
    // Store analysis and ops in frame for access by opcodes
    frame.tailcall_ops = @ptrCast(ops.ptr);
    frame.tailcall_index = 0;
    
    // Start execution with first instruction
    var ip: usize = 0;
    return @call(.always_tail, ops[0], .{ frame, ops.ptr, &ip });
}

// Helper to advance to next instruction
inline fn next(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    ip.* += 1;
    return @call(.always_tail, ops[ip.*], .{ frame, ops, ip });
}

// Opcode implementations

fn op_stop(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    _ = frame;
    _ = ops;
    _ = ip;
    return Error.STOP;
}

fn op_add(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.arithmetic.op_add(frame);
    return next(frame, ops, ip);
}

fn op_mul(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.arithmetic.op_mul(frame);
    return next(frame, ops, ip);
}

fn op_sub(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.arithmetic.op_sub(frame);
    return next(frame, ops, ip);
}

fn op_div(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.arithmetic.op_div(frame);
    return next(frame, ops, ip);
}

fn op_sdiv(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.arithmetic.op_sdiv(frame);
    return next(frame, ops, ip);
}

fn op_mod(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.arithmetic.op_mod(frame);
    return next(frame, ops, ip);
}

fn op_smod(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.arithmetic.op_smod(frame);
    return next(frame, ops, ip);
}

fn op_addmod(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.arithmetic.op_addmod(frame);
    return next(frame, ops, ip);
}

fn op_mulmod(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.arithmetic.op_mulmod(frame);
    return next(frame, ops, ip);
}

fn op_exp(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.arithmetic.op_exp(frame);
    return next(frame, ops, ip);
}

fn op_signextend(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.arithmetic.op_signextend(frame);
    return next(frame, ops, ip);
}

fn op_lt(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.arithmetic.op_lt(frame);
    return next(frame, ops, ip);
}

fn op_gt(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.arithmetic.op_gt(frame);
    return next(frame, ops, ip);
}

fn op_slt(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.arithmetic.op_slt(frame);
    return next(frame, ops, ip);
}

fn op_sgt(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.arithmetic.op_sgt(frame);
    return next(frame, ops, ip);
}

fn op_eq(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.arithmetic.op_eq(frame);
    return next(frame, ops, ip);
}

fn op_iszero(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.arithmetic.op_iszero(frame);
    return next(frame, ops, ip);
}

fn op_and(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.bitwise.op_and(frame);
    return next(frame, ops, ip);
}

fn op_or(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.bitwise.op_or(frame);
    return next(frame, ops, ip);
}

fn op_xor(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.bitwise.op_xor(frame);
    return next(frame, ops, ip);
}

fn op_not(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.bitwise.op_not(frame);
    return next(frame, ops, ip);
}

fn op_byte(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.bitwise.op_byte(frame);
    return next(frame, ops, ip);
}

fn op_shl(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.bitwise.op_shl(frame);
    return next(frame, ops, ip);
}

fn op_shr(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.bitwise.op_shr(frame);
    return next(frame, ops, ip);
}

fn op_sar(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.bitwise.op_sar(frame);
    return next(frame, ops, ip);
}

fn op_keccak256(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.crypto.op_keccak256(frame);
    return next(frame, ops, ip);
}

// Continue with more opcodes...
fn op_address(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.environment.op_address(frame);
    return next(frame, ops, ip);
}

fn op_balance(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.environment.op_balance(frame);
    return next(frame, ops, ip);
}

fn op_origin(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.environment.op_origin(frame);
    return next(frame, ops, ip);
}

fn op_caller(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.environment.op_caller(frame);
    return next(frame, ops, ip);
}

fn op_callvalue(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.environment.op_callvalue(frame);
    return next(frame, ops, ip);
}

fn op_calldataload(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.environment.op_calldataload(frame);
    return next(frame, ops, ip);
}

fn op_calldatasize(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.environment.op_calldatasize(frame);
    return next(frame, ops, ip);
}

fn op_calldatacopy(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.environment.op_calldatacopy(frame);
    return next(frame, ops, ip);
}

fn op_codesize(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.environment.op_codesize(frame);
    return next(frame, ops, ip);
}

fn op_codecopy(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.environment.op_codecopy(frame);
    return next(frame, ops, ip);
}

fn op_gasprice(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.environment.op_gasprice(frame);
    return next(frame, ops, ip);
}

fn op_extcodesize(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.environment.op_extcodesize(frame);
    return next(frame, ops, ip);
}

fn op_extcodecopy(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.environment.op_extcodecopy(frame);
    return next(frame, ops, ip);
}

fn op_returndatasize(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.environment.op_returndatasize(frame);
    return next(frame, ops, ip);
}

fn op_returndatacopy(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.environment.op_returndatacopy(frame);
    return next(frame, ops, ip);
}

fn op_extcodehash(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.environment.op_extcodehash(frame);
    return next(frame, ops, ip);
}

// Block info opcodes
fn op_blockhash(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.block.op_blockhash(frame);
    return next(frame, ops, ip);
}

fn op_coinbase(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.block.op_coinbase(frame);
    return next(frame, ops, ip);
}

fn op_timestamp(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.block.op_timestamp(frame);
    return next(frame, ops, ip);
}

fn op_number(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.block.op_number(frame);
    return next(frame, ops, ip);
}

fn op_difficulty(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.block.op_difficulty(frame);
    return next(frame, ops, ip);
}

fn op_gaslimit(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.block.op_gaslimit(frame);
    return next(frame, ops, ip);
}

fn op_chainid(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.block.op_chainid(frame);
    return next(frame, ops, ip);
}

fn op_selfbalance(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.block.op_selfbalance(frame);
    return next(frame, ops, ip);
}

fn op_basefee(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.block.op_basefee(frame);
    return next(frame, ops, ip);
}

fn op_blobhash(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.block.op_blobhash(frame);
    return next(frame, ops, ip);
}

fn op_blobbasefee(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.block.op_blobbasefee(frame);
    return next(frame, ops, ip);
}

// Stack operations
fn op_pop(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_pop(frame);
    return next(frame, ops, ip);
}

fn op_push0(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_push0(frame);
    return next(frame, ops, ip);
}

// TODO: Implement push with data bytes
fn op_push(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    _ = frame;
    _ = ops;
    _ = ip;
    return Error.OpcodeNotImplemented;
}

// DUP operations
fn op_dup1(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_dup1(frame);
    return next(frame, ops, ip);
}

fn op_dup2(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_dup2(frame);
    return next(frame, ops, ip);
}

fn op_dup3(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_dup3(frame);
    return next(frame, ops, ip);
}

fn op_dup4(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_dup4(frame);
    return next(frame, ops, ip);
}

fn op_dup5(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_dup5(frame);
    return next(frame, ops, ip);
}

fn op_dup6(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_dup6(frame);
    return next(frame, ops, ip);
}

fn op_dup7(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_dup7(frame);
    return next(frame, ops, ip);
}

fn op_dup8(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_dup8(frame);
    return next(frame, ops, ip);
}

fn op_dup9(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_dup9(frame);
    return next(frame, ops, ip);
}

fn op_dup10(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_dup10(frame);
    return next(frame, ops, ip);
}

fn op_dup11(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_dup11(frame);
    return next(frame, ops, ip);
}

fn op_dup12(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_dup12(frame);
    return next(frame, ops, ip);
}

fn op_dup13(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_dup13(frame);
    return next(frame, ops, ip);
}

fn op_dup14(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_dup14(frame);
    return next(frame, ops, ip);
}

fn op_dup15(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_dup15(frame);
    return next(frame, ops, ip);
}

fn op_dup16(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_dup16(frame);
    return next(frame, ops, ip);
}

// SWAP operations
fn op_swap1(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_swap1(frame);
    return next(frame, ops, ip);
}

fn op_swap2(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_swap2(frame);
    return next(frame, ops, ip);
}

fn op_swap3(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_swap3(frame);
    return next(frame, ops, ip);
}

fn op_swap4(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_swap4(frame);
    return next(frame, ops, ip);
}

fn op_swap5(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_swap5(frame);
    return next(frame, ops, ip);
}

fn op_swap6(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_swap6(frame);
    return next(frame, ops, ip);
}

fn op_swap7(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_swap7(frame);
    return next(frame, ops, ip);
}

fn op_swap8(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_swap8(frame);
    return next(frame, ops, ip);
}

fn op_swap9(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_swap9(frame);
    return next(frame, ops, ip);
}

fn op_swap10(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_swap10(frame);
    return next(frame, ops, ip);
}

fn op_swap11(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_swap11(frame);
    return next(frame, ops, ip);
}

fn op_swap12(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_swap12(frame);
    return next(frame, ops, ip);
}

fn op_swap13(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_swap13(frame);
    return next(frame, ops, ip);
}

fn op_swap14(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_swap14(frame);
    return next(frame, ops, ip);
}

fn op_swap15(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_swap15(frame);
    return next(frame, ops, ip);
}

fn op_swap16(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_swap16(frame);
    return next(frame, ops, ip);
}

// Memory operations
fn op_mload(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.memory.op_mload(frame);
    return next(frame, ops, ip);
}

fn op_mstore(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.memory.op_mstore(frame);
    return next(frame, ops, ip);
}

fn op_mstore8(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.memory.op_mstore8(frame);
    return next(frame, ops, ip);
}

fn op_msize(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.memory.op_msize(frame);
    return next(frame, ops, ip);
}

fn op_mcopy(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.memory.op_mcopy(frame);
    return next(frame, ops, ip);
}

// Storage operations
fn op_sload(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.storage.op_sload(frame);
    return next(frame, ops, ip);
}

fn op_sstore(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.storage.op_sstore(frame);
    return next(frame, ops, ip);
}

fn op_tload(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.storage.op_tload(frame);
    return next(frame, ops, ip);
}

fn op_tstore(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.storage.op_tstore(frame);
    return next(frame, ops, ip);
}

// Control flow - TODO: Implement jump logic
fn op_jump(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    _ = frame;
    _ = ops;
    _ = ip;
    return Error.OpcodeNotImplemented;
}

fn op_jumpi(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    _ = frame;
    _ = ops;
    _ = ip;
    return Error.OpcodeNotImplemented;
}

fn op_pc(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_pc(frame);
    return next(frame, ops, ip);
}

fn op_gas(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.stack.op_gas(frame);
    return next(frame, ops, ip);
}

fn op_jumpdest(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    // JUMPDEST is a no-op, just continue
    return next(frame, ops, ip);
}

// Log operations
fn op_log0(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.log.op_log0(frame);
    return next(frame, ops, ip);
}

fn op_log1(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.log.op_log1(frame);
    return next(frame, ops, ip);
}

fn op_log2(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.log.op_log2(frame);
    return next(frame, ops, ip);
}

fn op_log3(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.log.op_log3(frame);
    return next(frame, ops, ip);
}

fn op_log4(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.log.op_log4(frame);
    return next(frame, ops, ip);
}

// System operations
fn op_create(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.system.op_create(frame);
    return next(frame, ops, ip);
}

fn op_call(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.system.op_call(frame);
    return next(frame, ops, ip);
}

fn op_callcode(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.system.op_callcode(frame);
    return next(frame, ops, ip);
}

fn op_return(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.system.op_return(frame);
    return Error.RETURN;
}

fn op_delegatecall(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.system.op_delegatecall(frame);
    return next(frame, ops, ip);
}

fn op_create2(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.system.op_create2(frame);
    return next(frame, ops, ip);
}

fn op_staticcall(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.system.op_staticcall(frame);
    return next(frame, ops, ip);
}

fn op_revert(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.system.op_revert(frame);
    return Error.REVERT;
}

fn op_invalid(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    _ = frame;
    _ = ops;
    _ = ip;
    return Error.INVALID;
}

fn op_selfdestruct(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!void {
    try execution.system.op_selfdestruct(frame);
    return Error.STOP;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const evm = @import("../root.zig");

test "interpret2: simple ADD operation" {
    const allocator = testing.allocator;
    
    // Bytecode: PUSH1 5, PUSH1 3, ADD, STOP
    const code = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01, 0x00 };
    
    // Create test components
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    var frame = try Frame.init(
        1_000_000,                    // gas
        false,                        // static
        0,                           // depth
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        undefined,                    // analysis will be set to null
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    // Execute
    const result = interpret2(&frame, &code);
    try testing.expectError(Error.STOP, result);
    
    // Check stack result
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    try testing.expectEqual(@as(u256, 8), try frame.stack.pop());
}

test "interpret2: jumpdest analysis" {
    const allocator = testing.allocator;
    
    // Bytecode with JUMPDEST at position 4
    const code = [_]u8{ 
        0x60, 0x04, // PUSH1 4
        0x56,       // JUMP
        0x00,       // STOP (shouldn't reach)
        0x5B,       // JUMPDEST
        0x00,       // STOP
    };
    
    var analysis = try analyzeCode(allocator, code);
    defer analysis.deinit();
    
    // Verify JUMPDEST at position 4
    try testing.expect(analysis.jumpdest_bitvec[4]);
    try testing.expect(!analysis.jumpdest_bitvec[0]);
    try testing.expect(!analysis.jumpdest_bitvec[1]);
    try testing.expect(!analysis.jumpdest_bitvec[2]);
    try testing.expect(!analysis.jumpdest_bitvec[3]);
    try testing.expect(!analysis.jumpdest_bitvec[5]);
}

test "interpret2: ops array building" {
    const allocator = testing.allocator;
    
    // Simple bytecode
    const code = [_]u8{ 0x01, 0x02, 0x00 }; // ADD, MUL, STOP
    
    const ops = try buildOpsArray(allocator, code);
    defer allocator.free(ops);
    
    try testing.expectEqual(@as(usize, 3), ops.len);
    try testing.expectEqual(&op_add, ops[0]);
    try testing.expectEqual(&op_mul, ops[1]);
    try testing.expectEqual(&op_stop, ops[2]);
}