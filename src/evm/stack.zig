//! High-performance EVM stack implementation.
//!
//! Pointer-based stack with downward growth for optimal CPU cache performance.
//! Supports up to 1024 256-bit words as per EVM specification.
//!
//! Key features:
//! - 64-byte cache line alignment
//! - Safe and unsafe operation variants
//! - Automatic index type selection based on capacity
//! - Zero-cost abstractions through compile-time configuration
//!
//! Memory safety is guaranteed through:
//! - Bounds checking in safe operations (push/pop/peek/set_top)
//! - Assertion-based validation in unsafe operations (*_unsafe variants)
//! - Proper ownership of aligned memory allocation
const std = @import("std");

const StackConfig = @import("stack_config.zig").StackConfig;


/// Creates a configured stack type.
///
/// The stack grows downward: push decrements pointer, pop increments.
/// This design optimizes for CPU cache locality and branch prediction.
pub fn Stack(comptime config: StackConfig) type {
    config.validate();


    return struct {
        pub const WordType = config.WordType;
        pub const IndexType = config.StackIndexType();
        pub const stack_capacity = config.stack_size;

        pub const Error = error{
            StackOverflow,
            StackUnderflow,
            AllocationError,
        };

        const Self = @This();

        // Ownership: pointer to aligned memory returned by alignedAlloc
        buf_ptr: [*]align(64) WordType,

        // Downward stack growth: stack_ptr points to next empty slot
        // Push: *stack_ptr = value; stack_ptr -= 1;
        // Pop: stack_ptr += 1; return *stack_ptr;
        stack_ptr: [*]WordType,


        /// Initialize a new stack with allocated memory.
        ///
        /// Allocates cache-aligned memory and sets up pointer boundaries.
        /// Stack pointer starts at the top (highest address) and grows downward.
        pub fn init(allocator: std.mem.Allocator) Error!Self {
            const memory = allocator.alignedAlloc(WordType, @enumFromInt(6), stack_capacity) catch return Error.AllocationError;
            errdefer allocator.free(memory);

            const base_ptr: [*]align(64) WordType = memory.ptr;

            return Self{
                .buf_ptr = base_ptr,
                .stack_ptr = base_ptr + stack_capacity,
            };
        }

        /// Deallocates the stack's aligned memory.
        /// Must be called when the stack is no longer needed.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            const memory_slice = self.buf_ptr[0..stack_capacity];
            allocator.free(memory_slice);
        }

        inline fn stack_base(self: *const Self) [*]WordType {
            return self.buf_ptr + stack_capacity;
        }
        
        inline fn stack_limit(self: *const Self) [*]WordType {
            return self.buf_ptr;
        }

        pub inline fn push_unsafe(self: *Self, value: WordType) void {
            @branchHint(.likely);
            std.debug.assert(@intFromPtr(self.stack_ptr) > @intFromPtr(self.stack_limit()));
            self.stack_ptr -= 1;
            self.stack_ptr[0] = value;
        }

        pub inline fn push(self: *Self, value: WordType) Error!void {
            if (@intFromPtr(self.stack_ptr) <= @intFromPtr(self.stack_limit())) {
                @branchHint(.cold);
                return Error.StackOverflow;
            }
            self.push_unsafe(value);
        }

        pub inline fn pop_unsafe(self: *Self) WordType {
            @branchHint(.likely);
            std.debug.assert(@intFromPtr(self.stack_ptr) < @intFromPtr(self.stack_base()));
            const value = self.stack_ptr[0];
            self.stack_ptr += 1;
            return value;
        }

        pub inline fn pop(self: *Self) Error!WordType {
            if (@intFromPtr(self.stack_ptr) >= @intFromPtr(self.stack_base())) {
                @branchHint(.cold);
                return Error.StackUnderflow;
            }
            return self.pop_unsafe();
        }

        pub inline fn set_top_unsafe(self: *Self, value: WordType) void {
            @branchHint(.likely);
            std.debug.assert(@intFromPtr(self.stack_ptr) < @intFromPtr(self.stack_base()));
            self.stack_ptr[0] = value;
        }

        pub inline fn set_top(self: *Self, value: WordType) Error!void {
            if (@intFromPtr(self.stack_ptr) >= @intFromPtr(self.stack_base())) {
                @branchHint(.cold);
                return Error.StackUnderflow;
            }
            self.set_top_unsafe(value);
        }

        pub inline fn peek_unsafe(self: *const Self) WordType {
            @branchHint(.likely);
            std.debug.assert(@intFromPtr(self.stack_ptr) < @intFromPtr(self.stack_base()));
            return self.stack_ptr[0];
        }

        pub inline fn peek(self: *Self) Error!WordType {
            if (@intFromPtr(self.stack_ptr) >= @intFromPtr(self.stack_base())) {
                @branchHint(.cold);
                return Error.StackUnderflow;
            }
            return self.peek_unsafe();
        }

        // Generic dup function for DUP1-DUP16
        pub fn dup_n(self: *Self, n: u8) Error!void {
            // Check if we have n items on stack
            const current_elements = self.size_internal();
            if (current_elements < n) {
                @branchHint(.cold);
                return Error.StackUnderflow;
            }
            // Check if we have room for one more
            if (@intFromPtr(self.stack_ptr) <= @intFromPtr(self.stack_limit())) {
                @branchHint(.cold);
                return Error.StackOverflow;
            }
            const value = self.stack_ptr[n - 1];
            self.push_unsafe(value);
        }

        // Unsafe generic dup without bounds checks (validated by planner)
        pub inline fn dup_n_unsafe(self: *Self, n: u8) void {
            std.debug.assert(self.size_internal() >= n);
            std.debug.assert(@intFromPtr(self.stack_ptr) > @intFromPtr(self.stack_limit()));
            // In downward stack, nth-from-top is at index n-1
            const value = self.stack_ptr[n - 1];
            self.push_unsafe(value);
        }

        // DUP1-DUP16 operations - individual functions calling generic dup_n
        pub fn dup1(self: *Self) Error!void { return self.dup_n(1); }
        pub fn dup2(self: *Self) Error!void { return self.dup_n(2); }
        pub fn dup3(self: *Self) Error!void { return self.dup_n(3); }
        pub fn dup4(self: *Self) Error!void { return self.dup_n(4); }
        pub fn dup5(self: *Self) Error!void { return self.dup_n(5); }
        pub fn dup6(self: *Self) Error!void { return self.dup_n(6); }
        pub fn dup7(self: *Self) Error!void { return self.dup_n(7); }
        pub fn dup8(self: *Self) Error!void { return self.dup_n(8); }
        pub fn dup9(self: *Self) Error!void { return self.dup_n(9); }
        pub fn dup10(self: *Self) Error!void { return self.dup_n(10); }
        pub fn dup11(self: *Self) Error!void { return self.dup_n(11); }
        pub fn dup12(self: *Self) Error!void { return self.dup_n(12); }
        pub fn dup13(self: *Self) Error!void { return self.dup_n(13); }
        pub fn dup14(self: *Self) Error!void { return self.dup_n(14); }
        pub fn dup15(self: *Self) Error!void { return self.dup_n(15); }
        pub fn dup16(self: *Self) Error!void { return self.dup_n(16); }

        // Generic swap function for SWAP1-SWAP16
        pub fn swap_n(self: *Self, n: u8) Error!void {
            // Check if we have n+1 items on stack
            const current_elements = self.size_internal();
            if (current_elements < n + 1) {
                @branchHint(.cold);
                return Error.StackUnderflow;
            }
            // Swap top with nth item
            std.mem.swap(WordType, &self.stack_ptr[0], &self.stack_ptr[n]);
        }

        // Unsafe generic swap without bounds checks (validated by planner)
        pub inline fn swap_n_unsafe(self: *Self, n: u8) void {
            std.debug.assert(self.size_internal() >= n + 1);
            const tmp = self.stack_ptr[0];
            self.stack_ptr[0] = self.stack_ptr[n];
            self.stack_ptr[n] = tmp;
        }

        // SWAP1-SWAP16 operations - individual functions calling generic swap_n
        pub fn swap1(self: *Self) Error!void { return self.swap_n(1); }
        pub fn swap2(self: *Self) Error!void { return self.swap_n(2); }
        pub fn swap3(self: *Self) Error!void { return self.swap_n(3); }
        pub fn swap4(self: *Self) Error!void { return self.swap_n(4); }
        pub fn swap5(self: *Self) Error!void { return self.swap_n(5); }
        pub fn swap6(self: *Self) Error!void { return self.swap_n(6); }
        pub fn swap7(self: *Self) Error!void { return self.swap_n(7); }
        pub fn swap8(self: *Self) Error!void { return self.swap_n(8); }
        pub fn swap9(self: *Self) Error!void { return self.swap_n(9); }
        pub fn swap10(self: *Self) Error!void { return self.swap_n(10); }
        pub fn swap11(self: *Self) Error!void { return self.swap_n(11); }
        pub fn swap12(self: *Self) Error!void { return self.swap_n(12); }
        pub fn swap13(self: *Self) Error!void { return self.swap_n(13); }
        pub fn swap14(self: *Self) Error!void { return self.swap_n(14); }
        pub fn swap15(self: *Self) Error!void { return self.swap_n(15); }
        pub fn swap16(self: *Self) Error!void { return self.swap_n(16); }
        
        // Internal size calculation without locking
        inline fn size_internal(self: *const Self) usize {
            const bytes_used = @intFromPtr(self.stack_base()) - @intFromPtr(self.stack_ptr);
            return bytes_used / @sizeOf(WordType);
        }
        
        // Accessors for tracer
        pub inline fn size(self: *Self) usize {
            return self.size_internal();
        }
        
        pub inline fn get_slice(self: *Self) []const WordType {
            const count = self.size_internal();
            if (count == 0) return &[_]WordType{};
            // Return slice from stack_ptr to stack_base
            return self.stack_ptr[0..count];
        }
    };
}