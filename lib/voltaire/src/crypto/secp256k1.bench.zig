const std = @import("std");
const zbench = @import("zbench");
const crypto = @import("crypto");
const secp256k1 = crypto.secp256k1;

// Test message hash (Keccak256 of "Hello, Ethereum!")
const test_message_hash = [_]u8{
    0x8c, 0x1c, 0x93, 0x8d, 0x4e, 0x03, 0x65, 0x7a,
    0xea, 0x45, 0xa9, 0x4f, 0xc7, 0xd4, 0x7b, 0xa8,
    0x26, 0xc8, 0xd6, 0x67, 0xc0, 0xd1, 0xe6, 0xe3,
    0x3a, 0x64, 0xa0, 0x36, 0xec, 0x44, 0xf5, 0x8f,
};

// Test signature components
const test_r = [_]u8{
    0x4e, 0x03, 0x65, 0x7a, 0xea, 0x45, 0xa9, 0x4f,
    0xc7, 0xd4, 0x7b, 0xa8, 0x26, 0xc8, 0xd6, 0x67,
    0xc0, 0xd1, 0xe6, 0xe3, 0x3a, 0x64, 0xa0, 0x36,
    0xec, 0x44, 0xf5, 0x8f, 0xa1, 0x2d, 0x6c, 0x45,
};

const test_s = [_]u8{
    0x69, 0x7a, 0x7b, 0x8c, 0x9d, 0xae, 0xbf, 0xc0,
    0xd1, 0xe2, 0xf3, 0x04, 0x15, 0x26, 0x37, 0x48,
    0x59, 0x6a, 0x7b, 0x8c, 0x9d, 0xae, 0xbf, 0xc0,
    0xd1, 0xe2, 0xf3, 0x04, 0x15, 0x26, 0x37, 0x48,
};

const test_v: u8 = 27;

// Benchmark: recoverPubkey
fn benchRecoverPubkey(allocator: std.mem.Allocator) void {
    const pubkey = secp256k1.recoverPubkey(&test_message_hash, &test_r, &test_s, test_v) catch return;
    _ = pubkey;
    _ = allocator;
}

// Benchmark: unauditedValidateSignature
fn benchValidateSignature(allocator: std.mem.Allocator) void {
    const r_u256: u256 = std.mem.readInt(u256, &test_r, .big);
    const s_u256: u256 = std.mem.readInt(u256, &test_s, .big);
    const valid = secp256k1.unauditedValidateSignature(r_u256, s_u256);
    _ = valid;
    _ = allocator;
}

// Benchmark: unauditedValidateSignature with high-S (malleable)
fn benchValidateHighS(allocator: std.mem.Allocator) void {
    const r_u256: u256 = std.mem.readInt(u256, &test_r, .big);
    const s_high: u256 = secp256k1.SECP256K1_N; // invalid (>= n)
    const valid = secp256k1.unauditedValidateSignature(r_u256, s_high);
    _ = valid;
    _ = allocator;
}

// Benchmark: AffinePoint.isOnCurve
fn benchAffinePointIsOnCurve(allocator: std.mem.Allocator) void {
    const point = secp256k1.AffinePoint.generator();
    const on_curve = point.isOnCurve();
    _ = on_curve;
    _ = allocator;
}

// Benchmark: AffinePoint.double
fn benchAffinePointDouble(allocator: std.mem.Allocator) void {
    const point = secp256k1.AffinePoint.generator();
    const doubled = point.double();
    _ = doubled;
    _ = allocator;
}

// Benchmark: AffinePoint.add
fn benchAffinePointAdd(allocator: std.mem.Allocator) void {
    const g = secp256k1.AffinePoint.generator();
    const g2 = g.double();
    const result = g.add(g2);
    _ = result;
    _ = allocator;
}

// Benchmark: AffinePoint.scalarMul (small scalar)
fn benchAffinePointScalarMulSmall(allocator: std.mem.Allocator) void {
    const g = secp256k1.AffinePoint.generator();
    const scalar: u256 = 42;
    const result = g.scalarMul(scalar);
    _ = result;
    _ = allocator;
}

pub fn main() !void {
    var buf: [8192]u8 = undefined;
    var stdout_file = std.fs.File.stdout();
    var writer_instance = stdout_file.writer(&buf);
    var writer = &writer_instance.interface;
    var bench = zbench.Benchmark.init(std.heap.page_allocator, .{
        .time_budget_ns = 10_000_000_000, // 10 seconds for crypto operations
    });
    defer bench.deinit();

    try bench.add("recoverPubkey", benchRecoverPubkey, .{});
    try bench.add("validateSignature", benchValidateSignature, .{});
    try bench.add("validateSignature (high-S)", benchValidateHighS, .{});
    try bench.add("AffinePoint.isOnCurve", benchAffinePointIsOnCurve, .{});
    try bench.add("AffinePoint.double", benchAffinePointDouble, .{});
    try bench.add("AffinePoint.add", benchAffinePointAdd, .{});
    try bench.add("AffinePoint.scalarMul (small)", benchAffinePointScalarMulSmall, .{});

    try writer.writeAll("\n");
    try bench.run(writer);
}
