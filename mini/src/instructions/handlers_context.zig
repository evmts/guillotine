/// Execution context opcode handlers for the EVM
const std = @import("std");
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;
const Address = primitives.Address;

/// Handlers struct - provides execution context operation handlers for a Frame type
/// The FrameType must have methods: consumeGas, popStack, pushStack, writeMemory, readMemory
/// and fields: pc, address, caller, value, calldata, bytecode, return_data, hardfork
pub fn Handlers(FrameType: type) type {
    return struct {
        /// Helper function to add two u32 values with overflow checking
        inline fn add_u32(a: u32, b: u32) FrameType.EvmError!u32 {
            return std.math.add(u32, a, b) catch return error.OutOfBounds;
        }

        /// Calculate copy gas cost based on size
        fn copyGasCost(size: u32) u64 {
            const words = wordCount(@as(u64, size));
            return GasConstants.CopyGas * words;
        }

        /// Calculate number of 32-byte words needed for size bytes
        fn wordCount(size: u64) u64 {
            return (size + 31) / 32;
        }

        /// Calculate word-aligned memory size for EVM compliance
        fn wordAlignedSize(bytes: u64) u32 {
            const words = wordCount(bytes);
            return @intCast(words * 32);
        }

        /// ADDRESS opcode (0x30) - Get address of currently executing account
        pub fn address(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasQuickStep);
            const addr_u256 = primitives.Address.toU256(frame.address);
            try frame.pushStack(addr_u256);
            frame.pc += 1;
        }

        /// BALANCE opcode (0x31) - Get balance of an account
        pub fn balance(frame: *FrameType) FrameType.EvmError!void {
            const evm = frame.getEvm();
            const addr_int = try frame.popStack();
            const addr = Address.fromU256(addr_int);

            // Gas cost: hardfork-aware
            // Berlin+: cold/warm access (2600/100)
            // Istanbul-Berlin: 700 gas (EIP-1884)
            // Tangerine Whistle-Petersburg: 400 gas
            // Pre-Tangerine Whistle: 20 gas
            const access_cost: u64 = if (evm.hardfork.isAtLeast(.BERLIN))
                try evm.accessAddress(addr)
            else if (evm.hardfork.isAtLeast(.ISTANBUL))
                @as(u64, 700)
            else if (evm.hardfork.isAtLeast(.TANGERINE_WHISTLE))
                @as(u64, 400)
            else
                @as(u64, 20);
            try frame.consumeGas(access_cost);
            const bal = evm.get_balance(addr);
            try frame.pushStack(bal);
            frame.pc += 1;
        }

        /// ORIGIN opcode (0x32) - Get execution origination address
        pub fn origin(frame: *FrameType) FrameType.EvmError!void {
            const evm = frame.getEvm();
            try frame.consumeGas(GasConstants.GasQuickStep);
            const origin_u256 = primitives.Address.toU256(evm.origin);
            try frame.pushStack(origin_u256);
            frame.pc += 1;
        }

        /// CALLER opcode (0x33) - Get caller address
        pub fn caller(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasQuickStep);
            const caller_u256 = primitives.Address.toU256(frame.caller);
            try frame.pushStack(caller_u256);
            frame.pc += 1;
        }

        /// CALLVALUE opcode (0x34) - Get deposited value by instruction/transaction responsible for this execution
        pub fn callvalue(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasQuickStep);
            try frame.pushStack(frame.value);
            frame.pc += 1;
        }

        /// CALLDATALOAD opcode (0x35) - Get input data of current environment
        pub fn calldataload(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasFastestStep);
            const offset = try frame.popStack();
            if (offset > std.math.maxInt(u32)) {
                try frame.pushStack(0);
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
                try frame.pushStack(result);
            }
            frame.pc += 1;
        }

        /// CALLDATASIZE opcode (0x36) - Get size of input data in current environment
        pub fn calldatasize(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasQuickStep);
            try frame.pushStack(frame.calldata.len);
            frame.pc += 1;
        }

        /// CALLDATACOPY opcode (0x37) - Copy input data in current environment to memory
        pub fn calldatacopy(frame: *FrameType) FrameType.EvmError!void {
            const dest_offset = try frame.popStack();
            const offset = try frame.popStack();
            const length = try frame.popStack();

            const dest_off = std.math.cast(u32, dest_offset) orelse return error.OutOfBounds;
            const src_off = std.math.cast(u32, offset) orelse return error.OutOfBounds;
            const len = std.math.cast(u32, length) orelse return error.OutOfBounds;

            // Charge base + memory expansion + copy per word
            const end_bytes_copy: u64 = @as(u64, dest_off) + @as(u64, len);
            const mem_cost4 = frame.memoryExpansionCost(end_bytes_copy);
            const copy_cost = copyGasCost(len);
            try frame.consumeGas(GasConstants.GasFastestStep + mem_cost4 + copy_cost);

            // Copy calldata to memory
            var i: u32 = 0;
            while (i < len) : (i += 1) {
                const src_idx_u32 = try add_u32(src_off, i);
                const src_idx: usize = @intCast(src_idx_u32);
                const byte = if (src_idx < frame.calldata.len) frame.calldata[src_idx] else 0;
                const dst_idx = try add_u32(dest_off, i);
                try frame.writeMemory(dst_idx, byte);
            }
            frame.pc += 1;
        }

        /// CODESIZE opcode (0x38) - Get size of code running in current environment
        pub fn codesize(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasQuickStep);
            try frame.pushStack(frame.bytecode.len());
            frame.pc += 1;
        }

        /// CODECOPY opcode (0x39) - Copy code running in current environment to memory
        pub fn codecopy(frame: *FrameType) FrameType.EvmError!void {
            const dest_offset = try frame.popStack();
            const offset = try frame.popStack();
            const length = try frame.popStack();

            const dest_off = std.math.cast(u32, dest_offset) orelse return error.OutOfBounds;
            const src_off = std.math.cast(u32, offset) orelse return error.OutOfBounds;
            const len = std.math.cast(u32, length) orelse return error.OutOfBounds;

            const end_bytes_code: u64 = @as(u64, dest_off) + @as(u64, len);
            const mem_cost5 = frame.memoryExpansionCost(end_bytes_code);
            const copy_cost = copyGasCost(len);
            try frame.consumeGas(GasConstants.GasFastestStep + mem_cost5 + copy_cost);

            // Copy code to memory
            var i: u32 = 0;
            while (i < len) : (i += 1) {
                const src_idx_u32 = try add_u32(src_off, i);
                const byte = frame.bytecode.getOpcode(src_idx_u32) orelse 0;
                const dst_idx = try add_u32(dest_off, i);
                try frame.writeMemory(dst_idx, byte);
            }
            frame.pc += 1;
        }

        /// GASPRICE opcode (0x3a) - Get price of gas in current environment
        pub fn gasprice(frame: *FrameType) FrameType.EvmError!void {
            const evm = frame.getEvm();
            try frame.consumeGas(GasConstants.GasQuickStep);
            try frame.pushStack(evm.gas_price);
            frame.pc += 1;
        }

        /// EXTCODESIZE opcode (0x3b) - Get size of an account's code
        pub fn extcodesize(frame: *FrameType) FrameType.EvmError!void {
            const evm = frame.getEvm();
            // Get code size of external account
            const addr_int = try frame.popStack();
            const ext_addr = primitives.Address.fromU256(addr_int);

            // Gas cost: hardfork-aware
            // Berlin+: cold/warm access (2600/100)
            // Istanbul-Berlin: 700 gas (EIP-1884)
            // Tangerine Whistle-Istanbul: 700 gas (EIP-150)
            // Pre-Tangerine Whistle: 20 gas
            const access_cost: u64 = if (evm.hardfork.isAtLeast(.BERLIN))
                try evm.accessAddress(ext_addr)
            else if (evm.hardfork.isAtLeast(.TANGERINE_WHISTLE))
                @as(u64, 700)
            else
                @as(u64, 20);
            try frame.consumeGas(access_cost);

            // Get the code from the external address
            const code = if (evm.host) |h| h.getCode(ext_addr) else evm.code.get(ext_addr) orelse &[_]u8{};
            try frame.pushStack(code.len);
            frame.pc += 1;
        }

        /// EXTCODECOPY opcode (0x3c) - Copy an account's code to memory
        pub fn extcodecopy(frame: *FrameType) FrameType.EvmError!void {
            const evm = frame.getEvm();
            // Copy external account code to memory
            const addr_int = try frame.popStack();
            const dest_offset = try frame.popStack();
            const offset = try frame.popStack();
            const size = try frame.popStack();

            const ext_addr = primitives.Address.fromU256(addr_int);
            const dest = std.math.cast(u32, dest_offset) orelse return error.OutOfBounds;
            const off = std.math.cast(u32, offset) orelse return error.OutOfBounds;
            const len = std.math.cast(u32, size) orelse return error.OutOfBounds;

            // Calculate ALL gas costs at once: access + copy + memory expansion
            // Gas cost: hardfork-aware
            // Berlin+: cold/warm access (2600/100)
            // Tangerine Whistle-Berlin: 700 gas (EIP-150)
            // Pre-Tangerine Whistle: 20 gas
            const access_cost: u64 = if (evm.hardfork.isAtLeast(.BERLIN))
                try evm.accessAddress(ext_addr)
            else if (evm.hardfork.isAtLeast(.TANGERINE_WHISTLE))
                @as(u64, 700)
            else
                @as(u64, 20);

            const copy_cost = copyGasCost(len);
            const end_bytes: u64 = @as(u64, dest) + @as(u64, len);
            const mem_cost = frame.memoryExpansionCost(end_bytes);

            // Charge all costs at once
            try frame.consumeGas(access_cost + copy_cost + mem_cost);

            // Get the code from the external address
            const code = if (evm.host) |h| h.getCode(ext_addr) else evm.code.get(ext_addr) orelse &[_]u8{};

            // Copy code to memory
            var i: u32 = 0;
            while (i < len) : (i += 1) {
                const dst_idx = try add_u32(dest, i);
                const src_idx = off + i;
                // If src_idx is beyond the code length, write 0 (per EVM spec)
                const byte = if (src_idx < code.len) code[src_idx] else 0;
                try frame.writeMemory(dst_idx, byte);
            }
            frame.pc += 1;
        }

        /// RETURNDATASIZE opcode (0x3d) - Get size of output data from the previous call
        pub fn returndatasize(frame: *FrameType) FrameType.EvmError!void {
            const evm = frame.getEvm();
            // EIP-211: RETURNDATASIZE was introduced in Byzantium hardfork
            if (evm.hardfork.isBefore(.BYZANTIUM)) return error.InvalidOpcode;

            try frame.consumeGas(GasConstants.GasQuickStep);
            try frame.pushStack(frame.return_data.len);
            frame.pc += 1;
        }

        /// RETURNDATACOPY opcode (0x3e) - Copy output data from the previous call to memory
        pub fn returndatacopy(frame: *FrameType) FrameType.EvmError!void {
            const evm = frame.getEvm();
            // EIP-211: RETURNDATACOPY was introduced in Byzantium hardfork
            if (evm.hardfork.isBefore(.BYZANTIUM)) return error.InvalidOpcode;

            const dest_offset = try frame.popStack();
            const offset = try frame.popStack();
            const length = try frame.popStack();

            const dest_off = std.math.cast(u32, dest_offset) orelse return error.OutOfBounds;
            const src_off = std.math.cast(u32, offset) orelse return error.OutOfBounds;
            const len = std.math.cast(u32, length) orelse return error.OutOfBounds;

            // Check bounds with overflow-safety
            const rd_len: usize = frame.return_data.len;
            const src_usize: usize = @intCast(src_off);
            const len_usize: usize = @intCast(len);
            if (src_usize > rd_len or len_usize > rd_len - src_usize) {
                return error.OutOfBounds;
            }

            const end_bytes_ret: u64 = @as(u64, dest_off) + @as(u64, len);
            const mem_cost6 = frame.memoryExpansionCost(end_bytes_ret);
            const copy_cost = copyGasCost(len);
            try frame.consumeGas(GasConstants.GasFastestStep + mem_cost6 + copy_cost);

            // Update memory size after charging for expansion
            const aligned_ret = wordAlignedSize(end_bytes_ret);
            if (aligned_ret > frame.memory_size) frame.memory_size = aligned_ret;

            // Copy return data to memory
            var i: u32 = 0;
            while (i < len) : (i += 1) {
                const src_idx = @as(usize, @intCast(src_off)) + @as(usize, @intCast(i));
                const byte = frame.return_data[src_idx];
                const dst_idx = try add_u32(dest_off, i);
                try frame.writeMemory(dst_idx, byte);
            }
            frame.pc += 1;
        }

        /// EXTCODEHASH opcode (0x3f) - Get hash of an account's code
        pub fn extcodehash(frame: *FrameType) FrameType.EvmError!void {
            const evm = frame.getEvm();
            // EIP-1052: EXTCODEHASH opcode was introduced in Constantinople hardfork
            if (evm.hardfork.isBefore(.CONSTANTINOPLE)) return error.InvalidOpcode;

            // Get code hash of external account
            const addr_int = try frame.popStack();
            const ext_addr = primitives.Address.fromU256(addr_int);

            // Gas cost: hardfork-aware
            // Berlin+: cold/warm access (2600/100)
            // Istanbul-Berlin: 700 gas (EIP-1884)
            // Constantinople-Petersburg: 400 gas
            const access_cost: u64 = if (evm.hardfork.isAtLeast(.BERLIN))
                try evm.accessAddress(ext_addr)
            else if (evm.hardfork.isAtLeast(.ISTANBUL))
                @as(u64, 700)
            else
                @as(u64, 400);
            try frame.consumeGas(access_cost);

            // Get the code from the external address
            const code = if (evm.host) |h| h.getCode(ext_addr) else evm.code.get(ext_addr) orelse &[_]u8{};

            if (code.len == 0) {
                // Return 0 for empty accounts (no code)
                try frame.pushStack(0);
            } else {
                // Compute keccak256 hash of the code
                var hash: [32]u8 = undefined;
                std.crypto.hash.sha3.Keccak256.hash(code, &hash, .{});

                // Convert hash bytes to u256 (big-endian)
                var hash_u256: u256 = 0;
                for (hash) |byte| {
                    hash_u256 = (hash_u256 << 8) | byte;
                }
                try frame.pushStack(hash_u256);
            }
            frame.pc += 1;
        }

        /// GAS opcode (0x5a) - Get the amount of available gas
        pub fn gas(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasQuickStep);
            try frame.pushStack(@intCast(frame.gas_remaining));
            frame.pc += 1;
        }
    };
}
