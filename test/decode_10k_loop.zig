const std = @import("std");

test "decode 10k hashes loop" {
    // The main loop part of the runtime code
    const loop_hex = "5f5b614e20811015605e5760408051602081018390520160408051601f19818403019052526001016034565b5056fe";
    
    
    // Convert hex to bytes for analysis
    var loop_bytes: [100]u8 = undefined;
    _ = try std.fmt.hexToBytes(&loop_bytes, loop_hex);
    const code = loop_bytes[0..loop_hex.len / 2];
    
    
    var pc: usize = 0;
    while (pc < code.len) {
        const op = code[pc];
        
        switch (op) {
            0x5f => {
                pc += 1;
            },
            0x5b => {
                pc += 1;
            },
            0x61 => {
                const value = (@as(u16, code[pc + 1]) << 8) | code[pc + 2];
                pc += 3;
            },
            0x81 => {
                pc += 1;
            },
            0x10 => {
                pc += 1;
            },
            0x15 => {
                pc += 1;
            },
            0x60 => {
                pc += 2;
            },
            0x57 => {
                pc += 1;
            },
            0x40 => {
                pc += 1;
            },
            0x80 => {
                pc += 1;
            },
            0x51 => {
                pc += 1;
            },
            0x52 => {
                pc += 1;
            },
            0x20 => {
                pc += 1;
            },
            0x83 => {
                pc += 1;
            },
            0x90 => {
                pc += 1;
            },
            0x01 => {
                pc += 1;
            },
            0x19 => {
                pc += 1;
            },
            0x84 => {
                pc += 1;
            },
            0x03 => {
                pc += 1;
            },
            0x1f => {
                pc += 1;
            },
            0x56 => {
                pc += 1;
            },
            0x5e => {
                pc += 1;
            },
            0x50 => {
                pc += 1;
            },
            0xfe => {
                pc += 1;
            },
            else => {
                pc += 1;
            },
        }
    }
    
}