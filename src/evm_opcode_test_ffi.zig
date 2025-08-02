const std = @import("std");
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;

// Global allocator for C FFI
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

// Wrapper structs to hold Zig objects
const EvmWrapper = struct {
    evm: *Evm.Evm,
    memory_db: *Evm.MemoryDatabase,
};

const FrameWrapper = struct {
    frame: *Evm.Frame,
    contract: *Evm.Contract,
};

// C-compatible U256 representation
const CU256 = extern struct {
    words: [4]u64,
};

fn cU256ToZig(c_value: CU256) u256 {
    // Zig uses little-endian u256 representation
    return @as(u256, c_value.words[0]) |
        (@as(u256, c_value.words[1]) << 64) |
        (@as(u256, c_value.words[2]) << 128) |
        (@as(u256, c_value.words[3]) << 192);
}

fn zigU256ToC(value: u256) CU256 {
    return CU256{
        .words = .{
            @truncate(value),
            @truncate(value >> 64),
            @truncate(value >> 128),
            @truncate(value >> 192),
        },
    };
}

export fn zigEvmCreate() ?*anyopaque {
    const memory_db = allocator.create(Evm.MemoryDatabase) catch return null;
    memory_db.* = Evm.MemoryDatabase.init(allocator);

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    const evm = allocator.create(Evm.Evm) catch {
        memory_db.deinit();
        allocator.destroy(memory_db);
        return null;
    };

    evm.* = builder.build() catch {
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

    wrapper.* = EvmWrapper{
        .evm = evm,
        .memory_db = memory_db,
    };

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

export fn zigFrameCreate(evm_ptr: ?*anyopaque) ?*anyopaque {
    if (evm_ptr) |ptr| {
        const evm_wrapper: *EvmWrapper = @ptrCast(@alignCast(ptr));

        const caller: Address.Address = [_]u8{0x11} ** 20;
        const contract_addr: Address.Address = [_]u8{0x33} ** 20;

        const contract = allocator.create(Evm.Contract) catch return null;
        contract.* = Evm.Contract.init(
            caller,
            contract_addr,
            0,
            1000,
            &[_]u8{},
            [_]u8{0} ** 32,
            &[_]u8{},
            false,
        );

        var builder = Evm.Frame.builder(allocator);
        const frame = allocator.create(Evm.Frame) catch {
            contract.deinit(allocator, null);
            allocator.destroy(contract);
            return null;
        };

        frame.* = builder
            .withVm(evm_wrapper.evm)
            .withContract(contract)
            .withGas(1000)
            .withCaller(primitives.Address.ZERO_ADDRESS)
            .build() catch {
            contract.deinit(allocator, null);
            allocator.destroy(contract);
            allocator.destroy(frame);
            return null;
        };

        const wrapper = allocator.create(FrameWrapper) catch {
            frame.deinit();
            contract.deinit(allocator, null);
            allocator.destroy(frame);
            allocator.destroy(contract);
            return null;
        };

        wrapper.* = FrameWrapper{
            .frame = frame,
            .contract = contract,
        };

        return @ptrCast(wrapper);
    }
    return null;
}

export fn zigFrameDestroy(frame_ptr: ?*anyopaque) void {
    if (frame_ptr) |ptr| {
        const wrapper: *FrameWrapper = @ptrCast(@alignCast(ptr));
        wrapper.frame.deinit();
        wrapper.contract.deinit(allocator, null);
        allocator.destroy(wrapper.frame);
        allocator.destroy(wrapper.contract);
        allocator.destroy(wrapper);
    }
}

export fn zigStackPush(frame_ptr: ?*anyopaque, value: CU256) void {
    if (frame_ptr) |ptr| {
        const wrapper: *FrameWrapper = @ptrCast(@alignCast(ptr));
        const zig_value = cU256ToZig(value);
        wrapper.frame.stack.append(zig_value) catch {
            // In real code, we'd handle this error properly
            std.debug.panic("Stack push failed\n", .{});
        };
    }
}

export fn zigStackPop(frame_ptr: ?*anyopaque) CU256 {
    if (frame_ptr) |ptr| {
        const wrapper: *FrameWrapper = @ptrCast(@alignCast(ptr));
        const value = wrapper.frame.stack.pop() catch {
            // Return 0 on error
            return zigU256ToC(0);
        };
        return zigU256ToC(value);
    }
    return zigU256ToC(0);
}

export fn zigStackSize(frame_ptr: ?*anyopaque) usize {
    if (frame_ptr) |ptr| {
        const wrapper: *FrameWrapper = @ptrCast(@alignCast(ptr));
        return wrapper.frame.stack.size();
    }
    return 0;
}

export fn zigExecuteOpcode(evm_ptr: ?*anyopaque, frame_ptr: ?*anyopaque, opcode: u8) i32 {
    if (evm_ptr) |evm_p| {
        if (frame_ptr) |frame_p| {
            const evm_wrapper: *EvmWrapper = @ptrCast(@alignCast(evm_p));
            const frame_wrapper: *FrameWrapper = @ptrCast(@alignCast(frame_p));

            const interpreter: Evm.Operation.Interpreter = evm_wrapper.evm;
            const state: Evm.Operation.State = frame_wrapper.frame;

            _ = evm_wrapper.evm.table.execute(0, interpreter, state, opcode) catch |err| {
                // Return error code based on error type
                switch (err) {
                    error.StackUnderflow => return -1,
                    error.StackOverflow => return -2,
                    error.OutOfGas => return -3,
                    error.InvalidJump => return -4,
                    error.InvalidOpcode => return -5,
                    else => return -99,
                }
            };

            return 0; // Success
        }
    }
    return -100; // Invalid pointers
}

export fn zigGetGasRemaining(frame_ptr: ?*anyopaque) u64 {
    if (frame_ptr) |ptr| {
        const wrapper: *FrameWrapper = @ptrCast(@alignCast(ptr));
        return wrapper.frame.gas_remaining;
    }
    return 0;
}

export fn zigSetGasRemaining(frame_ptr: ?*anyopaque, gas: u64) void {
    if (frame_ptr) |ptr| {
        const wrapper: *FrameWrapper = @ptrCast(@alignCast(ptr));
        wrapper.frame.gas_remaining = gas;
    }
}
