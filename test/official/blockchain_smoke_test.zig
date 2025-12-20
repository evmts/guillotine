const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");

const DefaultEvm = evm.Evm(.{});
const BlockInfo = evm.BlockInfo;
const TransactionContext = evm.TransactionContext;
const Database = evm.Database;
const Account = evm.Account;
const Hardfork = evm.Hardfork;

fn hexTrimPrefix(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) return s[2..];
    return s;
}

fn parseU64Hex(s: []const u8) !u64 {
    const d = hexTrimPrefix(std.mem.trim(u8, s, &std.ascii.whitespace));
    if (d.len == 0) return 0;
    return std.fmt.parseInt(u64, d, 16);
}

fn parseU256Hex(s: []const u8) !u256 {
    const d = hexTrimPrefix(std.mem.trim(u8, s, &std.ascii.whitespace));
    if (d.len == 0) return 0;
    return std.fmt.parseInt(u256, d, 16);
}

fn parseBytesHex(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const hex = primitives.Hex;
    const t = std.mem.trim(u8, s, &std.ascii.whitespace);
    if (t.len == 0 or std.mem.eql(u8, t, "0x")) return allocator.alloc(u8, 0);
    return try hex.hexToBytes(allocator, t);
}

fn parseHash32(s: []const u8) ![32]u8 {
    const hex = primitives.Hex;
    const t = std.mem.trim(u8, s, &std.ascii.whitespace);
    if (t.len == 0 or std.mem.eql(u8, t, "0x")) return [_]u8{0} ** 32;
    return try hex.hexToBytes_fixed(32, t);
}

fn hfFromName(name: []const u8) Hardfork {
    if (std.ascii.eqlIgnoreCase(name, "Cancun")) return .CANCUN;
    if (std.ascii.eqlIgnoreCase(name, "Shanghai")) return .SHANGHAI;
    if (std.ascii.eqlIgnoreCase(name, "London")) return .LONDON;
    if (std.ascii.eqlIgnoreCase(name, "Berlin")) return .BERLIN;
    if (std.ascii.eqlIgnoreCase(name, "Istanbul")) return .ISTANBUL;
    if (std.ascii.eqlIgnoreCase(name, "Byzantium")) return .BYZANTIUM;
    if (std.ascii.eqlIgnoreCase(name, "Frontier")) return .FRONTIER;
    if (std.ascii.eqlIgnoreCase(name, "Homestead")) return .HOMESTEAD;
    if (std.ascii.eqlIgnoreCase(name, "ConstantinopleFix")) return .PETERSBURG;
    if (std.ascii.eqlIgnoreCase(name, "Paris")) return .MERGE;
    return .CANCUN;
}

fn setPreState(allocator: std.mem.Allocator, db: *Database, pre_obj: std.json.Value) !void {
    if (pre_obj != .object) return error.InvalidFixture;
    const obj = pre_obj.object;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const addr_str = entry.key_ptr.*;
        if (entry.value_ptr.* != .object) return error.InvalidFixture;
        const acc = entry.value_ptr.*.object;

        const address = try primitives.Address.fromHex(addr_str);
        const nonce = try parseU64Hex(acc.get("nonce").?.string);
        const balance = try parseU256Hex(acc.get("balance").?.string);
        const code_hex = acc.get("code").?.string;
        const code_bytes = try parseBytesHex(allocator, code_hex);
        defer allocator.free(code_bytes);
        const code_hash = try db.set_code(code_bytes);

        const account = Account{
            .balance = balance,
            .nonce = nonce,
            .code_hash = code_hash,
            .storage_root = [_]u8{0} ** 32,
        };

        if (acc.get("storage")) |storage_val| {
            if (storage_val != .object) return error.InvalidFixture;
            const storage_obj = storage_val.object;
            var sit = storage_obj.iterator();
            while (sit.next()) |s_kv| {
                const key = try parseU256Hex(s_kv.key_ptr.*);
                const value = try parseU256Hex(s_kv.value_ptr.*.string);
                try db.set_storage(address.bytes, key, value);
            }
        }

        try db.set_account(address.bytes, account);
    }
}

fn applyGasAccounting(db: *Database, sender: primitives.Address, coinbase: primitives.Address, gas_used: u64, gas_price: u256, base_fee: u256) !void {
    const used_u256: u256 = @intCast(gas_used);
    const total_fee = gas_price * used_u256;
    const tip_per_gas: u256 = if (gas_price > base_fee) gas_price - base_fee else 0;
    const tip_total = tip_per_gas * used_u256;

    var sender_acc = (try db.get_account(sender.bytes)) orelse Account.zero();
    if (sender_acc.balance < total_fee) return error.InsufficientBalance;
    sender_acc.balance -= total_fee;
    sender_acc.nonce += 1;
    try db.set_account(sender.bytes, sender_acc);

    var coin_acc = (try db.get_account(coinbase.bytes)) orelse Account.zero();
    coin_acc.balance += tip_total;
    try db.set_account(coinbase.bytes, coin_acc);
}

fn expectPostState(db: *Database, post_state_obj: std.json.Value) !void {
    if (post_state_obj != .object) return error.InvalidFixture;
    const obj = post_state_obj.object;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const addr = try primitives.Address.fromHex(entry.key_ptr.*);
        if (entry.value_ptr.* != .object) return error.InvalidFixture;
        const acc_expected = entry.value_ptr.*.object;

        const actual = (try db.get_account(addr.bytes)) orelse Account.zero();

        if (acc_expected.get("nonce")) |n| {
            const exp = try parseU64Hex(n.string);
            try std.testing.expectEqual(exp, actual.nonce);
        }
        if (acc_expected.get("balance")) |b| {
            const exp = try parseU256Hex(b.string);
            try std.testing.expectEqual(exp, actual.balance);
        }
        if (acc_expected.get("code")) |c| {
            const exp_code_bytes = try parseBytesHex(std.testing.allocator, c.string);
            defer std.testing.allocator.free(exp_code_bytes);
            const act_code = try db.get_code_by_address(addr.bytes);
            try std.testing.expectEqualSlices(u8, exp_code_bytes, act_code);
        }
        if (acc_expected.get("storage")) |s| {
            if (s != .object) return error.InvalidFixture;
            const s_obj = s.object;
            var sit = s_obj.iterator();
            while (sit.next()) |skv| {
                const key = try parseU256Hex(skv.key_ptr.*);
                const exp = try parseU256Hex(skv.value_ptr.*.string);
                const got = try db.get_storage(addr.bytes, key);
                try std.testing.expectEqual(exp, got);
            }
        }
    }
}

fn isStrict() bool {
    const env = std.process.getEnvVarOwned(std.testing.allocator, "OFFICIAL_STRICT") catch return false;
    defer std.testing.allocator.free(env);
    return std.mem.eql(u8, env, "1") or std.mem.eql(u8, env, "true") or std.mem.eql(u8, env, "TRUE");
}

fn runBlockchainCase(allocator: std.mem.Allocator, json_path: []const u8) !void {
    var cwd = std.fs.cwd();
    const data = try cwd.readFileAlloc(allocator, json_path, 64 * 1024 * 1024);
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidFixture;
    const root = parsed.value.object;

    // Pick first test case
    var it = root.iterator();
    const first = it.next() orelse return error.InvalidFixture;
    if (first.value_ptr.* != .object) return error.InvalidFixture;
    const tc = first.value_ptr.*.object;

    // Network/fork name
    _ = tc.get("network").?.string; // fork_name is now configured at compile time

    // Pre-state
    var db = Database.init(allocator);
    defer db.deinit();
    try setPreState(allocator, &db, tc.get("pre").?);

    // Genesis header and defaults
    const gen = tc.get("genesisBlockHeader").?.object;
    const coinbase = try primitives.Address.fromHex(gen.get("coinbase").?.string);
    const gas_limit = try parseU64Hex(gen.get("gasLimit").?.string);

    // Transaction context template (will be overridden per tx)
    var tx_context = TransactionContext{
        .gas_limit = gas_limit,
        .coinbase = coinbase,
        .chain_id = 1,
        .blob_versioned_hashes = &.{},
        .blob_base_fee = 0,
    };

    // Iterate blocks
    const blocks_val = tc.get("blocks").?.array;
    var bidx: usize = 0;
    while (bidx < blocks_val.items.len) : (bidx += 1) {
        const block = blocks_val.items[bidx].object;
        const hdr = block.get("blockHeader").?.object;

        const b_coinbase = try primitives.Address.fromHex(hdr.get("coinbase").?.string);
        const b_base_fee = try parseU256Hex(hdr.get("baseFeePerGas").?.string);
        const b_gas_limit = try parseU64Hex(hdr.get("gasLimit").?.string);
        const b_timestamp = try parseU64Hex(hdr.get("timestamp").?.string);
        const b_number = try parseU64Hex(hdr.get("number").?.string);

        const block_info = BlockInfo{
            .chain_id = 1,
            .number = b_number,
            .timestamp = b_timestamp,
            .difficulty = 0,
            .gas_limit = b_gas_limit,
            .coinbase = b_coinbase,
            .base_fee = b_base_fee,
            .prev_randao = [_]u8{0} ** 32,
            .blob_base_fee = 0,
            .blob_versioned_hashes = &.{},
        };

        tx_context.gas_limit = b_gas_limit;
        tx_context.coinbase = b_coinbase;

        var vm = try DefaultEvm.init(allocator, &db, block_info, tx_context, 0, primitives.ZERO_ADDRESS);
        defer vm.deinit();

        // Apply transactions
        const txs = block.get("transactions").?.array;
        var tidx: usize = 0;
        while (tidx < txs.items.len) : (tidx += 1) {
            const txobj = txs.items[tidx].object;
            const sender = try primitives.Address.fromHex(txobj.get("sender").?.string);
            const to_str = txobj.get("to").?.string;
            const is_create = to_str.len == 0;
            var to_addr: primitives.Address = primitives.ZERO_ADDRESS;
            if (!is_create) to_addr = try primitives.Address.fromHex(to_str);
            const gas_price = try parseU256Hex(txobj.get("gasPrice").?.string);
            const gas_lim_tx = try parseU64Hex(txobj.get("gasLimit").?.string);
            const value = try parseU256Hex(txobj.get("value").?.string);
            const input = try parseBytesHex(allocator, txobj.get("data").?.string);
            defer allocator.free(input);

            var res = vm.call(if (is_create)
                DefaultEvm.CallParams{ .create = .{ .caller = sender, .value = value, .init_code = input, .gas = gas_lim_tx } }
            else
                DefaultEvm.CallParams{ .call = .{ .caller = sender, .to = to_addr, .value = value, .input = input, .gas = gas_lim_tx } }
            );

            const gas_used: u64 = gas_lim_tx - res.gas_left;
            try applyGasAccounting(&db, sender, b_coinbase, gas_used, gas_price, b_base_fee);
            // Free any allocated result buffers/logs
            res.deinit(allocator);
        }
    }

    if (isStrict()) {
        try expectPostState(&db, tc.get("postState").?);
    }
}

test "official: blockchain test smoke (self_destructing_initcode single)" {
    const alloc = std.testing.allocator;
    const default_path = "test/official/fixtures/blockchain_tests/cancun/eip6780_selfdestruct/selfdestruct/self_destructing_initcode.json";
    if (std.process.getEnvVarOwned(alloc, "OFFICIAL_JSON")) |p| {
        defer alloc.free(p);
        try runBlockchainCase(alloc, p);
    } else |_| {
        try runBlockchainCase(alloc, default_path);
    }
}
