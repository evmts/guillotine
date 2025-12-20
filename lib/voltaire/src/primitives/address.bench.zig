const std = @import("std");
const zbench = @import("zbench");
const primitives = @import("voltaire");
const Address = primitives.Address;

// Benchmark: Address.fromHex
fn benchFromHex(allocator: std.mem.Allocator) void {
    const addr_hex = "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0";
    const addr = Address.fromHex(addr_hex) catch unreachable;
    _ = addr;
    _ = allocator;
}

// Benchmark: Address.toHex
fn benchToHex(allocator: std.mem.Allocator) void {
    const addr = Address{ .bytes = [_]u8{0x74} ** 20 };
    const hex = addr.toHex();
    _ = hex;
    _ = allocator;
}

// Benchmark: Address.toChecksumHex (EIP-55)
fn benchToChecksumHex(allocator: std.mem.Allocator) void {
    const addr = Address{ .bytes = [_]u8{0x74} ** 20 };
    const checksum = addr.toChecksumHex();
    _ = checksum;
    _ = allocator;
}

// Benchmark: Address.fromPublicKey
fn benchFromPublicKey(allocator: std.mem.Allocator) void {
    const pubkey_x: u256 = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
    const pubkey_y: u256 = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8;
    const addr = Address.fromPublicKey(pubkey_x, pubkey_y);
    _ = addr;
    _ = allocator;
}

// Benchmark: Address.calculateCreateAddress (CREATE opcode)
fn benchCalculateCreate(allocator: std.mem.Allocator) void {
    const deployer = Address{ .bytes = [_]u8{0x12} ** 20 };
    const nonce: u64 = 42;
    const addr = Address.calculateCreateAddress(allocator, deployer, nonce) catch unreachable;
    _ = addr;
}

// Benchmark: Address.getCreate2Address (CREATE2 opcode, pre-hashed init code)
fn benchCalculateCreate2(allocator: std.mem.Allocator) void {
    const deployer = Address{ .bytes = [_]u8{0x12} ** 20 };
    const salt = [_]u8{0xab} ** 32;
    const init_code_hash = [_]u8{0xcd} ** 32;
    const addr = Address.getCreate2Address(deployer, salt, init_code_hash);
    _ = addr;
    _ = allocator;
}

// Benchmark: Address.toU256
fn benchToU256(allocator: std.mem.Allocator) void {
    const addr = Address{ .bytes = [_]u8{0x74} ** 20 };
    const value = addr.toU256();
    _ = value;
    _ = allocator;
}

// Benchmark: Address.fromU256
fn benchFromU256(allocator: std.mem.Allocator) void {
    const value: u256 = 0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0;
    const addr = Address.fromU256(value);
    _ = addr;
    _ = allocator;
}

// Benchmark: Address.equals
fn benchEquals(allocator: std.mem.Allocator) void {
    const addr1 = Address{ .bytes = [_]u8{0x74} ** 20 };
    const addr2 = Address{ .bytes = [_]u8{0x74} ** 20 };
    const result = addr1.equals(addr2);
    _ = result;
    _ = allocator;
}

// Benchmark: Address.isZero
fn benchIsZero(allocator: std.mem.Allocator) void {
    const addr = Address.ZERO;
    const result = addr.isZero();
    _ = result;
    _ = allocator;
}

pub fn main() !void {
    var buf: [8192]u8 = undefined;
    var stdout_file = std.fs.File.stdout();
    var writer_instance = stdout_file.writer(&buf);
    var writer = &writer_instance.interface;
    var bench = zbench.Benchmark.init(std.heap.page_allocator, .{});
    defer bench.deinit();

    try bench.add("Address.fromHex", benchFromHex, .{});
    try bench.add("Address.toHex", benchToHex, .{});
    try bench.add("Address.toChecksumHex (EIP-55)", benchToChecksumHex, .{});
    try bench.add("Address.fromPublicKey", benchFromPublicKey, .{});
    try bench.add("Address.calculateCreate", benchCalculateCreate, .{});
    try bench.add("Address.calculateCreate2", benchCalculateCreate2, .{});
    try bench.add("Address.toU256", benchToU256, .{});
    try bench.add("Address.fromU256", benchFromU256, .{});
    try bench.add("Address.equals", benchEquals, .{});
    try bench.add("Address.isZero", benchIsZero, .{});

    try writer.writeAll("\n");
    try bench.run(writer);
}
