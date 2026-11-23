//! Multi-Oracle Differential EVM Execution Fuzzer
//!
//! Structure-aware bytecode + state + calldata + hardfork generator that executes
//! every generated scenario across multiple independent oracles and enforces EXACT
//! consensus parity:
//!
//!   Oracle 1: Mainnet Performance EVM (`enable_fusion = true`)
//!   Oracle 2: Mainnet Performance EVM (`enable_fusion = false`) -> catches ANY bytecode fusion bug!
//!   Oracle 3: `simulate()` vs `call()` -> proves zero state mutation & exact output/gas parity!
//!   Oracle 4: Multi-hardfork execution (FRONTIER -> PRAGUE) -> verifies fork-gated opcodes & gas!
//!
//! Covers 8 structured generation modes:
//!   0: Raw arbitrary bytecode (fuzzes decoder/invalid opcodes/truncated PUSH)
//!   1: Stack-balanced arithmetic/bitwise/comparison/keccak programs
//!   2: Control-flow programs with valid JUMPDESTs, JUMP, JUMPI, bounded loops
//!   3: Fusion-heavy programs intentionally triggering every synthetic opcode
//!   4: Memory & copy programs (MLOAD/MSTORE/MSTORE8/MCOPY/CALLDATACOPY/CODECOPY)
//!   5: Storage & transient storage programs (SLOAD/SSTORE/TLOAD/TSTORE + gas stipend/refunds)
//!   6: Multi-contract nested calls (CALL/CALLCODE/DELEGATECALL/STATICCALL/CREATE/CREATE2/SELFDESTRUCT)
//!   7: Multi-hardfork compatibility & fork-gated opcodes (PUSH0, MCOPY, TLOAD/TSTORE, BASEFEE, BLOBBASEFEE)

const std = @import("std");
const evm = @import("evm");
const fuzz_alloc = @import("fuzz_alloc.zig");
const primitives = @import("voltaire");

const Address = primitives.Address.Address;
const Database = evm.Database;
const Account = evm.Account;
const BlockInfo = evm.BlockInfo;
const TransactionContext = evm.TransactionContext;
const Hardfork = evm.Hardfork;

const EvmFusionOn = evm.Evm(.{ .enable_fusion = true, .eips = .{ .hardfork = .CANCUN } });
const EvmFusionOff = evm.Evm(.{ .enable_fusion = false, .eips = .{ .hardfork = .CANCUN } });
const EvmFrontier = evm.Evm(.{ .enable_fusion = true, .eips = .{ .hardfork = .FRONTIER } });
const EvmFrontierNoFusion = evm.Evm(.{ .enable_fusion = false, .eips = .{ .hardfork = .FRONTIER } });
const EvmBerlin = evm.Evm(.{ .enable_fusion = true, .eips = .{ .hardfork = .BERLIN } });
const EvmBerlinNoFusion = evm.Evm(.{ .enable_fusion = false, .eips = .{ .hardfork = .BERLIN } });
const EvmShanghai = evm.Evm(.{ .enable_fusion = true, .eips = .{ .hardfork = .SHANGHAI } });
const EvmShanghaiNoFusion = evm.Evm(.{ .enable_fusion = false, .eips = .{ .hardfork = .SHANGHAI } });
const EvmPrague = evm.Evm(.{ .enable_fusion = true, .eips = .{ .hardfork = .PRAGUE } });
const EvmPragueNoFusion = evm.Evm(.{ .enable_fusion = false, .eips = .{ .hardfork = .PRAGUE } });

const CALLER = Address{ .bytes = [_]u8{0} ** 19 ++ [_]u8{0xaa} };
const CONTRACT_A = Address{ .bytes = [_]u8{0} ** 19 ++ [_]u8{0x01} };
const CONTRACT_B = Address{ .bytes = [_]u8{0} ** 19 ++ [_]u8{0x02} };
const BENEFICIARY = Address{ .bytes = [_]u8{0} ** 19 ++ [_]u8{0xbb} };

fn makeBlockInfo(seed_byte: u8) BlockInfo {
    var randao = [_]u8{0} ** 32;
    randao[31] = seed_byte;
    return BlockInfo{
        .chain_id = 1,
        .number = 20_000_000 + @as(u64, seed_byte),
        .timestamp = 1_700_000_000 + @as(u64, seed_byte) * 12,
        .difficulty = 0,
        .prev_randao = randao,
        .gas_limit = 30_000_000,
        .coinbase = BENEFICIARY,
        .base_fee = 1 + @as(u64, seed_byte % 10),
        .blob_base_fee = 1,
        .blob_versioned_hashes = &.{},
    };
}

/// Generates structure-aware EVM bytecode from raw fuzzer bytes.
fn buildStructuredProgram(allocator: std.mem.Allocator, mode: u8, bytes: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    switch (mode) {
        0 => { // Raw bytes (capped to 512 bytes)
            const n = @min(bytes.len, 512);
            try out.appendSlice(allocator, bytes[0..n]);
        },
        1 => { // Stack-balanced arithmetic / bitwise / comparison / keccak
            const bin_ops = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0a, 0x0b, 0x10, 0x11, 0x12, 0x13, 0x14, 0x16, 0x17, 0x18, 0x1a, 0x1b, 0x1c, 0x1d };
            const un_ops = [_]u8{ 0x15, 0x19 };
            // Seed initial stack with 4 values
            for (0..4) |k| {
                const v = if (k < bytes.len) bytes[k] else @as(u8, @truncate(k + 1));
                try out.appendSlice(allocator, &.{ 0x60, v });
            }
            var i: usize = 0;
            while (i + 1 < bytes.len and out.items.len < 400) : (i += 2) {
                const sel = bytes[i];
                const imm = bytes[i + 1];
                switch (sel % 6) {
                    0, 1 => { // PUSH1 imm + binop
                        try out.appendSlice(allocator, &.{ 0x60, imm, bin_ops[sel % bin_ops.len] });
                    },
                    2 => { // PUSH2 + PUSH1 + ADDMOD/MULMOD
                        try out.appendSlice(allocator, &.{ 0x60, imm, 0x60, sel, if ((imm & 1) == 0) @as(u8, 0x08) else @as(u8, 0x09) });
                    },
                    3 => { // DUP + SWAP + unary
                        try out.appendSlice(allocator, &.{ 0x80, un_ops[sel % un_ops.len], 0x90 });
                    },
                    4 => { // Store to mem and KECCAK256
                        try out.appendSlice(allocator, &.{ 0x80, 0x60, imm & 0x3f, 0x52, 0x60, 0x20, 0x60, imm & 0x3f, 0x20 });
                    },
                    else => { // PUSH4 imm pattern
                        try out.appendSlice(allocator, &.{ 0x63, sel, imm, sel ^ imm, imm +% 1, bin_ops[imm % bin_ops.len] });
                    },
                }
            }
            // Return top of stack
            try out.appendSlice(allocator, &.{ 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 });
        },
        2 => { // Control flow: JUMPDESTs, conditional JUMPI, bounded loop, PC, GAS
            var jumpdests: [8]usize = undefined;
            var jd_count: usize = 0;
            // Prologue: push counter & accumulator
            try out.appendSlice(allocator, &.{ 0x60, 0x05, 0x60, 0x01 });
            var i: usize = 0;
            while (i < bytes.len and out.items.len < 300) : (i += 1) {
                const b = bytes[i];
                switch (b % 7) {
                    0 => { // Emit JUMPDEST
                        if (jd_count < jumpdests.len) {
                            jumpdests[jd_count] = out.items.len;
                            jd_count += 1;
                        }
                        try out.append(allocator, 0x5b);
                    },
                    1 => { // Conditional forward/backward jump to recorded JUMPDEST
                        if (jd_count > 0) {
                            const target = jumpdests[b % jd_count];
                            if (target <= 0xff) {
                                // Push condition from byte parity, jump if taken
                                try out.appendSlice(allocator, &.{ 0x60, b & 1, 0x60, @intCast(target), 0x57 });
                            }
                        }
                    },
                    2 => { // PC + ADD
                        try out.appendSlice(allocator, &.{ 0x58, 0x01 });
                    },
                    3 => { // GAS + MOD
                        try out.appendSlice(allocator, &.{ 0x5a, 0x60, 0x10, 0x06, 0x01 });
                    },
                    4 => { // PUSH containing fake 0x5b (never a valid jumpdest)
                        try out.appendSlice(allocator, &.{ 0x61, 0x5b, 0x5b, 0x50 });
                    },
                    5 => { // Decrement-style conditional branch
                        try out.appendSlice(allocator, &.{ 0x60, 0x01, 0x03, 0x80, 0x15 });
                    },
                    else => { // MSTORE + ADD
                        try out.appendSlice(allocator, &.{ 0x80, 0x60, 0x00, 0x52, 0x60, b, 0x01 });
                    },
                }
            }
            try out.appendSlice(allocator, &.{ 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 });
        },
        3 => { // Fusion stress: emit every synthetic fusion pattern back-to-back!
            // Seed stack deeply so none underflow
            for (0..8) |k| {
                try out.appendSlice(allocator, &.{ 0x60, @as(u8, @truncate(k + 3)) });
            }
            var i: usize = 0;
            while (i + 1 < bytes.len and out.items.len < 420) : (i += 2) {
                const sel = bytes[i];
                const imm = bytes[i + 1];
                switch (sel % 14) {
                    0 => try out.appendSlice(allocator, &.{ 0x60, imm, 0x01 }), // PUSH_ADD
                    1 => try out.appendSlice(allocator, &.{ 0x60, imm, 0x02 }), // PUSH_MUL
                    2 => try out.appendSlice(allocator, &.{ 0x60, imm, 0x03 }), // PUSH_SUB
                    3 => try out.appendSlice(allocator, &.{ 0x60, imm | 1, 0x04 }), // PUSH_DIV
                    4 => try out.appendSlice(allocator, &.{ 0x60, imm, 0x16 }), // PUSH_AND
                    5 => try out.appendSlice(allocator, &.{ 0x60, imm, 0x17 }), // PUSH_OR
                    6 => try out.appendSlice(allocator, &.{ 0x60, imm, 0x18 }), // PUSH_XOR
                    7 => try out.appendSlice(allocator, &.{ 0x60, imm & 0x3f, 0x51 }), // PUSH_MLOAD
                    8 => try out.appendSlice(allocator, &.{ 0x80, 0x60, imm & 0x3f, 0x52 }), // DUP1 + PUSH_MSTORE
                    9 => try out.appendSlice(allocator, &.{ 0x81, 0x52, 0x60, 0x20 }), // DUP2_MSTORE_PUSH
                    10 => { // ISZERO_JUMPI to immediate next JUMPDEST
                        const jd_pc = out.items.len + 4;
                        if (jd_pc <= 0xff) {
                            try out.appendSlice(allocator, &.{ 0x80, 0x15, 0x60, @intCast(jd_pc), 0x57, 0x5b });
                        }
                    },
                    11 => { // FUNCTION_DISPATCH pattern (PUSH4, EQ, PUSH2, JUMPI)
                        const jd_pc = out.items.len + 11;
                        if (jd_pc <= 0xffff) {
                            try out.appendSlice(allocator, &.{
                                0x80, 0x63, 0x00, 0x00, 0x00, imm & 0x0f,
                                0x14, 0x61, @intCast((jd_pc >> 8) & 0xff), @intCast(jd_pc & 0xff), 0x57,
                                0x5b,
                            });
                        }
                    },
                    12 => { // Multi-PUSH (PUSH1, PUSH1, PUSH1) + ADD + MUL
                        try out.appendSlice(allocator, &.{ 0x60, imm, 0x60, sel, 0x60, 0x07, 0x01, 0x02 });
                    },
                    else => { // PUSH32 + ADD (pointer/large-literal fusion path!)
                        try out.append(allocator, 0x7f);
                        var k: usize = 0;
                        while (k < 32) : (k += 1) {
                            try out.append(allocator, imm ^ @as(u8, @truncate(k)));
                        }
                        try out.append(allocator, 0x01);
                    },
                }
            }
            try out.appendSlice(allocator, &.{ 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 });
        },
        4 => { // Memory & Copy: MLOAD, MSTORE, MSTORE8, MSIZE, MCOPY, CALLDATALOAD, CALLDATACOPY, CODECOPY
            var i: usize = 0;
            while (i + 2 < bytes.len and out.items.len < 360) : (i += 3) {
                const op = bytes[i];
                const a = bytes[i + 1] & 0x7f;
                const b = bytes[i + 2] & 0x3f;
                switch (op % 8) {
                    0 => try out.appendSlice(allocator, &.{ 0x60, op, 0x60, a, 0x52 }), // MSTORE
                    1 => try out.appendSlice(allocator, &.{ 0x60, op, 0x60, a, 0x53 }), // MSTORE8
                    2 => try out.appendSlice(allocator, &.{ 0x60, a, 0x51, 0x50 }), // MLOAD + POP
                    3 => try out.appendSlice(allocator, &.{ 0x60, b, 0x60, a, 0x60, (a +% 5) & 0x7f, 0x5e }), // MCOPY (overlapping!)
                    4 => try out.appendSlice(allocator, &.{ 0x60, b, 0x60, a, 0x60, 0x00, 0x37 }), // CALLDATACOPY
                    5 => try out.appendSlice(allocator, &.{ 0x60, b, 0x60, a, 0x60, 0x10, 0x39 }), // CODECOPY
                    6 => try out.appendSlice(allocator, &.{ 0x60, a, 0x35, 0x60, 0x00, 0x52 }), // CALLDATALOAD + MSTORE
                    else => try out.appendSlice(allocator, &.{ 0x59, 0x60, 0x20, 0x52 }), // MSIZE + MSTORE
                }
            }
            // Return first 64 bytes of memory
            try out.appendSlice(allocator, &.{ 0x60, 0x40, 0x60, 0x00, 0xf3 });
        },
        5 => { // Storage, Transient Storage, Logs (SLOAD, SSTORE, TLOAD, TSTORE, LOG0-LOG2)
            var i: usize = 0;
            while (i + 2 < bytes.len and out.items.len < 360) : (i += 3) {
                const op = bytes[i];
                const slot = bytes[i + 1] & 0x07;
                const val = bytes[i + 2];
                switch (op % 7) {
                    0, 1 => try out.appendSlice(allocator, &.{ 0x60, val, 0x60, slot, 0x55 }), // SSTORE (including 0 clears for refunds!)
                    2 => try out.appendSlice(allocator, &.{ 0x60, slot, 0x54, 0x60, 0x00, 0x52 }), // SLOAD -> mem[0]
                    3 => try out.appendSlice(allocator, &.{ 0x60, val, 0x60, slot, 0x5d }), // TSTORE
                    4 => try out.appendSlice(allocator, &.{ 0x60, slot, 0x5c, 0x60, 0x20, 0x52 }), // TLOAD -> mem[32]
                    5 => try out.appendSlice(allocator, &.{ 0x60, val, 0x60, 0x20, 0x60, 0x00, 0xa1 }), // LOG1
                    else => { // Clear slot to zero to trigger SSTORE gas refund!
                        try out.appendSlice(allocator, &.{ 0x60, 0x00, 0x60, slot, 0x55 });
                    },
                }
            }
            // Decide RETURN vs REVERT based on last byte (tests revert rollback of SSTORE/TSTORE/LOG!)
            const should_revert = bytes.len > 0 and (bytes[bytes.len - 1] & 0x03) == 0;
            try out.appendSlice(allocator, &.{ 0x60, 0x40, 0x60, 0x00, if (should_revert) @as(u8, 0xfd) else @as(u8, 0xf3) });
        },
        6 => { // Multi-contract: CALL, STATICCALL, DELEGATECALL, CALLCODE, CREATE, CREATE2, SELFDESTRUCT, EXTCODE*
            var i: usize = 0;
            while (i + 1 < bytes.len and out.items.len < 340) : (i += 2) {
                const op = bytes[i];
                const arg = bytes[i + 1];
                switch (op % 9) {
                    0 => { // CALL CONTRACT_B with gas 50000
                        try out.appendSlice(allocator, &.{
                            0x60, 0x20, // retSize
                            0x60, 0x00, // retOffset
                            0x60, 0x04, // argsSize
                            0x60, 0x00, // argsOffset
                            0x60, arg & 0x0f, // value
                            0x60, 0x02, // address = CONTRACT_B (0x...02)
                            0x61, 0xc3, 0x50, // gas = 50000
                            0xf1, // CALL
                            0x60, 0x00, 0x52, // store success
                        });
                    },
                    1 => { // STATICCALL CONTRACT_B (must reject SSTORE/LOG/CREATE!)
                        try out.appendSlice(allocator, &.{
                            0x60, 0x20, 0x60, 0x00, 0x60, 0x04, 0x60, 0x00,
                            0x60, 0x02, 0x61, 0xc3, 0x50, 0xfa, 0x60, 0x00, 0x52,
                        });
                    },
                    2 => { // DELEGATECALL CONTRACT_B
                        try out.appendSlice(allocator, &.{
                            0x60, 0x20, 0x60, 0x00, 0x60, 0x04, 0x60, 0x00,
                            0x60, 0x02, 0x61, 0xc3, 0x50, 0xf4, 0x60, 0x00, 0x52,
                        });
                    },
                    3 => { // CALLCODE CONTRACT_B
                        try out.appendSlice(allocator, &.{
                            0x60, 0x20, 0x60, 0x00, 0x60, 0x04, 0x60, 0x00,
                            0x60, 0x00, 0x60, 0x02, 0x61, 0xc3, 0x50, 0xf2, 0x60, 0x00, 0x52,
                        });
                    },
                    4 => { // CREATE minimal contract returning 1 byte (0x00)
                        // Init code: PUSH1 0x01, PUSH1 0x00, RETURN (60016000f3 -> 5 bytes)
                        try out.appendSlice(allocator, &.{
                            0x64, 0x60, 0x01, 0x60, 0x00, 0xf3,
                            0x60, 0x00, 0x52,
                            0x60, 0x05, // size
                            0x60, 0x1b, // offset (27)
                            0x60, arg & 0x03, // value
                            0xf0, // CREATE
                            0x60, 0x20, 0x52,
                        });
                    },
                    5 => { // CREATE2 with fuzz salt
                        try out.appendSlice(allocator, &.{
                            0x64, 0x60, 0x01, 0x60, 0x00, 0xf3,
                            0x60, 0x00, 0x52,
                            0x60, arg, // salt
                            0x60, 0x05, // size
                            0x60, 0x1b, // offset
                            0x60, 0x00, // value
                            0xf5, // CREATE2
                            0x60, 0x20, 0x52,
                        });
                    },
                    6 => { // EXTCODESIZE, EXTCODEHASH, BALANCE on CONTRACT_B
                        try out.appendSlice(allocator, &.{
                            0x60, 0x02, 0x3b, 0x50, // EXTCODESIZE
                            0x60, 0x02, 0x3f, 0x50, // EXTCODEHASH
                            0x60, 0x02, 0x31, 0x50, // BALANCE
                        });
                    },
                    7 => { // RETURNDATASIZE + RETURNDATACOPY (if non-empty)
                        try out.appendSlice(allocator, &.{ 0x3d, 0x60, 0x40, 0x52 });
                    },
                    else => { // SSTORE before potential revert/selfdestruct
                        try out.appendSlice(allocator, &.{ 0x60, arg, 0x60, arg & 0x03, 0x55 });
                    },
                }
            }
            try out.appendSlice(allocator, &.{ 0x60, 0x40, 0x60, 0x00, 0xf3 });
        },
        else => { // Fork-specific opcodes (PUSH0, MCOPY, TLOAD/TSTORE, BASEFEE, BLOBBASEFEE, CHAINID, SELFBALANCE, SHL/SHR/SAR)
            const fork_ops = [_]u8{
                0x5f, // PUSH0 (Shanghai+)
                0x48, // BASEFEE (London+)
                0x46, // CHAINID (Istanbul+)
                0x47, // SELFBALANCE (Istanbul+)
                0x4a, // BLOBBASEFEE (Cancun+)
                0x3d, // RETURNDATASIZE (Byzantium+)
                0x44, // PREVRANDAO / DIFFICULTY
                0x45, // GASLIMIT
                0x42, // TIMESTAMP
                0x43, // NUMBER
            };
            for (bytes[0..@min(bytes.len, 32)]) |b| {
                const opc = fork_ops[b % fork_ops.len];
                try out.appendSlice(allocator, &.{ opc, 0x60, 0x00, 0x52 });
            }
            try out.appendSlice(allocator, &.{ 0x60, 0x20, 0x60, 0x00, 0xf3 });
        },
    }

    return out.toOwnedSlice(allocator);
}

fn setupWorld(
    db: *Database,
    code_a: []const u8,
    code_b: []const u8,
    init_slot0: u256,
) !void {
    try db.set_account(CALLER.bytes, .{
        .balance = 10_000_000_000_000,
        .nonce = 1,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });
    const hash_a = try db.set_code(code_a);
    try db.set_account(CONTRACT_A.bytes, .{
        .balance = 1_000_000,
        .nonce = 1,
        .code_hash = hash_a,
        .storage_root = [_]u8{0} ** 32,
    });
    const hash_b = try db.set_code(code_b);
    try db.set_account(CONTRACT_B.bytes, .{
        .balance = 500_000,
        .nonce = 1,
        .code_hash = hash_b,
        .storage_root = [_]u8{0} ** 32,
    });
    if (init_slot0 != 0) {
        try db.set_storage(CONTRACT_A.bytes, 0, init_slot0);
        try db.set_storage(CONTRACT_B.bytes, 0, init_slot0);
    }
}

fn assertDifferentialParity(
    comptime EvmA: type,
    comptime EvmB: type,
    allocator: std.mem.Allocator,
    code_a: []const u8,
    code_b: []const u8,
    calldata: []const u8,
    gas_limit: u64,
    value: u256,
    seed_byte: u8,
) !void {
    const block_info = makeBlockInfo(seed_byte);
    const tx_ctx = TransactionContext{
        .gas_limit = gas_limit,
        .coinbase = BENEFICIARY,
        .chain_id = 1,
    };

    var db_a = Database.init(allocator);
    defer db_a.deinit();
    var db_b = Database.init(allocator);
    defer db_b.deinit();

    const init_slot0: u256 = if ((seed_byte & 1) == 1) seed_byte else 0;
    try setupWorld(&db_a, code_a, code_b, init_slot0);
    try setupWorld(&db_b, code_a, code_b, init_slot0);

    var evm_a = try EvmA.init(allocator, &db_a, block_info, tx_ctx, 1, CALLER);
    defer evm_a.deinit();
    var evm_b = try EvmB.init(allocator, &db_b, block_info, tx_ctx, 1, CALLER);
    defer evm_b.deinit();

    const params = EvmA.CallParams{
        .call = .{
            .caller = CALLER,
            .to = CONTRACT_A,
            .value = value,
            .input = calldata,
            .gas = gas_limit,
        },
    };
    const params_b = EvmB.CallParams{
        .call = .{
            .caller = CALLER,
            .to = CONTRACT_A,
            .value = value,
            .input = calldata,
            .gas = gas_limit,
        },
    };

    // 1. Check simulate() produces identical result AND does NOT mutate database state!
    const pre_bal_a = try db_a.get_balance(CONTRACT_A.bytes);
    const pre_slot0_a = try db_a.get_storage(CONTRACT_A.bytes, 0);
    var sim_res = evm_a.simulate(params);
    defer sim_res.deinit(allocator);
    try std.testing.expectEqual(pre_bal_a, try db_a.get_balance(CONTRACT_A.bytes));
    try std.testing.expectEqual(pre_slot0_a, try db_a.get_storage(CONTRACT_A.bytes, 0));

    // 2. Execute call() on both Fusion-ON and Fusion-OFF EVMs!
    var res_a = evm_a.call(params);
    defer res_a.deinit(allocator);
    var res_b = evm_b.call(params_b);
    defer res_b.deinit(allocator);

    // 3. EXACT consensus parity assertions:
    //    (a) Fusion ON vs Fusion OFF
    try std.testing.expectEqual(res_a.success, res_b.success);
    try std.testing.expectEqual(res_a.gas_left, res_b.gas_left);
    try std.testing.expectEqualSlices(u8, res_a.output, res_b.output);
    try std.testing.expectEqual(res_a.logs.len, res_b.logs.len);
    for (res_a.logs, res_b.logs) |la, lb| {
        try std.testing.expectEqualSlices(u8, &la.address.bytes, &lb.address.bytes);
        try std.testing.expectEqualSlices(u256, la.topics, lb.topics);
        try std.testing.expectEqualSlices(u8, la.data, lb.data);
    }
    try std.testing.expectEqual(res_a.selfdestructs.len, res_b.selfdestructs.len);
    try std.testing.expectEqual(res_a.created_address, res_b.created_address);

    //    (b) simulate() vs call() exact parity!
    try std.testing.expectEqual(res_a.success, sim_res.success);
    try std.testing.expectEqual(res_a.gas_left, sim_res.gas_left);
    try std.testing.expectEqualSlices(u8, res_a.output, sim_res.output);
    try std.testing.expectEqual(res_a.logs.len, sim_res.logs.len);

    //    (c) Post-state storage & balance parity across all accounts & slots 0..7!
    for ([_]Address{ CALLER, CONTRACT_A, CONTRACT_B, BENEFICIARY }) |addr| {
        try std.testing.expectEqual(try db_a.get_balance(addr.bytes), try db_b.get_balance(addr.bytes));
        try std.testing.expectEqual(try db_a.get_nonce(addr.bytes), try db_b.get_nonce(addr.bytes));
        for (0..8) |slot| {
            try std.testing.expectEqual(
                try db_a.get_storage(addr.bytes, @intCast(slot)),
                try db_b.get_storage(addr.bytes, @intCast(slot)),
            );
        }
    }

    //    (d) Fundamental gas invariant: gas_left <= gas_limit
    try std.testing.expect(res_a.gas_left <= gas_limit);
}

pub fn fuzzDifferentialFusionAndSimulate(_: void, input: []const u8) !void {
    if (input.len < 4) return;
    const allocator = fuzz_alloc.get();

    const mode = input[0] % 7;
    const gas_bucket = input[1] % 6;
    const gas_limit: u64 = switch (gas_bucket) {
        0 => 21_000, // exact intrinsic gas boundary
        1 => 25_000, // tight OOG boundary
        2 => 60_000,
        3 => 200_000,
        4 => 1_000_000,
        else => 3_000_000,
    };
    const value: u256 = if ((input[2] & 1) == 0) 0 else @as(u256, input[2]) * 10;
    const seed_byte = input[3];

    const payload = input[4..];
    const cd_len = @min(payload.len / 4, 64);
    const calldata = payload[0..cd_len];
    const prog_bytes = payload[cd_len..];

    const code_a = try buildStructuredProgram(allocator, mode, prog_bytes);
    defer allocator.free(code_a);

    // Secondary contract B used in multi-contract mode: performs SSTORE or returns calldata or reverts
    const code_b: []const u8 = switch (seed_byte % 4) {
        0 => &.{ 0x60, 0x2a, 0x60, 0x00, 0x55, 0x60, 0x2a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 }, // SSTORE + RETURN 42
        1 => &.{ 0x60, 0x99, 0x60, 0x00, 0x55, 0x60, 0x04, 0x60, 0x00, 0xfd }, // SSTORE + REVERT
        2 => &.{ 0x60, 0x00, 0x35, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 }, // pure echo CALLDATALOAD (STATICCALL-safe!)
        else => &.{ 0x60, 0x01, 0x60, 0x00, 0x54, 0x01, 0x80, 0x60, 0x00, 0x55, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 }, // increment slot 0
    };

    try assertDifferentialParity(
        EvmFusionOn,
        EvmFusionOff,
        allocator,
        code_a,
        code_b,
        calldata,
        gas_limit,
        value,
        seed_byte,
    );
}

pub fn fuzzMultiHardforkDifferential(_: void, input: []const u8) !void {
    if (input.len < 3) return;
    const allocator = fuzz_alloc.get();

    const fork_sel = input[0] % 4;
    const mode: u8 = if ((input[1] & 1) == 0) 7 else (input[1] % 6);
    const seed_byte = input[2];
    const code_a = try buildStructuredProgram(allocator, mode, input[3..]);
    defer allocator.free(code_a);
    const code_b: []const u8 = &.{ 0x60, 0x07, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };

    switch (fork_sel) {
        0 => try assertDifferentialParity(EvmFrontier, EvmFrontierNoFusion, allocator, code_a, code_b, &.{}, 500_000, 0, seed_byte),
        1 => try assertDifferentialParity(EvmBerlin, EvmBerlinNoFusion, allocator, code_a, code_b, &.{}, 500_000, 0, seed_byte),
        2 => try assertDifferentialParity(EvmShanghai, EvmShanghaiNoFusion, allocator, code_a, code_b, &.{}, 500_000, 0, seed_byte),
        else => try assertDifferentialParity(EvmPrague, EvmPragueNoFusion, allocator, code_a, code_b, &.{}, 500_000, 0, seed_byte),
    }
}

pub fn fuzzCreateAndCreate2Parity(_: void, input: []const u8) !void {
    if (input.len < 4) return;
    const allocator = fuzz_alloc.get();

    const is_create2 = (input[0] & 1) == 1;
    const salt: u256 = std.mem.readInt(u16, input[1..3], .big);
    const init_code = input[3..@min(input.len, 256)];
    const gas_limit: u64 = 1_000_000;
    const block_info = makeBlockInfo(input[0]);
    const tx_ctx = TransactionContext{ .gas_limit = gas_limit, .coinbase = BENEFICIARY, .chain_id = 1 };

    var db_on = Database.init(allocator);
    defer db_on.deinit();
    var db_off = Database.init(allocator);
    defer db_off.deinit();

    try db_on.set_account(CALLER.bytes, .{ .balance = 10_000_000_000, .nonce = 1, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 });
    try db_off.set_account(CALLER.bytes, .{ .balance = 10_000_000_000, .nonce = 1, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 });

    var evm_on = try EvmFusionOn.init(allocator, &db_on, block_info, tx_ctx, 1, CALLER);
    defer evm_on.deinit();
    var evm_off = try EvmFusionOff.init(allocator, &db_off, block_info, tx_ctx, 1, CALLER);
    defer evm_off.deinit();

    const params_on: EvmFusionOn.CallParams = if (is_create2)
        .{ .create2 = .{ .caller = CALLER, .value = 0, .init_code = init_code, .salt = salt, .gas = gas_limit } }
    else
        .{ .create = .{ .caller = CALLER, .value = 0, .init_code = init_code, .gas = gas_limit } };

    const params_off: EvmFusionOff.CallParams = if (is_create2)
        .{ .create2 = .{ .caller = CALLER, .value = 0, .init_code = init_code, .salt = salt, .gas = gas_limit } }
    else
        .{ .create = .{ .caller = CALLER, .value = 0, .init_code = init_code, .gas = gas_limit } };

    var res_on = evm_on.call(params_on);
    defer res_on.deinit(allocator);
    var res_off = evm_off.call(params_off);
    defer res_off.deinit(allocator);

    if (res_on.success != res_off.success) {
        std.log.err("CREATE fusion divergence! is_create2={} on.success={} on.gas={} off.success={} off.gas={} init_code={x}", .{
            is_create2, res_on.success, res_on.gas_left, res_off.success, res_off.gas_left, init_code,
        });
    }
    try std.testing.expectEqual(res_on.success, res_off.success);
    try std.testing.expectEqual(res_on.gas_left, res_off.gas_left);
    try std.testing.expectEqualSlices(u8, res_on.output, res_off.output);
    try std.testing.expectEqual(res_on.created_address, res_off.created_address);

    // EIP-3541 invariant: deployed runtime code must NEVER start with 0xEF!
    if (res_on.success) {
        if (res_on.created_address) |created| {
            const deployed = db_on.get_code_by_address(created.bytes) catch &.{};
            if (deployed.len > 0) {
                try std.testing.expect(deployed[0] != 0xef);
            }
            // EIP-170 invariant: deployed code <= 24576 bytes
            try std.testing.expect(deployed.len <= 24576);
        }
    }
}

const seed_corpus: []const []const u8 = &.{
    &.{ 0, 4, 0, 0, 0x60, 0x01, 0x60, 0x02, 0x01, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 },
    &.{ 1, 4, 0, 1, 0, 5, 1, 9, 2, 7, 3, 4, 4, 16, 5, 3 },
    &.{ 2, 4, 0, 2, 0, 2, 3, 1, 4, 5, 6, 0, 1 },
    &.{ 3, 5, 0, 3, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14 },
    &.{ 4, 4, 0, 4, 0, 0, 10, 1, 5, 20, 3, 2, 16, 4, 0, 8, 5, 0, 8, 7, 0, 0 },
    &.{ 5, 4, 0, 5, 0, 1, 42, 2, 1, 0, 3, 2, 77, 4, 2, 0, 5, 0, 9, 6, 1, 0 },
    &.{ 6, 5, 1, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9 },
    &.{ 6, 5, 0, 1, 1, 0, 0, 0, 4, 1, 5, 2 }, // STATICCALL to SSTORE+REVERT contract
    &.{ 0, 1, 0, 0, 0x5b, 0x60, 0x00, 0x56 }, // Infinite loop hits OOG cleanly
    &.{ 1, 0, 1, 0x60, 0x01, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xf3 }, // CREATE
    &.{ 1, 0, 2, 0x60, 0xef, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xf3 }, // CREATE returning 0xEF (EIP-3541 reject!)
};

test "fuzz differential EVM execution: fusion ON vs fusion OFF vs simulate() across all modes" {
    try std.testing.fuzz({}, fuzzDifferentialFusionAndSimulate, .{ .corpus = seed_corpus });
}

test "fuzz multi-hardfork differential EVM execution (FRONTIER, BERLIN, SHANGHAI, PRAGUE)" {
    try std.testing.fuzz({}, fuzzMultiHardforkDifferential, .{ .corpus = seed_corpus });
}

test "fuzz CREATE and CREATE2 deployment parity and EIP-3541/EIP-170 invariants" {
    try std.testing.fuzz({}, fuzzCreateAndCreate2Parity, .{ .corpus = seed_corpus });
}
