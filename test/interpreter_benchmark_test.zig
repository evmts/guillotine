const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const revm_wrapper = @import("revm");

test {
    std.testing.log_level = .warn;
}

fn hex_decode(allocator: std.mem.Allocator, hex_str: []const u8) ![]u8 {
    const clean_hex = if (std.mem.startsWith(u8, hex_str, "0x")) hex_str[2..] else hex_str;
    const result = try allocator.alloc(u8, clean_hex.len / 2);
    _ = try std.fmt.hexToBytes(result, clean_hex);
    return result;
}

fn read_case_file(allocator: std.mem.Allocator, comptime case_name: []const u8, comptime file_name: []const u8) ![]u8 {
    const path = "/Users/williamcory/Guillotine/bench/official/cases/" ++ case_name ++ "/" ++ file_name;
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 16 * 1024 * 1024);
    const trimmed = std.mem.trim(u8, content, " \t\n\r");
    if (trimmed.ptr == content.ptr and trimmed.len == content.len) {
        return content;
    }
    defer allocator.free(content);
    const result = try allocator.alloc(u8, trimmed.len);
    @memcpy(result, trimmed);
    return result;
}

test "benchmark interpreters: ten-thousand-hashes" {
    const allocator = testing.allocator;
    
    const bytecode_hex = try read_case_file(allocator, "ten-thousand-hashes", "bytecode.txt");
    defer allocator.free(bytecode_hex);
    
    const init_code = try hex_decode(allocator, bytecode_hex);
    defer allocator.free(init_code);
    
    // Try reading calldata
    var calldata: []u8 = &.{};
    const calldata_path = "/Users/williamcory/Guillotine/bench/official/cases/ten-thousand-hashes/calldata.txt";
    if (std.fs.openFileAbsolute(calldata_path, .{})) |file| {
        defer file.close();
        const content = try file.readToEndAlloc(allocator, 1024);
        defer allocator.free(content);
        const trimmed = std.mem.trim(u8, content, " \t\n\r");
        calldata = try hex_decode(allocator, trimmed);
    } else |_| {
        calldata = try allocator.alloc(u8, 0);
    }
    defer if (calldata.len > 0) allocator.free(calldata);
    
    const deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    const fixed_addr = try Address.from_hex("0xc0de000000000000000000000000000000000000");
    
    std.debug.print("\n=== Ten Thousand Hashes Benchmark ===\n", .{});
    
    // Benchmark interpret.zig
    {
        var memory_db = evm.MemoryDatabase.init(allocator);
        defer memory_db.deinit();
        var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
        defer vm.deinit();
        
        try vm.state.set_balance(deployer, std.math.maxInt(u256));
        const create_result = try vm.create_contract(deployer, 0, init_code, 10_000_000);
        const contract_addr = create_result.address;
        
        const start = std.time.nanoTimestamp();
        const result = try vm.call(deployer, contract_addr, 0, calldata, 5_000_000);
        const elapsed = std.time.nanoTimestamp() - start;
        
        std.debug.print("interpret.zig:    {d:.3} ms (success: {}, gas used: {})\n", .{
            @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
            result.success,
            result.gas_used,
        });
    }
    
    // Benchmark call.zig
    {
        var memory_db = evm.MemoryDatabase.init(allocator);
        defer memory_db.deinit();
        var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
        defer vm.deinit();
        
        try vm.state.set_balance(deployer, std.math.maxInt(u256));
        const create_result = try vm.create_contract(deployer, 0, init_code, 10_000_000);
        const contract_addr = create_result.address;
        
        const params = evm.CallParams{
            .call = .{
                .caller = deployer,
                .to = contract_addr,
                .value = 0,
                .input = calldata,
                .gas = 5_000_000,
            },
        };
        
        const start = std.time.nanoTimestamp();
        const result = try vm.call(params);
        const elapsed = std.time.nanoTimestamp() - start;
        
        std.debug.print("call.zig:    {d:.3} ms (success: {}, gas left: {})\n", .{
            @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
            result.success,
            result.gas_left,
        });
    }
    
    // Benchmark REVM
    {
        var vm = try revm_wrapper.Revm.init(allocator, .{});
        defer vm.deinit();
        
        try vm.setBalance(deployer, std.math.maxInt(u256));
        var create_result = try vm.create(deployer, 0, init_code, 10_000_000);
        defer create_result.deinit();
        
        try vm.setCode(fixed_addr, create_result.output);
        
        const start = std.time.nanoTimestamp();
        var result = try vm.call(deployer, fixed_addr, 0, calldata, 5_000_000);
        defer result.deinit();
        const elapsed = std.time.nanoTimestamp() - start;
        
        std.debug.print("REVM:             {d:.3} ms (success: {}, gas used: {})\n", .{
            @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
            result.success,
            result.gas_used,
        });
    }
}

test "benchmark interpreters: erc20-transfer" {
    const allocator = testing.allocator;
    
    const bytecode_hex = try read_case_file(allocator, "erc20-transfer", "bytecode.txt");
    defer allocator.free(bytecode_hex);
    
    const init_code = try hex_decode(allocator, bytecode_hex);
    defer allocator.free(init_code);
    
    var calldata: []u8 = &.{};
    const calldata_path = "/Users/williamcory/Guillotine/bench/official/cases/erc20-transfer/calldata.txt";
    if (std.fs.openFileAbsolute(calldata_path, .{})) |file| {
        defer file.close();
        const content = try file.readToEndAlloc(allocator, 1024);
        defer allocator.free(content);
        const trimmed = std.mem.trim(u8, content, " \t\n\r");
        calldata = try hex_decode(allocator, trimmed);
    } else |_| {
        calldata = try allocator.alloc(u8, 0);
    }
    defer if (calldata.len > 0) allocator.free(calldata);
    
    const deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    const fixed_addr = try Address.from_hex("0xc0de000000000000000000000000000000000000");
    
    std.debug.print("\n=== ERC20 Transfer Benchmark ===\n", .{});
    
    // Benchmark interpret.zig
    {
        var memory_db = evm.MemoryDatabase.init(allocator);
        defer memory_db.deinit();
        var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
        defer vm.deinit();
        
        try vm.state.set_balance(deployer, std.math.maxInt(u256));
        const create_result = try vm.create_contract(deployer, 0, init_code, 10_000_000);
        const contract_addr = create_result.address;
        
        const start = std.time.nanoTimestamp();
        const result = try vm.call(deployer, contract_addr, 0, calldata, 1_000_000);
        const elapsed = std.time.nanoTimestamp() - start;
        
        std.debug.print("interpret.zig:    {d:.3} ms (success: {}, gas used: {})\n", .{
            @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
            result.success,
            result.gas_used,
        });
    }
    
    // Benchmark call.zig
    {
        var memory_db = evm.MemoryDatabase.init(allocator);
        defer memory_db.deinit();
        var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
        defer vm.deinit();
        
        try vm.state.set_balance(deployer, std.math.maxInt(u256));
        const create_result = try vm.create_contract(deployer, 0, init_code, 10_000_000);
        const contract_addr = create_result.address;
        
        const params = evm.CallParams{
            .call = .{
                .caller = deployer,
                .to = contract_addr,
                .value = 0,
                .input = calldata,
                .gas = 1_000_000,
            },
        };
        
        const start = std.time.nanoTimestamp();
        const result = try vm.call(params);
        const elapsed = std.time.nanoTimestamp() - start;
        
        std.debug.print("call.zig:    {d:.3} ms (success: {}, gas left: {})\n", .{
            @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
            result.success,
            result.gas_left,
        });
    }
    
    // Benchmark REVM
    {
        var vm = try revm_wrapper.Revm.init(allocator, .{});
        defer vm.deinit();
        
        try vm.setBalance(deployer, std.math.maxInt(u256));
        var create_result = try vm.create(deployer, 0, init_code, 10_000_000);
        defer create_result.deinit();
        
        try vm.setCode(fixed_addr, create_result.output);
        
        const start = std.time.nanoTimestamp();
        var result = try vm.call(deployer, fixed_addr, 0, calldata, 1_000_000);
        defer result.deinit();
        const elapsed = std.time.nanoTimestamp() - start;
        
        std.debug.print("REVM:             {d:.3} ms (success: {}, gas used: {})\n", .{
            @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
            result.success,
            result.gas_used,
        });
    }
}