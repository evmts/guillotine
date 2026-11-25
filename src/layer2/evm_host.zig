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
//! | Concern                         | Handling                                                    |
//! |---------------------------------|-------------------------------------------------------------|
//! | Specs                           | Bedrock through Jovian. One comptime `Evm` per `OpSpecId`:  |
//! |                                 | specs that share an Ethereum fork (Fjord and Granite on     |
//! |                                 | CANCUN, Isthmus and Jovian on PRAGUE) differ in precompiles |
//! | Ethereum fork                   | `spec.toEthHardfork()`: MERGE, SHANGHAI, CANCUN, PRAGUE     |
//! | OP precompiles (Fjord+:         | `optimism/precompiles.zig` `overrides(spec)` installed as   |
//! | P256VERIFY, BN254/BLS limits)   | `EvmConfig.precompile_overrides`; `Evm` consults them       |
//! |                                 | before its fork's own set in every frame, nested included   |
//! | Invalid deposit                 | `Result.invalid`: the executor includes a failed deposit    |
//! | Checkpoints                     | `Database` snapshots (O(1) to open, rollback costs the      |
//! |                                 | writes undone); refused over foreign snapshots              |
//! | Fees                            | settled by the executor; the EVM's own L1-style gas charge  |
//! |                                 | is pre-funded and reversed exactly (see `runFrame`)         |
//! | Block system calls (4788, 2935) | disabled here; they belong to block processing              |
//!
//! During execution BALANCE(origin) reads the balance after the executor's up-front
//! debit: `runFrame` pre-funds the EVM's own gas purchase with exactly that amount.
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
/// `PrecompileOverride` from src/evm_config.zig, the element type of
/// `EvmConfig.precompile_overrides`.
const PrecompileOverride = @typeInfo(@FieldType(evm.EvmConfig, "precompile_overrides")).pointer.child;

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

fn evmConfig(comptime spec: OpSpecId) evm.EvmConfig {
    return .{
        .eips = .{ .hardfork = spec.toEthHardfork() },
        .block_gas_limit = EVM_GAS_CAPACITY,
        .precompile_overrides = precompiles.overrides(PrecompileOverride, spec),
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
    /// Database snapshot IDs of the open checkpoints, oldest first. Checkpoint i is
    /// the database snapshot at depth i: no foreign snapshot sits below or between them.
    saved: std.ArrayList(u64) = .empty,

    /// Opaque checkpoint handle. Valid until it or an older checkpoint is committed
    /// or rolled back.
    pub const Token = struct { index: usize };

    pub fn init(allocator: std.mem.Allocator, database: *Database, block: Block) Host {
        return .{ .allocator = allocator, .database = database, .block = block };
    }

    /// Free the checkpoint list. Checkpoints still open stay open in `database`.
    pub fn deinit(self: *Host) void {
        self.saved.deinit(self.allocator);
    }

    /// Select the spec for the next transaction. Every OpSpecId has its own `Evm`
    /// instantiation with the spec's Ethereum fork and OP precompile overrides.
    pub fn configure(self: *Host, spec: OpSpecId) !void {
        self.spec = spec;
    }

    /// True when the database's open snapshots are exactly this host's checkpoints.
    fn ownsSnapshots(self: *const Host) bool {
        const open = self.database.snapshots.items;
        if (open.len != self.saved.items.len) return false;
        for (open, self.saved.items) |snapshot, id| {
            if (snapshot.id != id) return false;
        }
        return true;
    }

    /// Open a database snapshot: O(1), no copy of state. Refused while any snapshot
    /// other than this host's own is open, or a transaction cache or ephemeral view
    /// is active: a rollback here would undo, or be undone by, that work.
    pub fn checkpoint(self: *Host) !Token {
        const db = self.database;
        if (db.tx_cache != null or db.overlay_active or !self.ownsSnapshots()) return error.DatabaseBusy;
        try self.saved.ensureUnusedCapacity(self.allocator, 1);
        const id = try db.create_snapshot();
        self.saved.appendAssumeCapacity(id);
        return .{ .index = self.saved.items.len - 1 };
    }

    /// Restore the state saved by `token` and drop it and every newer checkpoint.
    /// Restores accounts, storage (with its non-zero slot counts), transient storage
    /// and code; never allocates.
    pub fn rollback(self: *Host, token: Token) void {
        if (token.index >= self.saved.items.len) {
            evm.log.err("layer2 host: rollback of a released checkpoint {d}", .{token.index});
            return;
        }
        if (!self.ownsSnapshots()) {
            evm.log.err("layer2 host: database snapshots changed under checkpoint {d}; not rolled back", .{token.index});
            return;
        }
        self.database.revert_to_depth(token.index);
        self.saved.shrinkRetainingCapacity(token.index);
    }

    /// Keep the current state and drop `token` and every newer checkpoint.
    pub fn commit(self: *Host, token: Token) void {
        if (token.index >= self.saved.items.len) {
            evm.log.err("layer2 host: commit of a released checkpoint {d}", .{token.index});
            return;
        }
        if (!self.ownsSnapshots()) {
            evm.log.err("layer2 host: database snapshots changed under checkpoint {d}; not committed", .{token.index});
            return;
        }
        // Newest first, so each commit closes the top snapshot. `ownsSnapshots` proved
        // every ID is open, so `commit_snapshot` (whose only error is an unknown ID)
        // succeeds.
        while (self.saved.items.len > token.index) {
            const id = self.saved.items[self.saved.items.len - 1];
            self.database.commit_snapshot(id) catch |err| {
                evm.log.err("layer2 host: commit of checkpoint {d} failed: {s}", .{ token.index, @errorName(err) });
                return;
            };
            self.saved.items.len -= 1;
        }
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
        switch (spec) {
            inline else => |comptime_spec| return self.runFrame(comptime_spec, tx),
        }
    }

    fn runFrame(self: *Host, comptime spec: OpSpecId, tx: executor.Transaction) !executor.Result {
        const hardfork = comptime spec.toEthHardfork();
        const Evm = evm.Evm(evmConfig(spec));
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
        // a failed deposit on every spec (op-revm `catch_error_failed_deposit`).
        const tokens = eips.tokens_in_calldata(tx.input);
        const intrinsic = eips.intrinsic_gas_cost(is_create) + eips.calldata_gas_cost(tokens, is_create, tx.input.len);
        const below_intrinsic = tx.gas_limit < intrinsic or tx.gas_limit < eips.floor_gas_cost(tokens);
        const initcode_too_large = is_create and tx.input.len > EVM_MAX_INITCODE;
        if (is_deposit) {
            if (below_intrinsic or initcode_too_large or tx.value > origin.balance) {
                return .{ .outcome = .halt, .gas_used = tx.gas_limit, .invalid = true };
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

        // `Evm.call` checks balance >= gas_limit * price + value, buys gas_limit * price
        // up front, buys back the unused gas after execution, and credits the coinbase
        // with gas_used * (price - base_fee). The executor already debited
        // gas_limit * price, so fund the EVM's purchase with it here and reverse the
        // net transfers afterwards.
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

test "Fjord P256VERIFY at 0x100: nested STATICCALL verifies the RIP-7212 vector; before Fjord 0x100 is empty" {
    // RIP-7212 reference vector (go-ethereum p256Verify.json "CallP256Verify").
    var input: [160]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, "4cee90eb86eaa050036147a12d49004b6b9c72bd725d39d4785011fe190f0b4d" ++
        "a73bd4903f0ce3b639bbbf6e8e80d16931ff4bcf5993d58468e8fb19086e8cac" ++
        "36dbcd03009df8c59286b162af3bd7fcc0450c9aa81be5d10d312af6c66b1d60" ++
        "4aebd3099c618202fcfe16ae7770b0c49ab5eadf74b754204a3bb6060e44eff3" ++
        "7618b065f9832de4ca6ca971a7a1adc826d0f7c00181a5fb2ddf79ae00b4e10e");
    // CALLDATACOPY(0x40, 0, CALLDATASIZE)
    // STATICCALL(GAS, 0x100, 0x40, CALLDATASIZE, 0, 32)
    // SSTORE(0, success) SSTORE(1, MLOAD(0)) SSTORE(2, RETURNDATASIZE) SSTORE(3, 0xff) STOP
    const code = [_]u8{
        0x36, 0x60, 0x00, 0x60, 0x40, 0x37,
        0x60, 0x20, 0x60, 0x00, 0x36, 0x60, 0x40, 0x61, 0x01, 0x00, 0x5a, 0xfa,
        0x60, 0x00, 0x55,
        0x60, 0x00, 0x51, 0x60, 0x01, 0x55,
        0x3d, 0x60, 0x02, 0x55,
        0x60, 0xff, 0x60, 0x03, 0x55,
        0x00,
    };
    const schedule = hardforks.MAINNET;
    const cases = [_]struct { timestamp: u64, spec: OpSpecId, verifies: bool }{
        .{ .timestamp = schedule.regolith, .spec = .REGOLITH, .verifies = false },
        .{ .timestamp = schedule.canyon, .spec = .CANYON, .verifies = false },
        .{ .timestamp = schedule.ecotone, .spec = .ECOTONE, .verifies = false },
        .{ .timestamp = schedule.fjord, .spec = .FJORD, .verifies = true },
        .{ .timestamp = schedule.granite, .spec = .GRANITE, .verifies = true },
        .{ .timestamp = schedule.holocene, .spec = .HOLOCENE, .verifies = true },
        .{ .timestamp = schedule.isthmus, .spec = .ISTHMUS, .verifies = true },
        .{ .timestamp = schedule.jovian, .spec = .JOVIAN, .verifies = true },
    };
    for (cases) |case| {
        try testing.expectEqual(case.spec, try schedule.specAt(case.timestamp));
        var db = Database.init(testing.allocator);
        defer db.deinit();
        const target = Address.fromU256(0xC0DE);
        try db.set_account(target.bytes, .{ .balance = 0, .code_hash = try db.set_code(&code), .storage_root = @as([32]u8, @splat(0)), .nonce = 1 });
        const sender = Address.fromU256(0xA11CE);
        try db.set_account(sender.bytes, .{ .balance = ETHER, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 0 });
        var host = Host.init(testing.allocator, &db, .{ .chain_id = 8453, .number = 1, .timestamp = case.timestamp, .gas_limit = 30_000_000, .coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS, .base_fee = 0 });
        defer host.deinit();
        var info = L1BlockInfo.empty();
        info.operator_fee_scalar = 0;
        info.operator_fee_constant = 0;
        const tx = executor.Transaction{ .sender = sender, .envelope = &.{ 0x01, 0x04 }, .gas_limit = 200_000, .base_fee = 0, .to = target, .input = &input };
        const result = try executor.executeBase(&host, info, 8453, case.timestamp, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
        try testing.expectEqual(deposits.Outcome.success, result.outcome);
        try testing.expectEqual(@as(u256, 0xff), try db.get_storage(target.bytes, 3));
        // A call to a precompile and a call to an empty account both succeed.
        try testing.expectEqual(@as(u256, 1), try db.get_storage(target.bytes, 0));
        try testing.expectEqual(@as(u256, if (case.verifies) 1 else 0), try db.get_storage(target.bytes, 1));
        try testing.expectEqual(@as(u256, if (case.verifies) 32 else 0), try db.get_storage(target.bytes, 2));
        try testing.expectEqual(@as(u64, 1), try db.get_nonce(sender.bytes));
        try testing.expectEqual(@as(usize, 0), db.snapshot_depth());
    }
}

test "Granite and Jovian BN254 pairing input limits halt a nested CALL; Fjord has no limit" {
    // CALLDATACOPY(0x40, 0, CALLDATASIZE)
    // CALL(GAS, 0x08, 0, 0x40, CALLDATASIZE, 0, 32)
    // SSTORE(0, success) SSTORE(1, MLOAD(0)) SSTORE(2, RETURNDATASIZE) SSTORE(3, 0xff) STOP
    const code = [_]u8{
        0x36, 0x60, 0x00, 0x60, 0x40, 0x37,
        0x60, 0x20, 0x60, 0x00, 0x36, 0x60, 0x40, 0x60, 0x00, 0x60, 0x08, 0x5a, 0xf1,
        0x60, 0x00, 0x55,
        0x60, 0x00, 0x51, 0x60, 0x01, 0x55,
        0x3d, 0x60, 0x02, 0x55,
        0x60, 0xff, 0x60, 0x03, 0x55,
        0x00,
    };
    // Pairing input is whole 192-byte pairs. 112,687 is not a multiple of 192, so the
    // largest input Granite accepts is 586 pairs (112,512 bytes) and 587 pairs
    // (112,704 bytes) is the smallest it rejects. Jovian's 81,984 is exactly 427 pairs.
    try testing.expectEqual(@as(usize, 112_687), precompiles.BN254_PAIRING_MAX_INPUT_GRANITE);
    try testing.expectEqual(@as(usize, 81_984), precompiles.BN254_PAIRING_MAX_INPUT_JOVIAN);
    try testing.expect(586 * 192 <= precompiles.BN254_PAIRING_MAX_INPUT_GRANITE and 587 * 192 > precompiles.BN254_PAIRING_MAX_INPUT_GRANITE);
    try testing.expectEqual(@as(usize, 427 * 192), precompiles.BN254_PAIRING_MAX_INPUT_JOVIAN);
    const schedule = hardforks.MAINNET;
    const cases = [_]struct { timestamp: u64, spec: OpSpecId, pairs: usize, accepted: bool }{
        // Above the Granite limit: Fjord runs the L1 Cancun precompile, which has none.
        .{ .timestamp = schedule.fjord, .spec = .FJORD, .pairs = 587, .accepted = true },
        .{ .timestamp = schedule.granite, .spec = .GRANITE, .pairs = 586, .accepted = true },
        .{ .timestamp = schedule.granite, .spec = .GRANITE, .pairs = 587, .accepted = false },
        // Between the Jovian and Granite limits: Granite through Isthmus accept it.
        .{ .timestamp = schedule.isthmus, .spec = .ISTHMUS, .pairs = 428, .accepted = true },
        .{ .timestamp = schedule.isthmus, .spec = .ISTHMUS, .pairs = 587, .accepted = false },
        .{ .timestamp = schedule.jovian, .spec = .JOVIAN, .pairs = 427, .accepted = true },
        .{ .timestamp = schedule.jovian, .spec = .JOVIAN, .pairs = 428, .accepted = false },
    };
    for (cases) |case| {
        try testing.expectEqual(case.spec, try schedule.specAt(case.timestamp));
        // Points at infinity: a valid pairing input whose check returns 1.
        const input = try testing.allocator.alloc(u8, case.pairs * 192);
        defer testing.allocator.free(input);
        @memset(input, 0);
        var db = Database.init(testing.allocator);
        defer db.deinit();
        const target = Address.fromU256(0xC0DE);
        try db.set_account(target.bytes, .{ .balance = 0, .code_hash = try db.set_code(&code), .storage_root = @as([32]u8, @splat(0)), .nonce = 1 });
        const sender = Address.fromU256(0xA11CE);
        try db.set_account(sender.bytes, .{ .balance = ETHER, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 0 });
        var host = Host.init(testing.allocator, &db, .{ .chain_id = 8453, .number = 1, .timestamp = case.timestamp, .gas_limit = 30_000_000, .coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS, .base_fee = 0 });
        defer host.deinit();
        var info = L1BlockInfo.empty();
        info.operator_fee_scalar = 0;
        info.operator_fee_constant = 0;
        // 587 pairs cost 45,000 + 34,000 * 587 = 20,003,000 gas inside the CALL.
        const tx = executor.Transaction{ .sender = sender, .envelope = &.{ 0x01, 0x05 }, .gas_limit = 25_000_000, .base_fee = 0, .to = target, .input = input };
        const result = try executor.executeBase(&host, info, 8453, case.timestamp, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
        try testing.expectEqual(deposits.Outcome.success, result.outcome);
        try testing.expectEqual(@as(u256, 0xff), try db.get_storage(target.bytes, 3));
        try testing.expectEqual(@as(u256, if (case.accepted) 1 else 0), try db.get_storage(target.bytes, 0));
        try testing.expectEqual(@as(u256, if (case.accepted) 1 else 0), try db.get_storage(target.bytes, 1));
        try testing.expectEqual(@as(u256, if (case.accepted) 32 else 0), try db.get_storage(target.bytes, 2));
        if (case.accepted) {
            try testing.expect(result.gas_used > 45_000 + 34_000 * @as(u64, case.pairs));
            try testing.expect(result.gas_used < 24_000_000);
        } else {
            // A halted precompile consumes all gas the CALL forwarded: 63/64 of the
            // roughly 24.5M left after the intrinsic and memory costs.
            try testing.expect(result.gas_used > 24_000_000);
        }
    }
}

test "Isthmus and Jovian operator fee: OperatorFeeVault receives the fee on gas used, exact balances" {
    const schedule = hardforks.MAINNET;
    // 21000 + GASPRICE 2 + PUSH1 3 + SSTORE 22100.
    const gas_used: u256 = 43_105;
    const cases = [_]struct { timestamp: u64, spec: OpSpecId, scalar: u256, constant: u256, operator_fee: u256 }{
        // Isthmus: gas_used * scalar / 1e6 + constant = 43,105 * 2,500,000 / 1e6 + 1,000.
        .{ .timestamp = schedule.isthmus, .spec = .ISTHMUS, .scalar = 2_500_000, .constant = 1_000, .operator_fee = 107_762 + 1_000 },
        // Jovian: gas_used * scalar * 100 + constant = 43,105 * 3 * 100 + 1,000.
        .{ .timestamp = schedule.jovian, .spec = .JOVIAN, .scalar = 3, .constant = 1_000, .operator_fee = 12_931_500 + 1_000 },
    };
    for (cases) |case| {
        try testing.expectEqual(case.spec, try schedule.specAt(case.timestamp));
        var db = Database.init(testing.allocator);
        defer db.deinit();
        // GASPRICE PUSH1 0 SSTORE STOP
        const code = [_]u8{ 0x3a, 0x60, 0x00, 0x55, 0x00 };
        const target = Address.fromU256(0xC0DE);
        try db.set_account(target.bytes, .{ .balance = 0, .code_hash = try db.set_code(&code), .storage_root = @as([32]u8, @splat(0)), .nonce = 1 });
        const sender = Address.fromU256(0xA11CE);
        const funded = ETHER;
        try db.set_account(sender.bytes, .{ .balance = funded, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 4 });
        const coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS;
        const base_fee: u64 = 1_000_000_000;
        var host = Host.init(testing.allocator, &db, .{ .chain_id = 8453, .number = 12, .timestamp = case.timestamp, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = base_fee });
        defer host.deinit();

        var info = L1BlockInfo.empty();
        info.l1_base_fee = 30 * GWEI;
        info.l1_base_fee_scalar = 1_368;
        info.l1_blob_base_fee = 1;
        info.l1_blob_base_fee_scalar = 810_949;
        info.operator_fee_scalar = case.scalar;
        info.operator_fee_constant = case.constant;
        const envelope = [_]u8{0x02} ++ @as([100]u8, @splat(0x5a));
        var cost_info = info;
        const l1_fee = cost_info.calculateTxL1Cost(&envelope, case.spec);
        try testing.expect(l1_fee > 0);

        const tx = executor.Transaction{
            .sender = sender,
            .envelope = &envelope,
            .gas_limit = 60_000,
            .fee = .{ .dynamic = .{ .max_fee_per_gas = 5 * GWEI, .max_priority_fee_per_gas = GWEI / 2 } },
            .base_fee = base_fee,
            .value = 777,
            .nonce = 4,
            .to = target,
        };
        const result = try executor.executeBase(&host, info, 8453, case.timestamp, tx, coinbase);
        try testing.expectEqual(deposits.Outcome.success, result.outcome);
        try testing.expectEqual(@as(u64, 43_105), result.gas_used);
        const price = base_fee + GWEI / 2;
        try testing.expectEqual(price, try db.get_storage(target.bytes, 0));
        try testing.expectEqual(case.operator_fee, try db.get_balance(constants.OPERATOR_FEE_VAULT_ADDRESS.bytes));
        try testing.expectEqual(funded - 777 - gas_used * price - l1_fee - case.operator_fee, try db.get_balance(sender.bytes));
        try testing.expectEqual(@as(u64, 5), try db.get_nonce(sender.bytes));
        try testing.expectEqual(@as(u256, 777), try db.get_balance(target.bytes));
        try testing.expectEqual(gas_used * (GWEI / 2), try db.get_balance(coinbase.bytes));
        try testing.expectEqual(gas_used * base_fee, try db.get_balance(constants.BASE_FEE_VAULT_ADDRESS.bytes));
        try testing.expectEqual(l1_fee, try db.get_balance(constants.L1_FEE_VAULT_ADDRESS.bytes));
    }
}

test "Bedrock on the MERGE EVM: Bedrock L1 fee, free system deposit, invalid deposits are failed deposits" {
    const coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS;
    // GASPRICE PUSH1 0 SSTORE STOP
    const code = [_]u8{ 0x3a, 0x60, 0x00, 0x55, 0x00 };
    const target = Address.fromU256(0xC0DE);
    const sender = Address.fromU256(0xA11CE);

    // User transaction: (dataGas + overhead) * l1BaseFee * l1Scalar / 1e6, with the
    // 1,088 pre-Regolith data gas overhead.
    {
        var db = Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(target.bytes, .{ .balance = 0, .code_hash = try db.set_code(&code), .storage_root = @as([32]u8, @splat(0)), .nonce = 1 });
        try db.set_account(sender.bytes, .{ .balance = ETHER, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 0 });
        const base_fee: u64 = 1_000;
        var host = Host.init(testing.allocator, &db, .{ .chain_id = 10, .number = 1, .timestamp = 1, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = base_fee });
        defer host.deinit();
        var info = L1BlockInfo.empty();
        info.l1_base_fee = 30 * GWEI;
        info.l1_fee_overhead = 188;
        info.l1_base_fee_scalar = 684_000;
        const envelope = [_]u8{0x02} ++ @as([40]u8, @splat(0x11));
        // 41 non-zero bytes * 16 + 1,088 + 188 = 1,932 gas; * 30 gwei * 0.684.
        const l1_fee: u256 = 1_932 * 30 * GWEI * 684_000 / 1_000_000;
        var cost_info = info;
        try testing.expectEqual(l1_fee, cost_info.calculateTxL1Cost(&envelope, .BEDROCK));
        const tx = executor.Transaction{ .sender = sender, .envelope = &envelope, .gas_limit = 50_000, .fee = .{ .dynamic = .{ .max_fee_per_gas = 3_000, .max_priority_fee_per_gas = 500 } }, .base_fee = base_fee, .to = target };
        const result = try executor.execute(&host, info, .BEDROCK, tx, coinbase);
        try testing.expectEqual(deposits.Outcome.success, result.outcome);
        // Berlin cold SSTORE: 21000 + 2 + 3 + 22100.
        try testing.expectEqual(@as(u64, 43_105), result.gas_used);
        try testing.expectEqual(@as(u256, 1_500), try db.get_storage(target.bytes, 0));
        try testing.expectEqual(ETHER - 43_105 * 1_500 - l1_fee, try db.get_balance(sender.bytes));
        try testing.expectEqual(@as(u256, 43_105 * 500), try db.get_balance(coinbase.bytes));
        try testing.expectEqual(@as(u256, 43_105 * 1_000), try db.get_balance(constants.BASE_FEE_VAULT_ADDRESS.bytes));
        try testing.expectEqual(l1_fee, try db.get_balance(constants.L1_FEE_VAULT_ADDRESS.bytes));
        try testing.expect(!db.account_exists(constants.OPERATOR_FEE_VAULT_ADDRESS.bytes));
    }

    // A successful system deposit executes and uses no gas.
    {
        var db = Database.init(testing.allocator);
        defer db.deinit();
        // PUSH1 1 PUSH1 0 SSTORE STOP
        const store_one = [_]u8{ 0x60, 0x01, 0x60, 0x00, 0x55, 0x00 };
        try db.set_account(target.bytes, .{ .balance = 0, .code_hash = try db.set_code(&store_one), .storage_root = @as([32]u8, @splat(0)), .nonce = 1 });
        var host = Host.init(testing.allocator, &db, .{ .chain_id = 10, .number = 1, .timestamp = 1, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0 });
        defer host.deinit();
        const tx = executor.Transaction{ .sender = sender, .envelope = &.{0x7e}, .gas_limit = 100_000, .base_fee = 0, .to = target, .deposit = DepositTransactionParts.deposit(@as([32]u8, @splat(9)), 10, true) };
        const result = try executor.execute(&host, L1BlockInfo.empty(), .BEDROCK, tx, coinbase);
        try testing.expectEqual(deposits.Outcome.success, result.outcome);
        try testing.expectEqual(@as(u64, 0), result.gas_used);
        try testing.expectEqual(@as(u256, 1), try db.get_storage(target.bytes, 0));
        try testing.expectEqual(@as(u256, 10), try db.get_balance(sender.bytes));
        try testing.expectEqual(@as(u64, 1), try db.get_nonce(sender.bytes));
    }

    // Deposits that fail validation (below intrinsic gas) never execute and are
    // failed deposits, unlike a Bedrock frame halt: a CREATE deposit's nonce is still
    // bumped, and a failed system deposit is free.
    for ([_]bool{ false, true }) |system| {
        var db = Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(sender.bytes, .{ .balance = 5, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 3 });
        var host = Host.init(testing.allocator, &db, .{ .chain_id = 10, .number = 1, .timestamp = 1, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0 });
        defer host.deinit();
        // PUSH1 0 PUSH1 0 RETURN; a CREATE needs 53,000 intrinsic gas.
        const tx = executor.Transaction{ .sender = sender, .envelope = &.{0x7e}, .gas_limit = 30_000, .base_fee = 0, .is_call = false, .input = &.{ 0x60, 0x00, 0x60, 0x00, 0xf3 }, .deposit = DepositTransactionParts.deposit(@as([32]u8, @splat(10)), 1_000, system) };
        const result = try executor.execute(&host, L1BlockInfo.empty(), .BEDROCK, tx, coinbase);
        try testing.expectEqual(deposits.Outcome.halt, result.outcome);
        try testing.expectEqual(@as(u64, if (system) 0 else 30_000), result.gas_used);
        try testing.expectEqual(@as(u256, 1_005), try db.get_balance(sender.bytes));
        try testing.expectEqual(@as(u64, 4), try db.get_nonce(sender.bytes));
        try testing.expectEqual(@as(usize, 0), db.snapshot_depth());
    }
}

test "checkpoint composes with Evm.call snapshots and refuses foreign snapshots" {
    var db = Database.init(testing.allocator);
    defer db.deinit();
    const address = Address.fromU256(0x1234);
    try db.set_account(address.bytes, .{ .balance = 10, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 1 });
    var host = Host.init(testing.allocator, &db, .{ .chain_id = 8453, .number = 1, .timestamp = 0, .gas_limit = 30_000_000, .coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS, .base_fee = 0 });
    defer host.deinit();

    // A snapshot the host did not open blocks a checkpoint.
    const foreign = try db.create_snapshot();
    try testing.expectError(error.DatabaseBusy, host.checkpoint());
    try db.commit_snapshot(foreign);

    // The host's own checkpoints nest.
    const outer = try host.checkpoint();
    const inner = try host.checkpoint();
    try testing.expectEqual(@as(usize, 2), db.snapshot_depth());
    try testing.expectEqual(@as(usize, 1), inner.index);
    // A foreign snapshot opened over them blocks a new checkpoint.
    const above = try db.create_snapshot();
    try testing.expectError(error.DatabaseBusy, host.checkpoint());
    try db.revert_to_snapshot(above);
    try testing.expectEqual(@as(usize, 2), db.snapshot_depth());
    // Committing the outer checkpoint drops the newer one too.
    try host.credit(address, 5);
    host.commit(outer);
    try testing.expectEqual(@as(usize, 0), db.snapshot_depth());
    try testing.expectEqual(@as(usize, 0), host.saved.items.len);
    try testing.expectEqual(@as(u256, 15), try db.get_balance(address.bytes));

    // A frame that reverts inside a host checkpoint: Evm.call opens and closes its
    // own snapshots above the host's, and the host rollback undoes the whole frame.
    // PUSH1 1 PUSH1 0 SSTORE STOP
    const code = [_]u8{ 0x60, 0x01, 0x60, 0x00, 0x55, 0x00 };
    const target = Address.fromU256(0xC0DE);
    try db.set_account(target.bytes, .{ .balance = 0, .code_hash = try db.set_code(&code), .storage_root = @as([32]u8, @splat(0)), .nonce = 1 });
    const sender = Address.fromU256(0xA11CE);
    try db.set_account(sender.bytes, .{ .balance = ETHER, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 0 });
    try host.configure(.JOVIAN);
    const token = try host.checkpoint();
    const result = try host.executeFrame(.{ .sender = sender, .envelope = &.{ 0x01, 0x06 }, .gas_limit = 100_000, .base_fee = 0, .to = target });
    try testing.expectEqual(deposits.Outcome.success, result.outcome);
    try testing.expectEqual(@as(usize, 1), db.snapshot_depth());
    try testing.expectEqual(@as(u256, 1), try db.get_storage(target.bytes, 0));
    try testing.expectEqual(@as(?usize, 1), db.storage_slot_counts.get(target.bytes));
    host.rollback(token);
    try testing.expectEqual(@as(usize, 0), db.snapshot_depth());
    try testing.expectEqual(@as(u256, 0), try db.get_storage(target.bytes, 0));
    try testing.expectEqual(@as(?usize, 0), db.storage_slot_counts.get(target.bytes));
    try testing.expectEqual(@as(u64, 0), try db.get_nonce(sender.bytes));
    try testing.expectEqual(ETHER, try db.get_balance(sender.bytes));
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

test "rollback restores storage slot counts: re-set and clear after rollback does not underflow" {
    var db = Database.init(testing.allocator);
    defer db.deinit();
    const address = Address.fromU256(0x5107);
    try db.set_account(address.bytes, .{ .balance = 1, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 1 });
    var host = Host.init(testing.allocator, &db, .{ .chain_id = 8453, .number = 1, .timestamp = 0, .gas_limit = 30_000_000, .coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS, .base_fee = 0 });
    defer host.deinit();

    // (1) Set slot 1 non-zero under a checkpoint.
    const first = try host.checkpoint();
    try db.set_storage(address.bytes, 1, 11);
    try testing.expectEqual(@as(?usize, 1), db.storage_slot_counts.get(address.bytes));
    // (2) Roll back: the slot and its count return to zero.
    host.rollback(first);
    try testing.expectEqual(@as(u256, 0), try db.get_storage(address.bytes, 1));
    try testing.expect(!(try db.has_storage(address.bytes)));
    // (3) Set the same slot non-zero again.
    try db.set_storage(address.bytes, 1, 12);
    try testing.expectEqual(@as(?usize, 1), db.storage_slot_counts.get(address.bytes));
    // (4) Clear it to zero.
    try db.set_storage(address.bytes, 1, 0);
    // (5) Count and state agree.
    try testing.expectEqual(@as(?usize, 0), db.storage_slot_counts.get(address.bytes));
    try testing.expect(!(try db.has_storage(address.bytes)));

    // A slot that was non-zero before the checkpoint and cleared under it: the
    // rollback must restore its count, or clearing it again underflows the count.
    try db.set_storage(address.bytes, 2, 22);
    try testing.expectEqual(@as(?usize, 1), db.storage_slot_counts.get(address.bytes));
    const second = try host.checkpoint();
    try db.set_storage(address.bytes, 2, 0);
    try testing.expectEqual(@as(?usize, 0), db.storage_slot_counts.get(address.bytes));
    host.rollback(second);
    try testing.expectEqual(@as(u256, 22), try db.get_storage(address.bytes, 2));
    try testing.expectEqual(@as(?usize, 1), db.storage_slot_counts.get(address.bytes));
    try db.set_storage(address.bytes, 2, 23);
    try db.set_storage(address.bytes, 2, 0);
    try testing.expectEqual(@as(?usize, 0), db.storage_slot_counts.get(address.bytes));
    try testing.expect(!(try db.has_storage(address.bytes)));
    try testing.expectEqual(@as(usize, 0), db.snapshot_depth());
}
