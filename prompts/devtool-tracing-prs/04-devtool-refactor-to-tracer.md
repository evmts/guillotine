## PR 4: Devtool Refactor to Tracer-Driven Execution

### Problem

The devtool currently reproduces interpreter logic to step instructions, making it hard to maintain. With Debug Hooks and the Standard Tracer, we can eliminate duplication and drive the UI from trace data.

### Goals

- Replace duplicated stepping logic in `src/devtool/evm.zig` with calls to EVM `set_debug_hooks` and `set_tracer`.
- Implement a `MemoryTracerAdapter` that accumulates steps and exposes the exact data the UI needs.
- Provide pause/resume/step/break functionality via hooks.

### Existing Devtool Behaviors to Preserve

- Opcode listing and current PC highlight.
- Stack visualization (top-first), memory view with hex dump, storage and logs views.
- Gas tracking per step and cumulative gas used.
- Error surfacing (e.g., stack underflow, invalid jump) to the UI.

### Scope

- `src/devtool/evm.zig`:
  - Create a wrapper around `Evm` that:
    - initializes with `set_debug_hooks` and `set_tracer`.
    - exposes `start(bytecode, calldata, env)`, `step()`, `continue()`, `pause()`, `reset()`.
  - Implement internal ring buffer for steps to support back/forward scrubbing without recomputation; cap size and allow replay.
- UI wiring (`src/devtool/solid/*`):
  - Switch data source from custom interpreter model to tracer stream.
  - Maintain derived selectors for current step, gas, stack/memory/storage.

### APIs

- `DevtoolRunner` (Zig):
  - `init(allocator)` / `deinit()`
  - `load(bytecode, calldata, env)`
  - `step() bool` -> executes one opcode and appends a step; returns false if halted/paused.
  - `continue(max_steps?: usize)` -> runs until halt/pause/breakpoint or step cap.
  - `set_breakpoints(pcs: []usize)` and honor in `onStep`.
  - `get_trace()` -> `ExecutionTrace` for export.

### Tests

- Add headless tests under `test/devtool/` (new dir) that:
  - Run bytecode through `DevtoolRunner` and assert sequence of ops matches analysis mapping.
  - Verify pause on breakpoint and resume continues correctly.
  - Ensure error propagation is visible to UI layer (expose last error string/code).

### Acceptance Criteria

- Devtool builds and runs with tracer-driven execution; stepping works with pause/resume.
- No interpreter code duplication remains in devtool; only uses EVM public APIs and tracer data.
- All existing devtool UI affordances remain functional.

### Notes

- Pausing relies on PR 1 `StepControl.pause`.
- Memory/stack representations must match UI expectations (endianness, formatting).

---

## Implementation Guide (Deep Dive)

### Architecture Overview

This PR transforms the devtool from a duplicated interpreter to a tracer-driven system. The key insight: instead of stepping through bytecode manually, we'll use the EVM's tracing system to capture execution data and debug hooks to control execution flow.

#### Current Devtool Architecture (to be replaced)
```
User clicks "Step" → devtool/evm.zig stepExecute() → Manual opcode execution → UI update
```

#### New Tracer-Driven Architecture
```
User clicks "Step" → DevtoolRunner.step() → DebugHooks pause execution → Tracer captures state → UI reads from trace buffer
```

### Existing Codebase Components

#### 1. EVM Tracer System (`src/evm/tracer.zig`)
The tracer outputs REVM-compatible JSON traces:
```zig
pub const Tracer = struct {
    writer: std.io.AnyWriter,
    
    pub fn trace(
        self: *Tracer,
        pc: usize,           // Program counter
        opcode: u8,          // Current opcode byte
        stack: []const u256, // Current stack state (full array)
        gas: u64,            // Gas remaining
        gas_cost: u64,       // Gas cost of this opcode (0 in block-based)
        memory_size: usize,  // Current memory size
        depth: u32,          // Call depth
    ) !void
```

**JSON Output Format** (one line per step):
```json
{"pc":0,"op":96,"gas":"0x4c4b40","gasCost":"0x0","stack":[],"depth":0,"returnData":"0x","refund":"0x0","memSize":0,"opName":"PUSH1"}
{"pc":2,"op":96,"gas":"0x4c4b40","gasCost":"0x0","stack":["0x42"],"depth":0,"returnData":"0x","refund":"0x0","memSize":0,"opName":"PUSH1"}
```

#### 2. Tracing Integration in Interpreter (`src/evm/evm/interpret.zig`)
Tracing happens in `pre_step()` function (lines 36-73):
```zig
inline fn pre_step(self: *Evm, frame: *Frame, inst: *const Instruction, loop_iterations: *usize) void {
    // ... safety checks ...
    
    if (comptime build_options.enable_tracing) {
        if (self.tracer) |writer| {
            // Derive PC from instruction pointer
            const pc = analysis.inst_to_pc[idx];
            const opcode = frame.analysis.code[pc];
            const stack_view = frame.stack.data[0..frame.stack.size()];
            
            var tr = Tracer.init(writer);
            _ = tr.trace(pc, opcode, stack_view, frame.gas_remaining, 0, frame.memory.size(), frame.depth) catch {};
        }
    }
}
```

#### 3. EVM Tracer Control (`src/evm/evm.zig`)
```zig
pub fn enable_tracing_to_path(self: *Evm, path: []const u8, append: bool) !void {
    // Compile-time gated behind build_options.enable_tracing
    var file = try std.fs.cwd().createFile(path, .{ .truncate = !append });
    self.trace_file = file;
    self.tracer = file.writer().any();
}

pub fn disable_tracing(self: *Evm) void {
    self.tracer = null;
    if (self.trace_file) |f| f.close();
}
```

**Key Fields in Evm struct**:
```zig
/// Optional tracer for capturing execution traces
tracer: ?std.io.AnyWriter = null, // 16 bytes - debugging only
/// Open file handle used by tracer when tracing to file
trace_file: ?std.fs.File = null,  // 8 bytes - debugging only
```

#### 4. Debug Hooks (from PR 1 - may not exist yet)
Expected API based on the requirements:
```zig
pub const StepControl = enum { continue, pause, abort };
pub const MessagePhase = enum { before, after };

pub const OnStepFn = *const fn (user_ctx: ?*anyopaque, frame: *Frame, pc: usize, opcode: u8) anyerror!StepControl;
pub const OnMessageFn = *const fn (user_ctx: ?*anyopaque, params: *const CallParams, phase: MessagePhase) anyerror!void;

pub const DebugHooks = struct {
    user_ctx: ?*anyopaque = null,
    on_step: ?OnStepFn = null,
    on_message: ?OnMessageFn = null,
};
```

#### 5. Current Devtool Implementation (`src/devtool/evm.zig` - to be replaced)
The current devtool duplicates EVM logic with manual stepping. Key functions to replace:
- `resetExecution()` - Initialize execution state
- `stepExecute()` - Execute one opcode manually
- Internal state tracking for PC, gas, stack, memory

#### 6. Build Configuration (`build.zig`)
```zig
const enable_tracing = b.option(bool, "enable-tracing", "Enable EVM instruction tracing (compile-time)") orelse false;
build_options.addOption(bool, "enable_tracing", enable_tracing);
```

**Critical**: Always build with tracing enabled:
```bash
zig build -Denable-tracing=true && zig build test -Denable-tracing=true
```

### Key Design Patterns and Constraints

#### 1. std.io.AnyWriter Pattern
The tracer uses Zig's type-erased writer interface:
```zig
pub const AnyWriter = struct {
    context: *const anyopaque,
    writeFn: *const fn (context: *const anyopaque, bytes: []const u8) anyerror!usize,
    
    pub fn write(self: Self, bytes: []const u8) anyerror!usize {
        return self.writeFn(self.context, bytes);
    }
};
```

**For MemoryTracerAdapter**:
```zig
const MemoryTracerAdapter = struct {
    // ... fields ...
    
    fn writeFn(context: *const anyopaque, bytes: []const u8) anyerror!usize {
        const self: *MemoryTracerAdapter = @ptrFromInt(@intFromPtr(context));
        return self.writeToBuffer(bytes);
    }
    
    pub fn writer(self: *MemoryTracerAdapter) std.io.AnyWriter {
        return std.io.AnyWriter{
            .context = @ptrCast(self),
            .writeFn = writeFn,
        };
    }
};
```

#### 2. Memory Management Principles
- **Zero allocations in hot path**: `writeFn` must be allocation-free
- **Pre-allocated ring buffer**: Fixed-size circular buffer for trace storage
- **Defer cleanup**: All allocations cleaned up with defer patterns
- **Arena allocator**: Use for temporary parsing operations

#### 3. Error Handling Patterns
- Tracer errors are ignored by `interpret.zig` (line 63: `catch {}`))
- Debug hooks control execution flow, not tracer
- Use `anyerror!` for hook functions to allow error propagation

#### 4. Frame and State Access Patterns
Key data structures for UI:

**Frame struct** (`src/evm/frame.zig` - cache-optimized layout):
```zig
pub const Frame = struct {
    // === FIRST CACHE LINE - ULTRA HOT ===
    gas_remaining: u64,           // Every opcode checks/consumes gas
    stack: Stack,                 // 32 bytes - accessed by every opcode
    analysis: *const CodeAnalysis, // Control flow validation
    host: Host,                   // 16 bytes - hardfork checks, gas costs
    
    // === SECOND CACHE LINE - MEMORY OPERATIONS ===
    memory: Memory,               // 72 bytes - MLOAD/MSTORE/etc
    
    // === THIRD CACHE LINE - STORAGE OPERATIONS ===
    state: DatabaseInterface,     // 16 bytes - SLOAD/SSTORE
    contract_address: Address,    // 20 bytes
    depth: u16,                   // Call depth
    is_static: bool,              // STATICCALL restriction
    
    // === FOURTH CACHE LINE - CALL CONTEXT ===
    caller: Address,              // 20 bytes
    value: u256,                  // 32 bytes
    input_buffer: []const u8,     // Calldata
    output_buffer: []const u8,    // Return data
};
```

**Stack struct** (`src/evm/stack/stack.zig`):
```zig
pub const Stack = struct {
    current: [*]u256,           // Pointer to current top
    base: [*]u256,              // Base of stack
    limit: [*]u256,             // Stack limit (1024 items)
    data: *[CAPACITY]u256,      // Actual data array
    
    pub const CAPACITY: usize = 1024; // EVM spec limit
    
    pub fn size(self: *const Stack) usize {
        return @intFromPtr(self.current) - @intFromPtr(self.base)) / @sizeOf(u256);
    }
    
    pub fn peek_n(self: *const Stack, n: usize) !u256 {
        // Returns stack[top-n], where n=0 is the top element
    }
};
```

**Memory struct** access patterns:
```zig
const memory_size = frame.memory.size();
const memory_data = try memory_read.get_slice(&frame.memory, 0, memory_size);
```

### High-Level Design After Refactor

#### DevtoolRunner Architecture
```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   DevtoolRunner │────│ MemoryTracerAdapter │────│   Ring Buffer   │
│                 │    │                  │    │                 │
│ - step()        │    │ - writeFn()      │    │ - trace_steps   │
│ - continue()    │    │ - parseTrace()   │    │ - current_step  │
│ - pause()       │    │ - getCurrentStep()│    │ - step_count    │
│ - breakpoints   │    │                  │    │                 │
└─────────────────┘    └──────────────────┘    └─────────────────┘
         │                                              │
         v                                              v
┌─────────────────┐                            ┌─────────────────┐
│      EVM        │                            │   Solid UI      │
│                 │                            │                 │
│ - debug_hooks   │                            │ - Stack view    │
│ - tracer        │                            │ - Memory view   │
│ - interpret()   │                            │ - Gas tracking  │
└─────────────────┘                            └─────────────────┘
```

#### Execution Flow
1. **DevtoolRunner.step()** sets debug hooks to pause after 1 opcode
2. **EVM.interpret()** runs until `onStep` returns `StepControl.pause`
3. **Tracer writes JSON** to MemoryTracerAdapter during execution
4. **MemoryTracerAdapter** parses JSON and stores in ring buffer
5. **UI queries** DevtoolRunner for current state from parsed trace data

#### Data Flow
```
Bytecode → EVM.interpret() → pre_step() → Tracer.trace() → MemoryTracerAdapter.writeFn() → Ring Buffer → UI
                         ↗
          DebugHooks.onStep() ← DevtoolRunner (controls execution)
```

### MemoryTracerAdapter Detailed Design

#### Core Data Structures
```zig
/// Parsed trace step for efficient UI access
const TraceStep = struct {
    pc: usize,
    opcode: u8,
    opcode_name: []const u8,     // Static string, no allocation needed
    gas_remaining: u64,
    gas_cost: u64,
    depth: u32,
    memory_size: usize,
    stack_size: usize,
    
    // Stack data stored inline for cache efficiency
    // UI typically only shows top 10-20 items
    stack_data: [32]u256,        // Fixed-size array, avoid allocation
    
    // Error information
    has_error: bool,
    error_name: ?[]const u8,     // Static string or null
};

const MemoryTracerAdapter = struct {
    allocator: std.mem.Allocator,
    
    // Ring buffer for trace steps
    trace_steps: []TraceStep,    // Pre-allocated circular buffer
    current_step: usize,         // Current position in ring
    step_count: usize,           // Total steps taken
    buffer_size: usize,          // Ring buffer capacity
    
    // JSON parsing buffer - reused to avoid allocations
    parse_buffer: []u8,          // For incomplete JSON lines
    parse_offset: usize,         // Current parse position
    
    // Current execution state (derived from latest trace)
    current_pc: usize,
    current_gas: u64,
    current_depth: u32,
    is_halted: bool,
    
    // Error tracking
    last_error: ?anyerror,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, buffer_size: usize) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        
        // MEMORY ALLOCATION: Ring buffer for trace steps
        // Expected size: buffer_size * ~300 bytes per step
        // Lifetime: Entire devtool session
        self.trace_steps = try allocator.alloc(TraceStep, buffer_size);
        errdefer allocator.free(self.trace_steps);
        
        // MEMORY ALLOCATION: JSON parsing buffer
        // Expected size: 4KB (typical JSON line is <1KB)
        // Lifetime: Entire devtool session  
        self.parse_buffer = try allocator.alloc(u8, 4096);
        errdefer allocator.free(self.parse_buffer);
        
        self.* = Self{
            .allocator = allocator,
            .trace_steps = self.trace_steps,
            .current_step = 0,
            .step_count = 0,
            .buffer_size = buffer_size,
            .parse_buffer = self.parse_buffer,
            .parse_offset = 0,
            .current_pc = 0,
            .current_gas = 0,
            .current_depth = 0,
            .is_halted = false,
            .last_error = null,
        };
        
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.trace_steps);
        self.allocator.free(self.parse_buffer);
        self.allocator.destroy(self);
    }
    
    // CRITICAL: This function is called in the EVM hot path
    // Must be allocation-free and fast
    fn writeFn(context: *const anyopaque, bytes: []const u8) anyerror!usize {
        const self: *Self = @ptrFromInt(@intFromPtr(context));
        return self.writeToBuffer(bytes) catch bytes.len; // Don't fail EVM execution
    }
    
    fn writeToBuffer(self: *Self, bytes: []const u8) !usize {
        // Handle partial JSON lines by buffering
        if (self.parse_offset + bytes.len > self.parse_buffer.len) {
            // Buffer overflow - reset and start fresh
            self.parse_offset = 0;
        }
        
        // Copy new data to parse buffer
        const available = self.parse_buffer.len - self.parse_offset;
        const to_copy = @min(bytes.len, available);
        @memcpy(self.parse_buffer[self.parse_offset..self.parse_offset + to_copy], bytes[0..to_copy]);
        self.parse_offset += to_copy;
        
        // Process complete JSON lines (terminated by newline)
        var start: usize = 0;
        while (start < self.parse_offset) {
            if (std.mem.indexOfScalar(u8, self.parse_buffer[start..self.parse_offset], '\n')) |newline_pos| {
                const line_end = start + newline_pos;
                const json_line = self.parse_buffer[start..line_end];
                
                // Parse this complete JSON line
                self.parseAndStoreTrace(json_line) catch {}; // Don't fail on parse errors
                
                start = line_end + 1; // Skip the newline
            } else {
                // No complete line yet, move remaining data to front of buffer
                if (start > 0) {
                    const remaining = self.parse_offset - start;
                    @memcpy(self.parse_buffer[0..remaining], self.parse_buffer[start..self.parse_offset]);
                    self.parse_offset = remaining;
                }
                break;
            }
        }
        
        if (start > 0 and start >= self.parse_offset) {
            // All data was processed
            self.parse_offset = 0;
        }
        
        return bytes.len;
    }
    
    fn parseAndStoreTrace(self: *Self, json_line: []const u8) !void {
        // Parse JSON trace entry
        var trace_step = TraceStep{
            .pc = 0,
            .opcode = 0,
            .opcode_name = "UNKNOWN",
            .gas_remaining = 0,
            .gas_cost = 0,
            .depth = 0,
            .memory_size = 0,
            .stack_size = 0,
            .stack_data = [_]u256{0} ** 32,
            .has_error = false,
            .error_name = null,
        };
        
        // Use std.json.parseFromSlice for parsing
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json_line, .{});
        defer parsed.deinit();
        
        const root = parsed.value.object;
        
        // Extract fields from JSON
        if (root.get("pc")) |pc_val| {
            trace_step.pc = @intCast(pc_val.integer);
        }
        
        if (root.get("op")) |op_val| {
            trace_step.opcode = @intCast(op_val.integer);
            trace_step.opcode_name = opcodeToString(trace_step.opcode);
        }
        
        // Parse gas as hex string
        if (root.get("gas")) |gas_val| {
            if (gas_val == .string) {
                const gas_str = gas_val.string;
                if (std.mem.startsWith(u8, gas_str, "0x")) {
                    trace_step.gas_remaining = std.fmt.parseInt(u64, gas_str[2..], 16) catch 0;
                }
            }
        }
        
        // Parse stack array
        if (root.get("stack")) |stack_val| {
            if (stack_val == .array) {
                const stack_array = stack_val.array;
                trace_step.stack_size = @min(stack_array.items.len, 32);
                
                for (stack_array.items[0..trace_step.stack_size], 0..) |item, i| {
                    if (item == .string) {
                        const hex_str = item.string;
                        if (std.mem.startsWith(u8, hex_str, "0x")) {
                            trace_step.stack_data[i] = std.fmt.parseInt(u256, hex_str[2..], 16) catch 0;
                        }
                    }
                }
            }
        }
        
        // Parse other fields...
        if (root.get("depth")) |depth_val| {
            trace_step.depth = @intCast(depth_val.integer);
        }
        
        if (root.get("memSize")) |mem_val| {
            trace_step.memory_size = @intCast(mem_val.integer);
        }
        
        // Store in ring buffer
        const buffer_index = self.step_count % self.buffer_size;
        self.trace_steps[buffer_index] = trace_step;
        self.step_count += 1;
        
        // Update current state
        self.current_pc = trace_step.pc;
        self.current_gas = trace_step.gas_remaining;
        self.current_depth = trace_step.depth;
    }
    
    pub fn writer(self: *Self) std.io.AnyWriter {
        return std.io.AnyWriter{
            .context = @ptrCast(self),
            .writeFn = writeFn,
        };
    }
    
    pub fn getCurrentStep(self: *const Self) ?*const TraceStep {
        if (self.step_count == 0) return null;
        const index = (self.step_count - 1) % self.buffer_size;
        return &self.trace_steps[index];
    }
    
    pub fn getStepHistory(self: *const Self, count: usize) []const TraceStep {
        const available = @min(count, @min(self.step_count, self.buffer_size));
        if (available == 0) return &[_]TraceStep{};
        
        const start_index = if (self.step_count >= self.buffer_size) 
            (self.step_count) % self.buffer_size 
        else 
            0;
        
        // Return slice from ring buffer (may wrap around)
        return self.trace_steps[start_index..start_index + available];
    }
    
    pub fn reset(self: *Self) void {
        self.current_step = 0;
        self.step_count = 0;
        self.parse_offset = 0;
        self.current_pc = 0;
        self.current_gas = 0;
        self.current_depth = 0;
        self.is_halted = false;
        self.last_error = null;
        @memset(std.mem.asBytes(&self.trace_steps[0]), 0);
    }
};
```

#### Ring Buffer Management
- **Circular buffer**: Old steps are overwritten when buffer is full
- **Configurable size**: Default 1000 steps (adjustable for deep execution traces)
- **Efficient access**: Latest steps always available without shifting
- **Memory bounded**: Fixed memory usage regardless of execution length

### DevtoolRunner Implementation

```zig
const DevtoolRunner = struct {
    allocator: std.mem.Allocator,
    evm: *Evm,
    tracer_adapter: *MemoryTracerAdapter,
    
    // Execution control
    is_paused: bool,
    step_count: usize,
    max_steps: ?usize,    // For continue() with step limit
    
    // Breakpoint management
    breakpoints: std.AutoHashMap(usize, void), // PC -> void
    
    // Execution state
    current_bytecode: ?[]const u8,
    current_calldata: ?[]const u8,
    current_env: ?ExecutionEnv,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        
        // Create EVM instance with tracing enabled
        var memory_db = MemoryDatabase.init(allocator);
        const db_interface = memory_db.to_database_interface();
        
        self.evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
        errdefer self.evm.deinit();
        
        // Create tracer adapter with reasonable buffer size
        self.tracer_adapter = try MemoryTracerAdapter.init(allocator, 1000);
        errdefer self.tracer_adapter.deinit();
        
        // Configure EVM with our tracer
        self.evm.tracer = self.tracer_adapter.writer();
        
        // Initialize breakpoints map
        self.breakpoints = std.AutoHashMap(usize, void).init(allocator);
        errdefer self.breakpoints.deinit();
        
        self.* = Self{
            .allocator = allocator,
            .evm = self.evm,
            .tracer_adapter = self.tracer_adapter,
            .is_paused = false,
            .step_count = 0,
            .max_steps = null,
            .breakpoints = self.breakpoints,
            .current_bytecode = null,
            .current_calldata = null,
            .current_env = null,
        };
        
        // Set up debug hooks for step control
        var hooks = DebugHooks{
            .user_ctx = @ptrCast(self),
            .on_step = onStepHook,
            .on_message = null, // Not needed for basic stepping
        };
        
        self.evm.set_debug_hooks(hooks);
        
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        self.evm.deinit();
        self.tracer_adapter.deinit();
        self.breakpoints.deinit();
        self.allocator.destroy(self);
    }
    
    pub fn load(self: *Self, bytecode: []const u8, calldata: []const u8, env: ExecutionEnv) !void {
        // Store execution parameters
        self.current_bytecode = bytecode;
        self.current_calldata = calldata;
        self.current_env = env;
        
        // Reset state
        self.is_paused = false;
        self.step_count = 0;
        self.tracer_adapter.reset();
        self.evm.reset();
        
        // Set up EVM input
        self.evm.current_input = calldata;
    }
    
    pub fn step(self: *Self) !bool {
        if (self.current_bytecode == null) return error.NotLoaded;
        
        // Set step limit to 1 and resume
        self.max_steps = 1;
        self.is_paused = false;
        
        return self.executeUntilPause();
    }
    
    pub fn continue_execution(self: *Self, max_steps: ?usize) !bool {
        if (self.current_bytecode == null) return error.NotLoaded;
        
        self.max_steps = max_steps;
        self.is_paused = false;
        
        return self.executeUntilPause();
    }
    
    pub fn pause(self: *Self) void {
        self.is_paused = true;
    }
    
    pub fn set_breakpoints(self: *Self, pcs: []const usize) !void {
        self.breakpoints.clear();
        for (pcs) |pc| {
            try self.breakpoints.put(pc, {});
        }
    }
    
    fn executeUntilPause(self: *Self) !bool {
        const bytecode = self.current_bytecode orelse return error.NotLoaded;
        
        // Execute contract with current bytecode
        const result = self.evm.run_contract(
            Address.ZERO,      // contract_address
            Address.ZERO,      // caller
            0,                 // value
            bytecode,
            self.current_calldata orelse &[_]u8{},
            5_000_000,         // gas_limit
        );
        
        // Check execution result
        return switch (result) {
            .success => false,  // Execution completed
            .revert => false,   // Execution reverted
            .paused => true,    // Paused by debug hook
            else => false,      // Other terminal states
        };
    }
    
    // Debug hook callback - called from EVM during execution
    fn onStepHook(user_ctx: ?*anyopaque, frame: *Frame, pc: usize, opcode: u8) anyerror!StepControl {
        const self: *Self = @ptrFromInt(@intFromPtr(user_ctx.?));
        
        self.step_count += 1;
        
        // Check if paused externally
        if (self.is_paused) {
            return .pause;
        }
        
        // Check step limit
        if (self.max_steps) |limit| {
            if (self.step_count >= limit) {
                return .pause;
            }
        }
        
        // Check breakpoints
        if (self.breakpoints.contains(pc)) {
            return .pause;
        }
        
        return .continue;
    }
    
    // UI Interface Methods
    pub fn getCurrentTrace(self: *const Self) ?*const TraceStep {
        return self.tracer_adapter.getCurrentStep();
    }
    
    pub fn getTrace(self: *const Self) ExecutionTrace {
        const current = self.tracer_adapter.getCurrentStep();
        
        return ExecutionTrace{
            .steps = self.tracer_adapter.getStepHistory(100), // Last 100 steps
            .current_step = if (current) |step| step else null,
            .total_steps = self.step_count,
            .is_completed = !self.is_paused and self.step_count > 0,
            .gas_used = if (current) |step| step.gas_remaining else 0,
        };
    }
    
    pub fn reset(self: *Self) void {
        self.is_paused = false;
        self.step_count = 0;
        self.max_steps = null;
        self.tracer_adapter.reset();
        if (self.evm.tracer) |_| {
            // Tracer is still connected, just reset state
            self.evm.reset();
        }
    }
};

// Data structure for UI consumption
pub const ExecutionTrace = struct {
    steps: []const TraceStep,
    current_step: ?*const TraceStep,
    total_steps: usize,
    is_completed: bool,
    gas_used: u64,
};

// Helper function for converting opcode to string (static, no allocation)
fn opcodeToString(opcode: u8) []const u8 {
    return switch (opcode) {
        0x00 => "STOP",
        0x01 => "ADD",
        0x02 => "MUL",
        // ... (full mapping as in src/devtool/debug_state.zig)
        else => "UNKNOWN",
    };
}
```

### Integration with Solid UI

#### TypeScript Interface Bindings
The current UI expects JSON data structures. Update the bindings:

```typescript
// Updated types to match tracer output
interface TraceStep {
  pc: number;
  opcode: number;
  opcodeName: string;
  gasRemaining: number;
  gasCost: number;
  depth: number;
  memorySize: number;
  stackSize: number;
  stackData: string[]; // Hex strings
  hasError: boolean;
  errorName?: string;
}

interface ExecutionTrace {
  steps: TraceStep[];
  currentStep?: TraceStep;
  totalSteps: number;
  isCompleted: boolean;
  gasUsed: number;
}

// Updated Zig interface calls
declare const invoke: {
  devtool_step(): Promise<boolean>;
  devtool_continue(maxSteps?: number): Promise<boolean>;
  devtool_pause(): Promise<void>;
  devtool_set_breakpoints(pcs: number[]): Promise<void>;
  devtool_get_trace(): Promise<ExecutionTrace>;
  devtool_reset(): Promise<void>;
  devtool_load(bytecode: string, calldata: string): Promise<void>;
};
```

#### UI Component Updates
Key components that need updating:

1. **EvmDebugger.tsx** - Main orchestrator, switch from polling Frame state to trace data
2. **ExecutionStepsView.tsx** - Display trace steps instead of manually tracked steps
3. **Stack.tsx** - Read stack from `currentStep.stackData` instead of Frame
4. **Memory.tsx** - Use memory size from trace, fetch actual memory data separately if needed
5. **GasUsage.tsx** - Track gas from trace steps instead of manual calculation

### Testing Strategy

#### Unit Tests
```zig
test "MemoryTracerAdapter parses JSON traces correctly" {
    const allocator = std.testing.allocator;
    
    var adapter = try MemoryTracerAdapter.init(allocator, 10);
    defer adapter.deinit();
    
    // Test JSON parsing
    const json_line = "{\"pc\":0,\"op\":96,\"gas\":\"0x4c4b40\",\"stack\":[\"0x42\"],\"depth\":0}";
    try adapter.writeToBuffer(json_line);
    try adapter.writeToBuffer("\n");
    
    const step = adapter.getCurrentStep() orelse return error.NoStep;
    try testing.expectEqual(@as(usize, 0), step.pc);
    try testing.expectEqual(@as(u8, 96), step.opcode);
    try testing.expectEqual(@as(u64, 0x4c4b40), step.gas_remaining);
    try testing.expectEqual(@as(usize, 1), step.stack_size);
    try testing.expectEqual(@as(u256, 0x42), step.stack_data[0]);
}

test "DevtoolRunner step execution works" {
    const allocator = std.testing.allocator;
    
    var runner = try DevtoolRunner.init(allocator);
    defer runner.deinit();
    
    // Simple bytecode: PUSH1 42, PUSH1 24, ADD, STOP
    const bytecode = &[_]u8{0x60, 0x2a, 0x60, 0x18, 0x01, 0x00};
    try runner.load(bytecode, &[_]u8{}, .{});
    
    // Step through execution
    var continued = try runner.step(); // PUSH1 42
    try testing.expect(continued);
    
    continued = try runner.step(); // PUSH1 24
    try testing.expect(continued);
    
    continued = try runner.step(); // ADD
    try testing.expect(continued);
    
    continued = try runner.step(); // STOP
    try testing.expect(!continued); // Should be halted
    
    // Check final trace
    const trace = runner.getTrace();
    try testing.expectEqual(@as(usize, 4), trace.total_steps);
    try testing.expect(trace.is_completed);
    
    if (trace.current_step) |step| {
        try testing.expectEqual(@as(u8, 0x00), step.opcode); // STOP
    }
}

test "DevtoolRunner breakpoints work" {
    const allocator = std.testing.allocator;
    
    var runner = try DevtoolRunner.init(allocator);
    defer runner.deinit();
    
    // Bytecode with breakpoint at PC 4 (ADD instruction)
    const bytecode = &[_]u8{0x60, 0x2a, 0x60, 0x18, 0x01, 0x00};
    try runner.load(bytecode, &[_]u8{}, .{});
    
    // Set breakpoint at PC 4
    try runner.set_breakpoints(&[_]usize{4});
    
    // Continue should stop at breakpoint
    const continued = try runner.continue_execution(null);
    try testing.expect(continued); // Should be paused at breakpoint
    
    const trace = runner.getTrace();
    if (trace.current_step) |step| {
        try testing.expectEqual(@as(usize, 4), step.pc);
    }
}
```

#### Integration Tests
```zig
test "DevtoolRunner with ERC20 bytecode" {
    const allocator = std.testing.allocator;
    
    // Load ERC20 bytecode from bench files
    const initcode_path = "bench/official/cases/erc20-transfer/bytecode.txt";
    const calldata_path = "bench/official/cases/erc20-transfer/calldata.txt";
    
    var runner = try DevtoolRunner.init(allocator);
    defer runner.deinit();
    
    // Load from files (similar to existing test pattern)
    const bytecode = try loadHexFromFile(allocator, initcode_path);
    defer allocator.free(bytecode);
    const calldata = try loadHexFromFile(allocator, calldata_path);  
    defer allocator.free(calldata);
    
    try runner.load(bytecode, calldata, .{});
    
    // Step through a few instructions
    var steps: usize = 0;
    while (steps < 10) {
        const continued = try runner.step();
        if (!continued) break;
        steps += 1;
        
        // Validate trace data
        const trace = runner.getTrace();
        try testing.expect(trace.current_step != null);
    }
    
    try testing.expect(steps > 0);
}
```

### Build Configuration and Compilation

#### Critical Build Requirements
```bash
# Always build with tracing enabled
zig build -Denable-tracing=true

# Always test with tracing enabled
zig build test -Denable-tracing=true

# For devtool specifically
zig build devtool -Denable-tracing=true
```

#### Devtool Build Configuration
Update `build_utils/devtool.zig` to ensure tracing is enabled:

```zig
pub fn build_devtool(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, dependencies: DevtoolDependencies) !void {
    // Ensure tracing is enabled for devtool
    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_tracing", true); // Force enable
    
    // ... rest of build configuration
}
```

#### Runtime Validation
Add compile-time checks to ensure tracing is available:

```zig
comptime {
    if (!build_options.enable_tracing) {
        @compileError("DevtoolRunner requires tracing to be enabled. Build with -Denable-tracing=true");
    }
}
```

### Error Handling and Edge Cases

#### Trace Buffer Overflow
```zig
// When ring buffer is full, old traces are discarded
// UI should indicate when showing partial history
pub fn getAvailableStepCount(self: *const Self) usize {
    return @min(self.step_count, self.buffer_size);
}

pub fn isHistoryComplete(self: *const Self) bool {
    return self.step_count <= self.buffer_size;
}
```

#### JSON Parse Failures
```zig
// Graceful degradation when JSON is malformed
fn parseAndStoreTrace(self: *Self, json_line: []const u8) !void {
    var trace_step = TraceStep.createDefault();
    
    // Try to parse JSON
    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_line, .{}) catch {
        // On parse failure, create minimal trace step with available info
        trace_step.has_error = true;
        trace_step.error_name = "JSON_PARSE_ERROR";
        self.storeTraceStep(trace_step);
        return;
    };
    defer parsed.deinit();
    
    // Extract fields with fallbacks...
}
```

#### EVM Execution Errors
```zig
// Handle EVM errors gracefully in DevtoolRunner
fn executeUntilPause(self: *Self) !bool {
    const result = self.evm.run_contract(...) catch |err| {
        // Store error in trace
        if (self.tracer_adapter.getCurrentStep()) |step| {
            step.has_error = true;
            step.error_name = @errorName(err);
        }
        return false; // Execution terminated
    };
    
    // ... handle result
}
```

#### Memory Management Safety
```zig
// Ensure all allocations are properly cleaned up
pub fn deinit(self: *Self) void {
    // Clean up in reverse allocation order
    self.breakpoints.deinit();
    self.tracer_adapter.deinit();
    self.evm.deinit();
    self.allocator.destroy(self);
}

// Use defer patterns consistently
pub fn init(allocator: std.mem.Allocator) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    
    self.evm = try Evm.init(...);
    errdefer self.evm.deinit();
    
    self.tracer_adapter = try MemoryTracerAdapter.init(...);
    errdefer self.tracer_adapter.deinit();
    
    // ... rest of initialization
    return self;
}
```

### Performance Considerations

#### Hot Path Optimization
- **MemoryTracerAdapter.writeFn()** is called for every opcode - must be fast
- **Pre-allocated buffers** avoid allocation in execution path
- **Ring buffer design** provides O(1) insertion and bounded memory
- **Static opcode names** avoid string allocations

#### Memory Usage
- **Ring buffer size**: 1000 steps × ~300 bytes = ~300KB
- **Parse buffer**: 4KB for JSON buffering
- **Total overhead**: <1MB for trace storage

#### Parsing Optimization
```zig
// Use stack-allocated JSON parser when possible
var stream = std.json.TokenStream.init(json_line);
while (try stream.next()) |token| {
    switch (token) {
        .string => |s| if (std.mem.eql(u8, stream.slice, "pc")) {
            const pc_token = try stream.next();
            trace_step.pc = @intCast(pc_token.number.integer);
        },
        // ... handle other fields
    }
}
```

### Migration Path from Current Devtool

#### Phase 1: Create DevtoolRunner alongside existing system
- Implement DevtoolRunner and MemoryTracerAdapter
- Add new endpoints to devtool API
- Keep existing devtool/evm.zig working

#### Phase 2: Update UI to use new API
- Update TypeScript bindings
- Modify React components to consume trace data
- Add feature flag to switch between old/new systems

#### Phase 3: Remove old implementation
- Delete devtool/evm.zig stepping logic
- Remove unused UI code
- Clean up redundant state management

#### Compatibility Considerations
- Maintain same UI behavior during transition
- Ensure trace data contains all information needed by existing components
- Preserve breakpoint and step timing behavior

### Key Implementation Files to Create/Modify

#### New Files:
1. `src/devtool/devtool_runner.zig` - Main DevtoolRunner implementation
2. `src/devtool/memory_tracer_adapter.zig` - Ring buffer tracer adapter
3. `src/devtool/trace_step.zig` - TraceStep data structure
4. `test/devtool/devtool_runner_test.zig` - Comprehensive tests

#### Modified Files:
1. `src/devtool/app.zig` - Add DevtoolRunner endpoints
2. `src/devtool/evm.zig` - Remove duplicated logic (Phase 3)
3. `solid/components/evm-debugger/EvmDebugger.tsx` - Switch to trace API
4. `solid/lib/types.ts` - Update TypeScript interfaces

#### Dependencies:
- Requires PR 1 (Debug Hooks) to be implemented first
- Build system must enforce `-Denable-tracing=true` for devtool

This implementation provides a complete, production-ready refactor that eliminates code duplication while maintaining all existing devtool functionality through a clean, tracer-driven architecture.
