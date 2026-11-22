//! Per-opcode gas differential: every defined opcode, fed all-zero or all-one
//! operands, must spend exactly the same execution gas in the dispatch Frame as
//! in the sequential reference interpreter (MinimalEvm).
const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");

const gas_limit: u64 = 1_000_000;
const contract = primitives.Address{ .bytes = [_]u8{0x42} ++ [_]u8{0} ** 19 };
const caller = primitives.Address{ .bytes = [_]u8{0x10} ++ [_]u8{0} ** 19 };

const Outcome = struct { success: bool, gas_used: u64 };

fn guillotineRun(code: []const u8) !Outcome {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();
    const code_hash = try db.set_code(code);
    try db.set_account(contract.bytes, evm.Account{
        .balance = 1_000,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });
    const block_info = evm.BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    const context = evm.TransactionContext{
        .gas_limit = gas_limit,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    const CancunEvm = evm.Evm(.{ .eips = evm.Eips{ .hardfork = .CANCUN } });
    var vm = try CancunEvm.init(allocator, &db, block_info, context, 0, caller);
    defer vm.deinit();
    var result = vm.call(.{ .call = .{
        .caller = caller,
        .to = contract,
        .value = 0,
        .input = &.{},
        .gas = gas_limit,
    } });
    defer result.deinit(allocator);
    return .{ .success = result.success, .gas_used = gas_limit - result.gas_left };
}

fn minimalRun(code: []const u8) !Outcome {
    const allocator = std.testing.allocator;
    const minimal = try evm.MinimalEvm.initPtr(allocator);
    defer minimal.deinitPtr(allocator);
    minimal.setHardfork(.CANCUN);
    try minimal.setCode(contract, code);
    try minimal.setBalance(contract, 1_000);
    const result = try minimal.execute(code, @intCast(gas_limit), caller, contract, 0, &.{});
    return .{ .success = result.success, .gas_used = gas_limit - result.gas_left };
}

test "gas sweep: every opcode matches MinimalEvm" {
    const info = evm.opcode_data.OPCODE_INFO;
    var mismatches: usize = 0;
    for ([_]u8{ 0x00, 0x01 }) |operand| {
        var opcode: usize = 0;
        while (opcode < 256) : (opcode += 1) {
            const op: u8 = @intCast(opcode);
            if (op >= 0x60 and op <= 0x7f) continue; // PUSH has immediates
            if (op == 0x56 or op == 0x57 or op == 0x5b) continue; // control flow covered elsewhere
            var code: [80]u8 = undefined;
            var n: usize = 0;
            var k: usize = 0;
            while (k < info[op].stack_inputs) : (k += 1) {
                code[n] = 0x60;
                code[n + 1] = operand;
                n += 2;
            }
            if (op >= 0x80 and op <= 0x9f) {
                const depth: usize = if (op <= 0x8f) op - 0x7f else op - 0x8e;
                k = 0;
                while (k < depth) : (k += 1) {
                    code[n] = 0x60;
                    code[n + 1] = operand;
                    n += 2;
                }
            }
            code[n] = op;
            code[n + 1] = 0x00;
            n += 2;
            const g = try guillotineRun(code[0..n]);
            const m = try minimalRun(code[0..n]);
            if (g.success != m.success or (m.success and g.gas_used != m.gas_used)) {
                mismatches += 1;
                std.debug.print("SWEEP op=0x{x:0>2} operand={} guillotine={}/{} minimal={}/{}\n", .{ op, operand, g.success, g.gas_used, m.success, m.gas_used });
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}
