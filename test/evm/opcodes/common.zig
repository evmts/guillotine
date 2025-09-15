const std = @import("std");
const ArrayList = std.ArrayList;

pub fn build_bytecode(allocator: std.mem.Allocator, opcode: u8) ![]u8 {
    var buf = ArrayList(u8){};
    defer buf.deinit(allocator);

    // Helper functions as a struct namespace
    const helpers = struct {
        inline fn push_bytes(alloc: std.mem.Allocator, b: *std.ArrayList(u8), data: []const u8) !void {
            if (data.len == 0) {
                try b.append(alloc, 0x5f); // PUSH0
                return;
            }
            if (data.len > 32) return error.InvalidPushLength;
            const op: u8 = 0x60 + @as(u8, @intCast(data.len - 1));
            try b.append(alloc, op);
            try b.appendSlice(alloc, data);
        }

        inline fn push_u8(alloc: std.mem.Allocator, b: *std.ArrayList(u8), v: u8) !void {
            if (v == 0) {
                try b.append(alloc, 0x5f); // PUSH0
            } else {
                try b.append(alloc, 0x60); // PUSH1
                try b.append(alloc, v);
            }
        }

        inline fn push_u16(alloc: std.mem.Allocator, b: *std.ArrayList(u8), v: u16) !void {
            if (v <= 0xff) {
                try push_u8(alloc, b, @intCast(v));
            } else {
                try b.append(alloc, 0x61); // PUSH2
                try b.append(alloc, @intCast((v >> 8) & 0xff));
                try b.append(alloc, @intCast(v & 0xff));
            }
        }

        inline fn push_u256(alloc: std.mem.Allocator, b: *std.ArrayList(u8), v: u256) !void {
            if (v == 0) return push_u8(alloc, b, 0);
            var tmp: [32]u8 = [_]u8{0} ** 32;
            std.mem.writeInt(u256, &tmp, v, .big);
            const first_non_zero = std.mem.indexOfNonePos(u8, &tmp, 0, &[_]u8{0}) orelse 32;
            const slice = tmp[first_non_zero..];
            try push_bytes(alloc, b, slice);
        }

        inline fn ret_top32(alloc: std.mem.Allocator, b: *std.ArrayList(u8)) !void {
            // Store top of stack to memory[0] and return it
            try b.append(alloc, 0x60); // PUSH1
            try b.append(alloc, 0x00); // 0 (memory offset)
            try b.append(alloc, 0x52); // MSTORE - stores top of stack at memory[0]
            try b.append(alloc, 0x60); // PUSH1
            try b.append(alloc, 0x20); // 32 (length)
            try b.append(alloc, 0x60); // PUSH1
            try b.append(alloc, 0x00); // 0 (offset)
            try b.append(alloc, 0xf3); // RETURN
        }

        inline fn ret_const(alloc: std.mem.Allocator, b: *std.ArrayList(u8), v: u256) !void {
            try push_u256(alloc, b, v);
            try b.append(alloc, 0x00); // STOP
        }

        inline fn discard_top_and_return_const(alloc: std.mem.Allocator, b: *std.ArrayList(u8), v: u256) !void {
            try b.append(alloc, 0x50); // POP
            try push_u256(alloc, b, v);
            try b.append(alloc, 0x00); // STOP
        }
    };

    // Build by category
    switch (opcode) {
        // 0x00 STOP
        0x00 => {
            try buf.append(allocator, 0x00);
            // No return; STOP exits successfully with empty output
        },

        // Arithmetic 0x01..0x0b
        0x01 => { // ADD: 2 + 3 = 5
            try helpers.push_u8(allocator, &buf, 0x02); // push a=2
            try helpers.push_u8(allocator, &buf, 0x03); // push b=3 (top)
            try buf.append(allocator, 0x01); // ADD: a + b = 5
            try helpers.ret_top32(allocator, &buf);
        },
        0x02 => { // MUL: 5 * 2 = 10
            try helpers.push_u8(allocator, &buf, 0x05); // push a=5
            try helpers.push_u8(allocator, &buf, 0x02); // push b=2 (top)
            try buf.append(allocator, 0x02); // MUL: a * b = 10
            try helpers.ret_top32(allocator, &buf);
        },
        0x03 => { // SUB: 10 - 3 = 7
            try helpers.push_u8(allocator, &buf, 0x0a); // push a=10 (bottom)
            try helpers.push_u8(allocator, &buf, 0x03); // push b=3 (top)
            try buf.append(allocator, 0x03); // SUB: a - b = 7
            try helpers.ret_top32(allocator, &buf);
        },
        0x04 => { // DIV: 20 / 4 = 5
            try helpers.push_u8(allocator, &buf, 0x14); // push a=20
            try helpers.push_u8(allocator, &buf, 0x04); // push b=4 (top)
            try buf.append(allocator, 0x04); // DIV: a / b = 5
            try helpers.ret_top32(allocator, &buf);
        },
        0x05 => { // SDIV: -10 / 3 = -3
            var minus10: [32]u8 = [_]u8{0xff} ** 32;
            minus10[31] = 0xf6; // two's complement -10
            try helpers.push_bytes(allocator, &buf, &minus10); // push a=-10
            try helpers.push_u8(allocator, &buf, 0x03); // push b=3 (top)
            try buf.append(allocator, 0x05); // SDIV: a / b = -3
            try helpers.ret_top32(allocator, &buf);
        },
        0x06 => { // MOD: 17 % 5 = 2
            try helpers.push_u8(allocator, &buf, 0x11); // push a=17
            try helpers.push_u8(allocator, &buf, 0x05); // push b=5 (top)
            try buf.append(allocator, 0x06); // MOD: a % b = 2
            try helpers.ret_top32(allocator, &buf);
        },
        0x07 => { // SMOD: -10 % 3 = -1
            var minus10b: [32]u8 = [_]u8{0xff} ** 32;
            minus10b[31] = 0xf6; // -10
            try helpers.push_bytes(allocator, &buf, &minus10b); // push a=-10
            try helpers.push_u8(allocator, &buf, 0x03); // push b=3 (top)
            try buf.append(allocator, 0x07); // SMOD: a % b = -1
            try helpers.ret_top32(allocator, &buf);
        },
        0x08 => { // ADDMOD: (10 + 6) % 5 = 1
            try helpers.push_u8(allocator, &buf, 0x0a); // push a=10
            try helpers.push_u8(allocator, &buf, 0x06); // push b=6
            try helpers.push_u8(allocator, &buf, 0x05); // push N=5 (modulus)
            try buf.append(allocator, 0x08); // ADDMOD: (a + b) % N = 1
            try helpers.ret_top32(allocator, &buf);
        },
        0x09 => { // MULMOD: (7 * 4) % 5 = 3
            try helpers.push_u8(allocator, &buf, 0x07); // push a=7
            try helpers.push_u8(allocator, &buf, 0x04); // push b=4
            try helpers.push_u8(allocator, &buf, 0x05); // push N=5 (modulus)
            try buf.append(allocator, 0x09); // MULMOD: (a * b) % N = 3
            try helpers.ret_top32(allocator, &buf);
        },
        0x0a => { // EXP: 2^3 = 8
            try helpers.push_u8(allocator, &buf, 0x02); // push base=2
            try helpers.push_u8(allocator, &buf, 0x03); // push exp=3 (top)
            try buf.append(allocator, 0x0a); // EXP: base^exp = 8
            try helpers.ret_top32(allocator, &buf);
        },
        0x0b => { // SIGNEXTEND: extend byte 0 of 0xff
            try helpers.push_u8(allocator, &buf, 0xff); // push value=0xff
            try helpers.push_u8(allocator, &buf, 0x00); // push byte_num=0 (top)
            try buf.append(allocator, 0x0b); // SIGNEXTEND
            try helpers.ret_top32(allocator, &buf);
        },

        // Comparisons and bitwise 0x10..0x1d
        0x10 => { // LT
            try helpers.push_u8(allocator, &buf, 0x04);
            try helpers.push_u8(allocator, &buf, 0x03);
            try buf.append(allocator, 0x10);
            try helpers.ret_top32(allocator, &buf);
        },
        0x11 => { // GT
            try helpers.push_u8(allocator, &buf, 0x04);
            try helpers.push_u8(allocator, &buf, 0x05);
            try buf.append(allocator, 0x11);
            try helpers.ret_top32(allocator, &buf);
        },
        0x12 => { // SLT
            try helpers.push_u8(allocator, &buf, 0x01);
            var neg2: [32]u8 = [_]u8{0xff} ** 32;
            neg2[31] = 0xfe; // -2
            try helpers.push_bytes(allocator, &buf, &neg2);
            try buf.append(allocator, 0x12);
            try helpers.ret_top32(allocator, &buf);
        },
        0x13 => { // SGT
            var neg2b: [32]u8 = [_]u8{0xff} ** 32;
            neg2b[31] = 0xfe; // -2
            try helpers.push_bytes(allocator, &buf, &neg2b);
            try helpers.push_u8(allocator, &buf, 0x01);
            try buf.append(allocator, 0x13);
            try helpers.ret_top32(allocator, &buf);
        },
        0x14 => { // EQ
            try helpers.push_u8(allocator, &buf, 0x2a);
            try helpers.push_u8(allocator, &buf, 0x2a);
            try buf.append(allocator, 0x14);
            try helpers.ret_top32(allocator, &buf);
        },
        0x15 => { // ISZERO
            try helpers.push_u8(allocator, &buf, 0x00);
            try buf.append(allocator, 0x15);
            try helpers.ret_top32(allocator, &buf);
        },
        0x16 => { // AND
            try helpers.push_u8(allocator, &buf, 0x3c); // 0b00111100
            try helpers.push_u8(allocator, &buf, 0xa5); // 0b10100101 (top)
            try buf.append(allocator, 0x16); // AND: 0x3c & 0xa5 = 0x24
            try helpers.ret_top32(allocator, &buf);
        },
        0x17 => { // OR
            try helpers.push_u8(allocator, &buf, 0x12); // 0b00010010
            try helpers.push_u8(allocator, &buf, 0x45); // 0b01000101 (top)
            try buf.append(allocator, 0x17); // OR: 0x12 | 0x45 = 0x57
            try helpers.ret_top32(allocator, &buf);
        },
        0x18 => { // XOR
            try helpers.push_u8(allocator, &buf, 0x69); // 0b01101001
            try helpers.push_u8(allocator, &buf, 0x3a); // 0b00111010 (top)
            try buf.append(allocator, 0x18); // XOR: 0x69 ^ 0x3a = 0x53
            try helpers.ret_top32(allocator, &buf);
        },
        0x19 => { // NOT
            try helpers.push_u8(allocator, &buf, 0x00);
            try buf.append(allocator, 0x19);
            try helpers.ret_top32(allocator, &buf);
        },
        0x1a => { // BYTE
            try helpers.push_u8(allocator, &buf, 0xaa);
            try helpers.push_u8(allocator, &buf, 0x1f); // index 31
            try buf.append(allocator, 0x1a);
            try helpers.ret_top32(allocator, &buf);
        },
        0x1b => { // SHL
            try helpers.push_u8(allocator, &buf, 0x03); // value to shift (different from shift amount)
            try helpers.push_u8(allocator, &buf, 0x02); // shift amount (top of stack)
            try buf.append(allocator, 0x1b); // SHL: value << shift = 3 << 2 = 12
            try helpers.ret_top32(allocator, &buf);
        },
        0x1c => { // SHR
            try helpers.push_u8(allocator, &buf, 0x08); // value to shift (different from shift amount)
            try helpers.push_u8(allocator, &buf, 0x02); // shift amount (top of stack)
            try buf.append(allocator, 0x1c); // SHR: value >> shift = 8 >> 2 = 2
            try helpers.ret_top32(allocator, &buf);
        },
        0x1d => { // SAR
            var neg16: [32]u8 = [_]u8{0xff} ** 32;
            neg16[31] = 0xf0; // -16
            try helpers.push_bytes(allocator, &buf, &neg16); // value to shift
            try helpers.push_u8(allocator, &buf, 0x03); // shift amount (top)
            try buf.append(allocator, 0x1d); // SAR: -16 >> 3 = -2
            try helpers.ret_top32(allocator, &buf);
        },

        // SHA3 0x20
        0x20 => { // SHA3/KECCAK256
            // Store some data, then hash it
            try helpers.push_u256(allocator, &buf, 0xdeadbeef);
            try helpers.push_u8(allocator, &buf, 0x00);
            try buf.append(allocator, 0x52); // MSTORE
            try helpers.push_u8(allocator, &buf, 0x20); // length
            try helpers.push_u8(allocator, &buf, 0x00); // offset
            try buf.append(allocator, 0x20); // SHA3
            try helpers.ret_top32(allocator, &buf);
        },

        // Context ops 0x30..0x3f
        0x30 => { // ADDRESS
            try buf.append(allocator, 0x30);
            try helpers.ret_top32(allocator, &buf);
        },
        0x31 => { // BALANCE
            try buf.append(allocator, 0x30); // Get address first
            try buf.append(allocator, 0x31); // Then balance
            try helpers.ret_top32(allocator, &buf);
        },
        0x32 => { // ORIGIN
            try buf.append(allocator, 0x32);
            try helpers.ret_top32(allocator, &buf);
        },
        0x33 => { // CALLER
            try buf.append(allocator, 0x33);
            try helpers.ret_top32(allocator, &buf);
        },
        0x34 => { // CALLVALUE
            try buf.append(allocator, 0x34);
            try helpers.ret_top32(allocator, &buf);
        },
        0x35 => { // CALLDATALOAD
            try helpers.push_u8(allocator, &buf, 0x00);
            try buf.append(allocator, 0x35);
            try helpers.ret_top32(allocator, &buf);
        },
        0x36 => { // CALLDATASIZE
            try buf.append(allocator, 0x36);
            try helpers.ret_top32(allocator, &buf);
        },
        0x37 => { // CALLDATACOPY
            try helpers.push_u8(allocator, &buf, 0x04); // length
            try helpers.push_u8(allocator, &buf, 0x00); // offset
            try helpers.push_u8(allocator, &buf, 0x00); // destOffset
            try buf.append(allocator, 0x37);
            // Just stop - no return data
            try buf.append(allocator, 0x00); // STOP
        },
        0x38 => { // CODESIZE
            try buf.append(allocator, 0x38);
            try helpers.ret_top32(allocator, &buf);
        },
        0x39 => { // CODECOPY
            // Copy first 4 bytes of code to memory at offset 0
            try helpers.push_u8(allocator, &buf, 0x04); // length = 4
            try helpers.push_u8(allocator, &buf, 0x00); // offset = 0
            try helpers.push_u8(allocator, &buf, 0x00); // destOffset = 0
            try buf.append(allocator, 0x39); // CODECOPY
            
            // Return the copied data from memory
            try helpers.push_u8(allocator, &buf, 0x20); // size = 32 bytes
            try helpers.push_u8(allocator, &buf, 0x00); // offset = 0
            try buf.append(allocator, 0xf3); // RETURN
        },
        0x3a => { // GASPRICE
            try buf.append(allocator, 0x3a);
            try helpers.ret_top32(allocator, &buf);
        },
        0x3b => { // EXTCODESIZE
            try buf.append(allocator, 0x30); // ADDRESS
            try buf.append(allocator, 0x3b);
            try helpers.ret_top32(allocator, &buf);
        },
        0x3c => { // EXTCODECOPY
            try helpers.push_u8(allocator, &buf, 0x04); // length
            try helpers.push_u8(allocator, &buf, 0x00); // offset
            try helpers.push_u8(allocator, &buf, 0x00); // destOffset
            try buf.append(allocator, 0x30); // ADDRESS
            try buf.append(allocator, 0x3c);
            // Just stop - no return data
            try buf.append(allocator, 0x00); // STOP
        },
        0x3d => { // RETURNDATASIZE
            // RETURNDATASIZE should return 0 when there's no previous call
            try buf.append(allocator, 0x3d);
            // Just stop - no return data
            try buf.append(allocator, 0x00); // STOP
        },
        0x3e => { // RETURNDATACOPY  
            // RETURNDATACOPY requires return data from a previous call
            // Since there's no return data initially, trying to copy anything should fail
            // Let's test by trying to copy 1 byte, which should cause OutOfBounds error
            try helpers.push_u8(allocator, &buf, 0x01); // length = 1 byte
            try helpers.push_u8(allocator, &buf, 0x00); // offset in return data = 0  
            try helpers.push_u8(allocator, &buf, 0x00); // destOffset in memory = 0
            try buf.append(allocator, 0x3e); // RETURNDATACOPY
            
            // If we get here somehow, return 0 (should not reach this)
            try helpers.ret_const(allocator, &buf, 0);
        },
        0x3f => { // EXTCODEHASH
            try buf.append(allocator, 0x30); // ADDRESS
            try buf.append(allocator, 0x3f);
            try helpers.ret_top32(allocator, &buf);
        },

        // Block context 0x40..0x48
        0x40 => { // BLOCKHASH
            try helpers.push_u8(allocator, &buf, 0x01);
            try buf.append(allocator, 0x40);
            try helpers.ret_top32(allocator, &buf);
        },
        0x41 => { // COINBASE
            try buf.append(allocator, 0x41);
            try helpers.ret_top32(allocator, &buf);
        },
        0x42 => { // TIMESTAMP
            try buf.append(allocator, 0x42);
            try helpers.ret_top32(allocator, &buf);
        },
        0x43 => { // NUMBER
            try buf.append(allocator, 0x43);
            try helpers.ret_top32(allocator, &buf);
        },
        0x44 => { // DIFFICULTY/PREVRANDAO
            try buf.append(allocator, 0x44);
            try helpers.ret_top32(allocator, &buf);
        },
        0x45 => { // GASLIMIT
            try buf.append(allocator, 0x45);
            try helpers.ret_top32(allocator, &buf);
        },
        0x46 => { // CHAINID
            try buf.append(allocator, 0x46);
            try helpers.ret_top32(allocator, &buf);
        },
        0x47 => { // SELFBALANCE
            try buf.append(allocator, 0x47);
            try helpers.ret_top32(allocator, &buf);
        },
        0x48 => { // BASEFEE
            try buf.append(allocator, 0x48);
            try helpers.ret_top32(allocator, &buf);
        },
        0x49 => { // BLOBHASH
            try helpers.push_u8(allocator, &buf, 0x00);
            try buf.append(allocator, 0x49);
            try helpers.ret_top32(allocator, &buf);
        },
        0x4a => { // BLOBBASEFEE
            try buf.append(allocator, 0x4a);
            try helpers.ret_top32(allocator, &buf);
        },

        // Stack ops 0x50..0x5f
        0x50 => { // POP
            try helpers.push_u8(allocator, &buf, 0x42);
            try buf.append(allocator, 0x50);
            try helpers.ret_const(allocator, &buf, 1);
        },
        0x51 => { // MLOAD
            try helpers.push_u8(allocator, &buf, 0x00);
            try buf.append(allocator, 0x51);
            try helpers.ret_top32(allocator, &buf);
        },
        0x52 => { // MSTORE
            try helpers.push_u256(allocator, &buf, 0xdeadbeef);
            try helpers.push_u8(allocator, &buf, 0x00);
            try buf.append(allocator, 0x52);
            try helpers.push_u8(allocator, &buf, 0x00);
            try buf.append(allocator, 0x51); // MLOAD
            try helpers.ret_top32(allocator, &buf);
        },
        0x53 => { // MSTORE8
            try helpers.push_u8(allocator, &buf, 0xab);
            try helpers.push_u8(allocator, &buf, 0x1f);
            try buf.append(allocator, 0x53);
            try helpers.push_u8(allocator, &buf, 0x00);
            try buf.append(allocator, 0x51); // MLOAD
            try helpers.ret_top32(allocator, &buf);
        },
        0x54 => { // SLOAD
            try helpers.push_u8(allocator, &buf, 0x00);
            try buf.append(allocator, 0x54);
            try helpers.ret_top32(allocator, &buf);
        },
        0x55 => { // SSTORE
            try helpers.push_u256(allocator, &buf, 0xcafe);
            try helpers.push_u8(allocator, &buf, 0x00);
            try buf.append(allocator, 0x55);
            try helpers.push_u8(allocator, &buf, 0x00);
            try buf.append(allocator, 0x54); // SLOAD to verify
            try helpers.ret_top32(allocator, &buf);
        },
        0x56 => { // JUMP
            // Create a simple jump target
            try helpers.push_u8(allocator, &buf, 0x05); // Jump to position 5 (where JUMPDEST actually is)
            try buf.append(allocator, 0x56); // JUMP
            try buf.append(allocator, 0x00); // Should be skipped
            try buf.append(allocator, 0x00); // Should be skipped
            try buf.append(allocator, 0x5b); // JUMPDEST at position 5
            try helpers.ret_const(allocator, &buf, 1);
        },
        0x57 => { // JUMPI
            // Test both branches: condition true AND false
            // First: condition false (no jump)
            try helpers.push_u8(allocator, &buf, 0x00); // Condition false
            try helpers.push_u8(allocator, &buf, 0xFF); // Invalid destination (doesn't matter)
            try buf.append(allocator, 0x57); // JUMPI - should NOT jump
            
            // Then: condition true (jump)
            try helpers.push_u8(allocator, &buf, 0x01); // Condition true
            try helpers.push_u8(allocator, &buf, 0x0C); // Jump to position 12 (JUMPDEST)
            try buf.append(allocator, 0x57); // JUMPI - should jump
            try buf.append(allocator, 0x00); // Should be skipped
            try buf.append(allocator, 0x00); // Should be skipped
            try buf.append(allocator, 0x5b); // JUMPDEST at position 12
            try helpers.ret_const(allocator, &buf, 1);
        },
        0x58 => { // PC
            try buf.append(allocator, 0x58);
            try helpers.ret_top32(allocator, &buf);
        },
        0x59 => { // MSIZE
            try buf.append(allocator, 0x59);
            try helpers.ret_top32(allocator, &buf);
        },
        0x5a => { // GAS
            try buf.append(allocator, 0x5a);
            try helpers.ret_top32(allocator, &buf);
        },
        0x5b => { // JUMPDEST
            try buf.append(allocator, 0x5b);
            try helpers.ret_const(allocator, &buf, 1);
        },
        0x5c => { // TLOAD
            try helpers.push_u8(allocator, &buf, 0x00);
            try buf.append(allocator, 0x5c);
            try helpers.ret_top32(allocator, &buf);
        },
        0x5d => { // TSTORE
            try helpers.push_u256(allocator, &buf, 0xbeef);
            try helpers.push_u8(allocator, &buf, 0x00);
            try buf.append(allocator, 0x5d);
            try helpers.push_u8(allocator, &buf, 0x00);
            try buf.append(allocator, 0x5c); // TLOAD to verify
            try helpers.ret_top32(allocator, &buf);
        },
        0x5e => { // MCOPY
            // Store some data first
            try helpers.push_u256(allocator, &buf, 0xdeadbeef);
            try helpers.push_u8(allocator, &buf, 0x00);
            try buf.append(allocator, 0x52); // MSTORE
            // Copy 32 bytes from 0 to 32
            try helpers.push_u8(allocator, &buf, 0x20); // length
            try helpers.push_u8(allocator, &buf, 0x00); // src
            try helpers.push_u8(allocator, &buf, 0x20); // dest
            try buf.append(allocator, 0x5e); // MCOPY
            // Load from destination
            try helpers.push_u8(allocator, &buf, 0x20);
            try buf.append(allocator, 0x51); // MLOAD
            try helpers.ret_top32(allocator, &buf);
        },
        0x5f => { // PUSH0
            try buf.append(allocator, 0x5f);
            try helpers.ret_top32(allocator, &buf);
        },

        // PUSH operations 0x60..0x7f
        0x60...0x7f => |push_op| {
            const n = push_op - 0x5f;
            try buf.append(allocator, push_op);
            // Push n bytes of data
            var i: u8 = 0;
            while (i < n) : (i += 1) {
                try buf.append(allocator, 0xaa + i);
            }
            try helpers.ret_top32(allocator, &buf);
        },

        // DUP operations 0x80..0x8f
        0x80...0x8f => |dup_op| {
            const n = dup_op - 0x7f;
            // Push n different values
            var i: u8 = 1;
            while (i <= n) : (i += 1) {
                try helpers.push_u8(allocator, &buf, i);
            }
            try buf.append(allocator, dup_op);
            try helpers.ret_top32(allocator, &buf);
        },

        // SWAP operations 0x90..0x9f
        0x90...0x9f => |swap_op| {
            const n = swap_op - 0x8f;
            // Push n+1 different values
            var i: u8 = 0;
            while (i <= n) : (i += 1) {
                try helpers.push_u8(allocator, &buf, i);
            }
            try buf.append(allocator, swap_op);
            try helpers.ret_top32(allocator, &buf);
        },

        // LOG operations 0xa0..0xa4
        0xa0 => { // LOG0
            try helpers.push_u256(allocator, &buf, 0xdeadbeef);
            try helpers.push_u8(allocator, &buf, 0x00);
            try buf.append(allocator, 0x52); // MSTORE
            try helpers.push_u8(allocator, &buf, 0x20); // length
            try helpers.push_u8(allocator, &buf, 0x00); // offset
            try buf.append(allocator, 0xa0);
            try helpers.ret_const(allocator, &buf, 1);
        },
        0xa1 => { // LOG1
            try helpers.push_u256(allocator, &buf, 0xdeadbeef);
            try helpers.push_u8(allocator, &buf, 0x00);
            try buf.append(allocator, 0x52); // MSTORE
            try helpers.push_u256(allocator, &buf, 0xaabbccdd); // topic
            try helpers.push_u8(allocator, &buf, 0x20); // length
            try helpers.push_u8(allocator, &buf, 0x00); // offset
            try buf.append(allocator, 0xa1);
            try helpers.ret_const(allocator, &buf, 1);
        },
        0xa2 => { // LOG2
            try helpers.push_u256(allocator, &buf, 0xdeadbeef);
            try helpers.push_u8(allocator, &buf, 0x00);
            try buf.append(allocator, 0x52); // MSTORE
            try helpers.push_u256(allocator, &buf, 0x22222222); // topic2
            try helpers.push_u256(allocator, &buf, 0x11111111); // topic1
            try helpers.push_u8(allocator, &buf, 0x20); // length
            try helpers.push_u8(allocator, &buf, 0x00); // offset
            try buf.append(allocator, 0xa2);
            try helpers.ret_const(allocator, &buf, 1);
        },
        0xa3 => { // LOG3
            try helpers.push_u256(allocator, &buf, 0xdeadbeef);
            try helpers.push_u8(allocator, &buf, 0x00);
            try buf.append(allocator, 0x52); // MSTORE
            try helpers.push_u256(allocator, &buf, 0x33333333); // topic3
            try helpers.push_u256(allocator, &buf, 0x22222222); // topic2
            try helpers.push_u256(allocator, &buf, 0x11111111); // topic1
            try helpers.push_u8(allocator, &buf, 0x20); // length
            try helpers.push_u8(allocator, &buf, 0x00); // offset
            try buf.append(allocator, 0xa3);
            try helpers.ret_const(allocator, &buf, 1);
        },
        0xa4 => { // LOG4
            try helpers.push_u256(allocator, &buf, 0xdeadbeef);
            try helpers.push_u8(allocator, &buf, 0x00);
            try buf.append(allocator, 0x52); // MSTORE
            try helpers.push_u256(allocator, &buf, 0x44444444); // topic4
            try helpers.push_u256(allocator, &buf, 0x33333333); // topic3
            try helpers.push_u256(allocator, &buf, 0x22222222); // topic2
            try helpers.push_u256(allocator, &buf, 0x11111111); // topic1
            try helpers.push_u8(allocator, &buf, 0x20); // length
            try helpers.push_u8(allocator, &buf, 0x00); // offset
            try buf.append(allocator, 0xa4);
            try helpers.ret_const(allocator, &buf, 1);
        },

        // System operations 0xf0..0xff
        0xf0 => { // CREATE
            // Deploy minimal contract
            // Stack order for CREATE: [value, offset, size]
            try helpers.push_u8(allocator, &buf, 0x00); // size
            try helpers.push_u8(allocator, &buf, 0x00); // offset  
            try helpers.push_u8(allocator, &buf, 0x00); // value
            try buf.append(allocator, 0xf0);
            try helpers.ret_top32(allocator, &buf);
        },
        0xf1 => { // CALL
            // Call address 0x0 (which should be empty) with no data
            // This will succeed but do nothing, returning 1 for success
            try helpers.push_u8(allocator, &buf, 0x00); // retLength
            try helpers.push_u8(allocator, &buf, 0x00); // retOffset
            try helpers.push_u8(allocator, &buf, 0x00); // argsLength
            try helpers.push_u8(allocator, &buf, 0x00); // argsOffset
            try helpers.push_u8(allocator, &buf, 0x00); // value
            try helpers.push_u8(allocator, &buf, 0x00); // address (0x0 - empty account)
            try helpers.push_u16(allocator, &buf, 0x2710); // gas 10000
            try buf.append(allocator, 0xf1); // CALL
            try helpers.ret_top32(allocator, &buf); // Return the result (1 for success)
        },
        0xf2 => { // CALLCODE
            try helpers.push_u8(allocator, &buf, 0x00); // retLength
            try helpers.push_u8(allocator, &buf, 0x00); // retOffset
            try helpers.push_u8(allocator, &buf, 0x00); // argsLength
            try helpers.push_u8(allocator, &buf, 0x00); // argsOffset
            try helpers.push_u8(allocator, &buf, 0x00); // value
            try buf.append(allocator, 0x30); // ADDRESS
            try helpers.push_u16(allocator, &buf, 0x2710); // gas 10000
            try buf.append(allocator, 0xf2);
            try helpers.ret_top32(allocator, &buf);
        },
        0xf3 => { // RETURN
            try helpers.push_u256(allocator, &buf, 0xcafebabe);
            try helpers.push_u8(allocator, &buf, 0x00);
            try buf.append(allocator, 0x52); // MSTORE
            try helpers.push_u8(allocator, &buf, 0x00); // offset
            try helpers.push_u8(allocator, &buf, 0x20); // length 
            try buf.append(allocator, 0xf3);
        },
        0xf4 => { // DELEGATECALL
            try helpers.push_u8(allocator, &buf, 0x00); // retLength
            try helpers.push_u8(allocator, &buf, 0x00); // retOffset
            try helpers.push_u8(allocator, &buf, 0x00); // argsLength
            try helpers.push_u8(allocator, &buf, 0x00); // argsOffset
            try buf.append(allocator, 0x30); // ADDRESS
            try helpers.push_u16(allocator, &buf, 0x2710); // gas 10000
            try buf.append(allocator, 0xf4);
            try helpers.ret_top32(allocator, &buf);
        },
        0xf5 => { // CREATE2
            // Deploy minimal contract with salt
            try helpers.push_u256(allocator, &buf, 0x12345678); // salt
            try helpers.push_u8(allocator, &buf, 0x00); // length
            try helpers.push_u8(allocator, &buf, 0x00); // offset
            try helpers.push_u8(allocator, &buf, 0x00); // value
            try buf.append(allocator, 0xf5);
            try helpers.ret_top32(allocator, &buf);
        },
        0xf6 => { // AUTH - EIP-3074
            // AUTH requires 5 stack items: [authority, commitment, sig_v, sig_r, sig_s]
            // Push valid signature components (but will fail verification)
            try helpers.push_u256(allocator, &buf, 0); // sig_s
            try helpers.push_u256(allocator, &buf, 0); // sig_r  
            try helpers.push_u8(allocator, &buf, 27); // sig_v
            try helpers.push_u256(allocator, &buf, 0); // commitment
            try helpers.push_u256(allocator, &buf, 0x1234567890123456789012345678901234567890); // authority address
            try buf.append(allocator, 0xf6); // AUTH
            try helpers.ret_top32(allocator, &buf);
        },
        0xf7 => { // AUTHCALL - EIP-3074
            // AUTHCALL requires 8 stack items: [gas, to, value, input_offset, input_size, output_offset, output_size, auth]
            try helpers.push_u8(allocator, &buf, 0x00); // auth flag (0 = no auth)
            try helpers.push_u8(allocator, &buf, 0x00); // output_size
            try helpers.push_u8(allocator, &buf, 0x00); // output_offset
            try helpers.push_u8(allocator, &buf, 0x00); // input_size
            try helpers.push_u8(allocator, &buf, 0x00); // input_offset
            try helpers.push_u8(allocator, &buf, 0x00); // value
            try buf.append(allocator, 0x30); // ADDRESS - use self as target
            try helpers.push_u16(allocator, &buf, 0x2710); // gas 10000
            try buf.append(allocator, 0xf7); // AUTHCALL
            try helpers.ret_top32(allocator, &buf);
        },
        0xfa => { // STATICCALL
            try helpers.push_u8(allocator, &buf, 0x00); // retLength
            try helpers.push_u8(allocator, &buf, 0x00); // retOffset
            try helpers.push_u8(allocator, &buf, 0x00); // argsLength
            try helpers.push_u8(allocator, &buf, 0x00); // argsOffset
            try buf.append(allocator, 0x30); // ADDRESS
            try helpers.push_u16(allocator, &buf, 0x2710); // gas 10000
            try buf.append(allocator, 0xfa);
            try helpers.ret_top32(allocator, &buf);
        },
        0xfd => { // REVERT
            try helpers.push_u256(allocator, &buf, 0xdeadbeef);
            try helpers.push_u8(allocator, &buf, 0x00);
            try buf.append(allocator, 0x52); // MSTORE
            try helpers.push_u8(allocator, &buf, 0x00); // offset
            try helpers.push_u8(allocator, &buf, 0x20); // length
            try buf.append(allocator, 0xfd);
        },
        0xfe => { // INVALID
            try buf.append(allocator, 0xfe);
        },
        0xff => { // SELFDESTRUCT
            try buf.append(allocator, 0x30); // ADDRESS
            try buf.append(allocator, 0xff);
        },

        // Undefined opcodes
        else => {
            // Just emit the opcode - should fail in both EVMs
            try buf.append(allocator, opcode);
        },
    }

    return buf.toOwnedSlice(allocator);
}