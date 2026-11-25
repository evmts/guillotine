//! OP Stack execution host backed by Guillotine's EVM and in-memory `Database`.
//!
//! Implements the host contract documented in executor.zig: `executor.execute(&host, ...)`
//! runs deposits and user transactions with OP Stack fee rules, and this host runs the
//! EVM frame (`Evm.call`) against `database`.
//!
//! Module layout: this file is the root of its own test artifact
//! (`layer2-evm-host-tests`, run by `zig build test-layer2`). It imports only `std`,
//! `voltaire`, and `evm`, and reaches the layer 2 code through `evm.layer2`, because the
//! `evm` module already owns src/layer2/mod.zig and a file may belong to one module only.
//!
//! What the EVM supports, and what this host refuses (fail closed, never diverge):
//!
//! | Concern                         | Handling                                                    |
//! |---------------------------------|-------------------------------------------------------------|
//! | Ethereum fork per OpSpecId      | one comptime `Evm` per fork (MERGE, SHANGHAI, CANCUN)       |
//! | OP precompile overrides (Fjord+:| `configure` returns error.PrecompileOverridesUnsupported:    |
//! | P256VERIFY, BN254/BLS limits)   | `Evm` dispatches precompiles by its comptime fork and       |
//! |                                 | ignores `EvmConfig.precompile_overrides` (src/evm.zig       |
//! |                                 | `executePrecompileInline`), so nested calls would diverge   |
//! | Bedrock                         | error.UnsupportedSpec (Base starts at Regolith)             |
//! | Fees                            | settled by the executor; the EVM's own L1-style gas charge  |
//! |                                 | is pre-funded and reversed exactly (see `runFrame`)         |
//! | Block system calls (4788, 2935) | disabled here; they belong to block processing              |
//!
//! Known inherited EVM behaviour: `Evm.call` charges gas after execution instead of
//! debiting gas_limit * gas_price up front, so during execution BALANCE(origin) reads
//! the balance before the gas debit (the same as an L1 transaction on this EVM).
const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");

const layer2 = evm.layer2;
const executor = layer2.executor;
const deposits = layer2.optimism.deposit;
const precompiles = layer2.optimism.precompiles;
const OpSpecId = layer2.OpSpecId;
const Address = primitives.Address;
const Database = evm.Database;
const Account = evm.Account;
const Hardfork = evm.Hardfork;

/// Block fields the EVM reads (opcodes BLOCKHASH..BLOBBASEFEE).
pub const Block = struct {
    /// CHAINID. A u64: Base Sepolia is 84532.
    chain_id: u64,
    number: u64,
    timestamp: u64,
    gas_limit: u64,
    coinbase: Address,
    base_fee: u64,
    prev_randao: [32]u8 = @as([32]u8, @splat(0)),
    blob_base_fee: u64 = 0,
    /// Hashes of recent ancestors, newest first (see BlockInfo.block_hashes).
    block_hashes: []const [32]u8 = &.{},
};

/// Largest init code `CallParams.validate` accepts (EIP-3860 size), on every fork.
const EVM_MAX_INITCODE: usize = 49_152;
/// Largest calldata `CallParams.validate` accepts. Not a protocol limit.
const EVM_MAX_INPUT: usize = 4 * 1024 * 1024;
/// Frame gas capacity: `block_gas_limit` sizes `Frame.GasType` (i64 above 2^31-1).
const EVM_GAS_CAPACITY: u64 = std.math.maxInt(u32);

fn evmConfig(comptime hardfork: Hardfork) evm.EvmConfig {
    return .{
        .eips = .{ .hardfork = hardfork },
        .block_gas_limit = EVM_GAS_CAPACITY,
        .enable_beacon_roots = false,
        .enable_historical_block_hashes = false,
        .enable_validator_deposits = false,
        .enable_validator_withdrawals = false,
    };
}

pub const Host = struct {
    allocator: std.mem.Allocator,
    database: *Database,
    block: Block,
    spec: ?OpSpecId = null,
    saved: std.ArrayList(Saved) = .empty,

    const Accounts = @FieldType(Database, "accounts");
    const Storage = @FieldType(Database, "storage");
    const Saved = struct { accounts: Accounts, storage: Storage };

    /// Opaque checkpoint handle. Valid until it or an older checkpoint is committed
    /// or rolled back.
    pub const Token = struct { index: usize };

    pub fn init(allocator: std.mem.Allocator, database: *Database, block: Block) Host {
        return .{ .allocator = allocator, .database = database, .block = block };
    }

    pub fn deinit(self: *Host) void {
        for (self.saved.items) |*saved| {
            saved.accounts.deinit();
            saved.storage.deinit();
        }
        self.saved.deinit(self.allocator);
    }

    /// Select the spec for the next transaction. Fails closed when the EVM cannot
    /// apply the spec's precompile set in every frame.
    pub fn configure(self: *Host, spec: OpSpecId) !void {
        if (spec == .BEDROCK) return error.UnsupportedSpec;
        const overrides = switch (spec) {
            inline else => |fork| precompiles.entries(fork).len,
        };
        if (overrides != 0) return error.PrecompileOverridesUnsupported;
        switch (spec.toEthHardfork()) {
            .MERGE, .SHANGHAI, .CANCUN => {},
            else => return error.UnsupportedSpec,
        }
        self.spec = spec;
    }

    /// Copy accounts and storage so `rollback` can restore them without allocating.
    pub fn checkpoint(self: *Host) !Token {
        const db = self.database;
        if (db.snapshots.items.len != 0 or db.tx_cache != null or db.overlay_active) return error.DatabaseBusy;
        var accounts = try db.accounts.clone();
        errdefer accounts.deinit();
        var storage = try db.storage.clone();
        errdefer storage.deinit();
        try self.saved.append(self.allocator, .{ .accounts = accounts, .storage = storage });
        return .{ .index = self.saved.items.len - 1 };
    }

    /// Restore the state saved by `token` and drop it and every newer checkpoint.
    /// Code added since stays in the content-addressed code store, unreferenced.
    pub fn rollback(self: *Host, token: Token) void {
        if (token.index >= self.saved.items.len) {
            evm.log.err("layer2 host: rollback of a released checkpoint {d}", .{token.index});
            return;
        }
        const db = self.database;
        const saved = self.saved.items[token.index];
        db.accounts.deinit();
        db.storage.deinit();
        db.accounts = saved.accounts;
        db.storage = saved.storage;
        db.clear_transient_storage();
        for (self.saved.items[token.index + 1 ..]) |*newer| {
            newer.accounts.deinit();
            newer.storage.deinit();
        }
        self.saved.shrinkRetainingCapacity(token.index);
    }

    /// Keep the current state and drop `token` and every newer checkpoint.
    pub fn commit(self: *Host, token: Token) void {
        if (token.index >= self.saved.items.len) {
            evm.log.err("layer2 host: commit of a released checkpoint {d}", .{token.index});
            return;
        }
        for (self.saved.items[token.index..]) |*saved| {
            saved.accounts.deinit();
            saved.storage.deinit();
        }
        self.saved.shrinkRetainingCapacity(token.index);
    }

    pub fn caller(self: *Host, address: Address) !deposits.CallerState {
        const account = (try self.database.get_account(address.bytes)) orelse Account.zero();
        return .{ .balance = account.balance, .nonce = account.nonce };
    }

    pub fn setCaller(self: *Host, address: Address, state: deposits.CallerState) !void {
        var account = (try self.database.get_account(address.bytes)) orelse Account.zero();
        account.balance = state.balance;
        account.nonce = state.nonce;
        try self.database.set_account(address.bytes, account);
    }

    /// Add `amount` wei. A zero credit leaves no account behind (EIP-161 removes a
    /// touched empty account at the end of the transaction).
    pub fn credit(self: *Host, address: Address, amount: u256) !void {
        if (amount == 0) return;
        var account = (try self.database.get_account(address.bytes)) orelse Account.zero();
        account.balance = std.math.add(u256, account.balance, amount) catch return error.BalanceOverflow;
        try self.database.set_account(address.bytes, account);
    }

    fn debit(self: *Host, address: Address, amount: u256) !void {
        if (amount == 0) return;
        var account = (try self.database.get_account(address.bytes)) orelse return error.DebitFromMissingAccount;
        account.balance = std.math.sub(u256, account.balance, amount) catch return error.DebitExceedsBalance;
        try self.database.set_account(address.bytes, account);
    }

    pub fn executeFrame(self: *Host, tx: executor.Transaction) !executor.Result {
        const spec = self.spec orelse return error.NotConfigured;
        switch (spec.toEthHardfork()) {
            .MERGE => return self.runFrame(.MERGE, tx),
            .SHANGHAI => return self.runFrame(.SHANGHAI, tx),
            .CANCUN => return self.runFrame(.CANCUN, tx),
            else => return error.UnsupportedSpec,
        }
    }

    fn runFrame(self: *Host, comptime hardfork: Hardfork, tx: executor.Transaction) !executor.Result {
        const Evm = evm.Evm(evmConfig(hardfork));
        const eips = evm.Eips{ .hardfork = hardfork };
        const is_deposit = tx.deposit != null;
        const is_create = !tx.is_call;
        const price = try executor.gasPrice(tx);
        if (tx.base_fee != self.block.base_fee) return error.BaseFeeMismatch;
        if (tx.gas_limit > EVM_GAS_CAPACITY) return error.GasLimitExceedsEvmCapacity;
        // Limits `CallParams.validate` applies that are not protocol rules on this fork.
        if (tx.is_call and tx.input.len > EVM_MAX_INPUT) return error.InputExceedsEvmLimit;
        if (is_create and tx.input.len > EVM_MAX_INITCODE and !hardfork.isAtLeast(.SHANGHAI)) return error.InitCodeExceedsEvmLimit;

        var origin = (try self.database.get_account(tx.sender.bytes)) orelse Account.zero();
        // Transaction validity the EVM reports only as a failed call. For a user
        // transaction it is a rejection (revm `InvalidTransaction`); for a deposit it is
        // a failed deposit (op-revm `catch_error_failed_deposit`): halt, all gas used.
        const tokens = eips.tokens_in_calldata(tx.input);
        const intrinsic = eips.intrinsic_gas_cost(is_create) + eips.calldata_gas_cost(tokens, is_create, tx.input.len);
        const below_intrinsic = tx.gas_limit < intrinsic or tx.gas_limit < eips.floor_gas_cost(tokens);
        const initcode_too_large = is_create and tx.input.len > EVM_MAX_INITCODE;
        if (is_deposit) {
            if (below_intrinsic or initcode_too_large or tx.value > origin.balance) {
                return .{ .outcome = .halt, .gas_used = tx.gas_limit };
            }
        } else {
            if (below_intrinsic) return error.IntrinsicGasTooLow;
            if (initcode_too_large) return error.CreateInitCodeSizeLimit;
            // EIP-3607 (revm `RejectCallerWithCode`): a sender with code cannot originate.
            if (!std.mem.allEqual(u8, &origin.code_hash, 0) and !std.mem.eql(u8, &origin.code_hash, &primitives.EMPTY_CODE_HASH)) return error.SenderHasCode;
        }

        // `Evm.call` increments the origin nonce. The executor already did so for a CALL
        // deposit, so undo that one increment first.
        if (is_deposit and tx.is_call) {
            origin.nonce = std.math.sub(u64, origin.nonce, 1) catch return error.DepositNonceNotBumped;
        }
        if (origin.nonce == std.math.maxInt(u64)) return error.NonceOverflow;
        const nonce_before = origin.nonce;

        // `Evm.call` checks balance >= gas_limit * price + value and, after execution,
        // debits gas_used * price from the origin and credits the coinbase with
        // gas_used * (price - base_fee). The executor already debited gas_limit * price,
        // so fund the EVM's check with it here and reverse both transfers afterwards.
        const gas_money = std.math.mul(u256, tx.gas_limit, price) catch return error.GasCostOverflow;
        origin.balance = std.math.add(u256, origin.balance, gas_money) catch return error.BalanceOverflow;
        try self.database.set_account(tx.sender.bytes, origin);

        const block_info = evm.BlockInfo{
            .chain_id = self.block.chain_id,
            .number = self.block.number,
            .timestamp = self.block.timestamp,
            .difficulty = 0,
            .gas_limit = self.block.gas_limit,
            .coinbase = self.block.coinbase,
            .base_fee = self.block.base_fee,
            .prev_randao = self.block.prev_randao,
            .blob_base_fee = self.block.blob_base_fee,
            .block_hashes = self.block.block_hashes,
        };
        const context = evm.TransactionContext{
            .gas_limit = tx.gas_limit,
            .coinbase = self.block.coinbase,
            // Not read during execution: CHAINID reads BlockInfo.chain_id (u64). Set only
            // when the field is wide enough for every chain ID.
            .chain_id = if (comptime std.math.maxInt(@FieldType(evm.TransactionContext, "chain_id")) >= std.math.maxInt(u64)) self.block.chain_id else 0,
        };
        var instance = try Evm.init(self.allocator, self.database, block_info, context, price, tx.sender);
        defer instance.deinit();
        const params: evm.CallParams = if (tx.to) |to|
            .{ .call = .{ .caller = tx.sender, .to = to, .value = tx.value, .input = tx.input, .gas = tx.gas_limit } }
        else
            .{ .create = .{ .caller = tx.sender, .value = tx.value, .init_code = tx.input, .gas = tx.gas_limit } };
        var result = instance.call(params);
        defer result.deinit(self.allocator);

        // Every transaction that reaches execution increments the origin nonce first.
        // An unchanged nonce means `Evm.call` returned before executing (an internal
        // failure it reports as a failed call), so the frame result is not trustworthy.
        const after = (try self.database.get_account(tx.sender.bytes)) orelse return error.EvmAbortedTransaction;
        if (after.nonce == nonce_before) return error.EvmAbortedTransaction;
        if (result.gas_left > tx.gas_limit) return error.GasAccountingMismatch;
        const gas_used = tx.gas_limit - result.gas_left;

        const used_cost = @as(u256, gas_used) * price;
        try self.debit(tx.sender, gas_money - used_cost);
        if (price > self.block.base_fee) try self.debit(self.block.coinbase, @as(u256, gas_used) * (price - self.block.base_fee));

        const outcome: deposits.Outcome = if (result.success) .success else if (result.gas_left > 0) .revert else .halt;
        return .{ .outcome = outcome, .gas_used = gas_used };
    }
};

// ============================================================================
// End-to-end tests: executor.execute / executeBase over the real EVM.
// ============================================================================

const testing = std.testing;
const constants = layer2.optimism.constants;
const hardforks = layer2.base.hardforks;
const L1BlockInfo = layer2.optimism.L1BlockInfo;
const DepositTransactionParts = layer2.optimism.DepositTransactionParts;

const ETHER: u256 = 1_000_000_000_000_000_000;
const GWEI: u256 = 1_000_000_000;

test "Base Mainnet and Sepolia deposit: mint, value transfer, CALL, CHAINID as u64" {
    const cases = [_]struct { chain_id: u64, timestamp: u64 }{
        .{ .chain_id = 8453, .timestamp = hardforks.MAINNET.ecotone },
        .{ .chain_id = 84532, .timestamp = hardforks.SEPOLIA.ecotone },
    };
    for (cases) |case| {
        var db = Database.init(testing.allocator);
        defer db.deinit();
        // CALLVALUE PUSH1 0 SSTORE CHAINID PUSH1 1 SSTORE STOP
        const code = [_]u8{ 0x34, 0x60, 0x00, 0x55, 0x46, 0x60, 0x01, 0x55, 0x00 };
        const target = Address.fromU256(0xC0DE);
        try db.set_account(target.bytes, .{ .balance = 0, .code_hash = try db.set_code(&code), .storage_root = @as([32]u8, @splat(0)), .nonce = 1 });
        var host = Host.init(testing.allocator, &db, .{ .chain_id = case.chain_id, .number = 1, .timestamp = case.timestamp, .gas_limit = 30_000_000, .coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS, .base_fee = 1_000_000 });
        defer host.deinit();

        const sender = Address.fromU256(0xA11CE);
        const tx = executor.Transaction{
            .sender = sender,
            .envelope = &.{ 0x7e, 0x01 },
            .gas_limit = 100_000,
            .base_fee = 1_000_000,
            .value = ETHER / 10,
            .to = target,
            .deposit = DepositTransactionParts.deposit(@as([32]u8, @splat(7)), @intCast(ETHER), false),
        };
        const result = try executor.executeBase(&host, L1BlockInfo.empty(), case.chain_id, case.timestamp, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
        try testing.expectEqual(deposits.Outcome.success, result.outcome);
        // 21000 + CALLVALUE 2 + PUSH1 3 + SSTORE 22100 + CHAINID 2 + PUSH1 3 + SSTORE 22100.
        try testing.expectEqual(@as(u64, 65_210), result.gas_used);
        try testing.expectEqual(ETHER - ETHER / 10, try db.get_balance(sender.bytes));
        try testing.expectEqual(@as(u64, 1), try db.get_nonce(sender.bytes));
        try testing.expectEqual(ETHER / 10, try db.get_balance(target.bytes));
        try testing.expectEqual(ETHER / 10, try db.get_storage(target.bytes, 0));
        try testing.expectEqual(@as(u256, case.chain_id), try db.get_storage(target.bytes, 1));
        // Deposits pay no fees.
        for ([_]Address{ constants.SEQUENCER_FEE_VAULT_ADDRESS, constants.BASE_FEE_VAULT_ADDRESS, constants.L1_FEE_VAULT_ADDRESS, constants.OPERATOR_FEE_VAULT_ADDRESS }) |vault| {
            try testing.expect(!db.account_exists(vault.bytes));
        }
    }
}

test "deposit that halts is a failed deposit: mint and nonce kept, frame effects and value discarded" {
    var db = Database.init(testing.allocator);
    defer db.deinit();
    // PUSH1 1 PUSH1 0 SSTORE INVALID
    const code = [_]u8{ 0x60, 0x01, 0x60, 0x00, 0x55, 0xfe };
    const target = Address.fromU256(0xBAD);
    try db.set_account(target.bytes, .{ .balance = 0, .code_hash = try db.set_code(&code), .storage_root = @as([32]u8, @splat(0)), .nonce = 1 });
    const sender = Address.fromU256(0xA11CE);
    try db.set_account(sender.bytes, .{ .balance = 5, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 3 });
    var host = Host.init(testing.allocator, &db, .{ .chain_id = 8453, .number = 1, .timestamp = hardforks.MAINNET.ecotone, .gas_limit = 30_000_000, .coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS, .base_fee = 7 });
    defer host.deinit();
    const tx = executor.Transaction{
        .sender = sender,
        .envelope = &.{0x7e},
        .gas_limit = 80_000,
        .base_fee = 7,
        .value = 1_000,
        .to = target,
        .deposit = DepositTransactionParts.deposit(@as([32]u8, @splat(8)), 2_000, false),
    };
    const result = try executor.executeBase(&host, L1BlockInfo.empty(), 8453, hardforks.MAINNET.ecotone, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
    try testing.expectEqual(deposits.Outcome.halt, result.outcome);
    try testing.expectEqual(@as(u64, 80_000), result.gas_used);
    try testing.expectEqual(@as(u256, 2_005), try db.get_balance(sender.bytes));
    try testing.expectEqual(@as(u64, 4), try db.get_nonce(sender.bytes));
    try testing.expectEqual(@as(u256, 0), try db.get_balance(target.bytes));
    try testing.expectEqual(@as(u256, 0), try db.get_storage(target.bytes, 0));

    // A deposit below intrinsic gas is also a failed deposit, without running the EVM.
    var short = tx;
    short.gas_limit = 20_000;
    const failed = try executor.executeBase(&host, L1BlockInfo.empty(), 8453, hardforks.MAINNET.ecotone, short, constants.SEQUENCER_FEE_VAULT_ADDRESS);
    try testing.expectEqual(@as(u64, 20_000), failed.gas_used);
    try testing.expectEqual(@as(u256, 4_005), try db.get_balance(sender.bytes));
    try testing.expectEqual(@as(u64, 5), try db.get_nonce(sender.bytes));
}

test "EIP-1559 user transaction: L1 data fee and vault routing with exact balances" {
    const cases = [_]struct { chain_id: u64, timestamp: u64 }{
        .{ .chain_id = 8453, .timestamp = hardforks.MAINNET.ecotone },
        .{ .chain_id = 84532, .timestamp = hardforks.SEPOLIA.ecotone },
    };
    for (cases) |case| {
        var db = Database.init(testing.allocator);
        defer db.deinit();
        // GASPRICE PUSH1 0 SSTORE STOP
        const code = [_]u8{ 0x3a, 0x60, 0x00, 0x55, 0x00 };
        const target = Address.fromU256(0xC0DE);
        try db.set_account(target.bytes, .{ .balance = 0, .code_hash = try db.set_code(&code), .storage_root = @as([32]u8, @splat(0)), .nonce = 1 });
        const sender = Address.fromU256(0xA11CE);
        const funded = ETHER;
        try db.set_account(sender.bytes, .{ .balance = funded, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 9 });
        const coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS;
        const base_fee: u64 = 1_000_000_000;
        var host = Host.init(testing.allocator, &db, .{ .chain_id = case.chain_id, .number = 12, .timestamp = case.timestamp, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = base_fee });
        defer host.deinit();

        var info = L1BlockInfo.empty();
        info.l1_base_fee = 30 * GWEI;
        info.l1_base_fee_scalar = 1_368;
        info.l1_blob_base_fee = 1;
        info.l1_blob_base_fee_scalar = 810_949;
        const envelope = [_]u8{0x02} ++ @as([100]u8, @splat(0x5a));
        var cost_info = info;
        const l1_fee = cost_info.calculateTxL1Cost(&envelope, .ECOTONE);
        try testing.expect(l1_fee > 0);

        const tx = executor.Transaction{
            .sender = sender,
            .envelope = &envelope,
            .gas_limit = 60_000,
            .fee = .{ .dynamic = .{ .max_fee_per_gas = 5 * GWEI, .max_priority_fee_per_gas = GWEI / 2 } },
            .base_fee = base_fee,
            .value = 12_345,
            .nonce = 9,
            .to = target,
        };
        const result = try executor.executeBase(&host, info, case.chain_id, case.timestamp, tx, coinbase);
        try testing.expectEqual(deposits.Outcome.success, result.outcome);
        // 21000 + GASPRICE 2 + PUSH1 3 + SSTORE 22100.
        const gas_used: u256 = 43_105;
        try testing.expectEqual(@as(u64, 43_105), result.gas_used);
        const price = base_fee + GWEI / 2;
        try testing.expectEqual(price, try db.get_storage(target.bytes, 0));
        try testing.expectEqual(funded - 12_345 - gas_used * price - l1_fee, try db.get_balance(sender.bytes));
        try testing.expectEqual(@as(u64, 10), try db.get_nonce(sender.bytes));
        try testing.expectEqual(@as(u256, 12_345), try db.get_balance(target.bytes));
        try testing.expectEqual(gas_used * (GWEI / 2), try db.get_balance(coinbase.bytes));
        try testing.expectEqual(gas_used * base_fee, try db.get_balance(constants.BASE_FEE_VAULT_ADDRESS.bytes));
        try testing.expectEqual(l1_fee, try db.get_balance(constants.L1_FEE_VAULT_ADDRESS.bytes));
        // Ecotone has no operator fee: no OperatorFeeVault account is created.
        try testing.expect(!db.account_exists(constants.OPERATOR_FEE_VAULT_ADDRESS.bytes));
    }
}

test "user transaction rejections leave state untouched" {
    var db = Database.init(testing.allocator);
    defer db.deinit();
    const sender = Address.fromU256(0xA11CE);
    try db.set_account(sender.bytes, .{ .balance = ETHER, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 2 });
    var host = Host.init(testing.allocator, &db, .{ .chain_id = 8453, .number = 1, .timestamp = hardforks.MAINNET.canyon, .gas_limit = 30_000_000, .coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS, .base_fee = 100 });
    defer host.deinit();
    var tx = executor.Transaction{ .sender = sender, .envelope = &.{ 0x01, 0x01 }, .gas_limit = 21_000, .fee = .{ .legacy = 100 }, .base_fee = 100, .nonce = 1, .to = Address.fromU256(0xB0B) };
    try testing.expectError(error.NonceTooLow, executor.executeBase(&host, L1BlockInfo.empty(), 8453, hardforks.MAINNET.canyon, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    tx.nonce = 2;
    tx.gas_limit = 20_999;
    try testing.expectError(error.IntrinsicGasTooLow, executor.executeBase(&host, L1BlockInfo.empty(), 8453, hardforks.MAINNET.canyon, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    tx.gas_limit = 21_000;
    tx.value = ETHER;
    try testing.expectError(error.InsufficientBalance, executor.executeBase(&host, L1BlockInfo.empty(), 8453, hardforks.MAINNET.canyon, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    try testing.expectEqual(ETHER, try db.get_balance(sender.bytes));
    try testing.expectEqual(@as(u64, 2), try db.get_nonce(sender.bytes));
    try testing.expect(!db.account_exists(constants.SEQUENCER_FEE_VAULT_ADDRESS.bytes));
    try testing.expectEqual(@as(usize, 0), host.saved.items.len);

    // A plain transfer then succeeds and pays exactly 21000 gas.
    tx.value = 1;
    const result = try executor.executeBase(&host, L1BlockInfo.empty(), 8453, hardforks.MAINNET.canyon, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
    try testing.expectEqual(@as(u64, 21_000), result.gas_used);
    try testing.expectEqual(ETHER - 1 - 21_000 * 100, try db.get_balance(sender.bytes));
    try testing.expectEqual(@as(u256, 21_000 * 100), try db.get_balance(constants.BASE_FEE_VAULT_ADDRESS.bytes));
    try testing.expectEqual(@as(u64, 3), try db.get_nonce(sender.bytes));
}

test "CREATE user transaction increments the sender nonce once" {
    var db = Database.init(testing.allocator);
    defer db.deinit();
    const sender = Address.fromU256(0xA11CE);
    try db.set_account(sender.bytes, .{ .balance = ETHER, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 0 });
    var host = Host.init(testing.allocator, &db, .{ .chain_id = 8453, .number = 1, .timestamp = hardforks.MAINNET.ecotone, .gas_limit = 30_000_000, .coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS, .base_fee = 0 });
    defer host.deinit();
    // PUSH1 0 PUSH1 0 RETURN: deploys empty code.
    const tx = executor.Transaction{ .sender = sender, .envelope = &.{ 0x01, 0x02 }, .gas_limit = 100_000, .fee = .{ .legacy = 0 }, .base_fee = 0, .is_call = false, .input = &.{ 0x60, 0x00, 0x60, 0x00, 0xf3 } };
    const result = try executor.executeBase(&host, L1BlockInfo.empty(), 8453, hardforks.MAINNET.ecotone, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
    try testing.expectEqual(deposits.Outcome.success, result.outcome);
    try testing.expectEqual(@as(u64, 1), try db.get_nonce(sender.bytes));
}

test "Granite and Jovian BN254 pairing limits: host refuses specs it cannot enforce" {
    // The EVM ignores OP precompile overrides, so a Granite+ BN254 pairing call above
    // 112,687 (Granite) or 81,984 (Jovian) bytes would succeed instead of halting.
    // The host must refuse those specs rather than execute them with L1 precompiles.
    try testing.expectEqual(@as(usize, 112_687), precompiles.BN254_PAIRING_MAX_INPUT_GRANITE);
    try testing.expectEqual(@as(usize, 81_984), precompiles.BN254_PAIRING_MAX_INPUT_JOVIAN);
    for ([_]u64{ 8453, 84532 }) |chain_id| {
        const schedule = layer2.base.BaseChain.fromChainId(chain_id).?.schedule();
        var db = Database.init(testing.allocator);
        defer db.deinit();
        const sender = Address.fromU256(0xA11CE);
        try db.set_account(sender.bytes, .{ .balance = ETHER, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 0 });
        var host = Host.init(testing.allocator, &db, .{ .chain_id = chain_id, .number = 1, .timestamp = schedule.granite, .gas_limit = 30_000_000, .coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS, .base_fee = 0 });
        defer host.deinit();
        const input: [precompiles.BN254_PAIRING_MAX_INPUT_JOVIAN + 192]u8 = @splat(0);
        const tx = executor.Transaction{ .sender = sender, .envelope = &.{ 0x01, 0x03 }, .gas_limit = 10_000_000, .base_fee = 0, .to = precompiles.BN254_PAIRING_ADDRESS, .input = &input };
        for ([_]u64{ schedule.fjord, schedule.granite, schedule.holocene, schedule.isthmus, schedule.jovian }) |timestamp| {
            try testing.expectError(error.PrecompileOverridesUnsupported, executor.executeBase(&host, L1BlockInfo.empty(), chain_id, timestamp, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
        }
        try testing.expectEqual(ETHER, try db.get_balance(sender.bytes));
        try testing.expectEqual(@as(u64, 0), try db.get_nonce(sender.bytes));
    }
    for (OpSpecId.ALL) |spec| {
        var db = Database.init(testing.allocator);
        defer db.deinit();
        var host = Host.init(testing.allocator, &db, .{ .chain_id = 8453, .number = 1, .timestamp = 0, .gas_limit = 30_000_000, .coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS, .base_fee = 0 });
        defer host.deinit();
        switch (spec) {
            .BEDROCK => try testing.expectError(error.UnsupportedSpec, host.configure(spec)),
            .REGOLITH, .CANYON, .ECOTONE => try host.configure(spec),
            .FJORD, .GRANITE, .HOLOCENE, .ISTHMUS, .JOVIAN => try testing.expectError(error.PrecompileOverridesUnsupported, host.configure(spec)),
        }
    }
}

test "checkpoint rollback restores accounts and storage; commit keeps them" {
    var db = Database.init(testing.allocator);
    defer db.deinit();
    const address = Address.fromU256(0x1234);
    try db.set_account(address.bytes, .{ .balance = 10, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 1 });
    try db.set_storage(address.bytes, 5, 50);
    var host = Host.init(testing.allocator, &db, .{ .chain_id = 8453, .number = 1, .timestamp = 0, .gas_limit = 30_000_000, .coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS, .base_fee = 0 });
    defer host.deinit();

    const outer = try host.checkpoint();
    try host.credit(address, 5);
    try db.set_storage(address.bytes, 5, 51);
    const inner = try host.checkpoint();
    try host.setCaller(address, .{ .balance = 1, .nonce = 9 });
    host.commit(inner);
    try testing.expectEqual(@as(u64, 9), try db.get_nonce(address.bytes));
    host.rollback(outer);
    try testing.expectEqual(@as(u256, 10), try db.get_balance(address.bytes));
    try testing.expectEqual(@as(u64, 1), try db.get_nonce(address.bytes));
    try testing.expectEqual(@as(u256, 50), try db.get_storage(address.bytes, 5));
    try testing.expectEqual(@as(usize, 0), host.saved.items.len);

    const kept = try host.checkpoint();
    try host.credit(address, 5);
    host.commit(kept);
    try testing.expectEqual(@as(u256, 15), try db.get_balance(address.bytes));
    try testing.expectError(error.BalanceOverflow, host.credit(address, std.math.maxInt(u256)));
}
