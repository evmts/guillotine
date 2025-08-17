const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");

test "benchmark: tailcall dispatch performance" {
    const allocator = std.testing.allocator;
    
    // Simple test bytecode - just arithmetic operations
    const code = [_]u8{
        // Push some values and do arithmetic
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3
        0x01,       // ADD
        0x60, 0x02, // PUSH1 2
        0x02,       // MUL
        0x60, 0x10, // PUSH1 16
        0x06,       // MOD
        0x50,       // POP
        0x00,       // STOP
    };
    
    std.debug.print("\n=== TAILCALL DISPATCH TEST ===\n", .{});
    std.debug.print("Testing tailcall dispatch implementation\n", .{});
    std.debug.print("Bytecode size: {} bytes\n\n", .{code.len});
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    
    // Create VM with proper parameters
    var vm = try evm.Evm.init(
        allocator,
        db_interface,
        null,   // table
        null,   // chain_rules  
        null,   // context
        0,      // depth
        false,  // read_only
        null    // tracer
    );
    defer vm.deinit();
    
    // Analyze the bytecode
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &evm.OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // Create a mock host
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    // Create frame with proper parameters
    var frame = try evm.Frame.init(
        1_000_000,                    // gas_remaining
        false,                        // static_call
        0,                           // call_depth
        primitives.Address.ZERO,     // contract_address
        primitives.Address.ZERO,     // caller
        0,                           // value
        &analysis,                   // analysis
        host,                        // host
        db_interface,                // state
        allocator                    // allocator
    );
    defer frame.deinit(allocator);
    
    // Run warm-up iterations
    std.debug.print("Running warm-up...\n", .{});
    for (0..100) |_| {
        // Reset frame for each iteration
        frame.gas_remaining = 1_000_000;
        frame.stack.clear();
        
        const result = vm.interpret(&frame);
        _ = result catch {};
    }
    
    // Benchmark
    std.debug.print("Running benchmark...\n", .{});
    const iterations = 10000;
    
    var timer = try std.time.Timer.start();
    
    for (0..iterations) |_| {
        // Reset frame state
        frame.gas_remaining = 1_000_000;
        frame.stack.clear();
        
        const result = vm.interpret(&frame);
        _ = result catch {};
    }
    
    const elapsed_ns = timer.read();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const avg_us = (elapsed_ms * 1000.0) / @as(f64, @floatFromInt(iterations));
    
    std.debug.print("\n=== RESULTS ===\n", .{});
    std.debug.print("Iterations: {}\n", .{iterations});
    std.debug.print("Total time: {d:.2}ms\n", .{elapsed_ms});
    std.debug.print("Average per iteration: {d:.3}μs\n", .{avg_us});
    std.debug.print("Operations per second: {d:.0}\n", .{
        @as(f64, @floatFromInt(iterations * 1_000_000_000)) / @as(f64, @floatFromInt(elapsed_ns))
    });
    
    std.debug.print("\nNote: This build uses TAILCALL dispatch by default\n", .{});
    std.debug.print("\nTo compare performance:\n", .{});
    std.debug.print("  With tailcall: zig build test-tailcall-benchmark\n", .{});
    std.debug.print("  With switch:   zig build test-tailcall-benchmark -Ddisable-tailcall-dispatch\n", .{});
}

test "benchmark: complex tailcall dispatch" {
    const allocator = std.testing.allocator;
    
    // Build more complex bytecode
    var code = std.ArrayList(u8).init(allocator);
    defer code.deinit();
    
    // Create a sequence with various operations
    for (0..50) |i| {
        try code.append(0x60); // PUSH1
        try code.append(@intCast(i + 1));
    }
    
    // DUP and SWAP operations
    for (0..20) |i| {
        try code.append(0x80 + @as(u8, @intCast(i % 16))); // DUP1-16
        try code.append(0x90 + @as(u8, @intCast(i % 16))); // SWAP1-16
    }
    
    // Arithmetic operations
    for (0..30) |_| {
        try code.append(0x01); // ADD
        try code.append(0x02); // MUL
        try code.append(0x06); // MOD
    }
    
    // Clean up stack
    for (0..50) |_| {
        try code.append(0x50); // POP
    }
    
    try code.append(0x00); // STOP
    
    std.debug.print("\n=== COMPLEX BYTECODE BENCHMARK ===\n", .{});
    std.debug.print("Bytecode size: {} bytes\n", .{code.items.len});
    std.debug.print("Testing with complex operation mix\n\n", .{});
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    
    var vm = try evm.Evm.init(
        allocator,
        db_interface,
        null,   // table
        null,   // chain_rules
        null,   // context
        0,      // depth
        false,  // read_only
        null    // tracer
    );
    defer vm.deinit();
    
    var analysis = try evm.CodeAnalysis.from_code(allocator, code.items, &evm.OpcodeMetadata.DEFAULT);
    defer analysis.deinit();
    
    // Create a mock host
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    var frame = try evm.Frame.init(
        10_000_000,                  // gas_remaining
        false,                       // static_call
        0,                          // call_depth
        primitives.Address.ZERO,    // contract_address
        primitives.Address.ZERO,    // caller
        0,                          // value
        &analysis,                  // analysis
        host,                       // host
        db_interface,               // state
        allocator                   // allocator
    );
    defer frame.deinit(allocator);
    
    // Benchmark
    const iterations = 1000;
    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    
    for (0..iterations) |_| {
        // Reset frame state
        frame.gas_remaining = 10_000_000;
        frame.stack.clear();
        
        var timer = try std.time.Timer.start();
        const result = vm.interpret(&frame);
        _ = result catch {};
        const elapsed = timer.read();
        
        total_ns += elapsed;
        min_ns = @min(min_ns, elapsed);
        max_ns = @max(max_ns, elapsed);
    }
    
    const avg_ns = total_ns / iterations;
    
    std.debug.print("=== STATISTICS ===\n", .{});
    std.debug.print("Iterations: {}\n", .{iterations});
    std.debug.print("Average: {d:.3}μs\n", .{@as(f64, @floatFromInt(avg_ns)) / 1000.0});
    std.debug.print("Min: {d:.3}μs\n", .{@as(f64, @floatFromInt(min_ns)) / 1000.0});
    std.debug.print("Max: {d:.3}μs\n", .{@as(f64, @floatFromInt(max_ns)) / 1000.0});
    std.debug.print("Throughput: {d:.0} ops/sec\n", .{
        @as(f64, @floatFromInt(iterations * 1_000_000_000)) / @as(f64, @floatFromInt(total_ns))
    });
}