/// Shared context instruction implementations
/// Phase 2.3 - Generic over FrameType, no static gas charging, no PC manipulation
///
/// Source of truth: guillotine-mini/src/instructions/handlers_context.zig
/// These implementations access execution context - caller must handle gas and PC

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const GasConstants = primitives.GasConstants;

/// Helper: Calculate copy gas cost based on size
fn copyGasCost(size: u32) u64 {
    const words = (@as(u64, size) + 31) / 32;
    return GasConstants.CopyGas * words;
}

/// Helper: Safe add for u32 indices
inline fn add_u32(a: u32, b: u32) error{OutOfBounds}!u32 {
    return std.math.add(u32, a, b) catch return error.OutOfBounds;
}

/// ADDRESS opcode (0x30) - Get address of currently executing account
pub fn AddressInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const addr_u256 = primitives.Address.toU256(frame.address);
            try frame.stack.push(addr_u256);
        }
    };
}

/// BALANCE opcode (0x31) - Get balance of an account
/// Note: Caller must charge hardfork-aware access cost (cold/warm)
/// This is a stub - requires EVM integration
pub fn BalanceInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const addr_int = try frame.stack.pop();
            const addr = Address.fromU256(addr_int);

            // Dynamic gas cost: hardfork-aware (caller handles)
            // Berlin+: cold/warm access via evm.accessAddress(addr)
            // Istanbul-Berlin: 700 gas
            // Tangerine Whistle-Petersburg: 400 gas
            // Pre-Tangerine Whistle: 20 gas

            // Stub: Get balance from EVM (would use frame.getEvm().get_balance(addr))
            _ = addr;
            const bal: u256 = 0; // TODO: Implement via frame.getEvm()
            try frame.stack.push(bal);
        }
    };
}

/// ORIGIN opcode (0x32) - Get execution origination address
/// Note: Requires EVM integration for tx.origin
pub fn OriginInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            // Stub: Get origin from EVM (would use frame.getEvm().origin)
            const origin_u256 = primitives.Address.toU256(Address.zero());
            try frame.stack.push(origin_u256);
        }
    };
}

/// CALLER opcode (0x33) - Get caller address
pub fn CallerInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const caller_u256 = primitives.Address.toU256(frame.caller);
            try frame.stack.push(caller_u256);
        }
    };
}

/// CALLVALUE opcode (0x34) - Get deposited value by instruction/transaction responsible for this execution
pub fn CallvalueInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            try frame.stack.push(frame.value);
        }
    };
}

/// CALLDATALOAD opcode (0x35) - Get input data of current environment
pub fn CalldataloadInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const offset = try frame.stack.pop();
            if (offset > std.math.maxInt(u32)) {
                try frame.stack.push(0);
            } else {
                const off = @as(u32, @intCast(offset));
                var result: u256 = 0;
                var i: u32 = 0;
                while (i < 32) : (i += 1) {
                    const idx_u32 = try add_u32(off, i);
                    const idx: usize = @intCast(idx_u32);
                    const byte = if (idx < frame.calldata.len) frame.calldata[idx] else 0;
                    result = (result << 8) | byte;
                }
                try frame.stack.push(result);
            }
        }
    };
}

/// CALLDATASIZE opcode (0x36) - Get size of input data in current environment
pub fn CalldasizeInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            try frame.stack.push(frame.calldata.len);
        }
    };
}

/// CALLDATACOPY opcode (0x37) - Copy input data in current environment to memory
/// Note: Caller must charge: GasFastestStep + mem_expansion_cost + copy_cost
pub fn CalldatacopyInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const dest_offset = try frame.stack.pop();
            const offset = try frame.stack.pop();
            const length = try frame.stack.pop();

            const dest_off = std.math.cast(u32, dest_offset) orelse return error.OutOfBounds;
            const src_off = std.math.cast(u32, offset) orelse return error.OutOfBounds;
            const len = std.math.cast(u32, length) orelse return error.OutOfBounds;

            // Dynamic gas: memory expansion + copy per word
            const end_bytes_copy: u64 = @as(u64, dest_off) + @as(u64, len);
            const mem_cost = frame.memoryExpansionCost(end_bytes_copy);
            const copy_cost = copyGasCost(len);
            try frame.consumeGas(mem_cost + copy_cost);

            // Copy calldata to memory
            var i: u32 = 0;
            while (i < len) : (i += 1) {
                const src_idx_u32 = try add_u32(src_off, i);
                const src_idx: usize = @intCast(src_idx_u32);
                const byte = if (src_idx < frame.calldata.len) frame.calldata[src_idx] else 0;
                const dst_idx = try add_u32(dest_off, i);
                try frame.writeMemory(dst_idx, byte);
            }
        }
    };
}

/// CODESIZE opcode (0x38) - Get size of code running in current environment
pub fn CodesizeInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            try frame.stack.push(frame.bytecode.len);
        }
    };
}

/// CODECOPY opcode (0x39) - Copy code running in current environment to memory
/// Note: Caller must charge: GasFastestStep + mem_expansion_cost + copy_cost
pub fn CodecopyInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const dest_offset = try frame.stack.pop();
            const offset = try frame.stack.pop();
            const length = try frame.stack.pop();

            const dest_off = std.math.cast(u32, dest_offset) orelse return error.OutOfBounds;
            const src_off = std.math.cast(u32, offset) orelse return error.OutOfBounds;
            const len = std.math.cast(u32, length) orelse return error.OutOfBounds;

            // Dynamic gas: memory expansion + copy per word
            const end_bytes_code: u64 = @as(u64, dest_off) + @as(u64, len);
            const mem_cost = frame.memoryExpansionCost(end_bytes_code);
            const copy_cost = copyGasCost(len);
            try frame.consumeGas(mem_cost + copy_cost);

            // Copy code to memory
            var i: u32 = 0;
            while (i < len) : (i += 1) {
                const src_idx_u32 = try add_u32(src_off, i);
                const src_idx: usize = @intCast(src_idx_u32);
                const byte = if (src_idx < frame.bytecode.len) frame.bytecode[src_idx] else 0;
                const dst_idx = try add_u32(dest_off, i);
                try frame.writeMemory(dst_idx, byte);
            }
        }
    };
}

/// GASPRICE opcode (0x3a) - Get price of gas in current environment
/// Note: Requires EVM integration for tx.gasprice
pub fn GaspriceInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            // Stub: Get gas price from EVM (would use frame.getEvm().gas_price)
            const gas_price: u256 = 0; // TODO: Implement via frame.getEvm()
            try frame.stack.push(gas_price);
        }
    };
}

/// EXTCODESIZE opcode (0x3b) - Get size of an account's code
/// Note: Caller must charge hardfork-aware access cost
/// This is a stub - requires EVM integration
pub fn ExtcodesizeInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const addr_int = try frame.stack.pop();
            const ext_addr = Address.fromU256(addr_int);

            // Dynamic gas cost: hardfork-aware (caller handles)
            // Berlin+: cold/warm access via evm.accessAddress(ext_addr)
            // Tangerine Whistle+: 700 gas
            // Pre-Tangerine Whistle: 20 gas

            // Stub: Get code from EVM
            _ = ext_addr;
            const code_size: u256 = 0; // TODO: Implement via frame.getEvm()
            try frame.stack.push(code_size);
        }
    };
}

/// EXTCODECOPY opcode (0x3c) - Copy an account's code to memory
/// Note: Caller must charge hardfork-aware access cost + memory + copy cost
/// This is a stub - requires EVM integration
pub fn ExtcodecopyInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const addr_int = try frame.stack.pop();
            const dest_offset = try frame.stack.pop();
            const offset = try frame.stack.pop();
            const size = try frame.stack.pop();

            const ext_addr = Address.fromU256(addr_int);
            const dest = std.math.cast(u32, dest_offset) orelse return error.OutOfBounds;
            const off = std.math.cast(u32, offset) orelse return error.OutOfBounds;
            const len = std.math.cast(u32, size) orelse return error.OutOfBounds;

            // Dynamic gas cost: hardfork-aware access + memory expansion + copy
            const end_bytes: u64 = @as(u64, dest) + @as(u64, len);
            const mem_cost = frame.memoryExpansionCost(end_bytes);
            const copy_cost = copyGasCost(len);
            try frame.consumeGas(mem_cost + copy_cost);

            // Stub: Copy external code to memory
            _ = ext_addr;
            _ = off;
            var i: u32 = 0;
            while (i < len) : (i += 1) {
                const byte: u8 = 0; // TODO: Get from frame.getEvm().getCode(ext_addr)
                const dst_idx = try add_u32(dest, i);
                try frame.writeMemory(dst_idx, byte);
            }
        }
    };
}

/// RETURNDATASIZE opcode (0x3d) - Get size of output data from the previous call
pub fn ReturndatasizeInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            try frame.stack.push(frame.return_data.len);
        }
    };
}

/// RETURNDATACOPY opcode (0x3e) - Copy output data from the previous call to memory
/// Note: Caller must charge: GasFastestStep + mem_expansion_cost + copy_cost
pub fn ReturndatacopyInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const dest_offset = try frame.stack.pop();
            const offset = try frame.stack.pop();
            const length = try frame.stack.pop();

            const dest_off = std.math.cast(u32, dest_offset) orelse return error.OutOfBounds;
            const src_off = std.math.cast(u32, offset) orelse return error.OutOfBounds;
            const len = std.math.cast(u32, length) orelse return error.OutOfBounds;

            // Check bounds: offset + length must not exceed return_data size
            const end_offset: u64 = @as(u64, src_off) + @as(u64, len);
            if (end_offset > frame.return_data.len) {
                return error.ReturnDataOutOfBounds;
            }

            // Dynamic gas: memory expansion + copy per word
            const end_bytes: u64 = @as(u64, dest_off) + @as(u64, len);
            const mem_cost = frame.memoryExpansionCost(end_bytes);
            const copy_cost = copyGasCost(len);
            try frame.consumeGas(mem_cost + copy_cost);

            // Copy return data to memory
            var i: u32 = 0;
            while (i < len) : (i += 1) {
                const src_idx_u32 = try add_u32(src_off, i);
                const src_idx: usize = @intCast(src_idx_u32);
                const byte = frame.return_data[src_idx];
                const dst_idx = try add_u32(dest_off, i);
                try frame.writeMemory(dst_idx, byte);
            }
        }
    };
}

/// EXTCODEHASH opcode (0x3f) - Get hash of an account's code
/// Note: Caller must charge hardfork-aware access cost
/// This is a stub - requires EVM integration
pub fn ExtcodehashInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const addr_int = try frame.stack.pop();
            const ext_addr = Address.fromU256(addr_int);

            // Dynamic gas cost: hardfork-aware (caller handles)
            // Berlin+: cold/warm access via evm.accessAddress(ext_addr)
            // Constantinople+: 700 gas (before Berlin)

            // Stub: Get code hash from EVM
            _ = ext_addr;
            const code_hash: u256 = 0; // TODO: Implement via frame.getEvm()
            try frame.stack.push(code_hash);
        }
    };
}

/// GAS opcode (0x5a) - Get the amount of available gas
pub fn GasInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            // Return current gas remaining (caller handles static gas cost)
            const gas_remaining: u256 = if (frame.gas_remaining >= 0)
                @intCast(frame.gas_remaining)
            else
                0;
            try frame.stack.push(gas_remaining);
        }
    };
}
