const std = @import("std");

pub const repetitions: u32 = 128;
pub const Source = union(enum) {
    bytecode: []const u8,
    fixture: []const u8,
    precompile: u16,
    clz,
    p256verify,
};

pub const Workload = struct {
    name: []const u8,
    category: []const u8,
    source: Source,
    input: []const u8 = &.{},
    operations: u32 = 1,
    expected: ?u256 = null,
    output_len: ?usize = null,
    // Prepopulate independent storage slots for cold/warm SLOAD cases.
    storage: bool = false,
};

pub fn decodeHex(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var hex = std.mem.trim(u8, text, " \t\n\r");
    if (std.mem.startsWith(u8, hex, "0x") or std.mem.startsWith(u8, hex, "0X")) hex = hex[2..];
    if (hex.len % 2 != 0) return error.OddHexLength;
    const bytes = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(bytes);
    _ = try std.fmt.hexToBytes(bytes, hex);
    return bytes;
}

/// Small assembler used only during untimed setup. Jumps are patched to actual
/// bytecode PCs, never dispatch schedule indices. Every buffer is arena-owned.
const Assembler = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn op(self: *Assembler, value: u8) !void {
        try self.bytes.append(self.allocator, value);
    }
    fn raw(self: *Assembler, values: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, values);
    }
    fn push(self: *Assembler, value: u256) !void {
        var bytes: [32]u8 = undefined;
        std.mem.writeInt(u256, &bytes, value, .big);
        var index: usize = 0;
        while (index < 31 and bytes[index] == 0) : (index += 1) {}
        try self.op(@intCast(0x5f + 32 - index));
        try self.raw(bytes[index..]);
    }
    fn label(self: *Assembler) !u16 {
        const pc = std.math.cast(u16, self.bytes.items.len) orelse return error.CodeTooLarge;
        try self.op(0x5b);
        return pc;
    }
    fn jump(self: *Assembler, opcode: u8) !usize {
        try self.raw(&.{ 0x61, 0, 0, opcode });
        return self.bytes.items.len - 3;
    }
    fn patch(self: *Assembler, position: usize, pc: u16) void {
        std.mem.writeInt(u16, self.bytes.items[position..][0..2], pc, .big);
    }
    fn store(self: *Assembler, slot: u16) !void {
        try self.push(slot);
        try self.op(0x52);
    }
    fn load(self: *Assembler, slot: u16) !void {
        try self.push(slot);
        try self.op(0x51);
    }
    fn finish(self: *Assembler, offset: u16) ![]const u8 {
        try self.push(32);
        try self.push(offset);
        try self.op(0xf3);
        return self.bytes.toOwnedSlice(self.allocator);
    }
};

pub fn build(allocator: std.mem.Allocator) ![]Workload {
    var list: std.ArrayList(Workload) = .empty;
    errdefer list.deinit(allocator);
    const arithmetic = [_]struct { name: []const u8, opcode: u8, expected: u256 }{
        .{ .name = "ADD", .opcode = 0x01, .expected = 10 },
        .{ .name = "MUL", .opcode = 0x02, .expected = 21 },
        .{ .name = "DIV", .opcode = 0x04, .expected = 2 },
        .{ .name = "SDIV", .opcode = 0x05, .expected = 2 },
        .{ .name = "MOD", .opcode = 0x06, .expected = 1 },
        .{ .name = "EXP", .opcode = 0x0a, .expected = 343 },
        .{ .name = "AND", .opcode = 0x16, .expected = 3 },
        .{ .name = "OR", .opcode = 0x17, .expected = 7 },
        .{ .name = "XOR", .opcode = 0x18, .expected = 4 },
        .{ .name = "SHL", .opcode = 0x1b, .expected = 384 },
        .{ .name = "SHR", .opcode = 0x1c, .expected = 0 },
        .{ .name = "SAR", .opcode = 0x1d, .expected = 0 },
    };
    for (arithmetic) |item| {
        var code = Assembler{ .allocator = allocator };
        for (0..repetitions) |_| {
            try code.push(3);
            try code.push(7);
            try code.op(item.opcode);
            try code.store(0);
        }
        try list.append(allocator, .{
            .name = try std.fmt.allocPrint(allocator, "opcode/{s}", .{item.name}),
            .category = "opcode",
            .source = .{ .bytecode = try code.finish(0) },
            .operations = repetitions,
            .expected = item.expected,
        });
    }
    try list.append(allocator, .{ .name = "opcode/CLZ", .category = "opcode", .source = .clz, .operations = repetitions, .expected = 253 });
    const memory = [_][]const u8{ "MLOAD", "MSTORE", "MCOPY", "KECCAK256", "SLOAD-cold", "SLOAD-warm", "SSTORE-cold", "SSTORE-warm", "CALL", "STATICCALL" };
    for (memory, 0..) |name, kind| {
        var code = Assembler{ .allocator = allocator };
        try code.push(42);
        try code.store(0);
        if (kind == 5 or kind == 7) {
            try code.push(0);
            try code.op(0x54);
            try code.op(0x50);
        }
        for (0..repetitions) |index| {
            switch (kind) {
                0 => {
                    try code.load(0);
                    try code.store(32);
                },
                1 => {
                    try code.push(42);
                    try code.store(32);
                },
                2 => {
                    try code.push(32);
                    try code.push(0);
                    try code.push(32);
                    try code.op(0x5e);
                },
                3 => {
                    try code.push(32);
                    try code.push(0);
                    try code.op(0x20);
                    try code.store(32);
                },
                4, 5 => {
                    try code.push(if (kind == 4) index else 0);
                    try code.op(0x54);
                    try code.store(32);
                },
                6, 7 => {
                    try code.push(8 + index % 2);
                    try code.push(if (kind == 6) index else 0);
                    try code.op(0x55);
                },
                8, 9 => {
                    // Child at 0x2000 returns 42. Accumulate success flags;
                    // a failed nested call changes the checked result.
                    try code.push(0);
                    try code.push(0);
                    try code.push(0);
                    try code.push(0);
                    if (kind == 8) try code.push(0);
                    try code.push(0x2000);
                    try code.push(50_000);
                    try code.op(if (kind == 8) 0xf1 else 0xfa);
                    try code.load(32);
                    try code.op(0x01);
                    try code.store(32);
                },
                else => unreachable,
            }
        }
        if (kind == 6 or kind == 7) {
            try code.push(if (kind == 6) repetitions - 1 else 0);
            try code.op(0x54);
            try code.store(32);
        }
        var word = @as([32]u8, @splat(0));
        word[31] = 42;
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(&word, &hash, .{});
        const expected: u256 = switch (kind) {
            3 => std.mem.readInt(u256, &hash, .big),
            4, 5 => 7,
            6, 7 => 9,
            8, 9 => repetitions,
            else => 42,
        };
        try list.append(allocator, .{
            .name = try std.fmt.allocPrint(allocator, "opcode/{s}", .{name}),
            .category = "opcode",
            .source = .{ .bytecode = try code.finish(32) },
            .operations = repetitions,
            .expected = expected,
            .storage = kind >= 4 and kind <= 7,
        });
    }
    // Bounded loop containing both conditional and unconditional jumps.
    {
        var code = Assembler{ .allocator = allocator };
        try code.push(repetitions);
        const start = try code.label();
        try code.push(1);
        try code.op(0x90);
        try code.op(0x03);
        try code.op(0x80);
        try code.op(0x15);
        const end = try code.jump(0x57);
        try code.push(start);
        try code.op(0x56);
        code.patch(end, try code.label());
        try code.store(0);
        try list.append(allocator, .{ .name = "opcode/JUMP-JUMPI-loop", .category = "opcode", .source = .{ .bytecode = try code.finish(0) }, .operations = repetitions, .expected = 0 });
    }
    for ([_][]const u8{ "snailtracer", "erc20-mint", "erc20-transfer", "ten-thousand-hashes" }) |name| {
        try list.append(allocator, .{ .name = try std.fmt.allocPrint(allocator, "contract/{s}", .{name}), .category = "contract", .source = .{ .fixture = name } });
    }
    for ([_][]const u8{ "BubbleSort", "Fibonacci", "Factorial", "Keccak-loop", "Uniswap-like-swap" }, 0..) |name, kind| {
        const result = try algorithm(allocator, kind);
        try list.append(allocator, .{ .name = try std.fmt.allocPrint(allocator, "contract/{s}", .{name}), .category = "contract", .source = .{ .bytecode = result.code }, .expected = result.expected });
    }
    try precompiles(allocator, &list);
    return list.toOwnedSlice(allocator);
}

fn algorithm(allocator: std.mem.Allocator, kind: usize) !struct { code: []const u8, expected: u256 } {
    var code = Assembler{ .allocator = allocator };
    var expected: u256 = 0;
    switch (kind) {
        0 => {
            // Sort 16 descending words using the full bubble-sort comparison
            // network. Each comparison and conditional swap executes in EVM.
            for (0..16) |index| {
                try code.push(16 - index);
                try code.store(@intCast(index * 32));
            }
            for (0..15) |pass| {
                for (0..15 - pass) |index| {
                    const left: u16 = @intCast(index * 32);
                    const right = left + 32;
                    try code.load(right);
                    try code.load(left);
                    try code.op(0x11);
                    try code.op(0x15);
                    const skip = try code.jump(0x57);
                    try code.load(left);
                    try code.load(right);
                    try code.store(left);
                    try code.store(right);
                    code.patch(skip, try code.label());
                }
            }
            // Weighted checksum validates every sorted element, not just min.
            try code.push(0);
            for (0..16) |index| {
                try code.load(@intCast(index * 32));
                try code.push(index + 1);
                try code.op(0x02);
                try code.op(0x01);
            }
            try code.store(0);
            expected = 1496;
        },
        1 => {
            try code.push(0);
            try code.push(1);
            for (0..32) |_| {
                try code.op(0x81);
                try code.op(0x01);
                try code.op(0x90);
            }
            try code.op(0x50);
            try code.store(0);
            expected = 2178309;
        },
        2 => {
            try code.push(1);
            for (2..21) |value| {
                try code.push(value);
                try code.op(0x02);
            }
            try code.store(0);
            expected = 2432902008176640000;
        },
        3 => {
            var word = @as([32]u8, @splat(0));
            for (0..256) |_| {
                try code.push(32);
                try code.push(0);
                try code.op(0x20);
                try code.store(0);
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha3.Keccak256.hash(&word, &digest, .{});
                word = digest;
            }
            expected = std.mem.readInt(u256, &word, .big);
        },
        4 => {
            // Constant-product exact-input quote including the 0.3% fee:
            // out = input*997*reserveOut / (reserveIn*1000 + input*997).
            // This is a local AMM arithmetic workload, not a mainnet replay.
            for (0..64) |_| {
                try code.push(1_000_000 * 1000 + 1000 * 997);
                try code.push(1000);
                try code.push(997);
                try code.op(0x02);
                try code.push(2_000_000);
                try code.op(0x02);
                try code.op(0x04);
                try code.store(0);
            }
            expected = 1992;
        },
        else => unreachable,
    }
    return .{ .code = try code.finish(0), .expected = expected };
}

fn precompiles(allocator: std.mem.Allocator, list: *std.ArrayList(Workload)) !void {
    // A mathematically specified recoverable signature: private key d=1,
    // nonce k=1, message hash z=1. Thus r=G.x and s=r+1; G.y is even (v=27).
    const signature = try decodeHex(allocator, "0000000000000000000000000000000000000000000000000000000000000001" ++
        "000000000000000000000000000000000000000000000000000000000000001b" ++
        "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798" ++
        "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81799");
    try list.append(allocator, .{ .name = "precompile/ECRECOVER", .category = "precompile", .source = .{ .precompile = 1 }, .input = signature, .expected = 0x7e5f4552091a69125d5dfcb7b8c2659029395bdf });
    const message = try allocator.alloc(u8, 1024);
    @memset(message, 0xa5);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(message, &digest, .{});
    try list.append(allocator, .{ .name = "precompile/SHA256-1KiB", .category = "precompile", .source = .{ .precompile = 2 }, .input = message, .expected = std.mem.readInt(u256, &digest, .big) });
    const modexp = try allocator.alloc(u8, 192);
    @memset(modexp, 0);
    modexp[31] = 32;
    modexp[63] = 32;
    modexp[95] = 32;
    std.mem.writeInt(u256, modexp[96..128], 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef, .big);
    std.mem.writeInt(u256, modexp[128..160], 65537, .big);
    std.mem.writeInt(u256, modexp[160..192], 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f, .big);
    try list.append(allocator, .{ .name = "precompile/MODEXP-256", .category = "precompile", .source = .{ .precompile = 5 }, .input = modexp, .expected = 0x2686c19f3c49baa8d8cb1880496e7ede66488eceace7b8ad7f7ca07aa6ff790d });
    const add = try allocator.alloc(u8, 128);
    @memset(add, 0);
    add[31] = 1;
    add[63] = 2;
    add[95] = 1;
    add[127] = 2;
    try list.append(allocator, .{ .name = "precompile/BN254-add", .category = "precompile", .source = .{ .precompile = 6 }, .input = add, .output_len = 64 });
    const mul = try allocator.alloc(u8, 96);
    @memset(mul, 0);
    mul[31] = 1;
    mul[63] = 2;
    mul[95] = 17;
    try list.append(allocator, .{ .name = "precompile/BN254-mul", .category = "precompile", .source = .{ .precompile = 7 }, .input = mul, .output_len = 64 });
    // EIP-197 G2 generator paired with the non-infinity G1 generator. A
    // single nontrivial pairing evaluates false (the 32-byte zero word).
    const pairing = try decodeHex(allocator, "0000000000000000000000000000000000000000000000000000000000000001" ++
        "0000000000000000000000000000000000000000000000000000000000000002" ++
        "198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2" ++
        "1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed" ++
        "090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b" ++
        "12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa");
    try list.append(allocator, .{ .name = "precompile/BN254-pairing", .category = "precompile", .source = .{ .precompile = 8 }, .input = pairing, .expected = 0 });
    // BLS map-to-curve performs real field/curve work and avoids the infinity
    // shortcuts common in all-zero point-addition benchmark inputs. Final
    // EIP-2537 places MAP_FP_TO_G1 at 0x10 (0x12 was a withdrawn draft address).
    const field = try allocator.alloc(u8, 64);
    @memset(field, 0);
    field[63] = 42;
    try list.append(allocator, .{ .name = "precompile/BLS12-381-map-G1", .category = "precompile", .source = .{ .precompile = 0x10 }, .input = field, .output_len = 128 });
    const scheme = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    const key = try scheme.KeyPair.generateDeterministic(@as([scheme.KeyPair.seed_length]u8, @splat(42)));
    const text = "Guillotine P256 benchmark vector";
    const signature256 = (try key.sign(text, null)).toBytes();
    const public = key.public_key.toUncompressedSec1();
    const p256 = try allocator.alloc(u8, 160);
    std.crypto.hash.sha2.Sha256.hash(text, p256[0..32], .{});
    @memcpy(p256[32..96], &signature256);
    @memcpy(p256[96..160], public[1..65]);
    try list.append(allocator, .{ .name = "precompile/P256VERIFY", .category = "precompile", .source = .p256verify, .input = p256, .expected = 1 });
}

test "hex parser trims prefixes and rejects invalid fixtures" {
    const allocator = std.testing.allocator;
    const bytes = try decodeHex(allocator, " \n0X00fF\r");
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255 }, bytes);
    try std.testing.expectError(error.OddHexLength, decodeHex(allocator, "0x123"));
    try std.testing.expectError(error.InvalidCharacter, decodeHex(allocator, "zz"));
}

test "workloads fit protocol size, have unique names and valid jump destinations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const workloads = try build(arena.allocator());
    try std.testing.expect(workloads.len >= 40);
    for (workloads, 0..) |workload, index| {
        for (workloads[0..index]) |previous| try std.testing.expect(!std.mem.eql(u8, workload.name, previous.name));
        switch (workload.source) {
            .bytecode => |code| {
                try std.testing.expect(code.len > 0 and code.len <= 24576);
                var pc: usize = 0;
                while (pc < code.len) : (pc += 1) {
                    if (code[pc] >= 0x60 and code[pc] <= 0x7f) {
                        const length = code[pc] - 0x5f;
                        try std.testing.expect(pc + length < code.len);
                        if (length == 2 and pc + 3 < code.len and (code[pc + 3] == 0x56 or code[pc + 3] == 0x57)) {
                            const dest = std.mem.readInt(u16, code[pc + 1 ..][0..2], .big);
                            try std.testing.expect(dest < code.len);
                            try std.testing.expectEqual(@as(u8, 0x5b), code[dest]);
                        }
                        pc += length;
                    }
                }
            },
            else => {},
        }
    }
}

test "ECRECOVER benchmark signature verifies independently with the standard library" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const suite = try build(arena.allocator());
    for (suite) |workload| {
        if (!std.mem.eql(u8, workload.name, "precompile/ECRECOVER")) continue;
        const scheme = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256;
        var secret = @as([32]u8, @splat(0));
        secret[31] = 1;
        const key = try scheme.KeyPair.fromSecretKey(try scheme.SecretKey.fromBytes(secret));
        const signature = scheme.Signature.fromBytes(workload.input[64..128].*);
        try signature.verifyPrehashed(workload.input[0..32].*, key.public_key);
        const public = key.public_key.toUncompressedSec1();
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(public[1..65], &hash, .{});
        try std.testing.expectEqual(workload.expected.?, @as(u256, std.mem.readInt(u160, hash[12..32], .big)));
        return;
    }
    return error.MissingEcrecoverBenchmark;
}
