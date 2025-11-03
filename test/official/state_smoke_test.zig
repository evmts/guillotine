const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");

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
    // Accept empty string and "0x" as empty bytes
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
    // Map fixture fork names to Hardfork enum
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

        // Storage
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

    // Update sender balance and nonce
    var sender_acc = (try db.get_account(sender.bytes)) orelse Account.zero();
    if (sender_acc.balance < total_fee) return error.InsufficientBalance;
    sender_acc.balance -= total_fee;
    sender_acc.nonce += 1;
    try db.set_account(sender.bytes, sender_acc);

    // Credit coinbase with tip
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

fn runSingleStateCase(allocator: std.mem.Allocator, json_path: []const u8) !void {
    var cwd = std.fs.cwd();
    const data = try cwd.readFileAlloc(allocator, json_path, 20 * 1024 * 1024);
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidFixture;
    const root = parsed.value.object;

    // Pick the first test case in this file
    var case_it = root.iterator();
    const first = case_it.next() orelse return error.InvalidFixture;
    if (first.value_ptr.* != .object) return error.InvalidFixture;
    const tc = first.value_ptr.*.object;

    // Choose fork: prefer Cancun if available, otherwise first key in post
    const post_val = tc.get("post").?;
    if (post_val != .object) return error.InvalidFixture;
    const post_obj = post_val.object;
    var fork_name: []const u8 = undefined;
    if (post_obj.getPtr("Cancun")) |_| fork_name = "Cancun" else blk: {
        var pit = post_obj.iterator();
        const pfirst = pit.next() orelse return error.InvalidFixture;
        fork_name = pfirst.key_ptr.*;
        break :blk;
    }

    const fork_val_ptr = post_obj.get(fork_name).?;
    if (fork_val_ptr != .array) return error.InvalidFixture;
    const fork_arr = fork_val_ptr.array;
    if (fork_arr.items.len == 0) return error.InvalidFixture;
    const post_item = fork_arr.items[0];
    if (post_item != .object) return error.InvalidFixture;
    const post_entry = post_item.object; // first combination

    // Build env
    const env_ptr = tc.get("env").?;
    if (env_ptr != .object) return error.InvalidFixture;
    const env = env_ptr.object;
    const coinbase = try primitives.Address.fromHex(env.get("currentCoinbase").?.string);
    const gas_limit = try parseU64Hex(env.get("currentGasLimit").?.string);
    const number = try parseU64Hex(env.get("currentNumber").?.string);
    const timestamp = try parseU64Hex(env.get("currentTimestamp").?.string);
    const difficulty = try parseU256Hex(env.get("currentDifficulty").?.string);
    const base_fee = try parseU256Hex(env.get("currentBaseFee").?.string);
    const prev_randao = try parseHash32(env.get("currentRandom").?.string);

    // Parse EIP-4844 blob gas fields if present (Cancun+)
    var blob_base_fee: u256 = 0;
    if (env.get("currentExcessBlobGas")) |excess_blob_gas_field| {
        const excess_blob_gas = try parseU64Hex(excess_blob_gas_field.string);
        // Calculate blob base fee from excess blob gas using EIP-4844 formula
        const Blob = @import("primitives").Blob;
        blob_base_fee = Blob.calculate_blob_gas_price(excess_blob_gas);
    }

    // Transaction
    const tx_ptr = tc.get("transaction").?;
    if (tx_ptr != .object) return error.InvalidFixture;
    const tx = tx_ptr.object;
    const sender = try primitives.Address.fromHex(tx.get("sender").?.string);
    const to_field = tx.get("to").?.string;
    const is_create = to_field.len == 0;
    var to_addr: primitives.Address = primitives.ZERO_ADDRESS;
    if (!is_create) to_addr = try primitives.Address.fromHex(to_field);
    const gas_price = try parseU256Hex(tx.get("gasPrice").?.string);
    const gas_lim = try parseU64Hex(tx.get("gasLimit").?.array.items[0].string);
    const value = try parseU256Hex(tx.get("value").?.array.items[0].string);
    const data_bytes = try parseBytesHex(allocator, tx.get("data").?.array.items[0].string);
    defer allocator.free(data_bytes);

    // Setup DB and pre-state
    var db = Database.init(allocator);
    defer db.deinit();
    try setPreState(allocator, &db, tc.get("pre").?);

    // Block and tx context
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = number,
        .timestamp = timestamp,
        .difficulty = difficulty,
        .gas_limit = gas_limit,
        .coinbase = coinbase,
        .base_fee = base_fee,
        .prev_randao = prev_randao,
        .blob_base_fee = blob_base_fee,
        .blob_versioned_hashes = &.{},
    };

    const tx_context = TransactionContext{
        .gas_limit = gas_lim,
        .coinbase = coinbase,
        .chain_id = 1,
        .blob_versioned_hashes = &.{},
        .blob_base_fee = blob_base_fee,
    };

    var vm = try DefaultEvm.init(allocator, &db, block_info, tx_context, gas_price, sender);
    defer vm.deinit();

    // Execute
    var res = vm.call(if (is_create)
        DefaultEvm.CallParams{ .create = .{ .caller = sender, .value = value, .init_code = data_bytes, .gas = gas_lim } }
    else
        DefaultEvm.CallParams{ .call = .{ .caller = sender, .to = to_addr, .value = value, .input = data_bytes, .gas = gas_lim } }
    );
    defer res.deinit(allocator);

    // Gas accounting and miner tip
    const gas_used: u64 = gas_lim - res.gas_left;
    try applyGasAccounting(&db, sender, coinbase, gas_used, gas_price, base_fee);

    // Verify post state (strict mode only). By default we only execute successfully.
    if (isStrict()) {
        try expectPostState(&db, post_entry.get("state").?);
    }
}

test "official: state test smoke (create_opcode_initcode first case)" {
    const alloc = std.testing.allocator;
    // Allow overriding the JSON path via OFFICIAL_JSON (for local experimentation)
    const default_path = "test/official/fixtures/state_tests/shanghai/eip3860_initcode/initcode/create_opcode_initcode.json";
    if (std.process.getEnvVarOwned(alloc, "OFFICIAL_JSON")) |p| {
        defer alloc.free(p);
        try runSingleStateCase(alloc, p);
    } else |_| {
        try runSingleStateCase(alloc, default_path);
    }
}
