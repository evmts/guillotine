const std = @import("std");
const evm = @import("evm");
const Vm = evm.Evm;
const Frame = evm.Frame;
const Contract = evm.Contract;
const MemoryDatabase = evm.MemoryDatabase;
const primitives = @import("primitives");
const Address = primitives.Address;
const revm = @import("revm");
const Revm = revm.Revm;
const RevmSettings = revm.RevmSettings;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("\n=== Direct Guillotine vs revm Performance Comparison ===\n\n", .{});
    
    // Test 1: Simple Smart Contract
    try compareSimpleContract(allocator);
    
    // Test 2: Arithmetic Operations
    try compareArithmeticOps(allocator);
    
    // Test 3: Memory Operations
    try compareMemoryOps(allocator);
    
    std.debug.print("\n=== Comparison Complete ===\n", .{});
}

fn compareSimpleContract(allocator: std.mem.Allocator) !void {
    std.debug.print("--- Simple Smart Contract ---\n", .{});
    
    // Use bytecode from solidity test files - simple constructor that returns a small contract
    const contract_bytecode_hex = "608060405234801561001057600080fd5b50610100565b6101008061001f6000396000f3fe";
    
    // Convert hex to bytes
    const bytecode_len = contract_bytecode_hex.len / 2;
    const bytecode = try allocator.alloc(u8, bytecode_len);
    defer allocator.free(bytecode);
    _ = try std.fmt.hexToBytes(bytecode, contract_bytecode_hex);
    
    const caller = Address.from_u256(0x1111);
    const contract_addr = Address.from_u256(0x2222);
    
    // Guillotine benchmark
    var guillotine_total: u64 = 0;
    const guillotine_runs = 100;
    
    var i: usize = 0;
    while (i < guillotine_runs) : (i += 1) {
        var memory_db = MemoryDatabase.init(allocator);
        defer memory_db.deinit();
        
        const db_interface = memory_db.to_database_interface();
        var vm = try Vm.init(allocator, db_interface, null, null, null, 0, false, null);
        defer vm.deinit();
        
        try vm.state.set_balance(caller, 1000000);
        
        var contract = Contract.init(
            caller,  // caller
            contract_addr,    // addr
            0, // value
            1000000, // gas
            bytecode,  // code
            [_]u8{0} ** 32, // code_hash
            &.{},  // input
            false, // is_static
        );
        
        const start = std.time.nanoTimestamp();
        const result = try vm.interpret(&contract, &.{}, false);
        const end = std.time.nanoTimestamp();
        
        guillotine_total += @intCast(end - start);
        std.mem.doNotOptimizeAway(result.gas_used);
    }
    
    // revm benchmark
    var revm_total: u64 = 0;
    i = 0;
    while (i < guillotine_runs) : (i += 1) {
        var vm = try Revm.init(allocator, .{});
        defer vm.deinit();
        
        try vm.setBalance(caller, 1000000);
        try vm.setCode(contract_addr, bytecode);
        
        const start = std.time.nanoTimestamp();
        var result = try vm.call(caller, contract_addr, 0, &.{}, 1000000);
        defer result.deinit();
        const end = std.time.nanoTimestamp();
        
        revm_total += @intCast(end - start);
        std.mem.doNotOptimizeAway(result.gas_used);
    }
    
    const guillotine_avg = guillotine_total / guillotine_runs;
    const revm_avg = revm_total / guillotine_runs;
    const ratio = @as(f64, @floatFromInt(guillotine_avg)) / @as(f64, @floatFromInt(revm_avg));
    
    std.debug.print("Guillotine: {} ns/op\n", .{guillotine_avg});
    std.debug.print("revm:       {} ns/op\n", .{revm_avg});
    std.debug.print("Ratio:      {d:.2}x ", .{ratio});
    
    if (ratio < 1.0) {
        std.debug.print("(Guillotine is {d:.1}% faster)\n\n", .{(1.0 - ratio) * 100});
    } else {
        std.debug.print("(revm is {d:.1}% faster)\n\n", .{(ratio - 1.0) * 100});
    }
}

fn compareArithmeticOps(allocator: std.mem.Allocator) !void {
    std.debug.print("--- Arithmetic Operations ---\n", .{});
    
    const bytecode = &[_]u8{
        0x60, 0x2A, // PUSH1 42
        0x60, 0x64, // PUSH1 100
        0x01,       // ADD
        0x60, 0x02, // PUSH1 2
        0x02,       // MUL
        0x60, 0x0A, // PUSH1 10
        0x04,       // DIV
        0x60, 0x05, // PUSH1 5
        0x03,       // SUB
        0x00,       // STOP
    };
    
    const runs = 100;
    var guillotine_total: u64 = 0;
    var revm_total: u64 = 0;
    
    // Benchmark both
    var i: usize = 0;
    while (i < runs) : (i += 1) {
        // Guillotine
        {
            var memory_db = MemoryDatabase.init(allocator);
            defer memory_db.deinit();
            
            const db_interface = memory_db.to_database_interface();
            var vm = try Vm.init(allocator, db_interface, null, null, null, 0, false, null);
            defer vm.deinit();
            
            const caller = Address.from_u256(0x1000);
            try vm.state.set_balance(caller, 1000000);
            
            var contract = Contract.init(
                caller,  // caller
                Address.from_u256(0x2000),  // addr
                0,  // value
                100000,  // gas
                bytecode,  // code
                [_]u8{0} ** 32,  // code_hash
                &.{},  // input
                false,  // is_static
            );
            
            const start = std.time.nanoTimestamp();
            const result = try vm.interpret(&contract, &.{}, false);
            const end = std.time.nanoTimestamp();
            
            guillotine_total += @intCast(end - start);
            std.mem.doNotOptimizeAway(result.gas_used);
        }
        
        // revm
        {
            var vm = try Revm.init(allocator, .{});
            defer vm.deinit();
            
            const caller = Address.from_u256(0x1000);
            const contract_addr = Address.from_u256(0x2000);
            
            try vm.setBalance(caller, 1000000);
            try vm.setCode(contract_addr, bytecode);
            
            const start = std.time.nanoTimestamp();
            var result = try vm.call(caller, contract_addr, 0, &.{}, 100000);
            defer result.deinit();
            const end = std.time.nanoTimestamp();
            
            revm_total += @intCast(end - start);
            std.mem.doNotOptimizeAway(result.gas_used);
        }
    }
    
    const guillotine_avg = guillotine_total / runs;
    const revm_avg = revm_total / runs;
    const ratio = @as(f64, @floatFromInt(guillotine_avg)) / @as(f64, @floatFromInt(revm_avg));
    
    std.debug.print("Guillotine: {} ns/op\n", .{guillotine_avg});
    std.debug.print("revm:       {} ns/op\n", .{revm_avg});
    std.debug.print("Ratio:      {d:.2}x ", .{ratio});
    
    if (ratio < 1.0) {
        std.debug.print("(Guillotine is {d:.1}% faster)\n\n", .{(1.0 - ratio) * 100});
    } else {
        std.debug.print("(revm is {d:.1}% faster)\n\n", .{(ratio - 1.0) * 100});
    }
}

fn compareMemoryOps(allocator: std.mem.Allocator) !void {
    std.debug.print("--- Memory Operations ---\n", .{});
    
    const bytecode = &[_]u8{
        0x60, 0xFF, // PUSH1 0xFF
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x00, // PUSH1 0
        0x51,       // MLOAD
        0x60, 0x20, // PUSH1 32
        0x51,       // MLOAD
        0x01,       // ADD
        0x00,       // STOP
    };
    
    const runs = 100;
    var guillotine_total: u64 = 0;
    var revm_total: u64 = 0;
    
    var i: usize = 0;
    while (i < runs) : (i += 1) {
        // Guillotine
        {
            var memory_db = MemoryDatabase.init(allocator);
            defer memory_db.deinit();
            
            const db_interface = memory_db.to_database_interface();
            var vm = try Vm.init(allocator, db_interface, null, null, null, 0, false, null);
            defer vm.deinit();
            
            const caller = Address.from_u256(0x1000);
            try vm.state.set_balance(caller, 1000000);
            
            var contract = Contract.init(
                caller,  // caller
                Address.from_u256(0x2000),  // addr
                0,  // value
                100000,  // gas
                bytecode,  // code
                [_]u8{0} ** 32,  // code_hash
                &.{},  // input
                false,  // is_static
            );
            
            const start = std.time.nanoTimestamp();
            const result = try vm.interpret(&contract, &.{}, false);
            const end = std.time.nanoTimestamp();
            
            guillotine_total += @intCast(end - start);
            std.mem.doNotOptimizeAway(result.gas_used);
        }
        
        // revm
        {
            var vm = try Revm.init(allocator, .{});
            defer vm.deinit();
            
            const caller = Address.from_u256(0x1000);
            const contract_addr = Address.from_u256(0x2000);
            
            try vm.setBalance(caller, 1000000);
            try vm.setCode(contract_addr, bytecode);
            
            const start = std.time.nanoTimestamp();
            var result = try vm.call(caller, contract_addr, 0, &.{}, 100000);
            defer result.deinit();
            const end = std.time.nanoTimestamp();
            
            revm_total += @intCast(end - start);
            std.mem.doNotOptimizeAway(result.gas_used);
        }
    }
    
    const guillotine_avg = guillotine_total / runs;
    const revm_avg = revm_total / runs;
    const ratio = @as(f64, @floatFromInt(guillotine_avg)) / @as(f64, @floatFromInt(revm_avg));
    
    std.debug.print("Guillotine: {} ns/op\n", .{guillotine_avg});
    std.debug.print("revm:       {} ns/op\n", .{revm_avg});
    std.debug.print("Ratio:      {d:.2}x ", .{ratio});
    
    if (ratio < 1.0) {
        std.debug.print("(Guillotine is {d:.1}% faster)\n\n", .{(1.0 - ratio) * 100});
    } else {
        std.debug.print("(revm is {d:.1}% faster)\n\n", .{(ratio - 1.0) * 100});
    }
}