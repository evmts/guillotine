//! Executable memory for JIT-compiled code.
//!
//! macOS aarch64: one RWX mapping with MAP_JIT. Writes happen with the
//! per-thread JIT write protection disabled; execution needs it enabled.
//! Linux (aarch64, x86_64) and macOS x86_64: map RW, copy, mprotect to RX.
//! aarch64 always invalidates the instruction cache after writing.

const std = @import("std");
const builtin = @import("builtin");

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;
const is_aarch64 = builtin.cpu.arch == .aarch64;

/// True when this target can map executable memory.
pub const supported = (is_macos or is_linux) and (is_aarch64 or builtin.cpu.arch == .x86_64);

/// macOS aarch64 uses MAP_JIT plus per-thread write protection toggling.
const use_map_jit = is_macos and is_aarch64;

extern "c" fn pthread_jit_write_protect_np(enabled: c_int) void;
extern "c" fn sys_icache_invalidate(start: *anyopaque, len: usize) void;

/// Zig 0.17 has no `std.posix.mprotect`; `protect` reports these instead.
pub const ProtectError = error{ AccessDenied, OutOfMemory } || std.posix.UnexpectedError;

pub const Error = error{
    UnsupportedPlatform,
    EmptyCode,
} || std.posix.MMapError || ProtectError;

/// Changes the protection of whole pages returned by `mmap`.
fn protect(bytes: []align(std.heap.page_size_min) u8, prot: std.posix.PROT) ProtectError!void {
    switch (std.posix.errno(std.posix.system.mprotect(@ptrCast(@alignCast(bytes.ptr)), bytes.len, prot))) {
        .SUCCESS => return,
        .ACCES => return error.AccessDenied,
        .NOMEM => return error.OutOfMemory,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

/// A sealed, executable copy of machine code. Owns its pages.
pub const ExecMemory = struct {
    bytes: []align(std.heap.page_size_min) u8,
    code_len: usize,

    /// Maps executable pages, copies `code` into them, and seals them.
    pub fn create(code: []const u8) Error!ExecMemory {
        if (comptime !supported) return error.UnsupportedPlatform;
        if (code.len == 0) return error.EmptyCode;
        const page = std.heap.pageSize();
        const len = std.mem.alignForward(usize, code.len, page);

        if (comptime use_map_jit) {
            const bytes = try std.posix.mmap(
                null,
                len,
                .{ .READ = true, .WRITE = true, .EXEC = true },
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .JIT = true },
                -1,
                0,
            );
            pthread_jit_write_protect_np(0);
            @memcpy(bytes[0..code.len], code);
            pthread_jit_write_protect_np(1);
            sys_icache_invalidate(bytes.ptr, code.len);
            return .{ .bytes = bytes, .code_len = code.len };
        }

        const bytes = try std.posix.mmap(
            null,
            len,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        errdefer std.posix.munmap(bytes);
        @memcpy(bytes[0..code.len], code);
        try protect(bytes, .{ .READ = true, .EXEC = true });
        if (comptime is_aarch64) clearCache(@intFromPtr(bytes.ptr), @intFromPtr(bytes.ptr) + code.len);
        return .{ .bytes = bytes, .code_len = code.len };
    }

    pub fn deinit(self: *ExecMemory) void {
        if (comptime !supported) return;
        std.posix.munmap(self.bytes);
        self.bytes = &.{};
        self.code_len = 0;
    }

    pub fn ptr(self: *const ExecMemory) [*]const u8 {
        return self.bytes.ptr;
    }
};

/// Instruction cache maintenance for aarch64 Linux (macOS uses sys_icache_invalidate).
fn clearCache(start: usize, end: usize) void {
    if (comptime !(is_aarch64 and is_linux)) return;
    const ctr = asm volatile ("mrs %[ctr], ctr_el0"
        : [ctr] "=r" (-> u64),
    );
    const dline = @as(usize, 4) << @intCast((ctr >> 16) & 0xf);
    const iline = @as(usize, 4) << @intCast(ctr & 0xf);
    var addr = start & ~(dline - 1);
    while (addr < end) : (addr += dline) {
        asm volatile ("dc cvau, %[a]"
            :
            : [a] "r" (addr),
            : .{ .memory = true });
    }
    asm volatile ("dsb ish" ::: .{ .memory = true });
    addr = start & ~(iline - 1);
    while (addr < end) : (addr += iline) {
        asm volatile ("ic ivau, %[a]"
            :
            : [a] "r" (addr),
            : .{ .memory = true });
    }
    asm volatile ("dsb ish\nisb" ::: .{ .memory = true });
}

test "ExecMemory maps, seals, and runs a tiny function" {
    if (comptime !supported) return error.SkipZigTest;
    if (comptime is_aarch64) {
        // movz w0, #42 ; ret
        const words = [_]u32{ 0x52800540, 0xD65F03C0 };
        var mem = try ExecMemory.create(std.mem.sliceAsBytes(&words));
        defer mem.deinit();
        const f: *const fn () callconv(.c) u32 = @ptrFromInt(@intFromPtr(mem.ptr()));
        try std.testing.expectEqual(@as(u32, 42), f());
    } else {
        // mov eax, 42 ; ret
        const bytes = [_]u8{ 0xB8, 42, 0, 0, 0, 0xC3 };
        var mem = try ExecMemory.create(&bytes);
        defer mem.deinit();
        const f: *const fn () callconv(.c) u32 = @ptrFromInt(@intFromPtr(mem.ptr()));
        try std.testing.expectEqual(@as(u32, 42), f());
    }
}

test "ExecMemory rejects empty code" {
    if (comptime !supported) return error.SkipZigTest;
    try std.testing.expectError(error.EmptyCode, ExecMemory.create(&.{}));
}
