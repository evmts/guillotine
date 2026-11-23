const std = @import("std");
const micro = @import("micro");
const RingBuffer = @import("ring_buffer").RingBuffer;

const N: usize = 1024;

fn benchRingBufferWrite(_: std.mem.Allocator) !u64 {
    var rb = RingBuffer.init();
    for (0..N) |i| {
        rb.write(.{
            .step_number = @intCast(i),
            .opcode = @intCast(i & 0xff),
            .opcode_name = "ADD",
            .gas_before = 1_000_000 - @as(i64, @intCast(i * 3)),
            .gas_after = 1_000_000 - @as(i64, @intCast(i * 3 + 3)),
            .stack_size = @intCast((i & 15) + 2),
            .memory_size = 64,
            .schedule_index = @intCast(i),
            .is_synthetic = false,
        });
    }
    var ordered: [10]RingBuffer.Entry = undefined;
    const slice = rb.getOrdered(&ordered);
    return slice.len + slice[slice.len - 1].step_number;
}

fn benchRingBufferOrdered(_: std.mem.Allocator) !u64 {
    var rb = RingBuffer.init();
    for (0..37) |i| {
        rb.write(.{
            .step_number = @intCast(i),
            .opcode = 0x01,
            .opcode_name = "ADD",
            .gas_before = 1000,
            .gas_after = 997,
            .stack_size = 2,
            .memory_size = 0,
            .schedule_index = @intCast(i),
            .is_synthetic = false,
        });
    }
    var acc: u64 = 0;
    var ordered: [10]RingBuffer.Entry = undefined;
    for (0..N) |_| {
        const slice = rb.getOrdered(&ordered);
        acc +%= slice[0].step_number + slice[slice.len - 1].step_number;
    }
    return acc;
}

pub fn main() void {
    micro.runSuite("tracer", &.{
        .{ .name = "tracer/ring-buffer-write-1024", .operations = N, .run = benchRingBufferWrite },
        .{ .name = "tracer/ring-buffer-ordered-1024", .operations = N, .run = benchRingBufferOrdered },
    });
}
