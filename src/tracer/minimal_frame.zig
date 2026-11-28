/// Minimal Frame implementation for tracing
/// This mirrors the architecture of frame/frame.zig but simplified for validation
const std = @import("std");
const primitives = @import("voltaire");
const minimal_evm_mod = @import("minimal_evm.zig");
const GasConstants = primitives.GasConstants;
const Address = primitives.Address.Address;
const MinimalEvm = minimal_evm_mod.MinimalEvm;
const MinimalEvmError = MinimalEvm.Error;
const Hardfork = @import("../eips_and_hardforks/eips.zig").Hardfork;
const fork_gas = @import("../frame/fork_gas.zig");
const block_info = @import("../block/block_info.zig");

pub const MinimalFrame = struct {
    const Self = @This();

    // Stack
    stack: std.ArrayList(u256),

    // Memory
    memory: std.AutoHashMap(u32, u8),
    memory_size: u32,

    // Execution state
    pc: u32,
    gas_remaining: i64,
    bytecode: []const u8,

    // Valid jump destinations for JUMP/JUMPI
    valid_jumpdests: std.array_hash_map.Auto(u32, void),

    // Call context
    caller: Address,
    address: Address,
    value: u256,
    calldata: []const u8,

    // Output
    output: []u8,
    return_data: []const u8,

    // Execution status
    stopped: bool,
    reverted: bool,

    /// True when the frame runs in a static context (EIP-214): it was entered by
    /// STATICCALL, or by a call from a frame that was. State changes are forbidden.
    is_static: bool,

    // Reference to MinimalEvm (like Frame has evm_ptr)
    evm_ptr: *anyopaque,

    // Allocator for frame operations
    allocator: std.mem.Allocator,

    // EIP-3074 AUTH state
    call_depth: u32,

    // Active hardfork configuration for gas rules
    hardfork: Hardfork,

    /// Analyze bytecode to identify valid JUMPDEST locations
    fn validateJumpDests(
        allocator: std.mem.Allocator,
        bytecode: []const u8,
        valid_jumpdests: *std.array_hash_map.Auto(u32, void),
    ) !void {
        var pc: u32 = 0;
        while (pc < bytecode.len) {
            const opcode = bytecode[pc];

            // Check if this is a JUMPDEST
            if (opcode == 0x5b) {
                try valid_jumpdests.put(allocator, pc, {});
                pc += 1;
            } else if (opcode >= 0x60 and opcode <= 0x7f) {
                // PUSH1 through PUSH32
                const push_size = opcode - 0x5f; // Number of bytes to push
                // Skip the PUSH opcode and its immediate data
                pc += 1 + push_size;
            } else {
                pc += 1;
            }
        }
    }

    /// Initialize a new frame
    pub fn init(
        allocator: std.mem.Allocator,
        bytecode: []const u8,
        gas: i64,
        caller: Address,
        address: Address,
        value: u256,
        calldata: []const u8,
        evm_ptr: *anyopaque,
        hardfork: Hardfork,
    ) !Self {
        var stack = std.ArrayList(u256).empty;
        try stack.ensureTotalCapacity(allocator, 1024);
        errdefer stack.deinit(allocator);

        var memory_map = std.AutoHashMap(u32, u8).init(allocator);
        errdefer memory_map.deinit();

        // Analyze bytecode to identify valid jump destinations
        var valid_jumpdests: std.array_hash_map.Auto(u32, void) = .empty;
        errdefer valid_jumpdests.deinit(allocator);
        try validateJumpDests(allocator, bytecode, &valid_jumpdests);

        return Self{
            .stack = stack,
            .memory = memory_map,
            .memory_size = 0,
            .pc = 0,
            .gas_remaining = gas,
            .bytecode = bytecode,
            .valid_jumpdests = valid_jumpdests,
            .caller = caller,
            .address = address,
            .value = value,
            .calldata = calldata,
            .output = &[_]u8{},
            .return_data = &[_]u8{},
            .stopped = false,
            .reverted = false,
            .is_static = false,
            .evm_ptr = evm_ptr,
            .allocator = allocator,
            .call_depth = 0,
            .hardfork = hardfork,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        // Note: When using arena allocator from MinimalEvm, this becomes a no-op
        // The arena will clean up all memory at once when MinimalEvm is destroyed
        self.stack.deinit(self.allocator);
        self.memory.deinit();
        self.valid_jumpdests.deinit(self.allocator);
        // No need to free output or return_data when using arena
    }

    /// Get the MinimalEvm instance
    pub fn getEvm(self: *Self) *MinimalEvm {
        return @as(*MinimalEvm, @ptrCast(@alignCast(self.evm_ptr)));
    }

    /// Push value onto stack
    pub fn pushStack(self: *Self, value: u256) MinimalEvmError!void {
        if (self.stack.items.len >= 1024) {
            return error.StackOverflow;
        }
        try self.stack.append(self.allocator, value);
    }

    /// Pop value from stack
    pub fn popStack(self: *Self) MinimalEvmError!u256 {
        if (self.stack.items.len == 0) {
            return error.StackUnderflow;
        }
        const value = self.stack.items[self.stack.items.len - 1];
        self.stack.items.len -= 1;
        return value;
    }

    /// Peek at top of stack
    pub fn peekStack(self: *const Self, index: usize) MinimalEvmError!u256 {
        if (index >= self.stack.items.len) {
            return error.StackUnderflow;
        }
        return self.stack.items[self.stack.items.len - 1 - index];
    }

    /// Number of 32-byte words that cover `bytes`. Cannot overflow for any u64.
    inline fn wordCount(bytes: u64) u64 {
        return bytes / 32 + @intFromBool(bytes % 32 != 0);
    }

    /// Word-aligned memory size that covers `bytes`. MinimalFrame addresses memory
    /// with 32 bits; a larger size costs more gas than any transaction can carry.
    fn wordAlignedSize(bytes: u64) MinimalEvmError!u32 {
        const aligned = std.math.mul(u64, wordCount(bytes), 32) catch return error.OutOfBounds;
        return std.math.cast(u32, aligned) orelse error.OutOfBounds;
    }

    /// Grow the memory size to cover [0, end). The expansion gas is charged by the caller.
    fn expandMemoryTo(self: *Self, end: u64) MinimalEvmError!void {
        if (end == 0) return;
        const aligned_size = try wordAlignedSize(end);
        if (aligned_size > self.memory_size) self.memory_size = aligned_size;
    }

    /// Read byte from memory
    pub fn readMemory(self: *Self, offset: u32) u8 {
        return self.memory.get(offset) orelse 0;
    }

    /// Write byte to memory
    pub fn writeMemory(self: *Self, offset: u32, value: u8) MinimalEvmError!void {
        // EVM memory expands to word-aligned (32-byte) boundaries. Checked before the
        // write so that the last addressable word cannot push the size past 32 bits.
        const word_aligned_size = try wordAlignedSize(@as(u64, offset) + 1);
        try self.memory.put(offset, value);
        if (word_aligned_size > self.memory_size) self.memory_size = word_aligned_size;
    }

    /// Get current opcode
    pub fn getCurrentOpcode(self: *const Self) ?u8 {
        if (self.pc >= self.bytecode.len) {
            return null;
        }
        return self.bytecode[self.pc];
    }

    /// Read immediate data for PUSH operations
    pub fn readImmediate(self: *const Self, size: u8) ?u256 {
        if (self.pc + 1 + size > self.bytecode.len) {
            return null;
        }

        var result: u256 = 0;
        var i: u8 = 0;
        while (i < size) : (i += 1) {
            result = (result << 8) | self.bytecode[self.pc + 1 + i];
        }
        return result;
    }

    /// ----------------------------------- GAS ---------------------------------- ///
    /// Consume gas
    pub fn consumeGas(self: *Self, amount: u64) MinimalEvmError!void {
        // An amount beyond i64 is more than any frame holds.
        const charge = std.math.cast(i64, amount) orelse {
            self.gas_remaining = 0;
            return error.OutOfGas;
        };
        if (self.gas_remaining < charge) {
            self.gas_remaining = 0;
            return error.OutOfGas;
        }
        self.gas_remaining -= charge;
    }

    /// Calculate memory expansion cost
    /// The total memory cost for n words is: 3n + n²/512, where a word is 32 bytes.
    fn memoryExpansionCost(self: *const Self, end_bytes: u64) u64 {
        const current_size = @as(u64, self.memory_size);

        if (end_bytes <= current_size) return 0;

        return memoryCost(wordCount(end_bytes)) -| memoryCost(wordCount(current_size));
    }

    /// Total memory cost of `words` words: 3n + n²/512. Saturates at the u64
    /// maximum, which no frame can pay, instead of overflowing.
    fn memoryCost(words: u64) u64 {
        const square = std.math.mul(u64, words, words) catch return std.math.maxInt(u64);
        return (GasConstants.MemoryGas *| words) +| square / GasConstants.QuadCoeffDiv;
    }

    /// Calculate memory expansion cost for CALL family opcodes
    /// Must consider BOTH input and return memory regions and charge for the maximum
    fn callMemoryExpansionCost(self: *const Self, in_offset: u64, in_size: u64, out_offset: u64, out_size: u64) !u64 {
        // Calculate end addresses with overflow protection
        const in_end = if (in_size > 0) blk: {
            const result = std.math.add(u64, in_offset, in_size) catch return error.OutOfBounds;
            break :blk result;
        } else 0;

        const out_end = if (out_size > 0) blk: {
            const result = std.math.add(u64, out_offset, out_size) catch return error.OutOfBounds;
            break :blk result;
        } else 0;

        // Take maximum of both regions to get the new memory size
        const max_end = @max(in_end, out_end);

        // Calculate expansion cost from current size to max_end
        return self.memoryExpansionCost(max_end);
    }

    /// Calculate gas cost for external account operations (EIP-150 aware)
    fn externalAccountGasCost(self: *Self, address: Address) !u64 {
        const evm = self.getEvm();

        if (self.hardfork.isAtLeast(.BERLIN)) {
            // Post-Berlin: Cold/warm access pattern
            @branchHint(.likely);
            return try evm.access_address(address);
        } else if (self.hardfork.isAtLeast(.TANGERINE_WHISTLE)) {
            // Post-EIP-150, Pre-Berlin: Fixed higher cost
            return GasConstants.GasExtStep;
        } else {
            // Pre-EIP-150: Lower cost
            return GasConstants.GasQuickStep;
        }
    }

    /// Calculate SELFDESTRUCT gas cost (EIP-150 aware)
    fn selfdestructGasCost(self: *const Self) u64 {
        if (self.hardfork.isBefore(.TANGERINE_WHISTLE)) {
            @branchHint(.cold);
            return 0; // Pre-EIP-150: Free operation
        }
        return GasConstants.SelfdestructGas; // Post-EIP-150: 5000 gas
    }

    /// Calculate SELFDESTRUCT refund (EIP-3529 aware)
    fn selfdestructRefund(self: *const Self) u64 {
        if (self.hardfork.isAtLeast(.LONDON)) {
            @branchHint(.likely);
            return 0; // EIP-3529: No refund in London+
        }
        return GasConstants.SelfdestructRefundGas; // Pre-London: 24,000 refund
    }

    /// Calculate CREATE gas cost (EIP-3860 aware)
    fn createGasCost(self: *const Self, init_code_size: u32) u64 {
        var gas_cost: u64 = GasConstants.CreateGas; // Base 32,000 gas

        if (self.hardfork.isAtLeast(.SHANGHAI)) {
            @branchHint(.likely);
            const word_count = wordCount(@as(u64, init_code_size));
            gas_cost += word_count * GasConstants.InitcodeWordGas;
        }

        return gas_cost;
    }

    /// Calculate CREATE2 gas cost (EIP-3860 aware)
    fn create2GasCost(self: *const Self, init_code_size: u32) u64 {
        var gas_cost: u64 = GasConstants.CreateGas; // Base 32,000 gas

        // Keccak256 hash cost (always present for CREATE2)
        const word_count = wordCount(@as(u64, init_code_size));
        gas_cost += word_count * GasConstants.Keccak256WordGas;

        if (self.hardfork.isAtLeast(.SHANGHAI)) {
            // Additional init code word cost
            @branchHint(.likely);
            gas_cost += word_count * GasConstants.InitcodeWordGas;
        }

        return gas_cost;
    }

    /// Calculate KECCAK256 gas cost (replaces manual calculation)
    fn keccak256GasCost(data_size: u32) u64 {
        const words = wordCount(@as(u64, data_size));
        return GasConstants.Keccak256Gas + words * GasConstants.Keccak256WordGas;
    }

    /// Calculate copy operation gas cost (replaces manual calculations)
    fn copyGasCost(size: u32) u64 {
        const words = wordCount(@as(u64, size));
        return GasConstants.CopyGas * words;
    }

    /// Calculate LOG operation gas cost (replaces manual calculation)
    fn logGasCost(topic_count: u8, data_size: u32) u64 {
        const base_cost = GasConstants.LogGas;
        const topic_cost = @as(u64, topic_count) * GasConstants.LogTopicGas;
        const data_cost = @as(u64, data_size) * GasConstants.LogDataGas;
        return base_cost + topic_cost + data_cost;
    }

    /// Shared body of CALLDATACOPY, CODECOPY, RETURNDATACOPY and EXTCODECOPY once
    /// their operands are popped: charge `base_gas`, the copy cost and the memory
    /// expansion, then copy `length` bytes of `source` from `offset` to memory at
    /// `dest_offset`. Source bytes past the end read as zero. A zero length touches
    /// no memory, so any `dest_offset` and `offset` are valid then.
    fn copyToMemory(
        self: *Self,
        source: []const u8,
        dest_offset: u256,
        offset: u256,
        length: u256,
        base_gas: u64,
    ) MinimalEvmError!void {
        const len = std.math.cast(u32, length) orelse return error.OutOfBounds;
        if (len == 0) return self.consumeGas(base_gas);

        const dest = std.math.cast(u32, dest_offset) orelse return error.OutOfBounds;
        const end: u64 = @as(u64, dest) + @as(u64, len);
        try self.consumeGas(base_gas +| self.memoryExpansionCost(end) +| copyGasCost(len));
        try self.expandMemoryTo(end);

        // Saturated so that a source offset beyond the address space reads zeros.
        const start = std.math.cast(usize, offset) orelse std.math.maxInt(usize);
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            const index = start +| i;
            try self.writeMemory(dest + i, if (index < source.len) source[index] else 0);
        }
    }

    /// Copy `len` bytes of memory starting at `offset` into a new buffer. The range
    /// must already be covered by `expandMemoryTo`.
    fn readMemoryRange(self: *Self, offset: u256, len: u32) MinimalEvmError![]u8 {
        const data = try self.allocator.alloc(u8, len);
        if (len == 0) return data;
        const start = std.math.cast(u32, offset) orelse return error.OutOfBounds;
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            data[i] = self.readMemory(start + i);
        }
        return data;
    }

    /// Gas a call or creation hands to the new frame out of the gas left. A call
    /// requests an amount; a creation (`requested == null`) takes all it may. EIP-150
    /// (Tangerine Whistle+) caps both at all but one 64th of the gas left. Earlier
    /// forks forward a request as is and run out of gas when it exceeds what is left.
    fn forwardedGas(self: *Self, requested: ?u64) MinimalEvmError!u64 {
        const remaining: u64 = @intCast(@max(self.gas_remaining, 0));
        const limit = if (fork_gas.hasAllButOne64th(self.hardfork)) remaining - remaining / 64 else remaining;
        const wanted = requested orelse return limit;
        if (fork_gas.hasAllButOne64th(self.hardfork)) return @min(wanted, limit);
        if (wanted > limit) {
            self.gas_remaining = 0;
            return error.OutOfGas;
        }
        return wanted;
    }

    /// CALL, CALLCODE, DELEGATECALL and STATICCALL.
    ///
    /// The callee's context follows the instruction: CALL and STATICCALL run in the
    /// target account, CALLCODE and DELEGATECALL in the current one, and
    /// DELEGATECALL keeps this frame's caller and value. A CALL or CALLCODE that
    /// sends value adds the 2300 gas stipend to what the callee receives.
    fn opCall(self: *Self, opcode: u8, kind: MinimalEvm.CallKind) MinimalEvmError!void {
        const evm = self.getEvm();
        const has_value = kind == .call or kind == .callcode;
        const gas = try self.popStack();
        const target = primitives.Address.fromU256(try self.popStack());
        const value: u256 = if (has_value) try self.popStack() else 0;
        const in_offset = try self.popStack();
        const in_length = try self.popStack();
        const out_offset = try self.popStack();
        const out_length = try self.popStack();

        // The fork's flat base price; from Berlin on (EIP-2929) the warm/cold access cost.
        var gas_cost = fork_gas.staticGas(self.hardfork, opcode, try evm.access_address(target));
        if (value > 0) gas_cost += GasConstants.CallValueTransferGas;
        // Creating an account costs G_newaccount: since Spurious Dragon (EIP-161) only
        // for a value transfer to an empty account; before it, for any CALL to an
        // account that does not exist.
        if (kind == .call) {
            const creates_account = if (fork_gas.newAccountNeedsValue(self.hardfork))
                value > 0 and evm.is_empty(target)
            else
                !evm.account_exists(target);
            if (creates_account) gas_cost += GasConstants.CallNewAccountGas;
        }

        // Memory expansion covers BOTH the input and the return region.
        // Zero-length regions do not touch memory regardless of offset (Yellow Paper).
        const in_length_u64 = std.math.cast(u64, in_length) orelse return error.OutOfBounds;
        const out_length_u64 = std.math.cast(u64, out_length) orelse return error.OutOfBounds;
        const in_offset_u64: u64 = if (in_length_u64 > 0) (std.math.cast(u64, in_offset) orelse return error.OutOfBounds) else 0;
        const out_offset_u64: u64 = if (out_length_u64 > 0) (std.math.cast(u64, out_offset) orelse return error.OutOfBounds) else 0;
        gas_cost +|= try self.callMemoryExpansionCost(in_offset_u64, in_length_u64, out_offset_u64, out_length_u64);
        try self.consumeGas(gas_cost);
        const in_end = if (in_length_u64 > 0) in_offset_u64 + in_length_u64 else 0;
        const out_end = if (out_length_u64 > 0) out_offset_u64 + out_length_u64 else 0;
        try self.expandMemoryTo(@max(in_end, out_end));

        // EIP-214: a CALL that sends value changes state, so it fails in a static context.
        if (kind == .call and value > 0 and self.is_static) return error.WriteProtection;

        const forwarded = try self.forwardedGas(std.math.cast(u64, gas) orelse std.math.maxInt(u64));
        const stipend: u64 = if (value > 0) GasConstants.CallStipend else 0;
        const in_len = std.math.cast(u32, in_length) orelse return error.OutOfBounds;
        const input = try self.readMemoryRange(in_offset, in_len);
        self.gas_remaining -= @intCast(forwarded);
        const result = try evm.call(.{
            .kind = kind,
            .target = target,
            .value = value,
            .input = input,
            .gas = forwarded +| stipend,
        });
        // Unused gas comes back, including what is left of the stipend.
        self.gas_remaining +|= std.math.cast(i64, result.gas_left) orelse std.math.maxInt(i64);

        // Write output to memory (memory expansion already charged above)
        const copy_len = @min(out_length_u64, result.output.len);
        if (copy_len > 0) {
            const out_off = std.math.cast(u32, out_offset) orelse return error.OutOfBounds;
            for (result.output[0..copy_len], 0..) |byte, index| {
                try self.writeMemory(out_off + @as(u32, @intCast(index)), byte);
            }
        }

        self.return_data = result.output;
        try self.pushStack(if (result.success) 1 else 0);
        self.pc += 1;
    }

    /// CREATE and CREATE2: charge the creation cost, then run the init code in
    /// MinimalEvm and push the new address, or 0 when the creation failed.
    fn opCreate(self: *Self, is_create2: bool) MinimalEvmError!void {
        const evm = self.getEvm();
        const value = try self.popStack();
        const offset = try self.popStack();
        const length = try self.popStack();
        const salt: ?u256 = if (is_create2) try self.popStack() else null;

        const len = std.math.cast(u32, length) orelse return error.OutOfBounds;
        // Init code is read from memory: charge expansion over [offset, offset+len)
        // (nothing for zero length, whatever the offset).
        var end: u64 = 0;
        if (len > 0) {
            const offset_u32 = std.math.cast(u32, offset) orelse return error.OutOfBounds;
            end = @as(u64, offset_u32) + @as(u64, len);
        }
        const gas_cost = if (is_create2) self.create2GasCost(len) else self.createGasCost(len);
        try self.consumeGas(gas_cost +| self.memoryExpansionCost(end));
        try self.expandMemoryTo(end);

        // EIP-214: creation changes state, so it fails in a static context.
        if (self.is_static) return error.WriteProtection;
        // EIP-3860 (Shanghai): oversized init code is an exceptional halt.
        if (self.hardfork.isAtLeast(.SHANGHAI) and len > GasConstants.MaxInitcodeSize) {
            self.gas_remaining = 0;
            return error.CreateInitCodeSizeLimit;
        }

        const init_code = try self.readMemoryRange(offset, len);
        const forwarded = try self.forwardedGas(null);
        self.gas_remaining -= @intCast(forwarded);
        self.return_data = &[_]u8{};
        const result = try evm.create(.{ .value = value, .init_code = init_code, .gas = forwarded, .salt = salt });
        self.gas_remaining +|= std.math.cast(i64, result.gas_left) orelse std.math.maxInt(i64);

        // Return data is the init code's revert data; empty after a successful creation.
        self.return_data = result.output;
        try self.pushStack(if (result.address) |address| primitives.Address.toU256(address) else 0);
        self.pc += 1;
    }

    /// ----------------------------------- OPCODES ---------------------------------- ///
    /// Execute a single opcode - delegates to MinimalEvm for external ops
    pub fn executeOpcode(self: *Self, opcode: u8) MinimalEvmError!void {
        const evm = self.getEvm();

        switch (opcode) {
            // STOP
            0x00 => {
                self.stopped = true;
                return;
            },
            // ADD
            0x01 => {
                try self.consumeGas(GasConstants.GasFastestStep);
                const a = try self.popStack();
                const b = try self.popStack();
                try self.pushStack(a +% b);
                self.pc += 1;
            },
            // MUL
            0x02 => {
                try self.consumeGas(GasConstants.GasFastStep);
                const a = try self.popStack();
                const b = try self.popStack();
                try self.pushStack(a *% b);
                self.pc += 1;
            },
            // SUB
            0x03 => {
                try self.consumeGas(GasConstants.GasFastestStep);
                const top = try self.popStack();
                const second = try self.popStack();
                try self.pushStack(top -% second);
                self.pc += 1;
            },
            // DIV
            0x04 => {
                try self.consumeGas(GasConstants.GasFastStep);
                const top = try self.popStack();
                const second = try self.popStack();
                const result = if (second == 0) 0 else top / second;
                try self.pushStack(result);
                self.pc += 1;
            },
            // SDIV
            0x05 => {
                try self.consumeGas(GasConstants.GasFastStep);
                const top = try self.popStack();
                const second = try self.popStack();
                const top_signed = @as(i256, @bitCast(top));
                const second_signed = @as(i256, @bitCast(second));
                const MIN_SIGNED = @as(u256, 1) << 255;
                const result = if (second == 0)
                    0
                else if (top == MIN_SIGNED and second == std.math.maxInt(u256))
                    MIN_SIGNED
                else
                    @as(u256, @bitCast(@divTrunc(top_signed, second_signed)));
                try self.pushStack(result);
                self.pc += 1;
            },
            // MOD
            0x06 => {
                try self.consumeGas(GasConstants.GasFastStep);
                const top = try self.popStack();
                const second = try self.popStack();
                const result = if (second == 0) 0 else top % second;
                try self.pushStack(result);
                self.pc += 1;
            },
            // SMOD
            0x07 => {
                try self.consumeGas(GasConstants.GasFastStep);
                const top = try self.popStack();
                const second = try self.popStack();
                const top_signed = @as(i256, @bitCast(top));
                const second_signed = @as(i256, @bitCast(second));
                const MIN_SIGNED = @as(u256, 1) << 255;
                const result = if (second == 0)
                    0
                else if (top == MIN_SIGNED and second == std.math.maxInt(u256))
                    0
                else
                    @as(u256, @bitCast(@rem(top_signed, second_signed)));
                try self.pushStack(result);
                self.pc += 1;
            },
            // ADDMOD
            0x08 => {
                try self.consumeGas(GasConstants.GasMidStep);
                const a = try self.popStack();
                const b = try self.popStack();
                const n = try self.popStack();
                const result = if (n == 0) 0 else blk: {
                    const a_wide = @as(u512, a);
                    const b_wide = @as(u512, b);
                    const n_wide = @as(u512, n);
                    break :blk @as(u256, @truncate((a_wide + b_wide) % n_wide));
                };
                try self.pushStack(result);
                self.pc += 1;
            },
            // MULMOD
            0x09 => {
                try self.consumeGas(GasConstants.GasMidStep);
                const a = try self.popStack();
                const b = try self.popStack();
                const n = try self.popStack();
                const result = if (n == 0) 0 else blk: {
                    // Use u512 to avoid overflow
                    const a_wide = @as(u512, a);
                    const b_wide = @as(u512, b);
                    const n_wide = @as(u512, n);
                    break :blk @as(u256, @truncate((a_wide * b_wide) % n_wide));
                };
                try self.pushStack(result);
                self.pc += 1;
            },

            // EXP
            0x0a => {
                const base = try self.popStack();
                const exp = try self.popStack();

                // EIP-160: Dynamic gas cost for EXP
                // Gas cost = GasSlowStep + gas_per_byte * ((log2(exponent) / 8) + 1)
                // This calculates the number of bytes needed to represent the exponent
                const exp_bytes: u32 = if (exp == 0) 0 else blk: {
                    // Find position of highest bit set
                    const bit_position = 255 - @clz(exp);
                    // Calculate byte count: (bit_position / 8) + 1
                    break :blk @as(u32, bit_position / 8 + 1);
                };

                // EIP-160 raised the per-byte cost from 10 to 50 in Spurious Dragon.
                const gas_per_byte: u32 = if (evm.hardfork.isBefore(.SPURIOUS_DRAGON)) 10 else 50;
                // Calculate gas cost based on the number of bytes needed to represent the exponent
                const gas_cost = GasConstants.GasSlowStep + gas_per_byte * exp_bytes;
                try self.consumeGas(gas_cost);

                // Square-and-multiply algorithm for base^exp
                var result: u256 = 1;
                var b = base;
                var e = exp;
                while (e > 0) : (e >>= 1) {
                    if (e & 1 == 1) {
                        result *%= b;
                    }
                    b *%= b;
                }
                try self.pushStack(result);
                self.pc += 1;
            },

            // SIGNEXTEND
            0x0b => {
                try self.consumeGas(GasConstants.GasFastStep);
                const byte_num = try self.popStack();
                const value = try self.popStack();

                const result = if (byte_num >= 31) value else blk: {
                    const bit_index = @as(u8, @intCast(byte_num)) * 8 + 7;
                    const bit = (value >> @intCast(bit_index)) & 1;
                    const mask = (@as(u256, 1) << @intCast(bit_index + 1)) - 1;
                    if (bit == 1) {
                        break :blk value | ~mask;
                    } else {
                        break :blk value & mask;
                    }
                };
                try self.pushStack(result);
                self.pc += 1;
            },

            // LT
            0x10 => {
                try self.consumeGas(GasConstants.GasFastestStep);
                const a = try self.popStack(); // Top of stack
                const b = try self.popStack(); // Second from top
                try self.pushStack(if (a < b) 1 else 0); // Compare a < b
                self.pc += 1;
            },

            // GT
            0x11 => {
                try self.consumeGas(GasConstants.GasFastestStep);
                const a = try self.popStack(); // Top of stack
                const b = try self.popStack(); // Second from top
                try self.pushStack(if (a > b) 1 else 0); // Compare a > b
                self.pc += 1;
            },

            // SLT
            0x12 => {
                try self.consumeGas(GasConstants.GasFastestStep);
                const a = try self.popStack(); // Top of stack
                const b = try self.popStack(); // Second from top
                const a_signed = @as(i256, @bitCast(a));
                const b_signed = @as(i256, @bitCast(b));
                try self.pushStack(if (a_signed < b_signed) 1 else 0); // Compare a < b (signed)
                self.pc += 1;
            },

            // SGT
            0x13 => {
                try self.consumeGas(GasConstants.GasFastestStep);
                const a = try self.popStack(); // Top of stack
                const b = try self.popStack(); // Second from top
                const a_signed = @as(i256, @bitCast(a));
                const b_signed = @as(i256, @bitCast(b));
                try self.pushStack(if (a_signed > b_signed) 1 else 0); // Compare a > b (signed)
                self.pc += 1;
            },

            // EQ
            0x14 => {
                try self.consumeGas(GasConstants.GasFastestStep);
                const top = try self.popStack();
                const second = try self.popStack();
                try self.pushStack(if (top == second) 1 else 0); // EQ is symmetric
                self.pc += 1;
            },

            // ISZERO
            0x15 => {
                try self.consumeGas(GasConstants.GasFastestStep);
                const a = try self.popStack();
                try self.pushStack(if (a == 0) 1 else 0);
                self.pc += 1;
            },

            // AND
            0x16 => {
                try self.consumeGas(GasConstants.GasFastestStep);
                const a = try self.popStack();
                const b = try self.popStack();
                try self.pushStack(a & b);
                self.pc += 1;
            },

            // OR
            0x17 => {
                try self.consumeGas(GasConstants.GasFastestStep);
                const a = try self.popStack();
                const b = try self.popStack();
                try self.pushStack(a | b);
                self.pc += 1;
            },

            // XOR
            0x18 => {
                try self.consumeGas(GasConstants.GasFastestStep);
                const a = try self.popStack();
                const b = try self.popStack();
                try self.pushStack(a ^ b);
                self.pc += 1;
            },

            // NOT
            0x19 => {
                try self.consumeGas(GasConstants.GasFastestStep);
                const a = try self.popStack();
                try self.pushStack(~a);
                self.pc += 1;
            },

            // BYTE
            0x1a => {
                try self.consumeGas(GasConstants.GasFastestStep);
                const i = try self.popStack();
                const x = try self.popStack();
                const result = if (i >= 32) 0 else (x >> @intCast(8 * (31 - i))) & 0xff;
                try self.pushStack(result);
                self.pc += 1;
            },

            // SHL
            0x1b => {
                // EIP-145: SHL opcode was introduced in Constantinople hardfork
                if (evm.hardfork.isBefore(.CONSTANTINOPLE)) return error.InvalidOpcode;

                try self.consumeGas(GasConstants.GasFastestStep);
                const shift = try self.popStack();
                const value = try self.popStack();
                const result = if (shift >= 256) 0 else value << @intCast(shift);
                try self.pushStack(result);
                self.pc += 1;
            },

            // SHR
            0x1c => {
                // EIP-145: SHR opcode was introduced in Constantinople hardfork
                if (evm.hardfork.isBefore(.CONSTANTINOPLE)) return error.InvalidOpcode;

                try self.consumeGas(GasConstants.GasFastestStep);
                const shift = try self.popStack();
                const value = try self.popStack();
                const result = if (shift >= 256) 0 else value >> @intCast(shift);
                try self.pushStack(result);
                self.pc += 1;
            },

            // SAR
            0x1d => {
                // EIP-145: SAR opcode was introduced in Constantinople hardfork
                if (evm.hardfork.isBefore(.CONSTANTINOPLE)) return error.InvalidOpcode;

                try self.consumeGas(GasConstants.GasFastestStep);
                const shift = try self.popStack();
                const value = try self.popStack();
                const value_signed = @as(i256, @bitCast(value));
                const result = if (shift >= 256) blk: {
                    break :blk if (value_signed < 0) @as(u256, @bitCast(@as(i256, -1))) else 0;
                } else blk: {
                    break :blk @as(u256, @bitCast(value_signed >> @intCast(shift)));
                };
                try self.pushStack(result);
                self.pc += 1;
            },

            // EIP-7939: count leading zero bits, including 256 for zero.
            0x1e => {
                if (evm.hardfork.isBefore(.OSAKA)) return error.InvalidOpcode;
                const value = try self.popStack();
                try self.consumeGas(GasConstants.GasFastStep);
                try self.pushStack(@clz(value));
                self.pc += 1;
            },

            // SHA3/KECCAK256
            0x20 => {
                const offset = try self.popStack();
                const size = try self.popStack();

                // Use centralized gas calculation
                const size_u32 = std.math.cast(u32, size) orelse return error.OutOfBounds;
                const gas_cost = keccak256GasCost(size_u32);
                try self.consumeGas(gas_cost);

                // Handle empty data case
                if (size == 0) {
                    // Keccak-256("") = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
                    const empty_hash: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
                    try self.pushStack(empty_hash);
                    self.pc += 1;
                } else {
                    const offset_u32 = std.math.cast(u32, offset) orelse return error.OutOfBounds;

                    // Charge memory expansion to cover [offset, offset+size)
                    const end_addr = @as(u64, offset_u32) + @as(u64, size_u32);
                    const mem_cost = self.memoryExpansionCost(end_addr);
                    try self.consumeGas(mem_cost);
                    try self.expandMemoryTo(end_addr);

                    // Read data from memory
                    var data = try self.allocator.alloc(u8, size_u32);
                    // No defer free needed with arena allocator

                    var i: u32 = 0;
                    while (i < size_u32) : (i += 1) {
                        data[i] = self.readMemory(offset_u32 + i);
                    }

                    // Compute Keccak-256 hash using std library
                    var hash_bytes: [32]u8 = undefined;
                    std.crypto.hash.sha3.Keccak256.hash(data, &hash_bytes, .{});

                    // Convert hash bytes to u256 (big-endian)
                    const hash_u256 = std.mem.readInt(u256, &hash_bytes, .big);
                    try self.pushStack(hash_u256);
                    self.pc += 1;
                }
            },

            // ADDRESS
            0x30 => {
                try self.consumeGas(GasConstants.GasQuickStep);
                const addr_u256 = primitives.Address.toU256(self.address);
                try self.pushStack(addr_u256);
                self.pc += 1;
            },

            // BALANCE
            0x31 => {
                const addr_int = try self.popStack();
                var addr_bytes: [20]u8 = undefined;
                var i: usize = 0;
                while (i < 20) : (i += 1) {
                    addr_bytes[19 - i] = @as(u8, @truncate(addr_int >> @intCast(i * 8)));
                }
                const addr = Address{ .bytes = addr_bytes };

                // EIP-150/EIP-2929: hardfork-aware account access cost
                const access_cost = try self.externalAccountGasCost(addr);
                try self.consumeGas(access_cost);
                const balance = evm.get_balance(addr);
                try self.pushStack(balance);
                self.pc += 1;
            },

            // ORIGIN
            0x32 => {
                try self.consumeGas(GasConstants.GasQuickStep);
                const origin_u256 = primitives.Address.toU256(evm.origin);
                try self.pushStack(origin_u256);
                self.pc += 1;
            },

            // CALLER
            0x33 => {
                try self.consumeGas(GasConstants.GasQuickStep);
                const caller_u256 = primitives.Address.toU256(self.caller);
                try self.pushStack(caller_u256);
                self.pc += 1;
            },

            // CALLVALUE
            0x34 => {
                try self.consumeGas(GasConstants.GasQuickStep);
                try self.pushStack(self.value);
                self.pc += 1;
            },

            // CALLDATALOAD
            0x35 => {
                try self.consumeGas(GasConstants.GasFastestStep);
                const offset = try self.popStack();
                if (offset > std.math.maxInt(u32)) {
                    try self.pushStack(0);
                } else {
                    // Widened so that an offset near the u32 maximum cannot wrap.
                    const off: u64 = @intCast(offset);
                    var result: u256 = 0;
                    var i: u64 = 0;
                    while (i < 32) : (i += 1) {
                        const idx = off + i;
                        const byte = if (idx < self.calldata.len) self.calldata[idx] else 0;
                        result = (result << 8) | byte;
                    }
                    try self.pushStack(result);
                }
                self.pc += 1;
            },

            // CALLDATASIZE
            0x36 => {
                try self.consumeGas(GasConstants.GasQuickStep);
                try self.pushStack(self.calldata.len);
                self.pc += 1;
            },

            // CALLDATACOPY
            0x37 => {
                const dest_offset = try self.popStack();
                const offset = try self.popStack();
                const length = try self.popStack();
                try self.copyToMemory(self.calldata, dest_offset, offset, length, GasConstants.GasFastestStep);
                self.pc += 1;
            },

            // CODESIZE
            0x38 => {
                try self.consumeGas(GasConstants.GasQuickStep);
                try self.pushStack(self.bytecode.len);
                self.pc += 1;
            },

            // CODECOPY
            0x39 => {
                const dest_offset = try self.popStack();
                const offset = try self.popStack();
                const length = try self.popStack();
                try self.copyToMemory(self.bytecode, dest_offset, offset, length, GasConstants.GasFastestStep);
                self.pc += 1;
            },

            // GASPRICE
            0x3a => {
                try self.consumeGas(GasConstants.GasQuickStep);
                try self.pushStack(evm.gas_price);
                self.pc += 1;
            },

            // RETURNDATASIZE
            0x3d => {
                // EIP-211: RETURNDATASIZE was introduced in Byzantium hardfork
                if (evm.hardfork.isBefore(.BYZANTIUM)) return error.InvalidOpcode;

                try self.consumeGas(GasConstants.GasQuickStep);
                try self.pushStack(self.return_data.len);
                self.pc += 1;
            },

            // RETURNDATACOPY
            0x3e => {
                // EIP-211: RETURNDATACOPY was introduced in Byzantium hardfork
                if (evm.hardfork.isBefore(.BYZANTIUM)) return error.InvalidOpcode;

                const dest_offset = try self.popStack();
                const offset = try self.popStack();
                const length = try self.popStack();

                // EIP-211: reading past the end of the return data is an exceptional
                // halt, also for a zero length. The sum is checked at full width.
                const source_end = std.math.add(u256, offset, length) catch return error.OutOfBounds;
                if (source_end > self.return_data.len) return error.OutOfBounds;
                try self.copyToMemory(self.return_data, dest_offset, offset, length, GasConstants.GasFastestStep);
                self.pc += 1;
            },

            // BLOCKHASH
            0x40 => {
                try self.consumeGas(GasConstants.GasExtStep);
                const block_number = try self.popStack();
                const hash = block_info.recentBlockHash(evm.block_hashes, evm.block_number, block_number);
                try self.pushStack(if (hash) |bytes| std.mem.readInt(u256, &bytes, .big) else 0);
                self.pc += 1;
            },

            // COINBASE
            0x41 => {
                try self.consumeGas(GasConstants.GasQuickStep);
                const coinbase_u256 = primitives.Address.toU256(evm.block_coinbase);
                try self.pushStack(coinbase_u256);
                self.pc += 1;
            },

            // TIMESTAMP
            0x42 => {
                try self.consumeGas(GasConstants.GasQuickStep);
                try self.pushStack(evm.block_timestamp);
                self.pc += 1;
            },

            // NUMBER
            0x43 => {
                try self.consumeGas(GasConstants.GasQuickStep);
                try self.pushStack(evm.block_number);
                self.pc += 1;
            },

            // DIFFICULTY/PREVRANDAO
            0x44 => {
                try self.consumeGas(GasConstants.GasQuickStep);
                if (evm.hardfork.isAtLeast(.MERGE)) {
                    try self.pushStack(evm.block_prevrandao);
                } else {
                    try self.pushStack(evm.block_difficulty);
                }
                self.pc += 1;
            },

            // GASLIMIT
            0x45 => {
                try self.consumeGas(GasConstants.GasQuickStep);
                try self.pushStack(@as(u256, evm.block_gas_limit));
                self.pc += 1;
            },

            // CHAINID
            0x46 => {
                // EIP-1344: CHAINID was introduced in Istanbul hardfork
                if (evm.hardfork.isBefore(.ISTANBUL)) return error.InvalidOpcode;

                try self.consumeGas(GasConstants.GasQuickStep);
                try self.pushStack(@as(u256, evm.chain_id));
                self.pc += 1;
            },

            // SELFBALANCE
            0x47 => {
                // EIP-1884: SELFBALANCE was introduced in Istanbul hardfork
                if (evm.hardfork.isBefore(.ISTANBUL)) return error.InvalidOpcode;

                try self.consumeGas(GasConstants.GasFastStep);
                const balance = evm.get_balance(self.address);
                try self.pushStack(balance);
                self.pc += 1;
            },

            // BASEFEE
            0x48 => {
                // EIP-3198: BASEFEE was introduced in London hardfork
                if (evm.hardfork.isBefore(.LONDON)) return error.InvalidOpcode;

                try self.consumeGas(GasConstants.GasQuickStep);
                try self.pushStack(evm.block_base_fee);
                self.pc += 1;
            },

            // BLOBHASH
            0x49 => {
                // EIP-4844: BLOBHASH was introduced in Cancun hardfork
                if (evm.hardfork.isBefore(.CANCUN)) return error.InvalidOpcode;

                try self.consumeGas(GasConstants.GasFastestStep);
                const index = try self.popStack();
                const hashes = evm.blob_versioned_hashes;
                const value = if (index < hashes.len) std.mem.readInt(u256, &hashes[@intCast(index)], .big) else 0;
                try self.pushStack(value);
                self.pc += 1;
            },

            // BLOBBASEFEE
            0x4a => {
                // EIP-7516: BLOBBASEFEE was introduced in Cancun hardfork
                if (evm.hardfork.isBefore(.CANCUN)) return error.InvalidOpcode;

                try self.consumeGas(GasConstants.GasQuickStep);
                try self.pushStack(evm.blob_base_fee);
                self.pc += 1;
            },

            // POP
            0x50 => {
                try self.consumeGas(GasConstants.GasQuickStep);
                _ = try self.popStack();
                self.pc += 1;
            },

            // MLOAD
            0x51 => {
                const offset = try self.popStack();
                const off = std.math.cast(u32, offset) orelse return error.OutOfBounds;

                // Charge base + memory expansion for reading 32 bytes
                const end_bytes: u64 = @as(u64, off) + 32;
                const mem_cost = self.memoryExpansionCost(end_bytes);
                try self.consumeGas(GasConstants.GasFastestStep + mem_cost);
                try self.expandMemoryTo(end_bytes);

                // Read word from memory
                var result: u256 = 0;
                var idx: u32 = 0;
                while (idx < 32) : (idx += 1) {
                    const byte = self.readMemory(off + idx);
                    result = (result << 8) | byte;
                }
                try self.pushStack(result);
                self.pc += 1;
            },

            // MSTORE
            0x52 => {
                const offset = try self.popStack();
                const value = try self.popStack();

                const off = std.math.cast(u32, offset) orelse return error.OutOfBounds;

                // Charge base + memory expansion for writing 32 bytes
                const end_bytes2: u64 = @as(u64, off) + 32;
                const mem_cost2 = self.memoryExpansionCost(end_bytes2);
                try self.consumeGas(GasConstants.GasFastestStep + mem_cost2);
                try self.expandMemoryTo(end_bytes2);

                // Write word to memory
                var idx: u32 = 0;
                while (idx < 32) : (idx += 1) {
                    const byte = @as(u8, @truncate(value >> @intCast((31 - idx) * 8)));
                    try self.writeMemory(off + idx, byte);
                }
                self.pc += 1;
            },

            // MSTORE8
            0x53 => {
                const offset = try self.popStack();
                const value = try self.popStack();

                const off = std.math.cast(u32, offset) orelse return error.OutOfBounds;
                const end_bytes3: u64 = @as(u64, off) + 1;
                const mem_cost3 = self.memoryExpansionCost(end_bytes3);
                try self.consumeGas(GasConstants.GasFastestStep + mem_cost3);
                const byte_value = @as(u8, @truncate(value));
                try self.writeMemory(off, byte_value);
                self.pc += 1;
            },

            // SLOAD
            0x54 => {
                const key = try self.popStack();

                // EIP-2929 (Berlin+): warm/cold storage access cost; the slot is warmed.
                // Earlier forks charge SLOAD's flat price for that fork (50, 200 or 800).
                const access_cost = try evm.access_storage_slot(self.address, key);
                const sload_cost = if (fork_gas.hasAccessLists(self.hardfork))
                    access_cost
                else
                    fork_gas.staticGas(self.hardfork, 0x54, fork_gas.warm_access_cost);
                try self.consumeGas(sload_cost);

                const value = evm.get_storage(self.address, key);
                try self.pushStack(value);
                self.pc += 1;
            },

            // SSTORE
            0x55 => {
                const key = try self.popStack();
                const value = try self.popStack();

                // EIP-2200 (Istanbul+): fail when gas left is at or below the stipend.
                const sentry_i64: i64 = @intCast(fork_gas.sstore_sentry_gas);
                if (fork_gas.sstoreHasSentry(self.hardfork) and self.gas_remaining <= sentry_i64) {
                    self.gas_remaining = 0;
                    return error.OutOfGas;
                }

                // Get current and original values for gas calculation
                const current_value = evm.get_storage(self.address, key);
                const original_value = evm.get_original_storage(self.address, key);

                // EIP-2929: Check if storage slot is cold and warm it
                const access_cost = try evm.access_storage_slot(self.address, key);
                const is_cold = fork_gas.hasAccessLists(self.hardfork) and access_cost == GasConstants.ColdSloadCost;

                // Same fork-aware metering as the Frame handler.
                const cost = fork_gas.sstoreCostFor(self.hardfork, .{
                    .original = original_value,
                    .current = current_value,
                    .new = value,
                    .is_cold = is_cold,
                });
                try self.consumeGas(cost.gas);

                // EIP-214: SSTORE changes state, so it fails in a static context.
                if (self.is_static) return error.WriteProtection;

                if (cost.refund > 0) {
                    evm.add_refund(@intCast(cost.refund));
                } else if (cost.refund < 0) {
                    // Takes back a refund granted earlier in this transaction.
                    const taken_back: u64 = @intCast(-cost.refund);
                    if (taken_back > evm.gas_refund) return error.InvalidOpcode;
                    evm.gas_refund -= taken_back;
                }

                try evm.set_storage(self.address, key, value);
                self.pc += 1;
            },

            // JUMP
            0x56 => {
                try self.consumeGas(GasConstants.GasMidStep);
                const dest = try self.popStack();
                const dest_pc = std.math.cast(u32, dest) orelse return error.InvalidJump;

                // Validate jump destination
                if (!self.valid_jumpdests.contains(dest_pc)) return error.InvalidJump;

                self.pc = dest_pc;
            },

            // JUMPI
            0x57 => {
                try self.consumeGas(GasConstants.GasSlowStep);
                const dest = try self.popStack();
                const condition = try self.popStack();

                if (condition != 0) {
                    const dest_pc = std.math.cast(u32, dest) orelse return error.InvalidJump;

                    // Validate jump destination
                    if (!self.valid_jumpdests.contains(dest_pc)) return error.InvalidJump;

                    self.pc = dest_pc;
                } else {
                    self.pc += 1;
                }
            },

            // PC
            0x58 => {
                try self.consumeGas(GasConstants.GasQuickStep);
                try self.pushStack(self.pc);
                self.pc += 1;
            },

            // MSIZE
            0x59 => {
                try self.consumeGas(GasConstants.GasQuickStep);
                // Memory size is already tracked as word-aligned in memory_size field
                try self.pushStack(self.memory_size);
                self.pc += 1;
            },

            // GAS
            0x5a => {
                try self.consumeGas(GasConstants.GasQuickStep);
                try self.pushStack(@intCast(self.gas_remaining));
                self.pc += 1;
            },

            // JUMPDEST
            0x5b => {
                try self.consumeGas(GasConstants.JumpdestGas);
                self.pc += 1;
            },

            // TLOAD
            0x5c => {
                // EIP-1153: TLOAD was introduced in Cancun hardfork
                if (evm.hardfork.isBefore(.CANCUN)) return error.InvalidOpcode;

                try self.consumeGas(GasConstants.WarmStorageReadCost);
                const key = try self.popStack();
                const value = evm.get_transient_storage(self.address, key);
                try self.pushStack(value);
                self.pc += 1;
            },

            // TSTORE
            0x5d => {
                // EIP-1153: TSTORE was introduced in Cancun hardfork
                if (evm.hardfork.isBefore(.CANCUN)) return error.InvalidOpcode;

                try self.consumeGas(GasConstants.WarmStorageReadCost);
                const key = try self.popStack();
                const value = try self.popStack();
                // EIP-1153: TSTORE fails in a static context.
                if (self.is_static) return error.WriteProtection;
                try evm.set_transient_storage(self.address, key, value);
                self.pc += 1;
            },

            // PUSH0
            0x5f => {
                // EIP-3855: PUSH0 was introduced in Shanghai hardfork
                if (evm.hardfork.isBefore(.SHANGHAI)) return error.InvalidOpcode;

                try self.consumeGas(GasConstants.GasQuickStep);
                try self.pushStack(0);
                self.pc += 1;
            },

            // PUSH1-PUSH32
            0x60...0x7f => {
                try self.consumeGas(GasConstants.GasFastestStep);
                const push_size = opcode - 0x5f;

                // Yellow Paper 9.4.1: bytes read past the end of the code are zero, so
                // a PUSH whose immediate is cut off by the end of the code pushes the
                // bytes that exist, padded on the right with zeros.
                const first: usize = @min(@as(usize, self.pc) + 1, self.bytecode.len);
                const available = self.bytecode[first..@min(first + push_size, self.bytecode.len)];
                var value: u256 = 0;
                for (available) |byte| {
                    value = (value << 8) | byte;
                }
                // With no byte available the value is already zero; a shift by all
                // 256 bits is not representable.
                const missing: usize = @as(usize, push_size) - available.len;
                if (available.len != 0) value <<= @intCast(8 * missing);

                try self.pushStack(value);
                self.pc += 1 + push_size;
            },

            // DUP1-DUP16
            0x80...0x8f => {
                try self.consumeGas(GasConstants.GasFastestStep);
                const n = opcode - 0x7f;
                if (self.stack.items.len < n) {
                    return error.StackUnderflow;
                }
                const value = self.stack.items[self.stack.items.len - n];
                try self.pushStack(value);
                self.pc += 1;
            },

            // SWAP1-SWAP16
            0x90...0x9f => {
                try self.consumeGas(GasConstants.GasFastestStep);
                const n = opcode - 0x8f;
                if (self.stack.items.len <= n) {
                    return error.StackUnderflow;
                }
                const top_idx = self.stack.items.len - 1;
                const swap_idx = self.stack.items.len - 1 - n;
                const temp = self.stack.items[top_idx];
                self.stack.items[top_idx] = self.stack.items[swap_idx];
                self.stack.items[swap_idx] = temp;
                self.pc += 1;
            },

            // LOG0-LOG4
            0xa0...0xa4 => {
                const topic_count = opcode - 0xa0;
                const offset = try self.popStack();
                const length = try self.popStack();

                // Pop topics
                var i: u8 = 0;
                while (i < topic_count) : (i += 1) {
                    _ = try self.popStack();
                }

                // Gas cost: static + per-topic + per-byte, plus memory expansion over the
                // data range (none for zero length, whatever the offset).
                const length_u32 = std.math.cast(u32, length) orelse return error.OutOfBounds;
                const log_cost = logGasCost(topic_count, length_u32);
                var end: u64 = 0;
                if (length_u32 > 0) {
                    const offset_u32 = std.math.cast(u32, offset) orelse return error.OutOfBounds;
                    end = @as(u64, offset_u32) + @as(u64, length_u32);
                }
                const mem_cost = if (end > 0) self.memoryExpansionCost(end) else 0;
                try self.consumeGas(log_cost + mem_cost);
                if (end > 0) {
                    try self.expandMemoryTo(end);
                }

                // EIP-214: LOG fails in a static context. MinimalFrame keeps no log
                // records; only the gas, memory and static rules are modeled.
                if (self.is_static) return error.WriteProtection;
                self.pc += 1;
            },

            // CREATE
            0xf0 => try self.opCreate(false),

            // CALL
            0xf1 => try self.opCall(opcode, .call),

            // CALLCODE
            0xf2 => try self.opCall(opcode, .callcode),

            // RETURN
            0xf3 => {
                const offset = try self.popStack();
                const length = try self.popStack();

                if (length > 0) {
                    const off = std.math.cast(u32, offset) orelse return error.OutOfBounds;
                    const len = std.math.cast(u32, length) orelse return error.OutOfBounds;

                    // Charge memory expansion for the return slice
                    const end_bytes = @as(u64, off) + @as(u64, len);
                    const mem_cost = self.memoryExpansionCost(end_bytes);
                    try self.consumeGas(mem_cost);
                    try self.expandMemoryTo(end_bytes);

                    self.output = try self.allocator.alloc(u8, len);
                    var idx: u32 = 0;
                    while (idx < len) : (idx += 1) {
                        self.output[idx] = self.readMemory(off + idx);
                    }
                }

                self.stopped = true;
                return;
            },

            // DELEGATECALL
            0xf4 => {
                // EIP-7: DELEGATECALL was introduced in Homestead hardfork
                if (evm.hardfork.isBefore(.HOMESTEAD)) return error.InvalidOpcode;
                try self.opCall(opcode, .delegatecall);
            },

            // CREATE2
            0xf5 => {
                // EIP-1014: CREATE2 opcode was introduced in Constantinople hardfork
                if (evm.hardfork.isBefore(.CONSTANTINOPLE)) return error.InvalidOpcode;
                try self.opCreate(true);
            },

            // STATICCALL
            0xfa => {
                // EIP-214: STATICCALL was introduced in Byzantium hardfork
                if (evm.hardfork.isBefore(.BYZANTIUM)) return error.InvalidOpcode;
                try self.opCall(opcode, .staticcall);
            },

            // MCOPY (EIP-5656)
            0x5e => {
                // EIP-5656: MCOPY was introduced in Cancun hardfork
                if (evm.hardfork.isBefore(.CANCUN)) return error.InvalidOpcode;

                // EIP-5656: μs[0] = dest (top), μs[1] = src, μs[2] = length.
                const dest = try self.popStack();
                const src = try self.popStack();
                const len = try self.popStack();

                // Zero length touches no memory but still pays the static G_verylow.
                if (len == 0) {
                    try self.consumeGas(GasConstants.GasFastestStep);
                    self.pc += 1;
                    return;
                }

                // Bounds and type conversions (clamp to u64 before u32/u24 style ops)
                const dest_u32 = std.math.cast(u32, dest) orelse return error.OutOfBounds;
                const src_u32 = std.math.cast(u32, src) orelse return error.OutOfBounds;
                const len_u32 = std.math.cast(u32, len) orelse return error.OutOfBounds;

                // Gas: memory expansion + copy gas (CopyGas per 32-byte word)
                const end_src: u64 = @as(u64, src_u32) + @as(u64, len_u32);
                const end_dest: u64 = @as(u64, dest_u32) + @as(u64, len_u32);
                const mem_cost_src = self.memoryExpansionCost(end_src);
                const mem_cost_dest = self.memoryExpansionCost(end_dest);
                const mem_cost = @max(mem_cost_src, mem_cost_dest);
                const copy_cost = copyGasCost(len_u32);
                try self.consumeGas(GasConstants.GasFastestStep + mem_cost + copy_cost);
                try self.expandMemoryTo(@max(end_src, end_dest));

                // Copy via temporary buffer to handle overlapping regions
                const tmp = try self.allocator.alloc(u8, len_u32);
                // No defer free needed with arena allocator

                var i: u32 = 0;
                while (i < len_u32) : (i += 1) {
                    tmp[i] = self.readMemory(src_u32 + i);
                }
                i = 0;
                while (i < len_u32) : (i += 1) {
                    try self.writeMemory(dest_u32 + i, tmp[i]);
                }

                self.pc += 1;
            },

            // REVERT
            0xfd => {
                // EIP-140: REVERT was introduced in Byzantium hardfork
                if (evm.hardfork.isBefore(.BYZANTIUM)) return error.InvalidOpcode;

                const offset = try self.popStack();
                const length = try self.popStack();

                if (length > 0) {
                    const off = std.math.cast(u32, offset) orelse return error.OutOfBounds;
                    const len = std.math.cast(u32, length) orelse return error.OutOfBounds;

                    // Charge memory expansion for the revert slice
                    const end_bytes: u64 = @as(u64, off) + @as(u64, len);
                    const mem_cost = self.memoryExpansionCost(end_bytes);
                    try self.consumeGas(mem_cost);
                    try self.expandMemoryTo(end_bytes);

                    self.output = try self.allocator.alloc(u8, len);
                    var idx: u32 = 0;
                    while (idx < len) : (idx += 1) {
                        self.output[idx] = self.readMemory(off + idx);
                    }
                }

                self.reverted = true;
                return;
            },

            // EXTCODESIZE
            0x3b => {
                const ext_addr = primitives.Address.fromU256(try self.popStack());

                // EIP-150/EIP-2929: hardfork-aware account access cost
                const access_cost = try self.externalAccountGasCost(ext_addr);
                try self.consumeGas(access_cost);

                try self.pushStack(evm.get_code(ext_addr).len);
                self.pc += 1;
            },

            // EXTCODECOPY
            0x3c => {
                const ext_addr = primitives.Address.fromU256(try self.popStack());
                const dest_offset = try self.popStack();
                const offset = try self.popStack();
                const size = try self.popStack();

                // EIP-150/EIP-2929: the account access is charged whatever the size.
                const access_cost = try self.externalAccountGasCost(ext_addr);
                try self.copyToMemory(evm.get_code(ext_addr), dest_offset, offset, size, access_cost);
                self.pc += 1;
            },

            // EXTCODEHASH
            0x3f => {
                // EIP-1052: EXTCODEHASH opcode was introduced in Constantinople hardfork
                if (evm.hardfork.isBefore(.CONSTANTINOPLE)) return error.InvalidOpcode;

                const ext_addr = primitives.Address.fromU256(try self.popStack());

                // EIP-150/EIP-2929: hardfork-aware account access cost
                const access_cost = try self.externalAccountGasCost(ext_addr);
                try self.consumeGas(access_cost);

                // EIP-1052: 0 for an account that does not exist or is empty (EIP-161),
                // otherwise the Keccak-256 hash of its code.
                var hash: u256 = 0;
                if (!evm.is_empty(ext_addr)) {
                    var hash_bytes: [32]u8 = undefined;
                    std.crypto.hash.sha3.Keccak256.hash(evm.get_code(ext_addr), &hash_bytes, .{});
                    hash = std.mem.readInt(u256, &hash_bytes, .big);
                }
                try self.pushStack(hash);
                self.pc += 1;
            },

            // AUTH/AUTHCALL (0xF6/0xF7) belonged to EIP-3074, which was withdrawn in favor of
            // EIP-7702 and never activated: they are undefined opcodes in every fork, as in Frame.
            0xf6, 0xf7 => {
                self.gas_remaining = 0;
                return error.InvalidOpcode;
            },

            // INVALID
            0xfe => {
                // INVALID opcode always fails
                // Consume all remaining gas
                self.gas_remaining = 0;
                return error.InvalidOpcode;
            },

            // SELFDESTRUCT
            0xff => {
                const beneficiary_u256 = try self.popStack();

                // Convert u256 to Address (take lower 160 bits)
                var addr_bytes: [20]u8 = undefined;
                var addr_i: u32 = 0;
                while (addr_i < 20) : (addr_i += 1) {
                    addr_bytes[19 - addr_i] = @as(u8, @truncate(beneficiary_u256 >> @intCast(addr_i * 8)));
                }
                const beneficiary = Address{ .bytes = addr_bytes };

                const contract_balance = evm.get_balance(self.address);
                var gas_cost = self.selfdestructGasCost();
                const access_cost = try evm.access_address(beneficiary);
                if (fork_gas.hasAccessLists(self.hardfork) and access_cost > fork_gas.warm_access_cost) {
                    gas_cost += fork_gas.cold_account_access_cost;
                }
                if (self.hardfork.isAtLeast(.TANGERINE_WHISTLE)) {
                    // Dead in the EIP-161 sense: no nonce, no balance, no code.
                    const dead = evm.get_nonce(beneficiary) == 0 and
                        evm.get_balance(beneficiary) == 0 and
                        evm.get_code(beneficiary).len == 0;
                    if (dead and (contract_balance > 0 or !fork_gas.newAccountNeedsValue(self.hardfork))) {
                        gas_cost += fork_gas.new_account_gas;
                    }
                }
                try self.consumeGas(gas_cost);

                // EIP-214: SELFDESTRUCT changes state, so it fails in a static context.
                // The gas is charged first, as in execution-specs.
                if (self.is_static) return error.WriteProtection;

                // EIP-6780 (Cancun): the account is deleted only when it was created in
                // this transaction. Before Cancun it is always deleted.
                const deletes_account = self.hardfork.isBefore(.CANCUN) or evm.wasCreatedInTransaction(self.address);

                if (!beneficiary.equals(self.address)) {
                    // Move the whole balance to the beneficiary.
                    if (contract_balance > 0) {
                        const beneficiary_balance = evm.get_balance(beneficiary);
                        try evm.setBalance(self.address, 0);
                        // Wrapping add for overflow safety
                        const next_balance = beneficiary_balance +% contract_balance;
                        try evm.setBalance(beneficiary, next_balance);
                    }
                } else if (deletes_account) {
                    // The beneficiary is the contract itself and the contract is
                    // deleted: its balance is burned.
                    try evm.setBalance(self.address, 0);
                }
                // Otherwise the beneficiary is the contract itself and it survives
                // (EIP-6780): the balance stays where it is.

                // The refund (removed by EIP-3529 in London) is granted once per
                // contract per transaction, however often it self-destructs.
                const first_destruction = try evm.markSelfdestructed(self.address);
                const refund = self.selfdestructRefund();
                if (refund > 0 and first_destruction) {
                    evm.gas_refund += refund;
                }

                self.stopped = true;
            },

            else => {
                return error.InvalidOpcode;
            },
        }
    }

    /// Execute a single step
    pub fn step(self: *Self) MinimalEvmError!void {
        if (self.stopped or self.reverted or self.pc >= self.bytecode.len) {
            return;
        }
        const opcode = self.getCurrentOpcode() orelse return;
        try self.executeOpcode(opcode);
    }

    /// Main execution loop
    pub fn execute(self: *Self) MinimalEvmError!void {
        while (!self.stopped and !self.reverted and self.pc < self.bytecode.len) {
            try self.step();
        }
    }
};

test "MinimalFrame JUMP and JUMPI validation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Use the real MinimalEvm for testing
    var evm = try MinimalEvm.init(allocator);
    defer evm.deinit();

    // Set up some basic blockchain context
    evm.setBlockchainContext(
        1, // chain_id
        100, // block_number
        1000, // block_timestamp
        1, // block_difficulty
        1, // block_prevrandao
        Address{ .bytes = @splat(0) }, // block_coinbase
        30000000, // block_gas_limit
        1, // block_base_fee
        1, // blob_base_fee
    );
    evm.setTransactionContext(
        Address{ .bytes = @splat(0) }, // origin
        1, // gas_price
    );

    // Test 1: Valid JUMP to JUMPDEST
    {
        const bytecode = [_]u8{
            0x60, 0x04, // PUSH1 4
            0x56, // JUMP (pc=2)
            0xFE, // INVALID (pc=3) - should be skipped
            0x5b, // JUMPDEST (pc=4) - valid destination
            0x00, // STOP (pc=5)
        };

        var frame = try MinimalFrame.init(
            allocator,
            &bytecode,
            10000,
            Address{ .bytes = @splat(0) },
            Address{ .bytes = @splat(0) },
            0,
            &.{},
            &evm,
            evm.hardfork,
        );
        defer frame.deinit();

        // Execute and verify we jumped to pc=4
        try frame.execute();
        try testing.expectEqual(@as(u32, 5), frame.pc); // Should be at STOP after JUMPDEST
        try testing.expect(frame.stopped);
    }

    // Test 2: Invalid JUMP (not to JUMPDEST)
    {
        const bytecode = [_]u8{
            0x60, 0x03, // PUSH1 3 - invalid destination
            0x56, // JUMP (pc=2)
            0xFE, // INVALID (pc=3) - not a JUMPDEST
            0x5b, // JUMPDEST (pc=4)
            0x00, // STOP
        };

        var frame = try MinimalFrame.init(
            allocator,
            &bytecode,
            10000,
            Address{ .bytes = @splat(0) },
            Address{ .bytes = @splat(0) },
            0,
            &.{},
            &evm,
            evm.hardfork,
        );
        defer frame.deinit();

        // Execute and expect InvalidJump error
        const result = frame.execute();
        try testing.expectError(error.InvalidJump, result);
    }

    // Test 3: Valid JUMPI with true condition
    {
        const bytecode = [_]u8{
            0x60, 0x01, // PUSH1 1 - true condition
            0x60, 0x06, // PUSH1 6 - destination (top of stack)
            0x57, // JUMPI (pc=4)
            0xFE, // INVALID (pc=5) - should be skipped
            0x5b, // JUMPDEST (pc=6) - valid destination
            0x00, // STOP
        };

        var frame = try MinimalFrame.init(
            allocator,
            &bytecode,
            10000,
            Address{ .bytes = @splat(0) },
            Address{ .bytes = @splat(0) },
            0,
            &.{},
            &evm,
            evm.hardfork,
        );
        defer frame.deinit();

        // Execute and verify we jumped
        try frame.execute();
        try testing.expectEqual(@as(u32, 7), frame.pc); // Should be at STOP after JUMPDEST
        try testing.expect(frame.stopped);
    }

    // Test 4: JUMPI with false condition (no jump)
    {
        const bytecode = [_]u8{
            0x60, 0x00, // PUSH1 0 - false condition
            0x60, 0x06, // PUSH1 6 - destination (top of stack)
            0x57, // JUMPI (pc=4)
            0x00, // STOP (pc=5) - should execute this
            0x5b, // JUMPDEST (pc=6)
        };

        var frame = try MinimalFrame.init(
            allocator,
            &bytecode,
            10000,
            Address{ .bytes = @splat(0) },
            Address{ .bytes = @splat(0) },
            0,
            &.{},
            &evm,
            evm.hardfork,
        );
        defer frame.deinit();

        // Execute and verify we didn't jump
        try frame.execute();
        try testing.expectEqual(@as(u32, 5), frame.pc); // Should stop at STOP
        try testing.expect(frame.stopped);
    }

    // Test 5: Invalid JUMPI to non-JUMPDEST
    {
        const bytecode = [_]u8{
            0x60, 0x01, // PUSH1 1 - true condition
            0x60, 0x05, // PUSH1 5 - invalid destination (top of stack)
            0x57, // JUMPI (pc=4)
            0xFE, // INVALID (pc=5) - not a JUMPDEST
            0x5b, // JUMPDEST (pc=6)
        };

        var frame = try MinimalFrame.init(
            allocator,
            &bytecode,
            10000,
            Address{ .bytes = @splat(0) },
            Address{ .bytes = @splat(0) },
            0,
            &.{},
            &evm,
            evm.hardfork,
        );
        defer frame.deinit();

        // Execute and expect InvalidJump error
        const result = frame.execute();
        try testing.expectError(error.InvalidJump, result);
    }

    // Test 6: Jump destination inside PUSH data should fail
    {
        const bytecode = [_]u8{
            0x60, 0x03, // PUSH1 3 - trying to jump into PUSH data
            0x56, // JUMP (pc=2)
            0x60, 0x5b, // PUSH1 0x5b (pc=3,4) - the 0x5b at pc=4 looks like JUMPDEST but it's data!
            0x00, // STOP
        };

        var frame = try MinimalFrame.init(
            allocator,
            &bytecode,
            10000,
            Address{ .bytes = @splat(0) },
            Address{ .bytes = @splat(0) },
            0,
            &.{},
            &evm,
            evm.hardfork,
        );
        defer frame.deinit();

        // Execute and expect InvalidJump error (pc=3 is inside PUSH1 instruction)
        const result = frame.execute();
        try testing.expectError(error.InvalidJump, result);
    }
}

test "callMemoryExpansionCost - basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var evm = try MinimalEvm.init(allocator);
    defer evm.deinit();

    evm.setBlockchainContext(
        1,
        100,
        1000,
        1,
        1,
        Address{ .bytes = @splat(0) },
        30000000,
        1,
        1,
    );
    evm.setTransactionContext(Address{ .bytes = @splat(0) }, 1);

    const bytecode = [_]u8{0x00}; // STOP
    var frame = try MinimalFrame.init(
        allocator,
        &bytecode,
        1000000,
        Address{ .bytes = @splat(0) },
        Address{ .bytes = @splat(0) },
        0,
        &.{},
        &evm,
        .CANCUN,
    );
    defer frame.deinit();

    // Test 1: No memory expansion (both sizes are 0)
    {
        const cost = try frame.callMemoryExpansionCost(0, 0, 0, 0);
        try testing.expectEqual(@as(u64, 0), cost);
    }

    // Test 2: Input only (32 bytes at offset 0)
    {
        const cost = try frame.callMemoryExpansionCost(0, 32, 0, 0);
        // 1 word = 3 gas + 1²/512 = 3 gas
        try testing.expectEqual(@as(u64, 3), cost);
    }

    // Test 3: Return only (32 bytes at offset 0)
    {
        frame.memory_size = 0; // Reset
        const cost = try frame.callMemoryExpansionCost(0, 0, 0, 32);
        try testing.expectEqual(@as(u64, 3), cost);
    }

    // Test 4: Both input and return at same location (no additional cost)
    {
        frame.memory_size = 0; // Reset
        const cost = try frame.callMemoryExpansionCost(0, 32, 0, 32);
        try testing.expectEqual(@as(u64, 3), cost); // Still 1 word
    }

    // Test 5: Non-overlapping regions - return extends further
    {
        frame.memory_size = 0; // Reset
        const cost = try frame.callMemoryExpansionCost(0, 32, 32, 32);
        // 2 words = 3*2 + 4/512 = 6 gas
        try testing.expectEqual(@as(u64, 6), cost);
    }

    // Test 6: Non-overlapping regions - input extends further
    {
        frame.memory_size = 0; // Reset
        const cost = try frame.callMemoryExpansionCost(0, 64, 0, 32);
        // 2 words = 3*2 + 4/512 = 6 gas
        try testing.expectEqual(@as(u64, 6), cost);
    }

    // Test 7: Large memory expansion with quadratic term
    {
        frame.memory_size = 0; // Reset
        const cost = try frame.callMemoryExpansionCost(0, 1024, 0, 0);
        // 32 words = 3*32 + 32²/512 = 96 + 2 = 98 gas
        try testing.expectEqual(@as(u64, 98), cost);
    }

    // Test 8: Expansion from existing memory
    {
        frame.memory_size = 64; // 2 words already allocated
        const cost = try frame.callMemoryExpansionCost(0, 128, 0, 0);
        // Expansion from 2 words to 4 words
        // Current cost: 3*2 + 4/512 = 6
        // New cost: 3*4 + 16/512 = 12
        // Expansion: 12 - 6 = 6 gas
        try testing.expectEqual(@as(u64, 6), cost);
    }

    // Test 9: Both regions beyond current memory
    {
        frame.memory_size = 0; // Reset
        const cost = try frame.callMemoryExpansionCost(64, 32, 128, 32);
        // max(96, 160) = 160 bytes = 5 words
        // Cost = 3*5 + 25/512 = 15 gas
        try testing.expectEqual(@as(u64, 15), cost);
    }

    // Test 10: Zero-size input with large return
    {
        frame.memory_size = 0; // Reset
        const cost = try frame.callMemoryExpansionCost(0, 0, 1000, 100);
        // 1100 bytes = 35 words (ceil(1100/32))
        // Cost = 3*35 + 35²/512 = 105 + 2 = 107 gas
        try testing.expectEqual(@as(u64, 107), cost);
    }

    // Test 11: Large input with zero-size return
    {
        frame.memory_size = 0; // Reset
        const cost = try frame.callMemoryExpansionCost(2000, 200, 0, 0);
        // 2200 bytes = 69 words (ceil(2200/32))
        // Cost = 3*69 + 69²/512 = 207 + 9 = 216 gas
        try testing.expectEqual(@as(u64, 216), cost);
    }

    // Test 12: Offset at 0, size 0 (edge case)
    {
        frame.memory_size = 0; // Reset
        const cost = try frame.callMemoryExpansionCost(0, 0, 0, 0);
        try testing.expectEqual(@as(u64, 0), cost);
    }

    // Test 13: Large offset with small size
    {
        frame.memory_size = 0; // Reset
        const cost = try frame.callMemoryExpansionCost(10000, 32, 0, 0);
        // 10032 bytes = 314 words (ceil(10032/32))
        // Cost = 3*314 + 314²/512 = 942 + 192 = 1134 gas
        try testing.expectEqual(@as(u64, 1134), cost);
    }

    // Test 14: Return region larger and further than input
    {
        frame.memory_size = 0; // Reset
        const cost = try frame.callMemoryExpansionCost(0, 32, 100, 200);
        // max(32, 300) = 300 bytes = 10 words (ceil(300/32))
        // Cost = 3*10 + 100/512 = 30 gas
        try testing.expectEqual(@as(u64, 30), cost);
    }

    // Test 15: Input region larger and further than return
    {
        frame.memory_size = 0; // Reset
        const cost = try frame.callMemoryExpansionCost(100, 200, 0, 32);
        // max(300, 32) = 300 bytes = 10 words
        // Cost = 3*10 + 100/512 = 30 gas
        try testing.expectEqual(@as(u64, 30), cost);
    }

    // Test 16: Exactly one word boundary
    {
        frame.memory_size = 0; // Reset
        const cost = try frame.callMemoryExpansionCost(0, 31, 0, 0);
        // 31 bytes = 1 word (ceil(31/32))
        // Cost = 3*1 + 1/512 = 3 gas
        try testing.expectEqual(@as(u64, 3), cost);
    }

    // Test 17: Just over one word boundary
    {
        frame.memory_size = 0; // Reset
        const cost = try frame.callMemoryExpansionCost(0, 33, 0, 0);
        // 33 bytes = 2 words (ceil(33/32))
        // Cost = 3*2 + 4/512 = 6 gas
        try testing.expectEqual(@as(u64, 6), cost);
    }
}

test "callMemoryExpansionCost - overflow protection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var evm = try MinimalEvm.init(allocator);
    defer evm.deinit();

    evm.setBlockchainContext(
        1,
        100,
        1000,
        1,
        1,
        Address{ .bytes = @splat(0) },
        30000000,
        1,
        1,
    );
    evm.setTransactionContext(Address{ .bytes = @splat(0) }, 1);

    const bytecode = [_]u8{0x00}; // STOP
    var frame = try MinimalFrame.init(
        allocator,
        &bytecode,
        1000000,
        Address{ .bytes = @splat(0) },
        Address{ .bytes = @splat(0) },
        0,
        &.{},
        &evm,
        .CANCUN,
    );
    defer frame.deinit();

    // Test overflow in input region
    {
        const result = frame.callMemoryExpansionCost(std.math.maxInt(u64) - 10, 20, 0, 0);
        try testing.expectError(error.OutOfBounds, result);
    }

    // Test overflow in return region
    {
        const result = frame.callMemoryExpansionCost(0, 0, std.math.maxInt(u64) - 10, 20);
        try testing.expectError(error.OutOfBounds, result);
    }

    // Test overflow in both regions
    {
        const result = frame.callMemoryExpansionCost(std.math.maxInt(u64) - 10, 20, std.math.maxInt(u64) - 10, 20);
        try testing.expectError(error.OutOfBounds, result);
    }
}

test "MinimalFrame SLOAD and SSTORE gas follow each fork's schedule" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const sload = [_]u8{ 0x60, 0x00, 0x54 }; // PUSH1 0, SLOAD
    const sstore = [_]u8{ 0x60, 0x01, 0x60, 0x00, 0x55 }; // PUSH1 1, PUSH1 0, SSTORE (0 -> 1)
    const Case = struct { hardfork: Hardfork, code: []const u8, gas: i64 };
    const cases = [_]Case{
        .{ .hardfork = .FRONTIER, .code = &sload, .gas = 3 + 50 },
        .{ .hardfork = .TANGERINE_WHISTLE, .code = &sload, .gas = 3 + 200 },
        .{ .hardfork = .PETERSBURG, .code = &sload, .gas = 3 + 200 },
        .{ .hardfork = .ISTANBUL, .code = &sload, .gas = 3 + 800 },
        .{ .hardfork = .BERLIN, .code = &sload, .gas = 3 + 2100 },
        .{ .hardfork = .CANCUN, .code = &sload, .gas = 3 + 2100 },
        .{ .hardfork = .FRONTIER, .code = &sstore, .gas = 6 + 20000 },
        .{ .hardfork = .PETERSBURG, .code = &sstore, .gas = 6 + 20000 },
        .{ .hardfork = .ISTANBUL, .code = &sstore, .gas = 6 + 20000 },
        .{ .hardfork = .BERLIN, .code = &sstore, .gas = 6 + 22100 },
        .{ .hardfork = .LONDON, .code = &sstore, .gas = 6 + 22100 },
        .{ .hardfork = .CANCUN, .code = &sstore, .gas = 6 + 22100 },
    };
    for (cases) |case| {
        const evm = try MinimalEvm.initPtr(allocator);
        defer evm.deinitPtr(allocator);
        evm.setHardfork(case.hardfork);

        var frame = try MinimalFrame.init(
            allocator,
            case.code,
            100000,
            Address{ .bytes = @as([20]u8, @splat(0)) },
            Address{ .bytes = @as([20]u8, @splat(0)) },
            0,
            &.{},
            evm,
            case.hardfork,
        );
        defer frame.deinit();

        try frame.execute();
        try testing.expectEqual(@as(i64, 100000) - case.gas, frame.gas_remaining);
    }
}

test "MinimalFrame SSTORE applies the EIP-2200 sentry and fork refunds" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Sentry: PUSH1 0, PUSH1 0, SSTORE with exactly 2300 gas left at the SSTORE.
    {
        const evm = try MinimalEvm.initPtr(allocator);
        defer evm.deinitPtr(allocator);
        evm.setHardfork(.CANCUN);
        const code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x55 };
        var frame = try MinimalFrame.init(allocator, &code, 6 + 2300, Address{ .bytes = @as([20]u8, @splat(0)) }, Address{ .bytes = @as([20]u8, @splat(0)) }, 0, &.{}, evm, .CANCUN);
        defer frame.deinit();
        try testing.expectError(error.OutOfGas, frame.execute());
    }

    // Refund: set 0 -> 1 then back to 0 restores the original zero.
    const Case = struct { hardfork: Hardfork, refund: u64 };
    const cases = [_]Case{
        .{ .hardfork = .ISTANBUL, .refund = 19200 },
        .{ .hardfork = .BERLIN, .refund = 19900 },
        .{ .hardfork = .CANCUN, .refund = 19900 },
        .{ .hardfork = .PETERSBURG, .refund = 15000 },
    };
    for (cases) |case| {
        const evm = try MinimalEvm.initPtr(allocator);
        defer evm.deinitPtr(allocator);
        evm.setHardfork(case.hardfork);
        const code = [_]u8{ 0x60, 0x01, 0x60, 0x00, 0x55, 0x60, 0x00, 0x60, 0x00, 0x55 };
        var frame = try MinimalFrame.init(allocator, &code, 100000, Address{ .bytes = @as([20]u8, @splat(0)) }, Address{ .bytes = @as([20]u8, @splat(0)) }, 0, &.{}, evm, case.hardfork);
        defer frame.deinit();
        try frame.execute();
        try testing.expectEqual(case.refund, evm.gas_refund);
    }
}

test "MinimalFrame SELFDESTRUCT: self beneficiary, deadness, static context, EIP-6780, single refund" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const contract = Address{ .bytes = @as([20]u8, @splat(0xAA)) };
    const other = Address{ .bytes = @as([20]u8, @splat(0xBB)) };
    const caller = Address{ .bytes = @as([20]u8, @splat(0x01)) };

    // ADDRESS, SELFDESTRUCT: the contract names itself as beneficiary.
    const destroy_to_self = [_]u8{ 0x30, 0xff };
    // PUSH20 other, SELFDESTRUCT
    const destroy_to_other = [_]u8{0x73} ++ @as([20]u8, @splat(0xBB)) ++ [_]u8{0xff};

    // Cancun, not created in this transaction: the contract survives and a
    // self-beneficiary leaves its balance untouched (it is neither doubled nor burned).
    {
        const evm = try MinimalEvm.initPtr(allocator);
        defer evm.deinitPtr(allocator);
        evm.setHardfork(.CANCUN);
        try evm.setBalance(contract, 1000);
        var frame = try MinimalFrame.init(allocator, &destroy_to_self, 100_000, caller, contract, 0, &.{}, evm, .CANCUN);
        defer frame.deinit();
        try frame.execute();
        try testing.expect(frame.stopped);
        try testing.expectEqual(@as(u256, 1000), evm.get_balance(contract));
    }

    // Cancun, created in this transaction: the contract is deleted and a
    // self-beneficiary burns the balance.
    {
        const evm = try MinimalEvm.initPtr(allocator);
        defer evm.deinitPtr(allocator);
        evm.setHardfork(.CANCUN);
        try evm.setBalance(contract, 1000);
        try evm.markCreated(contract);
        var frame = try MinimalFrame.init(allocator, &destroy_to_self, 100_000, caller, contract, 0, &.{}, evm, .CANCUN);
        defer frame.deinit();
        try frame.execute();
        try testing.expectEqual(@as(u256, 0), evm.get_balance(contract));
    }

    // Before Cancun the contract is always deleted: a self-beneficiary burns the balance.
    {
        const evm = try MinimalEvm.initPtr(allocator);
        defer evm.deinitPtr(allocator);
        evm.setHardfork(.SHANGHAI);
        try evm.setBalance(contract, 1000);
        var frame = try MinimalFrame.init(allocator, &destroy_to_self, 100_000, caller, contract, 0, &.{}, evm, .SHANGHAI);
        defer frame.deinit();
        try frame.execute();
        try testing.expectEqual(@as(u256, 0), evm.get_balance(contract));
    }

    // A different beneficiary receives the whole balance.
    {
        const evm = try MinimalEvm.initPtr(allocator);
        defer evm.deinitPtr(allocator);
        evm.setHardfork(.CANCUN);
        try evm.setBalance(contract, 1000);
        try evm.setBalance(other, 5);
        var frame = try MinimalFrame.init(allocator, &destroy_to_other, 100_000, caller, contract, 0, &.{}, evm, .CANCUN);
        defer frame.deinit();
        try frame.execute();
        try testing.expectEqual(@as(u256, 0), evm.get_balance(contract));
        try testing.expectEqual(@as(u256, 1005), evm.get_balance(other));
    }

    // Deadness includes the nonce. A beneficiary with a nonce but no balance and no code
    // is not dead, so no new-account gas is charged: PUSH20 (3) + SELFDESTRUCT (5000)
    // + cold access (2600). The same beneficiary without a nonce costs 25000 more.
    {
        const Case = struct { nonce: u64, gas: i64 };
        const cases = [_]Case{
            .{ .nonce = 1, .gas = 3 + 5000 + 2600 },
            .{ .nonce = 0, .gas = 3 + 5000 + 2600 + 25000 },
        };
        for (cases) |case| {
            const evm = try MinimalEvm.initPtr(allocator);
            defer evm.deinitPtr(allocator);
            evm.setHardfork(.CANCUN);
            try evm.setBalance(contract, 1000);
            try evm.setNonce(other, case.nonce);
            var frame = try MinimalFrame.init(allocator, &destroy_to_other, 100_000, caller, contract, 0, &.{}, evm, .CANCUN);
            defer frame.deinit();
            try frame.execute();
            try testing.expectEqual(@as(i64, 100_000) - case.gas, frame.gas_remaining);
        }
    }

    // A static context forbids SELFDESTRUCT and moves no balance.
    {
        const evm = try MinimalEvm.initPtr(allocator);
        defer evm.deinitPtr(allocator);
        evm.setHardfork(.CANCUN);
        try evm.setBalance(contract, 1000);
        try evm.setBalance(other, 5);
        var frame = try MinimalFrame.init(allocator, &destroy_to_other, 100_000, caller, contract, 0, &.{}, evm, .CANCUN);
        defer frame.deinit();
        frame.is_static = true;
        try testing.expectError(error.WriteProtection, frame.execute());
        try testing.expectEqual(@as(u256, 1000), evm.get_balance(contract));
        try testing.expectEqual(@as(u256, 5), evm.get_balance(other));
    }

    // Before London the 24000 refund is granted once per contract per transaction.
    {
        const evm = try MinimalEvm.initPtr(allocator);
        defer evm.deinitPtr(allocator);
        evm.setHardfork(.BERLIN);
        for (0..2) |_| {
            var frame = try MinimalFrame.init(allocator, &destroy_to_other, 100_000, caller, contract, 0, &.{}, evm, .BERLIN);
            defer frame.deinit();
            try frame.execute();
        }
        try testing.expectEqual(@as(u64, 24000), evm.gas_refund);
    }
}

test "W3-13: MinimalFrame refuses SSTORE, TSTORE, LOG and value CALL in a static context" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const caller = Address{ .bytes = @as([20]u8, @splat(0x01)) };
    const contract = Address{ .bytes = @as([20]u8, @splat(0xAA)) };
    const other = Address{ .bytes = @as([20]u8, @splat(0xBB)) };

    const sstore = [_]u8{ 0x60, 0x01, 0x60, 0x00, 0x55 };
    const tstore = [_]u8{ 0x60, 0x01, 0x60, 0x00, 0x5d };
    const log0 = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xa0 };
    const log4 = [_]u8{ 0x5f, 0x5f, 0x5f, 0x5f, 0x60, 0x00, 0x60, 0x00, 0xa4 };
    // CALL(gas, other, value 1, no data)
    const value_call = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x01, 0x73 } ++
        @as([20]u8, @splat(0xBB)) ++ [_]u8{ 0x5a, 0xf1 };
    const forbidden = [_][]const u8{ &sstore, &tstore, &log0, &log4, &value_call };

    for (forbidden) |code| {
        // The same code runs to its end outside a static context.
        for ([_]bool{ false, true }) |is_static| {
            const evm = try MinimalEvm.initPtr(allocator);
            defer evm.deinitPtr(allocator);
            evm.setHardfork(.CANCUN);
            try evm.setBalance(contract, 10);
            var frame = try MinimalFrame.init(evm.allocator, code, 1_000_000, caller, contract, 0, &.{}, evm, .CANCUN);
            frame.is_static = is_static;
            try evm.frames.append(evm.allocator, &frame);
            if (!is_static) {
                try frame.execute();
                continue;
            }
            try testing.expectError(error.WriteProtection, frame.execute());
            try testing.expectEqual(@as(u256, 0), evm.get_storage(contract, 0));
            try testing.expectEqual(@as(u256, 0), evm.get_transient_storage(contract, 0));
            try testing.expectEqual(@as(u256, 10), evm.get_balance(contract));
            try testing.expectEqual(@as(u256, 0), evm.get_balance(other));
        }
    }

    // A CALL without value is allowed in a static context, and the callee inherits it.
    {
        const evm = try MinimalEvm.initPtr(allocator);
        defer evm.deinitPtr(allocator);
        evm.setHardfork(.CANCUN);
        try evm.setCode(other, &sstore);
        const plain_call = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x73 } ++
            @as([20]u8, @splat(0xBB)) ++ [_]u8{ 0x5a, 0xf1 };
        var frame = try MinimalFrame.init(evm.allocator, &plain_call, 1_000_000, caller, contract, 0, &.{}, evm, .CANCUN);
        frame.is_static = true;
        try evm.frames.append(evm.allocator, &frame);
        try frame.execute();
        // The callee's SSTORE failed, so CALL pushed 0 and nothing was stored.
        try testing.expectEqual(@as(u256, 0), try frame.peekStack(0));
        try testing.expectEqual(@as(u256, 0), evm.get_storage(other, 0));
    }

    // STATICCALL makes the callee static.
    {
        const evm = try MinimalEvm.initPtr(allocator);
        defer evm.deinitPtr(allocator);
        evm.setHardfork(.CANCUN);
        try evm.setCode(other, &sstore);
        const result = try evm.inner_static_call(other, &.{}, 100_000);
        try testing.expect(!result.success);
        try testing.expectEqual(@as(u64, 0), result.gas_left);
        try testing.expectEqual(@as(u256, 0), evm.get_storage(other, 0));
    }
}

test "W3-13: CALLCODE and DELEGATECALL run the target's code in the caller's context" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const sender = Address{ .bytes = @as([20]u8, @splat(0x01)) };
    const contract = Address{ .bytes = @as([20]u8, @splat(0xAA)) };
    const library = Address{ .bytes = @as([20]u8, @splat(0xBB)) };

    // SSTORE(0, ADDRESS); SSTORE(1, CALLER); SSTORE(2, CALLVALUE); STOP
    const library_code = [_]u8{ 0x30, 0x60, 0x00, 0x55, 0x33, 0x60, 0x01, 0x55, 0x34, 0x60, 0x02, 0x55, 0x00 };
    // DELEGATECALL(gas, library, no data); STOP
    const delegatecall = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x73 } ++
        @as([20]u8, @splat(0xBB)) ++ [_]u8{ 0x5a, 0xf4, 0x00 };
    // CALLCODE(gas, library, value 3, no data); STOP
    const callcode = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x03, 0x73 } ++
        @as([20]u8, @splat(0xBB)) ++ [_]u8{ 0x5a, 0xf2, 0x00 };

    const Case = struct { code: []const u8, seen_caller: Address, seen_value: u256 };
    const cases = [_]Case{
        // DELEGATECALL keeps the frame's own caller and value.
        .{ .code = &delegatecall, .seen_caller = sender, .seen_value = 7 },
        // CALLCODE is a call from the contract to itself with the value argument.
        .{ .code = &callcode, .seen_caller = contract, .seen_value = 3 },
    };
    for (cases) |case| {
        const evm = try MinimalEvm.initPtr(allocator);
        defer evm.deinitPtr(allocator);
        evm.setHardfork(.CANCUN);
        try evm.setCode(library, &library_code);
        try evm.setBalance(contract, 10);

        var frame = try MinimalFrame.init(evm.allocator, case.code, 1_000_000, sender, contract, 7, &.{}, evm, .CANCUN);
        try evm.frames.append(evm.allocator, &frame);
        try frame.execute();

        try testing.expectEqual(@as(u256, 1), try frame.peekStack(0));
        // The writes land in the calling contract's storage, not the library's.
        try testing.expectEqual(primitives.Address.toU256(contract), evm.get_storage(contract, 0));
        try testing.expectEqual(primitives.Address.toU256(case.seen_caller), evm.get_storage(contract, 1));
        try testing.expectEqual(case.seen_value, evm.get_storage(contract, 2));
        try testing.expectEqual(@as(u256, 0), evm.get_storage(library, 0));
        try testing.expectEqual(@as(u256, 0), evm.get_storage(library, 1));
        // No value leaves the contract: CALLCODE sends to itself.
        try testing.expectEqual(@as(u256, 10), evm.get_balance(contract));
        try testing.expectEqual(@as(u256, 0), evm.get_balance(library));
    }
}

test "W3-13: a CALL or CALLCODE that sends value gives the callee the 2300 stipend" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const sender = Address{ .bytes = @as([20]u8, @splat(0x01)) };
    const contract = Address{ .bytes = @as([20]u8, @splat(0xAA)) };
    const callee = Address{ .bytes = @as([20]u8, @splat(0xBB)) };

    // GAS; MSTORE(0, gas); RETURN(0, 32)
    const callee_code = [_]u8{ 0x5a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    inline for ([_]u8{ 0xf1, 0xf2 }) |call_opcode| {
        const evm = try MinimalEvm.initPtr(allocator);
        defer evm.deinitPtr(allocator);
        evm.setHardfork(.CANCUN);
        try evm.setCode(callee, &callee_code);
        try evm.setBalance(contract, 10);

        // CALL/CALLCODE(gas 0, callee, value 1, no input, output to memory[0..32]); STOP
        const code = [_]u8{ 0x60, 0x20, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x01, 0x73 } ++
            @as([20]u8, @splat(0xBB)) ++ [_]u8{ 0x60, 0x00, call_opcode, 0x00 };
        var frame = try MinimalFrame.init(evm.allocator, &code, 1_000_000, sender, contract, 0, &.{}, evm, .CANCUN);
        try evm.frames.append(evm.allocator, &frame);
        try frame.execute();

        try testing.expectEqual(@as(u256, 1), try frame.peekStack(0));
        // The callee asked for no gas and ran on the stipend alone: 2300 minus GAS (2).
        var seen: u256 = 0;
        for (0..32) |index| seen = (seen << 8) | frame.readMemory(@intCast(index));
        try testing.expectEqual(@as(u256, 2300 - 2), seen);
    }
}

test "W3-13: MinimalFrame arithmetic on offsets, sizes and gas cannot overflow" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const zero = Address{ .bytes = @as([20]u8, @splat(0)) };
    const max_u32 = std.math.maxInt(u32);
    const max_u64 = std.math.maxInt(u64);

    const evm = try MinimalEvm.initPtr(allocator);
    defer evm.deinitPtr(allocator);
    evm.setHardfork(.CANCUN);

    // Pure helpers at the edge of their domain.
    try testing.expectEqual(@as(u64, max_u64 / 32 + 1), MinimalFrame.wordCount(max_u64));
    try testing.expectError(error.OutOfBounds, MinimalFrame.wordAlignedSize(max_u64));
    try testing.expectError(error.OutOfBounds, MinimalFrame.wordAlignedSize(@as(u64, max_u32) + 1));
    try testing.expectEqual(@as(u32, 0xFFFF_FFE0), try MinimalFrame.wordAlignedSize(0xFFFF_FFE0));
    try testing.expectEqual(@as(u64, max_u64), MinimalFrame.memoryCost(max_u64));
    try testing.expectEqual(@as(u64, max_u64), MinimalFrame.memoryCost(@as(u64, 1) << 32));
    try testing.expectEqual(@as(u64, 3 * 2 + 4 / 512), MinimalFrame.memoryCost(2));

    {
        var frame = try MinimalFrame.init(evm.allocator, &.{}, 1000, zero, zero, 0, &.{}, evm, .CANCUN);
        // A size no frame can pay for is a huge cost, not a wrapped small one.
        try testing.expect(frame.memoryExpansionCost(max_u64) > 1 << 62);
        try testing.expectError(error.OutOfBounds, frame.callMemoryExpansionCost(max_u64, 1, 0, 0));
        try testing.expectError(error.OutOfBounds, frame.callMemoryExpansionCost(0, 0, 1, max_u64));

        // The last addressable byte would need a size of 2^32, which does not fit.
        try testing.expectError(error.OutOfBounds, frame.writeMemory(max_u32, 1));
        try testing.expectEqual(@as(u32, 0), frame.memory_size);
        try frame.writeMemory(0xFFFF_FFDF, 1);
        try testing.expectEqual(@as(u32, 0xFFFF_FFE0), frame.memory_size);

        // A charge beyond i64 is an out-of-gas halt.
        try testing.expectError(error.OutOfGas, frame.consumeGas(max_u64));
        try testing.expectEqual(@as(i64, 0), frame.gas_remaining);
        frame.gas_remaining = 10;
        try testing.expectError(error.OutOfGas, frame.consumeGas(@as(u64, std.math.maxInt(i64)) + 1));
        frame.gas_remaining = 10;
        try frame.consumeGas(10);
        try testing.expectEqual(@as(i64, 0), frame.gas_remaining);
    }

    // CALLDATALOAD at offsets where `offset + i` passes the u32 maximum reads zeros.
    {
        const calldata = [_]u8{ 0x11, 0x22, 0x33 };
        const Case = struct { offset: u32, word: u256 };
        const cases = [_]Case{
            .{ .offset = max_u32, .word = 0 },
            .{ .offset = max_u32 - 31, .word = 0 },
            .{ .offset = max_u32 - 1, .word = 0 },
            .{ .offset = 2, .word = @as(u256, 0x33) << 248 },
            .{ .offset = 3, .word = 0 },
        };
        for (cases) |case| {
            // PUSH4 offset, CALLDATALOAD
            var code = [_]u8{ 0x63, 0, 0, 0, 0, 0x35 };
            std.mem.writeInt(u32, code[1..5], case.offset, .big);
            var frame = try MinimalFrame.init(evm.allocator, &code, 1000, zero, zero, 0, &calldata, evm, .CANCUN);
            try frame.execute();
            try testing.expectEqual(case.word, try frame.peekStack(0));
            try testing.expectEqual(@as(i64, 1000 - 6), frame.gas_remaining);
        }
    }

    // A zero-length copy touches no memory, so offsets up to 2^256 - 1 are valid.
    {
        const all_ones = @as([32]u8, @splat(0xFF));
        const operands = [_]u8{ 0x60, 0x00, 0x7f } ++ all_ones ++ [_]u8{0x7f} ++ all_ones;
        const calldatacopy = operands ++ [_]u8{0x37};
        const codecopy = operands ++ [_]u8{0x39};
        const mcopy = operands ++ [_]u8{0x5e};
        // EXTCODECOPY takes the account first: 3 x 4 pushes plus the cold access.
        const extcodecopy = operands ++ [_]u8{ 0x60, 0xEE, 0x3c };
        const Case = struct { code: []const u8, gas: i64 };
        const cases = [_]Case{
            .{ .code = &calldatacopy, .gas = 9 + 3 },
            .{ .code = &codecopy, .gas = 9 + 3 },
            .{ .code = &mcopy, .gas = 9 + 3 },
            .{ .code = &extcodecopy, .gas = 12 + 2600 },
        };
        for (cases) |case| {
            var frame = try MinimalFrame.init(evm.allocator, case.code, 100_000, zero, zero, 0, &.{}, evm, .CANCUN);
            try frame.execute();
            try testing.expectEqual(@as(i64, 100_000) - case.gas, frame.gas_remaining);
            try testing.expectEqual(@as(u32, 0), frame.memory_size);
            try testing.expectEqual(@as(usize, 0), frame.stack.items.len);
        }

        // A non-zero length at such an offset is refused, not wrapped.
        const one_byte = [_]u8{ 0x60, 0x01, 0x60, 0x00, 0x7f } ++ all_ones ++ [_]u8{0x37};
        var frame = try MinimalFrame.init(evm.allocator, &one_byte, 100_000, zero, zero, 0, &.{}, evm, .CANCUN);
        try testing.expectError(error.OutOfBounds, frame.execute());
    }
}

test "W3-13: EXTCODESIZE, EXTCODECOPY, EXTCODEHASH and BLOBHASH read real state" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const zero = Address{ .bytes = @as([20]u8, @splat(0)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xBB)) };
    const target_code = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00 };
    const push_target = [_]u8{0x73} ++ @as([20]u8, @splat(0xBB));

    const evm = try MinimalEvm.initPtr(allocator);
    defer evm.deinitPtr(allocator);
    evm.setHardfork(.CANCUN);
    try evm.setCode(target, &target_code);

    {
        const code = push_target ++ [_]u8{0x3b};
        var frame = try MinimalFrame.init(evm.allocator, &code, 100_000, zero, zero, 0, &.{}, evm, .CANCUN);
        try frame.execute();
        try testing.expectEqual(@as(u256, target_code.len), try frame.peekStack(0));
    }
    {
        var expected: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(&target_code, &expected, .{});
        const code = push_target ++ [_]u8{0x3f};
        var frame = try MinimalFrame.init(evm.allocator, &code, 100_000, zero, zero, 0, &.{}, evm, .CANCUN);
        try frame.execute();
        try testing.expectEqual(std.mem.readInt(u256, &expected, .big), try frame.peekStack(0));
    }
    {
        // EXTCODEHASH of an account that does not exist is 0.
        const code = [_]u8{0x73} ++ @as([20]u8, @splat(0xCC)) ++ [_]u8{0x3f};
        var frame = try MinimalFrame.init(evm.allocator, &code, 100_000, zero, zero, 0, &.{}, evm, .CANCUN);
        try frame.execute();
        try testing.expectEqual(@as(u256, 0), try frame.peekStack(0));
    }
    {
        // EXTCODECOPY(target, dest 0, offset 1, length 8): code bytes, then zero padding.
        const code = [_]u8{ 0x60, 0x08, 0x60, 0x01, 0x60, 0x00 } ++ push_target ++ [_]u8{0x3c};
        var frame = try MinimalFrame.init(evm.allocator, &code, 100_000, zero, zero, 0, &.{}, evm, .CANCUN);
        try frame.execute();
        const expected = [_]u8{ 0xAD, 0xBE, 0xEF, 0x00, 0, 0, 0, 0 };
        for (expected, 0..) |byte, index| try testing.expectEqual(byte, frame.readMemory(@intCast(index)));
        try testing.expectEqual(@as(u32, 32), frame.memory_size);
    }
    {
        const hashes = [_][32]u8{ @as([32]u8, @splat(0x01)), @as([32]u8, @splat(0x02)) };
        evm.setBlobVersionedHashes(&hashes);
        defer evm.setBlobVersionedHashes(&.{});
        // BLOBHASH(1), BLOBHASH(2), BLOBHASH(2^256 - 1)
        const code = [_]u8{ 0x60, 0x01, 0x49, 0x60, 0x02, 0x49, 0x7f } ++ @as([32]u8, @splat(0xFF)) ++ [_]u8{0x49};
        var frame = try MinimalFrame.init(evm.allocator, &code, 100_000, zero, zero, 0, &.{}, evm, .CANCUN);
        try frame.execute();
        try testing.expectEqual(@as(u256, 0), try frame.peekStack(0));
        try testing.expectEqual(@as(u256, 0), try frame.peekStack(1));
        try testing.expectEqual(std.mem.readInt(u256, &hashes[1], .big), try frame.peekStack(2));
    }
}
