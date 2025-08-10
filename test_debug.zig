const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");

fn testAddress(value: u160) primitives.Address.Address {
    return primitives.Address.from_u256(@as(u256, value));
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Simple test: PUSH1 0x42, store it in memory, and return it
    const bytecode = &[_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    const contract_addr = testAddress(0x1000);
    const caller = testAddress(0x2000);

    try vm.state.set_code(contract_addr, bytecode);

    const call_params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_addr,
        .value = 0,
        .input = &[_]u8{},
        .gas = 100000,
    } };

    const result = try vm.call(call_params);
    defer if (result.output) |output| allocator.free(output);

    std.debug.print("Success: {}\n", .{result.success});
    std.debug.print("Gas used: {}\n", .{result.gas_used});

    if (result.output) |output| {
        std.debug.print("Output length: {}\n", .{output.len});
        std.debug.print("Output bytes: ", .{});
        for (output) |byte| {
            std.debug.print("{x:0>2} ", .{byte});
        }
        std.debug.print("\n", .{});

        // Check if it's 0x42 at the end
        if (output.len == 32) {
            const value = output[31];
            std.debug.print("Last byte (should be 0x42): 0x{x:0>2}\n", .{value});
        }
    } else {
        std.debug.print("No output returned\n", .{});
    }
}
