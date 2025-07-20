const std = @import("std");
const testing = std.testing;

/// Maximum call depth supported by EVM (per EIP-150)
pub const MAX_CALL_DEPTH = 1024;

/// Virtual Machine for executing Ethereum bytecode with frame pool optimization.
///
/// Manages contract execution, gas accounting, state access, and protocol enforcement
/// according to the configured hardfork rules. Features a frame pool to eliminate
/// allocation overhead during contract calls.
pub const Evm = struct {
    // Hot fields (frequently accessed during execution)
    /// Memory allocator for VM operations
    allocator: std.mem.Allocator,
    /// Current call depth for overflow protection
    depth: u16 = 0,
    /// Whether the current context is read-only (STATICCALL)
    read_only: bool = false,

    // Frame pool for eliminating allocation overhead
    /// Pre-allocated frame pool to eliminate allocation overhead during calls
    frame_pool: [MAX_CALL_DEPTH]Frame = undefined,
    /// Tracks which frames in the pool are initialized
    frame_pool_initialized: [MAX_CALL_DEPTH]bool = [_]bool{false} ** MAX_CALL_DEPTH,

    /// Initialize EVM with frame pool
    pub fn init(allocator: std.mem.Allocator) Evm {
        return Evm{
            .allocator = allocator,
            .depth = 0,
            .read_only = false,
            .frame_pool = undefined, // Will be initialized lazily
            .frame_pool_initialized = [_]bool{false} ** MAX_CALL_DEPTH,
        };
    }

    /// Free all VM resources including frame pool
    pub fn deinit(self: *Evm) void {
        self.deinitFramePool();
    }

    /// Get a pooled frame at the current call depth.
    /// Initializes the frame lazily if not already initialized.
    /// Returns error if depth exceeds maximum call depth.
    pub fn getPooledFrame(self: *Evm, gas: u64, contract: *Contract, caller: Address, call_data: []const u8) !*Frame {
        if (self.depth >= MAX_CALL_DEPTH) {
            return Error.DepthLimit;
        }

        const depth_index = self.depth;
        
        if (!self.frame_pool_initialized[depth_index]) {
            self.frame_pool[depth_index] = try Frame.init(
                self.allocator,
                gas,
                contract,
                caller,
                call_data
            );
            self.frame_pool_initialized[depth_index] = true;
        } else {
            try self.frame_pool[depth_index].reset(gas, contract, caller, call_data);
        }
        
        return &self.frame_pool[depth_index];
    }

    /// Cleanup all initialized frames in the pool
    fn deinitFramePool(self: *Evm) void {
        for (0..MAX_CALL_DEPTH) |i| {
            if (self.frame_pool_initialized[i]) {
                self.frame_pool[i].deinit();
                self.frame_pool_initialized[i] = false;
            }
        }
    }

    /// Execute contract with frame pool optimization
    pub fn execute(self: *Evm, contract: *Contract, caller: Address, input: []const u8, gas: u64) !ExecutionResult {
        const frame = try self.getPooledFrame(gas, contract, caller, input);
        
        // Simulate execution
        frame.gas_remaining = frame.gas_remaining -| 21; // Base gas cost
        
        return ExecutionResult{
            .gas_used = gas - frame.gas_remaining,
            .output = &[_]u8{},
            .success = true,
        };
    }
};

/// Simplified Frame structure for testing
pub const Frame = struct {
    allocator: std.mem.Allocator,
    gas_remaining: u64 = 0,
    contract: *Contract = undefined,
    caller: Address = [_]u8{0} ** 20,
    input: []const u8 = &[_]u8{},
    stack: Stack,
    memory: Memory,

    pub fn init(allocator: std.mem.Allocator, gas: u64, contract: *Contract, caller: Address, input: []const u8) !Frame {
        return Frame{
            .allocator = allocator,
            .gas_remaining = gas,
            .contract = contract,
            .caller = caller,
            .input = input,
            .stack = try Stack.init(allocator),
            .memory = try Memory.init(allocator),
        };
    }

    pub fn deinit(self: *Frame) void {
        self.stack.deinit();
        self.memory.deinit();
    }

    pub fn reset(self: *Frame, gas: u64, contract: *Contract, caller: Address, input: []const u8) !void {
        self.gas_remaining = gas;
        self.contract = contract;
        self.caller = caller;
        self.input = input;
        
        self.stack.clear();
        try self.memory.reset();
    }
};

/// Simplified Contract structure
pub const Contract = struct {
    code: []const u8,
    address: Address,

    pub fn init(code: []const u8, address: Address) Contract {
        return Contract{
            .code = code,
            .address = address,
        };
    }
};

/// Simplified Address type
pub const Address = [20]u8;

/// Simplified Stack structure
pub const Stack = struct {
    items: std.ArrayList(u256),

    pub fn init(allocator: std.mem.Allocator) !Stack {
        return Stack{
            .items = std.ArrayList(u256).init(allocator),
        };
    }

    pub fn deinit(self: *Stack) void {
        self.items.deinit();
    }

    pub fn push(self: *Stack, value: u256) !void {
        try self.items.append(value);
    }

    pub fn pop(self: *Stack) Error!u256 {
        if (self.items.items.len == 0) return Error.StackUnderflow;
        const last_index = self.items.items.len - 1;
        const value = self.items.items[last_index];
        self.items.items.len -= 1;
        return value;
    }

    pub fn clear(self: *Stack) void {
        self.items.clearRetainingCapacity();
    }

    pub fn size(self: *Stack) usize {
        return self.items.items.len;
    }
};

/// Simplified Memory structure
pub const Memory = struct {
    data: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) !Memory {
        return Memory{
            .data = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Memory) void {
        self.data.deinit();
    }

    pub fn reset(self: *Memory) !void {
        self.data.clearRetainingCapacity();
    }
};

/// Execution result structure
pub const ExecutionResult = struct {
    gas_used: u64,
    output: []const u8,
    success: bool,
};

/// Error types
pub const Error = error{
    DepthLimit,
    StackUnderflow,
    OutOfGas,
    OutOfMemory,
};

// Tests
test "Evm frame pool initialization and basic usage" {
    var evm = Evm.init(testing.allocator);
    defer evm.deinit();
    
    const contract = Contract.init(&[_]u8{0x01}, [_]u8{0} ** 20);
    const caller = [_]u8{0} ** 20;
    const call_data = &[_]u8{0x02, 0x03};
    
    evm.depth = 0;
    
    const frame1 = try evm.getPooledFrame(1000000, @constCast(&contract), caller, call_data);
    try testing.expectEqual(@as(u64, 1000000), frame1.gas_remaining);
    
    // Modify frame state
    frame1.gas_remaining = 500000;
    try frame1.stack.push(42);
    
    // Get pooled frame again (should reuse and reset)
    const frame2 = try evm.getPooledFrame(2000000, @constCast(&contract), caller, &[_]u8{0x04, 0x05});
    try testing.expectEqual(@as(u64, 2000000), frame2.gas_remaining);
    try testing.expectEqual(@as(usize, 0), frame2.stack.size());
    try testing.expectEqual(@as(usize, 2), frame2.input.len);
    
    try testing.expect(frame1 == frame2); // Same frame reused
}

test "Evm frame pool depth isolation" {
    var evm = Evm.init(testing.allocator);
    defer evm.deinit();
    
    const contract = Contract.init(&[_]u8{0x01}, [_]u8{0} ** 20);
    const caller = [_]u8{0} ** 20;
    const call_data = &[_]u8{0x02, 0x03};
    
    // Get frame at depth 0
    evm.depth = 0;
    const frame_depth_0 = try evm.getPooledFrame(1000000, @constCast(&contract), caller, call_data);
    
    // Get frame at depth 1
    evm.depth = 1;
    const frame_depth_1 = try evm.getPooledFrame(2000000, @constCast(&contract), caller, call_data);
    
    // Should be different frames
    try testing.expect(frame_depth_0 != frame_depth_1);
    try testing.expectEqual(@as(u64, 1000000), frame_depth_0.gas_remaining);
    try testing.expectEqual(@as(u64, 2000000), frame_depth_1.gas_remaining);
}

test "Evm frame pool depth limit enforcement" {
    var evm = Evm.init(testing.allocator);
    defer evm.deinit();
    
    const contract = Contract.init(&[_]u8{0x01}, [_]u8{0} ** 20);
    const caller = [_]u8{0} ** 20;
    const call_data = &[_]u8{0x02, 0x03};
    
    evm.depth = MAX_CALL_DEPTH;
    
    const result = evm.getPooledFrame(1000000, @constCast(&contract), caller, call_data);
    try testing.expectError(Error.DepthLimit, result);
}

test "Evm execution with frame pool" {
    var evm = Evm.init(testing.allocator);
    defer evm.deinit();
    
    const contract = Contract.init(&[_]u8{0x01, 0x02, 0x03}, [_]u8{0} ** 20);
    const caller = [_]u8{0} ** 20;
    const input = &[_]u8{0x04, 0x05};
    
    const result = try evm.execute(@constCast(&contract), caller, input, 1000000);
    
    try testing.expect(result.success);
    try testing.expect(result.gas_used > 0);
    try testing.expect(result.gas_used <= 1000000);
}