const std = @import("std");
const root = @import("root.zig");
const Evm = root.Evm;
const Frame = Evm.Frame;
const Contract = Evm.Contract;
const primitives = root.primitives;
const Address = primitives.Address;
const Allocator = std.mem.Allocator;
const timing = @import("timing.zig");

// Fixed hash for benchmarks (not used in production)
const fixed_hash = [_]u8{0} ** 32;

/// Frame Lifecycle Benchmarks
pub fn bench_frame_init_minimal() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Minimal contract for testing
    const bytecode = &[_]u8{0x60, 0x01, 0x60, 0x02, 0x01}; // PUSH1 1 PUSH1 2 ADD
    
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const code_hash = fixed_hash;
        var contract = Contract.init(
            Address.zero(),  // caller
            Address.zero(),  // address  
            0,               // value
            1000000,         // gas
            bytecode,        // code
            code_hash,       // code_hash
            &[_]u8{},        // input
            false            // is_static
        );
        defer contract.deinit(allocator, null);
        
        var frame = Frame.init(allocator, &contract) catch unreachable;
        defer frame.deinit();
    }
}

pub fn bench_frame_deinit() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const bytecode = &[_]u8{0x60, 0x01, 0x60, 0x02, 0x01};
    
    const code_hash = fixed_hash;
    var contract = Contract.init(
        Address.zero(),  // caller
        Address.zero(),  // address  
        0,               // value
        1000000,         // gas
        bytecode,        // code
        code_hash,       // code_hash
        &[_]u8{},        // input
        false            // is_static
    );
    defer contract.deinit(allocator, null);
    
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var frame = Frame.init(allocator, &contract) catch unreachable;
        frame.deinit();
    }
}

pub fn bench_consume_gas_hot_path() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const bytecode = &[_]u8{0x60, 0x01, 0x60, 0x02, 0x01};
    
    const code_hash = fixed_hash;
    var contract = Contract.init(
        Address.zero(),  // caller
        Address.zero(),  // address  
        0,               // value
        1000000,         // gas
        bytecode,        // code
        code_hash,       // code_hash
        &[_]u8{},        // input
        false            // is_static
    );
    defer contract.deinit(allocator, null);
    
    var frame = Frame.init(allocator, &contract) catch unreachable;
    defer frame.deinit();
    
    frame.gas_remaining = 1000000;
    
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        frame.consume_gas(3) catch unreachable;
    }
}

/// Contract Management Benchmarks
pub fn bench_contract_init_small() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Small bytecode (typical transfer)
    const bytecode = &[_]u8{0x60, 0x01, 0x60, 0x02, 0x01, 0x00}; // 6 bytes
    
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const code_hash = fixed_hash;
        var contract = Contract.init(
            Address.zero(),  // caller
            Address.zero(),  // address  
            0,               // value
            1000000,         // gas
            bytecode,        // code
            code_hash,       // code_hash
            &[_]u8{},        // input
            false            // is_static
        );
        contract.deinit(allocator, null);
    }
}

pub fn bench_contract_init_large() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Large bytecode (complex contract)
    const bytecode = allocator.alloc(u8, 4096) catch unreachable;
    defer allocator.free(bytecode);
    @memset(bytecode, 0x60); // Fill with PUSH1
    
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const code_hash = fixed_hash;
        var contract = Contract.init(
            Address.zero(),  // caller
            Address.zero(),  // address  
            0,               // value
            1000000,         // gas
            bytecode,        // code
            code_hash,       // code_hash
            &[_]u8{},        // input
            false            // is_static
        );
        contract.deinit(allocator, null);
    }
}

/// Simple Call Stack Test
pub fn bench_shallow_call_stack() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const bytecode = &[_]u8{0x00};
    
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        // Create 5 levels of frames
        var contracts: [5]Contract = undefined;
        var frames: [5]Frame = undefined;
        
        // Initialize contracts and frames
        var j: usize = 0;
        while (j < 5) : (j += 1) {
            const code_hash = fixed_hash;
            contracts[j] = Contract.init(
                Address.zero(),  // caller
                Address.zero(),  // address  
                0,               // value
                1000000,         // gas
                bytecode,        // code
                code_hash,       // code_hash
                &[_]u8{},        // input
                false            // is_static
            );
            
            frames[j] = Frame.init(allocator, &contracts[j]) catch unreachable;
            frames[j].gas_remaining = 1000000;
        }
        
        // Clean up in reverse order
        j = 5;
        while (j > 0) {
            j -= 1;
            frames[j].deinit();
            contracts[j].deinit(allocator, null);
        }
    }
}

/// Run simplified frame benchmarks
pub fn run_frame_benchmarks(allocator: Allocator) !void {
    std.log.info("=== Simplified Frame Management Benchmarks ===", .{});
    
    var suite = timing.BenchmarkSuite.init(allocator);
    defer suite.deinit();
    
    // Frame Lifecycle
    std.log.info("Running Frame Lifecycle benchmarks...", .{});
    try suite.benchmark(.{
        .name = "frame_init_minimal",
        .iterations = 5,
        .warmup_iterations = 1,
    }, bench_frame_init_minimal);
    
    try suite.benchmark(.{
        .name = "frame_deinit",
        .iterations = 5,
        .warmup_iterations = 1,
    }, bench_frame_deinit);
    
    try suite.benchmark(.{
        .name = "consume_gas_hot_path",
        .iterations = 5,
        .warmup_iterations = 1,
    }, bench_consume_gas_hot_path);
    
    // Contract Management
    std.log.info("Running Contract Management benchmarks...", .{});
    try suite.benchmark(.{
        .name = "contract_init_small",
        .iterations = 5,
        .warmup_iterations = 1,
    }, bench_contract_init_small);
    
    try suite.benchmark(.{
        .name = "contract_init_large",
        .iterations = 5,
        .warmup_iterations = 1,
    }, bench_contract_init_large);
    
    // Call Stack Management
    std.log.info("Running Call Stack Management benchmarks...", .{});
    try suite.benchmark(.{
        .name = "shallow_call_stack",
        .iterations = 5,
        .warmup_iterations = 1,
    }, bench_shallow_call_stack);
    
    suite.print_results();
    
    std.log.info("Simplified frame benchmarks completed", .{});
}

test "simplified frame benchmarks compile" {
    // Simple compilation test
    try std.testing.expect(@TypeOf(bench_frame_init_minimal) == fn () void);
    try std.testing.expect(@TypeOf(run_frame_benchmarks) == fn (Allocator) anyerror!void);
}