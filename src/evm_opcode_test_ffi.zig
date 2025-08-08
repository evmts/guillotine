const std = @import("std");
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const CallParams = Evm.CallParams;

// Global allocator for C FFI
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

// Wrapper to own the EVM and its backing in-memory DB for testing
const EvmWrapper = struct {
    evm: *Evm.Evm,
    memory_db: *Evm.MemoryDatabase,
};

// C-facing types
pub const CAddress = extern struct { bytes: [20]u8 };
pub const CBytes = extern struct { ptr: [*]const u8, len: usize };
pub const CMutBytes = extern struct { ptr: [*]u8, len: usize };

pub const CU256 = extern struct { words_le: [4]u64 }; // little-endian 256-bit

pub const CCallKind = enum(c_int) { CALL = 0, STATICCALL = 1, DELEGATECALL = 2, CREATE = 3, CREATE2 = 4 };

pub const CCallRequest = extern struct {
    kind: CCallKind,
    caller: CAddress,
    to: CAddress, // ignored for CREATE/CREATE2
    value: CU256, // used for CALL/CREATE/CREATE2
    input: CBytes, // calldata or init code
    gas: u64,
    salt: CU256, // used for CREATE2 only
};

pub const CCallResponse = extern struct {
    success: bool,
    gas_left: u64,
    output: CMutBytes,
};

fn cu256_to_u256(x: CU256) u256 {
    return (@as(u256, x.words_le[0])) |
        (@as(u256, x.words_le[1]) << 64) |
        (@as(u256, x.words_le[2]) << 128) |
        (@as(u256, x.words_le[3]) << 192);
}

fn caddr_to_addr(a: CAddress) Address.Address {
    return a.bytes;
}

fn cbytes_to_slice(b: CBytes) []const u8 {
    if (b.len == 0) return &.{};
    return b.ptr[0..b.len];
}

export fn zigEvmCreate() ?*anyopaque {
    const memory_db = allocator.create(Evm.MemoryDatabase) catch return null;
    memory_db.* = Evm.MemoryDatabase.init(allocator);
    const db_interface = memory_db.to_database_interface();

    const evm = allocator.create(Evm.Evm) catch {
        memory_db.deinit();
        allocator.destroy(memory_db);
        return null;
    };

    evm.* = Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null) catch {
        memory_db.deinit();
        allocator.destroy(memory_db);
        allocator.destroy(evm);
        return null;
    };

    const wrapper = allocator.create(EvmWrapper) catch {
        evm.deinit();
        memory_db.deinit();
        allocator.destroy(memory_db);
        allocator.destroy(evm);
        return null;
    };
    wrapper.* = .{ .evm = evm, .memory_db = memory_db };
    return @ptrCast(wrapper);
}

export fn zigEvmDestroy(evm_ptr: ?*anyopaque) void {
    if (evm_ptr) |ptr| {
        const wrapper: *EvmWrapper = @ptrCast(@alignCast(ptr));
        wrapper.evm.deinit();
        wrapper.memory_db.deinit();
        allocator.destroy(wrapper.evm);
        allocator.destroy(wrapper.memory_db);
        allocator.destroy(wrapper);
    }
}

export fn zigEvmCall(evm_ptr: ?*anyopaque, req: *const CCallRequest, res: *CCallResponse) c_int {
    if (evm_ptr == null) return -1;
    const wrapper: *EvmWrapper = @ptrCast(@alignCast(evm_ptr.?));

    const kind = req.kind;
    const caller = caddr_to_addr(req.caller);
    const to = caddr_to_addr(req.to);
    const value = cu256_to_u256(req.value);
    const salt = cu256_to_u256(req.salt);
    const input = cbytes_to_slice(req.input);
    const gas: u64 = req.gas;

    const params: CallParams = switch (kind) {
        .CALL => .{ .call = .{ .caller = caller, .to = to, .value = value, .input = input, .gas = gas } },
        .STATICCALL => .{ .staticcall = .{ .caller = caller, .to = to, .input = input, .gas = gas } },
        .DELEGATECALL => .{ .delegatecall = .{ .caller = caller, .to = to, .input = input, .gas = gas } },
        .CREATE => .{ .create = .{ .caller = caller, .value = value, .init_code = input, .gas = gas } },
        .CREATE2 => .{ .create2 = .{ .caller = caller, .value = value, .init_code = input, .salt = salt, .gas = gas } },
    };

    const result = wrapper.evm.call(params) catch |err| {
        _ = err;
        res.* = .{ .success = false, .gas_left = 0, .output = .{ .ptr = undefined, .len = 0 } };
        return 0;
    };

    var out_ptr: [*]u8 = undefined;
    var out_len: usize = 0;
    if (result.output) |output| {
        if (output.len > 0) {
            const duped = allocator.alloc(u8, output.len) catch {
                res.* = .{ .success = result.success, .gas_left = result.gas_left, .output = .{ .ptr = undefined, .len = 0 } };
                return 0;
            };
            @memcpy(duped, output);
            out_ptr = duped.ptr;
            out_len = duped.len;
        }
    }

    res.* = .{ .success = result.success, .gas_left = result.gas_left, .output = .{ .ptr = out_ptr, .len = out_len } };
    return 0;
}

export fn zigEvmFreeBytes(ptr: ?[*]u8, len: usize) void {
    if (ptr) |p| {
        allocator.free(p[0..len]);
    }
}
