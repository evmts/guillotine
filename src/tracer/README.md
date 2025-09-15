# Tracer Module

Comprehensive execution tracing, debugging, and verification system for the Guillotine EVM implementation.

## Overview

The tracer module provides multiple implementations for different use cases:
- **`DefaultTracer`** — Production tracer with assertion support and minimal overhead
- **`MinimalEvm`** — Standalone EVM implementation for differential testing (65KB)
- **WASM Support** — C FFI wrapper for browser and embedded environments
- **Advanced Tracing** — Bytecode analysis, fusion detection, and gas tracking

## Components and Architecture

### Core Files
- **`tracer.zig`** - Main tracer implementation with DefaultTracer and interfaces
- **`MinimalEvm.zig`** - Standalone minimal EVM for testing and verification
- **`MinimalEvm_c.zig`** - C FFI wrapper for WASM compilation
- **`pc_tracker.zig`** - Program counter tracking and execution flow analysis
- **`spec.md`** - Detailed tracer specification and interface documentation

### Tracer Types

#### DefaultTracer
- **Assertion Support**: Replaced `std.debug.assert` with tracer assertions
- **Descriptive Messages**: Clear error messages for debugging
- **Production Ready**: Minimal overhead with comprehensive validation
- **Enhanced Interface**: Bytecode analysis and dispatch lifecycle tracking

#### MinimalEvm
- **Reference Implementation**: Standalone EVM for correctness verification
- **Stack Semantics**: Properly implements LIFO stack operations
- **Gas Accuracy**: Precise gas accounting matching Yellow Paper
- **Differential Testing**: Ground truth for testing main EVM
- **WASM Compatible**: Full C FFI interface for cross-platform usage

#### Enhanced Tracer Interface (2024)
- **Bytecode Analysis**: `onBytecodeAnalysisStart/Complete` lifecycle
- **Fusion Detection**: Track optimization opportunities
- **Jump Resolution**: Static jump validation and tracking
- **Assertion System**: Comprehensive validation with messages
- **Cursor Tracking**: Dispatch schedule execution monitoring

## Recent Major Updates (2024)

### Critical Bug Fixes
- **Stack Operand Order**: Fixed LIFO semantics for all binary operations
- **First Pop = Top**: Corrected ADD, SUB, DIV, MOD, and shift operations
- **Consensus Critical**: Prevents fund loss from incorrect execution

### WASM Integration
- **C FFI Wrapper**: Complete interface for browser/embedded usage
- **Opaque Handles**: Safe memory management across languages
- **Byte Array Conversion**: u256 values compatible with WASM
- **Build System**: Integrated WASM targets with size reporting

### Tracer Enhancements
- **Assertion System**: Descriptive messages replace debug asserts
- **Lifecycle Methods**: Complete bytecode analysis tracking
- **Gas Validation**: Differential comparison with reference implementations
- **Fusion Detection**: Track and validate optimizations

## Key Features

### Compile-Time Configuration
- **Zero-Cost Abstractions**: Tracer selection at compile time eliminates runtime overhead
- **Type Safety**: Compile-time verification of tracer interfaces and capabilities
- **Optimization**: Dead code elimination for unused tracer functionality
- **Conditional Compilation**: Feature flags for enabling/disabling tracing subsystems

### Execution Tracking
- **Opcode-Level Monitoring**: Every EVM instruction execution captured
- **State Transitions**: Before/after state snapshots for each operation
- **Gas Accounting**: Detailed gas consumption tracking and analysis
- **Error Handling**: Exception and error condition capture and reporting

### Performance Monitoring
- **Execution Timing**: High-resolution timing for performance analysis
- **Memory Usage**: Stack and memory allocation tracking
- **Resource Utilization**: CPU, memory, and I/O resource monitoring
- **Bottleneck Identification**: Hot path analysis and optimization insights

## Integration Points

### EVM Core
- **Frame Integration**: Deep integration with EVM execution frame
- **Opcode Dispatch**: Tracing hooks in opcode dispatch system
- **State Access**: Direct access to EVM stack, memory, and storage
- **Error Propagation**: Seamless integration with EVM error handling

### Host Interface
- **External Calls**: Tracing of host function invocations
- **State Queries**: Database and storage access tracing
- **Event Emission**: Contract event and log generation tracking
- **Precompile Execution**: Tracing of precompiled contract operations

### Testing Framework
- **Test Execution**: Comprehensive test execution tracing
- **Differential Analysis**: Comparison with reference implementations
- **Regression Detection**: Automated detection of behavior changes
- **Coverage Analysis**: Code coverage and execution path analysis

## Usage Examples

### Basic Configuration
```zig
const tracer = @import("tracer");
const evm = @import("evm");

// Production with assertions
const EvmProd = evm.Evm(tracer.DefaultTracer);
var prod = EvmProd.init(allocator, host);

// Minimal EVM for testing
const minimal = MinimalEvm.init(allocator, bytecode, gas_limit);
defer minimal.deinit();
```

### WASM C Interface
```c
// Create EVM instance
void* evm = evm_create(bytecode, bytecode_len, gas_limit);

// Set execution context
uint8_t caller[20] = {0};
uint8_t address[20] = {0};
uint8_t value[32] = {0}; // u256 as bytes
evm_set_call_context(evm, caller, address, value, calldata, calldata_len);

// Execute and inspect
bool success = evm_execute(evm);
uint64_t gas_used = evm_get_gas_used(evm);
uint32_t pc = evm_get_pc(evm);

// Stack manipulation
uint8_t stack_value[32];
evm_get_stack_item(evm, 0, stack_value); // Get top of stack

// Cleanup
evm_destroy(evm);
```

### MinimalEvm Stack Semantics
```zig
// CRITICAL: Stack is LIFO - first pop gets top of stack
pub fn add(self: *MinimalEvm) !void {
    const a = try self.popStack(); // Top of stack
    const b = try self.popStack(); // Second item
    try self.pushStack(a +% b);
}

pub fn sub(self: *MinimalEvm) !void {
    const a = try self.popStack(); // Top (subtrahend)
    const b = try self.popStack(); // Second (minuend)
    try self.pushStack(b -% a);    // Result: b - a
}

pub fn div(self: *MinimalEvm) !void {
    const a = try self.popStack(); // Divisor
    const b = try self.popStack(); // Dividend
    const result = if (a == 0) 0 else b / a;
    try self.pushStack(result);
}
```

### Tracer Assertions
```zig
// Tracer assertions with descriptive messages
pub fn validateDispatch(frame: *Frame) void {
    // Stack validation
    frame.getTracer().assert(
        frame.stack.size() >= 2,
        "Binary op: stack underflow, requires 2 items"
    );

    // Jump validation
    frame.getTracer().assert(
        self.cursor[1] == .jump_static,
        "Static jump: expected .jump_static metadata"
    );

    // Gas validation
    frame.getTracer().assert(
        frame.gas_remaining >= cost,
        "Insufficient gas for operation"
    );
}

// Bytecode analysis with tracer
var bytecode = try Bytecode.init(allocator, code, tracer);
tracer.onBytecodeAnalysisStart(code.len);
tracer.onJumpdestFound(pc, count);
tracer.onBytecodeAnalysisComplete(validated_len, opcode_count, jumpdest_count);
```

### Logging Tracer
```zig
// Configure logging tracer
var logging_tracer = tracer.LoggingTracer.init(allocator);
defer logging_tracer.deinit();

logging_tracer.set_options(.{
    .log_level = .DEBUG,
    .include_stack = true,
    .include_memory = false,
    .include_storage = true,
    .output_format = .JSON,
});

// Execute with logging
const LoggingEvm = evm.Evm(tracer.LoggingTracer);
var logging_evm = LoggingEvm.init(allocator, host);
defer logging_evm.deinit();

const result = try logging_evm.execute(bytecode);

// Logs are automatically written to stdout in JSON format
```

### File Tracer
```zig
// Configure file tracer for batch processing
var file_tracer = try tracer.FileTracer.init(
    allocator,
    "/tmp/execution_trace.json"
);
defer file_tracer.deinit();

file_tracer.set_options(.{
    .format = .JSON,
    .compression = .GZIP,
    .buffer_size = 64 * 1024, // 64KB buffer
    .flush_frequency = 1000,   // Flush every 1000 steps
});

// Execute with file tracing
const FileEvm = evm.Evm(tracer.FileTracer);
var file_evm = FileEvm.init(allocator, host);
defer file_evm.deinit();

const result = try file_evm.execute(bytecode);

// Trace data is automatically written to file
// Can be processed later with external tools
```

### Custom Tracer Implementation
```zig
// Implement custom tracer following the interface
const CustomTracer = struct {
    const Self = @This();
    
    steps: std.ArrayList(ExecutionStep),
    custom_data: std.HashMap(u32, CustomData),
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .steps = std.ArrayList(ExecutionStep).init(allocator),
            .custom_data = std.HashMap(u32, CustomData).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.steps.deinit();
        self.custom_data.deinit();
    }
    
    pub fn trace_step(
        self: *Self,
        pc: u32,
        opcode: u8,
        gas_before: i32,
        stack: []const u256,
        memory: []const u8,
    ) !void {
        // Custom tracing logic
        const step = ExecutionStep{
            .pc = pc,
            .opcode = opcode,
            .gas_before = gas_before,
            .custom_metric = self.calculate_custom_metric(opcode),
        };
        
        try self.steps.append(step);
        try self.custom_data.put(pc, CustomData{ .timestamp = std.time.nanoTimestamp() });
    }
    
    fn calculate_custom_metric(self: *Self, opcode: u8) f64 {
        // Custom analysis logic
        return @floatFromInt(opcode) * 1.5;
    }
};

// Use custom tracer
const CustomEvm = evm.Evm(CustomTracer);
```

## Performance Characteristics

### DefaultTracer Performance
- **Minimal Overhead**: Assertion checks with descriptive messages
- **Production Ready**: Optimized for deployment with validation
- **Memory Efficient**: Minimal allocations for tracking
- **CPU Efficient**: Branch prediction friendly assertion paths

### MinimalEvm Performance
- **Standalone**: 65KB implementation with full EVM semantics
- **Reference Speed**: Optimized for correctness over performance
- **Gas Accuracy**: Exact Yellow Paper gas calculations
- **WASM Optimized**: ReleaseSmall mode for minimal size

### WASM Performance
- **FFI Overhead**: Minimal with opaque handle pattern
- **Memory Safety**: Proper boundary checking for WASM
- **Byte Conversion**: Efficient u256 to/from byte arrays
- **Browser Ready**: Optimized for web execution contexts

## Configuration Options

### Tracer Selection
```zig
// Compile-time tracer selection
const Config = struct {
    tracer_type: type = if (builtin.mode == .Debug) 
        tracer.DebuggingTracer 
    else 
        tracer.DefaultTracer,
    
    // Other EVM configuration options
    enable_precompiles: bool = true,
    max_call_depth: u32 = 1024,
};
```

### Runtime Configuration
```zig
// Debugging tracer options
const DebugOptions = struct {
    capture_stack: bool = true,
    capture_memory: bool = false,
    capture_storage: bool = true,
    max_steps: ?u32 = null,
    breakpoints: []const Breakpoint = &[_]Breakpoint{},
    step_limit: ?u32 = null,
};

// Logging tracer options
const LoggingOptions = struct {
    log_level: LogLevel = .INFO,
    output_format: OutputFormat = .JSON,
    include_stack: bool = false,
    include_memory: bool = false,
    include_storage: bool = true,
    timestamp: bool = true,
};

// File tracer options
const FileOptions = struct {
    format: FileFormat = .JSON,
    compression: ?CompressionType = null,
    buffer_size: usize = 32 * 1024,
    flush_frequency: u32 = 500,
    max_file_size: ?u64 = null,
    file_rotation: bool = false,
};
```

## Analysis and Post-Processing

### Trace Analysis Tools
```zig
// Analyze execution trace for performance bottlenecks
const analyzer = tracer.TraceAnalyzer.init(allocator);
defer analyzer.deinit();

try analyzer.load_trace("execution_trace.json");

// Performance analysis
const hot_spots = try analyzer.find_hot_spots();
const gas_analysis = try analyzer.analyze_gas_usage();
const memory_patterns = try analyzer.analyze_memory_patterns();

// Generate reports
try analyzer.generate_report("performance_report.html");
```

### Differential Analysis
```zig
// Compare execution traces between implementations
const differ = tracer.TraceDiffer.init(allocator);
defer differ.deinit();

const differences = try differ.compare_traces(
    "guillotine_trace.json",
    "reference_trace.json"
);

for (differences) |diff| {
    std.debug.print("Difference at step {}: {} vs {}\n", .{
        diff.step_number, diff.guillotine_value, diff.reference_value
    });
}
```

## Tracer Events

The DefaultTracer logs comprehensive events throughout EVM execution. These events are crucial for debugging, performance analysis, and validation.

### Lifecycle Events

#### Frame Execution
- **`onFrameStart(code_len, gas, depth)`** - Frame execution begins
- **`onFrameComplete(gas_left, output_len)`** - Frame execution completes successfully
- **`onInterpret(frame, bytecode, gas_limit)`** - Interpreter initialization with MinimalEvm setup

#### Bytecode Analysis
- **`onBytecodeAnalysisStart(code_len)`** - Bytecode preprocessing begins
- **`onBytecodeAnalysisComplete(validated_up_to, opcode_count, jumpdest_count)`** - Analysis completed
- **`onJumpdestFound(pc, count)`** - JUMPDEST instruction detected during analysis
- **`onInvalidOpcode(pc, opcode)`** - Invalid opcode detected
- **`onTruncatedPush(pc, push_size, available)`** - PUSH instruction truncated at bytecode end

#### Dispatch Schedule Building
- **`onScheduleBuildStart(bytecode_len)`** - Dispatch schedule construction begins
- **`onScheduleBuildComplete(item_count, fusion_count)`** - Schedule built successfully
- **`onFusionDetected(pc, fusion_type, instruction_count)`** - Bytecode fusion opportunity detected
- **`onStaticJumpResolved(jump_pc, target_pc)`** - Static jump target resolved
- **`onInvalidStaticJump(jump_pc, target_pc)`** - Invalid static jump detected
- **`onJumpTableCreated(jumpdest_count)`** - Jump table constructed

### Instruction Execution Events

#### Per-Instruction Tracking
- **`before_instruction(frame, opcode, cursor)`** - Called before every instruction execution
  - Validates handler consistency
  - Increments instruction counters
  - Executes MinimalEvm validation
  - Logs execution details (PC, stack size, gas)
- **`after_instruction(frame, opcode, next_handler, next_cursor)`** - Called after successful execution
  - Advances schedule index
  - Validates next handler
  - Validates MinimalEvm state
  - Updates PC tracking
- **`after_complete(frame, opcode)`** - Called for terminal instructions (STOP, RETURN, REVERT)

### EVM Operation Events

#### Call Operations
- **`onCallStart(call_type, gas, to, value)`** - CALL/DELEGATECALL/STATICCALL begins
- **`onCallComplete(success, gas_left, output_len)`** - Call operation completes
- **`onCallPreflight(call_type, result)`** - Pre-flight validation for calls

#### System Operations
- **`onEvmInit(gas_price, origin, hardfork)`** - EVM initialization
- **`onAccountDelegation(account, delegated)`** - Account delegation detected
- **`onEmptyAccountAccess()`** - Empty account accessed
- **`onCodeRetrieval(address, code_len, is_empty)`** - Contract code retrieved

#### Protocol Updates
- **`onBeaconRootUpdate(success, error_val)`** - Beacon root processing (EIP-4788)
- **`onHistoricalBlockHashUpdate(success, error_val)`** - Block hash update
- **`onValidatorDeposits(success, error_val)`** - Validator deposit processing
- **`onValidatorWithdrawals(success, error_val)`** - Validator withdrawal processing

### Memory Management Events

#### Arena Allocator
- **`onArenaInit(initial_capacity, max_capacity, growth_factor)`** - Arena allocator initialized
- **`onArenaReset(mode, capacity_before, capacity_after)`** - Arena reset
- **`onArenaAlloc(size, alignment, current_capacity)`** - Allocation made
- **`onArenaGrow(old_capacity, new_capacity, requested_size)`** - Arena expanded
- **`onArenaAllocFailed(size, current_capacity, max_capacity)`** - Allocation failed

### Validation and Debugging

#### Assertion and Error Handling
- **`assert(condition, message)`** - Runtime assertion with descriptive message
- **`throwError(format, args)`** - Fatal error with formatted message

#### Logging Functions
- **`debug(format, args)`** - Debug-level logging
- **`info(format, args)`** - Info-level logging
- **`warn(format, args)`** - Warning-level logging
- **`err(format, args)`** - Error-level logging

### Internal Tracking

The DefaultTracer maintains internal state for validation:

```zig
// Execution counters
instruction_count: u64              // Total instructions executed
schedule_index: u64                 // Current dispatch schedule position
simple_instruction_count: u64       // Regular opcodes (0x00-0xFF)
fused_instruction_count: u64        // Synthetic opcodes (>0xFF)

// Safety and validation
instruction_safety: SafetyCounter   // 300M instruction limit
pc_tracker: ?PcTracker              // Program counter tracking
gas_tracker: ?u64                   // Gas consumption tracking
current_pc: u32                     // Current program counter
bytecode: []const u8                // Bytecode being executed

// MinimalEvm validation
minimal_evm: ?MinimalEvm            // Parallel execution for validation
```

### Event Usage Examples

```zig
// Frame execution lifecycle
tracer.onFrameStart(bytecode.len, gas_limit, depth);
// ... execute frame ...
tracer.onFrameComplete(gas_remaining, output.len);

// Instruction execution with validation
tracer.before_instruction(frame, .ADD, cursor);
// ... execute ADD ...
tracer.after_instruction(frame, .ADD, next_handler, next_cursor);

// Bytecode analysis tracking
tracer.onBytecodeAnalysisStart(code.len);
tracer.onJumpdestFound(pc, jumpdest_count);
tracer.onFusionDetected(pc, "PUSH_ADD", 2);
tracer.onBytecodeAnalysisComplete(validated_len, opcode_count, jumpdest_count);

// Error conditions
tracer.assert(stack.size() >= 2, "ADD requires 2 stack items");
tracer.err("[DIVERGENCE] Stack size mismatch: MinimalEvm={d}, Frame={d}", .{evm_size, frame_size});
```

## Testing Integration

### Differential Testing
```zig
// Compare MinimalEvm with main EVM
test "stack operand order verification" {
    const bytecode = &[_]u8{
        0x60, 0x03, // PUSH1 3
        0x60, 0x05, // PUSH1 5
        0x03,       // SUB
    };

    // MinimalEvm execution
    var minimal = try MinimalEvm.init(allocator, bytecode, 100000);
    defer minimal.deinit();
    try minimal.execute();
    const minimal_result = try minimal.popStack();

    // Main EVM execution
    var main_evm = try Evm.init(allocator, bytecode);
    defer main_evm.deinit();
    const main_result = try main_evm.execute();

    // Results must match (5 - 3 = 2)
    try std.testing.expectEqual(minimal_result, main_result);
    try std.testing.expectEqual(@as(u256, 2), minimal_result);
}
```

### Unit Testing with Tracing
```zig
test "EVM execution with tracing" {
    var debug_tracer = tracer.DebuggingTracer.init(std.testing.allocator);
    defer debug_tracer.deinit();
    
    const DebugEvm = evm.Evm(tracer.DebuggingTracer);
    var debug_evm = DebugEvm.init(std.testing.allocator, test_host);
    defer debug_evm.deinit();
    
    const bytecode = &[_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01 }; // PUSH1 1 PUSH1 2 ADD
    const result = try debug_evm.execute(bytecode);
    
    try std.testing.expect(result.success);
    try std.testing.expect(debug_tracer.steps.items.len == 3);
    
    const final_step = debug_tracer.steps.items[2];
    try std.testing.expect(final_step.opcode == 0x01); // ADD opcode
}
```

### Regression Testing
```zig
test "execution trace consistency" {
    // Execute same bytecode with different configurations
    const traces = try execute_with_all_tracers(test_bytecode);
    defer deinit_traces(traces);
    
    // Verify consistent execution results
    const reference_result = traces.noop_result;
    try std.testing.expect(std.meta.eql(reference_result, traces.debug_result));
    try std.testing.expect(std.meta.eql(reference_result, traces.logging_result));
}
```

The tracer module provides a powerful, flexible foundation for EVM execution analysis, debugging, and performance optimization while maintaining zero overhead in production deployments through compile-time configuration.
