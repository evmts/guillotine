const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const ZERO_ADDRESS = primitives.Address.ZERO_ADDRESS;
const ExecutionError = @import("evm").ExecutionError;
const frame_mod = @import("frame.zig");

pub const EvmConfig = struct {
    /// Maximum call depth allowed in the EVM (defaults to 1024 levels)
    /// This prevents infinite recursion and stack overflow attacks
    max_call_depth: u11 = 1024,
    
    /// Maximum input size for interpreter operations (128 KB)
    /// This prevents excessive memory usage in single operations
    max_input_size: u18 = 131072, // 128 KB
    
    /// Frame configuration parameters
    frame_config: frame_mod.FrameConfig = .{},
    
    /// Gets the appropriate type for depth based on max_call_depth
    fn get_depth_type(self: EvmConfig) type {
        return if (self.max_call_depth <= std.math.maxInt(u8))
            u8
        else if (self.max_call_depth <= std.math.maxInt(u11))
            u11
        else
            @compileError("max_call_depth too large");
    }
};

pub fn createEvm(comptime config: EvmConfig) type {
    const Frame = frame_mod.createColdFrame(config.frame_config);
    const DepthType = config.get_depth_type();
    
    return struct {
        const Self = @This();
        
        /// Stack of frames for nested calls
        frames: [config.max_call_depth]*Frame,
        
        /// Current call depth (0 = root call)
        depth: DepthType,
        
        /// Allocator for dynamic memory
        allocator: std.mem.Allocator,

        /// Parameters for different types of EVM calls
    pub const CallParams = union(enum) {
        /// Regular CALL operation
        call: struct {
            caller: Address,
            to: Address,
            value: u256,
            input: []const u8,
            gas: u64,
        },
        /// CALLCODE operation: execute external code with current storage/context
        /// Executes code at `to`, but uses caller's storage and address context
        callcode: struct {
            caller: Address,
            to: Address,
            value: u256,
            input: []const u8,
            gas: u64,
        },
        /// DELEGATECALL operation (preserves caller context)
        delegatecall: struct {
            caller: Address, // Original caller, not current contract
            to: Address,
            input: []const u8,
            gas: u64,
        },
        /// STATICCALL operation (read-only)
        staticcall: struct {
            caller: Address,
            to: Address,
            input: []const u8,
            gas: u64,
        },
        /// CREATE operation
        create: struct {
            caller: Address,
            value: u256,
            init_code: []const u8,
            gas: u64,
        },
        /// CREATE2 operation
        create2: struct {
            caller: Address,
            value: u256,
            init_code: []const u8,
            salt: u256,
            gas: u64,
        },
    };

    /// Result of a call execution
    pub const CallResult = struct {
        /// Indicates whether the call completed successfully.
        ///
        /// - `true`: Call executed without errors and any state changes were committed
        /// - `false`: Call failed due to revert, out of gas, or other errors
        ///
        /// Note: A successful call may still have no output data if the called
        /// contract intentionally returns nothing.
        success: bool,

        /// Amount of gas remaining after the call execution.
        ///
        /// This value is important for gas accounting:
        /// - For successful calls: Indicates unused gas to be refunded to the caller
        /// - For failed calls: May be non-zero if the call reverted (vs running out of gas)
        ///
        /// The calling context should add this back to its available gas to continue execution.
        gas_left: u64,

        /// Optional output data returned by the called contract.
        ///
        /// - `null`: No data was returned (valid for both success and failure)
        /// - `[]const u8`: Returned data buffer
        ///
        /// ## Memory Management
        /// The output data is a view into VM-owned memory (Evm.set_output).
        /// Do not free it; the VM will manage its lifetime. If you need to hold
        /// the data beyond the VM call, make your own copy.
        ///
        /// ## For Different Call Types
        /// - **RETURN**: Contains the data specified in the RETURN opcode
        /// - **REVERT**: Contains the revert reason/data if provided
        /// - **STOP**: Will be null (no data returned)
        /// - **Out of Gas/Invalid**: Will be null
        output: ?[]const u8,
    };
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .frames = undefined, // Will be initialized per call
            .depth = 0,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        _ = self;
        // Cleanup any allocated resources
    }

    pub fn call(self: *Self, params: CallParams) ExecutionError.Error!CallResult {
        // Reset depth for new top-level call
        self.depth = 0;
        
        // TODO: Initialize journal for state tracking
        // TODO: Charge base fee for the transaction
        // TODO: Initialize access list
        // TODO: Initialize trace if needed
        
        // Allocate and initialize the root frame
        const gas = switch (params) {
            inline else => |p| p.gas,
        };
        
        const bytecode = switch (params) {
            .call, .callcode, .delegatecall, .staticcall => blk: {
                // TODO: Load contract code from state for address to
                break :blk &[_]u8{}; // Placeholder
            },
            .create, .create2 => |p| p.init_code,
        };
        
        // Allocate root frame
        var frame = try Frame.init(self.allocator, bytecode, @intCast(gas));
        self.frames[0] = &frame;
        defer {
            frame.deinit(self.allocator);
            // TODO: Clean up any allocated memory
        }
        
        // Call inner_call with initialized frame
        return self.inner_call(params);
    }

    pub fn inner_call(self: *Self, params: CallParams) ExecutionError.Error!CallResult {
        // Check depth limit first (branch hint: cold - this rarely fails)
        if (self.depth >= config.max_call_depth) {
            @branchHint(.cold);
            return CallResult{
                .success = false,
                .gas_left = 0,
                .output = null,
            };
        }
        
        // TODO: Take journal snapshot for potential revert
        // TODO: Validate inputs (gas limits, value transfers, etc.)
        // TODO: Handle precompiled contracts
        // TODO: Handle is_berlin pre-warm address
        // TODO: Initialize correct frame type based on call type
        // TODO: Pass static opcode handlers for STATICCALL
        
        // Get current frame
        const frame = self.frames[self.depth];
        
        // Handle different call types
        switch (params) {
            .call => |p| {
                // TODO: Set up CALL context
                _ = p;
            },
            .callcode => |p| {
                // TODO: Set up CALLCODE context (execute at target but keep storage)
                _ = p;
            },
            .delegatecall => |p| {
                // TODO: Set up DELEGATECALL context (preserve original caller/value)
                _ = p;
            },
            .staticcall => |p| {
                // TODO: Set up STATICCALL context (read-only execution)
                // TODO: Use static opcode handlers that prevent state changes
                _ = p;
            },
            .create => |p| {
                // TODO: Handle CREATE operation
                // TODO: Generate new contract address
                // TODO: Initialize contract
                _ = p;
            },
            .create2 => |p| {
                // TODO: Handle CREATE2 operation  
                // TODO: Generate deterministic contract address using salt
                // TODO: Initialize contract
                _ = p;
            },
        }
        
        // Execute the frame
        frame.interpret(self.allocator) catch |err| {
            // TODO: Handle errors appropriately
            // TODO: Revert journal on failure
            // TODO: Return appropriate gas_left based on error type
            switch (err) {
                else => {
                    return CallResult{
                        .success = false,
                        .gas_left = 0,
                        .output = null,
                    };
                }
            }
        };
        
        // TODO: Handle success case
        // TODO: Commit journal changes
        // TODO: Process return data
        // TODO: Handle nested calls from CALL/CREATE opcodes
        
        return CallResult{
            .success = true,
            .gas_left = @intCast(frame.gas_remaining),
            .output = null, // TODO: Get from frame output
        };
    }
    };
}

// Export the default Evm type
pub const Evm = createEvm(.{});

test "CallParams and CallResult structures" {
    const testing = std.testing;
    
    // Test that CallParams compiles and can be created
    const call_params = Evm.CallParams{
        .call = .{
            .caller = ZERO_ADDRESS,
            .to = ZERO_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = 1000000,
        },
    };
    
    // Test that CallResult can be created
    const result = Evm.CallResult{
        .success = true,
        .gas_left = 900000,
        .output = null,
    };
    
    try testing.expect(call_params == .call);
    try testing.expect(result.success);
    try testing.expectEqual(@as(u64, 900000), result.gas_left);
    try testing.expect(result.output == null);
}

test "Evm creation with custom config" {
    const testing = std.testing;
    
    // Test creating Evm with custom configuration
    const CustomEvm = createEvm(.{
        .max_call_depth = 512,
        .max_input_size = 65536, // 64KB
        .frame_config = .{
            .stack_size = 512,
            .max_bytecode_size = 16384,
        },
    });
    
    var evm = CustomEvm.init(testing.allocator);
    defer evm.deinit();
    
    try testing.expectEqual(@as(u9, 0), evm.depth);
}

test "Evm call depth limit" {
    const testing = std.testing;
    
    var evm = Evm.init(testing.allocator);
    defer evm.deinit();
    
    // Set depth to max
    evm.depth = 1024;
    
    // Try to make a call - should fail due to depth limit
    const result = try evm.inner_call(.{
        .call = .{
            .caller = ZERO_ADDRESS,
            .to = ZERO_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = 1000000,
        },
    });
    
    try testing.expect(!result.success);
    try testing.expectEqual(@as(u64, 0), result.gas_left);
    try testing.expect(result.output == null);
}