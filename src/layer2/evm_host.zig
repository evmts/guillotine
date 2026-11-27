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
//! | Fees                            | settled by the executor; the frame runs through             |
//! |                                 | `Evm.inner_call`, which moves no gas money                  |
//! | Transaction processing          | `runFrame`: intrinsic gas, nonce, EIP-2929/2930 warm set,   |
//! |                                 | EIP-7702 authorizations, refunds, EIP-7623 floor            |
//! | Block system calls (4788, 2935) | disabled here; they belong to block processing              |
//!
//! During execution BALANCE(origin) reads the balance after the executor's up-front
//! debit of gas_limit * price and the L1 and operator fees.
const std = @import("std");
const builtin = @import("builtin");
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
    /// BLOBBASEFEE. Null selects the spec default: 1 from Ecotone on (an L2 block has
    /// no blob gas, so its blob base fee is MIN_BASE_FEE_PER_BLOB_GAS), else 0.
    blob_base_fee: ?u64 = null,
    /// Hashes of recent ancestors, newest first (see BlockInfo.block_hashes).
    block_hashes: []const [32]u8 = &.{},
};

/// EIP-3860 MAX_INITCODE_SIZE. Enforced from Shanghai (OP Stack Canyon) on only.
const MAX_INITCODE_SIZE: usize = 49_152;
/// Frame gas capacity: `block_gas_limit` sizes `Frame.GasType` (i64 above 2^31-1).
const EVM_GAS_CAPACITY: u64 = std.math.maxInt(u32);
/// Native stack for the top-level frame. `inner_call` recurses once per call depth
/// and, unlike `Evm.call`, does not move deep calls to a larger stack itself; this is
/// the size of the EVM's own large-stack worker (src/evm.zig `large_stack_size`).
const FRAME_STACK_SIZE: usize = 64 * 1024 * 1024;

/// EIP-2930 and EIP-7702 intrinsic gas. Every listed address, storage key and
/// authorization tuple is charged, duplicates included. Saturating: a list whose
/// cost does not fit is above every gas limit.
fn listIntrinsicGas(tx: executor.Transaction) u128 {
    var gas: u128 = 0;
    for (tx.access_list) |entry| {
        gas +|= executor.ACCESS_LIST_ADDRESS_COST;
        gas +|= @as(u128, executor.ACCESS_LIST_STORAGE_KEY_COST) *| entry.storage_keys.len;
    }
    gas +|= @as(u128, executor.AUTHORIZATION_COST) *| tx.authorization_list.len;
    return gas;
}

/// Run `instance.inner_call(params)` on a thread whose stack fits the deepest call
/// chain. The caller blocks until it finishes, so one thread at a time uses the EVM.
fn innerCallOnFrameStack(
    allocator: std.mem.Allocator,
    comptime Evm: type,
    instance: *Evm,
    params: anytype,
) !@typeInfo(@TypeOf(Evm.inner_call)).@"fn".return_type.? {
    if (comptime builtin.single_threaded) return error.FrameStackUnavailable;
    const Job = struct {
        instance: *Evm,
        params: @TypeOf(params),
        result: @typeInfo(@TypeOf(Evm.inner_call)).@"fn".return_type.?,
        fn run(job: *@This()) void {
            job.result = job.instance.inner_call(job.params);
        }
    };
    var job = Job{ .instance = instance, .params = params, .result = .failed(0) };
    const thread = try std.Thread.spawn(.{ .stack_size = FRAME_STACK_SIZE, .allocator = allocator }, Job.run, .{&job});
    thread.join();
    return job.result;
}

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
    /// other than this host's own is open, or an ephemeral view is active: a
    /// rollback here would undo, or be undone by, that work.
    pub fn checkpoint(self: *Host) !Token {
        const db = self.database;
        if (db.overlay_active or !self.ownsSnapshots()) return error.DatabaseBusy;
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
            evm.log.err(
                "layer2 host: database snapshots changed under checkpoint {d}; not rolled back",
                .{token.index},
            );
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

    /// Account destructions and EIP-161 empty-account pruning must observe
    /// post-fee balances after the executor credits fee vaults and coinbase.
    pub const Finalization = struct {
        touches: std.ArrayList(Address) = .empty,
        destructions: std.ArrayList(Address) = .empty,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.touches.deinit(allocator);
            self.destructions.deinit(allocator);
        }
    };

    pub fn finalize(self: *Host, effects: *const Finalization) !void {
        for (effects.destructions.items) |addr| {
            try self.database.delete_account(addr.bytes);
        }
        // Every OP Stack spec (Bedrock onward) is past Spurious Dragon (EIP-161).
        for (effects.touches.items) |addr| {
            if (try self.database.get_account(addr.bytes)) |account| {
                if (account.is_empty()) {
                    try self.database.delete_account(addr.bytes);
                }
            }
        }
    }

    pub fn executeFrame(self: *Host, tx: executor.Transaction) !executor.Result {
        var effects = Finalization{};
        defer effects.deinit(self.allocator);
        const result = try self.executeFrameBeforeFees(tx, &effects);
        try self.finalize(&effects);
        return result;
    }

    pub fn executeFrameBeforeFees(self: *Host, tx: executor.Transaction, effects: *Finalization) !executor.Result {
        const spec = self.spec orelse return error.NotConfigured;
        switch (spec) {
            inline else => |comptime_spec| return self.runFrame(comptime_spec, tx, effects),
        }
    }

    /// Apply an EIP-7702 authorization list (execution-specs Prague `set_delegation`)
    /// and warm every recovered authority. Invalid tuples are skipped. Returns the
    /// refund for authorities that already existed.
    fn applyAuthorizations(
        self: *Host,
        comptime hardfork: Hardfork,
        access_list: anytype,
        list: []const executor.Authorization,
    ) !u64 {
        // The intrinsic gas check already paid for the list.
        var unmetered: i64 = std.math.maxInt(i64);
        var processor = evm.AuthorizationProcessor{
            .db = self.database,
            .chain_id = self.block.chain_id,
            .gas_remaining = &unmetered,
            .eips = .{ .hardfork = hardfork },
        };
        var applied = try processor.processAuthorizationListWithResults(self.allocator, list);
        defer applied.deinit(self.allocator);
        for (applied.results) |tuple| {
            if (tuple.authority) |authority| try access_list.pre_warm_addresses(&[_]Address{authority});
        }
        return std.math.cast(u64, applied.refund) orelse error.AuthorizationRefundOutOfRange;
    }

    /// One transaction's EVM execution, in the order of execution-specs
    /// `process_transaction`: intrinsic checks, sender nonce, warm set, authorization
    /// list, message call, refunds and the EIP-7623 floor. The authorization list is
    /// applied outside the message call's snapshot, so a reverting call keeps it.
    fn runFrame(self: *Host, comptime spec: OpSpecId, tx: executor.Transaction, effects: *Finalization) !executor.Result {
        const hardfork = comptime spec.toEthHardfork();
        // `Evm.call` applies Osaka's transaction rules (EIP-7825 gas cap); this path
        // does not. Add them here before an OP spec maps to Osaka.
        comptime if (hardfork.isAtLeast(.OSAKA)) @compileError("runFrame does not apply Osaka transaction rules");
        const config = comptime evmConfig(spec);
        const Evm = evm.Evm(config);
        const eips = evm.Eips{ .hardfork = hardfork };
        const is_deposit = tx.deposit != null;
        const is_create = !tx.is_call;
        const price = try executor.gasPrice(tx);
        if (tx.base_fee != self.block.base_fee) return error.BaseFeeMismatch;
        if (tx.gas_limit > EVM_GAS_CAPACITY) return error.GasLimitExceedsEvmCapacity;
        if (tx.is_call != (tx.to != null)) return error.CallTargetMismatch;
        if (tx.authorization_list.len != 0 and (comptime !hardfork.isAtLeast(.PRAGUE))) {
            return error.AuthorizationListUnsupported;
        }

        var origin = (try self.database.get_account(tx.sender.bytes)) orelse Account.zero();
        // Transaction validity. For a user transaction it is a rejection (revm
        // `InvalidTransaction`); for a deposit it is a failed deposit on every spec
        // (op-revm `catch_error_failed_deposit`).
        const tokens = eips.tokens_in_calldata(tx.input);
        const calldata_gas = eips.calldata_gas_cost(tokens, is_create, tx.input.len);
        const intrinsic_wide = @as(u128, eips.intrinsic_gas_cost(is_create)) + calldata_gas +| listIntrinsicGas(tx);
        const floor = eips.floor_gas_cost(tokens);
        const below_intrinsic = tx.gas_limit < intrinsic_wide or tx.gas_limit < floor;
        // EIP-3860 from Shanghai (Canyon) on; Bedrock and Regolith have no init code limit.
        const has_shanghai = comptime hardfork.isAtLeast(.SHANGHAI);
        const initcode_too_large = has_shanghai and is_create and tx.input.len > MAX_INITCODE_SIZE;
        if (is_deposit) {
            if (below_intrinsic or initcode_too_large or tx.value > origin.balance) {
                return .{ .outcome = .halt, .gas_used = tx.gas_limit, .invalid = true };
            }
        } else {
            if (below_intrinsic) return error.IntrinsicGasTooLow;
            if (initcode_too_large) return error.CreateInitCodeSizeLimit;
            // EIP-3607 (revm `RejectCallerWithCode`): a sender with code cannot originate.
            // A delegated EOA has no code hash here (`Account.delegated_address`).
            const has_non_empty_code = !std.mem.allEqual(u8, &origin.code_hash, 0) and
                !std.mem.eql(u8, &origin.code_hash, &primitives.EMPTY_CODE_HASH);
            if (has_non_empty_code) return error.SenderHasCode;
        }
        const intrinsic: u64 = @intCast(intrinsic_wide);
        const execution_gas = tx.gas_limit - intrinsic;

        // Every executed transaction increments the sender nonce once, before the
        // authorization list (a self-sponsored authorization sees the new nonce). The
        // executor already did so for a CALL deposit.
        if (!(is_deposit and tx.is_call)) {
            if (origin.nonce == std.math.maxInt(u64)) return error.NonceOverflow;
            origin.nonce += 1;
            try self.database.set_account(tx.sender.bytes, origin);
        }

        const block_info = evm.BlockInfo{
            .chain_id = self.block.chain_id,
            .number = self.block.number,
            .timestamp = self.block.timestamp,
            .difficulty = 0,
            .gas_limit = self.block.gas_limit,
            .coinbase = self.block.coinbase,
            .base_fee = self.block.base_fee,
            .prev_randao = self.block.prev_randao,
            .blob_base_fee = self.block.blob_base_fee orelse if (comptime spec.isAtLeast(.ECOTONE)) 1 else 0,
            .block_hashes = self.block.block_hashes,
        };
        const context = evm.TransactionContext{
            .gas_limit = tx.gas_limit,
            .coinbase = self.block.coinbase,
            // Not read during execution: CHAINID reads BlockInfo.chain_id (u64). Set only
            // when the field is wide enough for every chain ID.
            .chain_id = if (comptime std.math.maxInt(@FieldType(evm.TransactionContext, "chain_id")) >=
                std.math.maxInt(u64)) self.block.chain_id else 0,
            .allow_gas_price_below_base_fee = true,
        };
        var instance = try Evm.init(self.allocator, self.database, block_info, context, price, tx.sender);
        defer instance.deinit();
        // EIP-1153: transient storage lives in the database and ends with the transaction.
        defer self.database.clear_transient_storage();

        // EIP-2929 warm set: sender, destination, coinbase (EIP-3651), this spec's
        // precompiles including the OP overrides, then the EIP-2930 access list.
        try eips.pre_warm_transaction_addresses(&instance.access_list, tx.sender, tx.to, self.block.coinbase);
        const last_precompile = comptime evm.precompiles.lastContiguousPrecompile(hardfork);
        var precompile: u16 = 0x01;
        while (precompile <= last_precompile) : (precompile += 1) {
            try instance.access_list.pre_warm_addresses(&[_]Address{Address.fromU256(precompile)});
        }
        if (comptime hardfork.isAtLeast(.OSAKA)) {
            try instance.access_list.pre_warm_addresses(&[_]Address{evm.precompiles.P256VERIFY_ADDRESS});
        }
        if (comptime config.enable_precompiles) {
            inline for (config.precompile_overrides) |override| {
                try instance.access_list.pre_warm_addresses(&[_]Address{override.address});
            }
        }
        for (tx.access_list) |entry| {
            try instance.access_list.pre_warm_addresses(&[_]Address{entry.address});
            for (entry.storage_keys) |key| _ = try instance.access_list.access_storage_slot(entry.address, key);
        }

        var authorization_refund: u64 = 0;
        if (tx.authorization_list.len != 0) {
            authorization_refund = try self.applyAuthorizations(hardfork, &instance.access_list, tx.authorization_list);
        }
        // EIP-7702: the delegate of a delegated destination starts warm. After the
        // authorization list, which can change the delegation.
        try instance.warmDelegatedTarget(tx.to);

        const params: evm.CallParams = if (tx.to) |to|
            .{ .call = .{ .caller = tx.sender, .to = to, .value = tx.value, .input = tx.input, .gas = execution_gas } }
        else
            .{ .create = .{ .caller = tx.sender, .value = tx.value, .init_code = tx.input, .gas = execution_gas } };
        // The creation transaction's nonce is already incremented and its intrinsic
        // gas paid CreateGas and the init code words.
        if (is_create) instance.tx_sender_nonce_incremented = true;
        self.database.failure = null;
        const depth = self.database.snapshot_depth();
        var result = try innerCallOnFrameStack(self.allocator, Evm, &instance, params);
        defer if (result.trace) |*trace| trace.deinit();
        if (instance.host_failure) |err| {
            // Not a transaction outcome. The executor rolls back its checkpoint, which
            // needs every snapshot the frame opened closed first.
            if (self.database.snapshot_depth() > depth) self.database.revert_to_depth(depth);
            return err;
        }
        if (self.database.snapshot_depth() != depth) {
            if (self.database.snapshot_depth() > depth) self.database.revert_to_depth(depth);
            return error.FrameSnapshotImbalance;
        }
        if (result.gas_left > execution_gas) return error.GasAccountingMismatch;

        if (result.success) {
            // SELFDESTRUCT records the account; deferred to `finalize` after fee settlement.
            var destructions = instance.self_destruct.iterator();
            while (destructions.next()) |entry| {
                try effects.destructions.append(self.allocator, entry.key_ptr.*);
            }
        }
        // EIP-161 (every OP Stack spec is past Spurious Dragon): defer empty-account
        // pruning until after fee settlement so touched fee recipients / coinbase observe
        // their credited balances (preserving storage when credited, pruning when 0).
        try instance.touchForPruning(self.block.coinbase);
        std.mem.swap(std.ArrayList(Address), &effects.touches, &instance.consensus_touched);

        // EIP-3529 refund cap on the whole transaction's gas. The authorization refund
        // counts whatever the outcome; execution refunds only on success.
        const used_before_refund = tx.gas_limit - result.gas_left;
        const refund_counter = authorization_refund +| (if (result.success) instance.gas_refund_counter else 0);
        const refund_cap = eips.eip_3529_gas_refund_cap(used_before_refund, refund_counter);
        const gas_used = @max(used_before_refund - refund_cap, floor);

        // REVERT and an exceptional halt are told apart by what the frame did, never by
        // the gas it left: `REVERT(0, 0)` can end with no gas at all, and that is
        // still a revert.
        const outcome: deposits.Outcome = if (result.success) .success else if (result.reverted) .revert else .halt;
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

test "REVERT(0, 0) with exactly zero gas left is a revert; out-of-gas and INVALID are halts" {
    // PUSH1 0, PUSH1 0, REVERT costs 6 gas. A gas limit of 21,006 leaves the frame
    // with nothing when REVERT runs, which a gas-based guess reads as a halt.
    const revert_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xfd };
    // PUSH1 1, PUSH1 0, SSTORE, then the same REVERT with data left to spare.
    const store_then_revert = [_]u8{ 0x60, 0x01, 0x60, 0x00, 0x55, 0x60, 0x00, 0x60, 0x00, 0xfd };
    const cases = [_]struct { code: []const u8, gas_limit: u64, outcome: deposits.Outcome }{
        .{ .code = &revert_code, .gas_limit = 21_006, .outcome = .revert },
        .{ .code = &revert_code, .gas_limit = 60_000, .outcome = .revert },
        .{ .code = &store_then_revert, .gas_limit = 100_000, .outcome = .revert },
        // One gas short of the block: out of gas before REVERT runs.
        .{ .code = &revert_code, .gas_limit = 21_005, .outcome = .halt },
        .{ .code = &revert_code, .gas_limit = 21_000, .outcome = .halt },
        // INVALID and a stack underflow consume everything: halts.
        .{ .code = &.{0xfe}, .gas_limit = 60_000, .outcome = .halt },
        .{ .code = &.{0x01}, .gas_limit = 60_000, .outcome = .halt },
        // SSTORE without its 20,000 gas: out of gas, a halt with gas spent.
        .{ .code = &store_then_revert, .gas_limit = 30_000, .outcome = .halt },
        .{ .code = &.{0x00}, .gas_limit = 21_000, .outcome = .success },
    };
    for (cases) |case| {
        var db = Database.init(testing.allocator);
        defer db.deinit();
        const target = Address.fromU256(0xC0DE);
        try db.set_account(target.bytes, .{ .balance = 0, .code_hash = try db.set_code(case.code), .storage_root = @as([32]u8, @splat(0)), .nonce = 1 });
        var host = Host.init(testing.allocator, &db, .{ .chain_id = 8453, .number = 1, .timestamp = hardforks.MAINNET.ecotone, .gas_limit = 30_000_000, .coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS, .base_fee = 1_000_000 });
        defer host.deinit();

        const sender = Address.fromU256(0xA11CE);
        const tx = executor.Transaction{
            .sender = sender,
            .envelope = &.{ 0x7e, 0x01 },
            .gas_limit = case.gas_limit,
            .base_fee = 1_000_000,
            .value = 0,
            .to = target,
            .deposit = DepositTransactionParts.deposit(@as([32]u8, @splat(7)), @intCast(ETHER), false),
        };
        const result = try executor.executeBase(&host, L1BlockInfo.empty(), 8453, hardforks.MAINNET.ecotone, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
        try testing.expectEqual(case.outcome, result.outcome);
        // A revert and a halt both undo the frame's storage writes.
        try testing.expectEqual(@as(u256, 0), try db.get_storage(target.bytes, 0));
        // The deposit is included either way: its mint stays and the nonce moves.
        try testing.expectEqual(ETHER, try db.get_balance(sender.bytes));
        try testing.expectEqual(@as(u64, 1), try db.get_nonce(sender.bytes));
        try testing.expectEqual(@as(usize, 0), db.snapshot_depth());
    }
}

test "EIP-161 on the OP Stack: an empty account touched by a deposit's call is deleted" {
    // PUSH1 0 (x5), PUSH20 empty, PUSH2 0xffff, CALL, POP, STOP: a zero-value call.
    const empty = Address{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{0xE0} };
    const code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x73 } ++ empty.bytes ++ [_]u8{ 0x61, 0xff, 0xff, 0xf1, 0x50, 0x00 };
    const untouched = Address.fromU256(0xE1E1);
    for ([_]bool{ true, false }) |call_succeeds| {
        var db = Database.init(testing.allocator);
        defer db.deinit();
        const target = Address.fromU256(0xC0DE);
        // The failing variant ends in INVALID instead of STOP.
        var variant = code;
        if (!call_succeeds) variant[variant.len - 1] = 0xfe;
        try db.set_account(target.bytes, .{ .balance = 0, .code_hash = try db.set_code(&variant), .storage_root = @as([32]u8, @splat(0)), .nonce = 1 });
        try db.set_account(empty.bytes, Account.zero());
        try db.set_account(untouched.bytes, Account.zero());
        var host = Host.init(testing.allocator, &db, .{ .chain_id = 8453, .number = 1, .timestamp = hardforks.MAINNET.ecotone, .gas_limit = 30_000_000, .coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS, .base_fee = 1_000_000 });
        defer host.deinit();

        const tx = executor.Transaction{
            .sender = Address.fromU256(0xA11CE),
            .envelope = &.{ 0x7e, 0x01 },
            .gas_limit = 200_000,
            .base_fee = 1_000_000,
            .value = 0,
            .to = target,
            .deposit = DepositTransactionParts.deposit(@as([32]u8, @splat(7)), @intCast(ETHER), false),
        };
        const result = try executor.executeBase(&host, L1BlockInfo.empty(), 8453, hardforks.MAINNET.ecotone, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
        try testing.expectEqual(if (call_succeeds) deposits.Outcome.success else deposits.Outcome.halt, result.outcome);
        // Touched and empty: deleted, unless the touching frame failed.
        try testing.expectEqual(!call_succeeds, db.account_exists(empty.bytes));
        try testing.expect(db.account_exists(untouched.bytes));
    }
}

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
        0x60, 0x20, 0x60, 0x00, 0x36, 0x60,
        0x40, 0x61, 0x01, 0x00, 0x5a, 0xfa,
        0x60, 0x00, 0x55, 0x60, 0x00, 0x51,
        0x60, 0x01, 0x55, 0x3d, 0x60, 0x02,
        0x55, 0x60, 0xff, 0x60, 0x03, 0x55,
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
        0x60, 0x20, 0x60, 0x00, 0x36, 0x60,
        0x40, 0x60, 0x00, 0x60, 0x08, 0x5a,
        0xf1, 0x60, 0x00, 0x55, 0x60, 0x00,
        0x51, 0x60, 0x01, 0x55, 0x3d, 0x60,
        0x02, 0x55, 0x60, 0xff, 0x60, 0x03,
        0x55, 0x00,
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

test "EIP-2930 type-1 access list: 2,400 per address, 1,900 per key, duplicates charged, listed slot warm" {
    const schedule = hardforks.MAINNET;
    const timestamp = schedule.ecotone;
    const sender = Address.fromU256(0xA11CE);
    const listed = Address.fromU256(0x1157);
    // PUSH1 0 SLOAD STOP
    const sload = [_]u8{ 0x60, 0x00, 0x54, 0x00 };
    const reader = Address.fromU256(0xC0DE);

    const keys = [_]u256{ 0, 0 };
    const one_key = [_]u256{0};
    const unused = [_]executor.AccessListEntry{.{ .address = listed }};
    const reader_slot = [_]executor.AccessListEntry{.{ .address = reader, .storage_keys = &one_key }};
    const duplicates = [_]executor.AccessListEntry{ .{ .address = listed, .storage_keys = &keys }, .{ .address = listed, .storage_keys = &one_key } };
    const cases = [_]struct { to: Address, list: []const executor.AccessListEntry, gas_used: u64 }{
        // a. One listed address the transaction never touches: 21,000 + 2,400.
        .{ .to = listed, .list = &unused, .gas_used = 23_400 },
        // b. SLOAD of a listed slot is warm: 21,000 + 2,400 + 1,900 + PUSH1 3 + SLOAD 100.
        .{ .to = reader, .list = &reader_slot, .gas_used = 25_403 },
        // Without the list the same SLOAD is cold: 21,000 + 3 + 2,100.
        .{ .to = reader, .list = &.{}, .gas_used = 23_103 },
        // c. Duplicate entries and keys are each charged: 21,000 + 2 * 2,400 + 3 * 1,900.
        .{ .to = listed, .list = &duplicates, .gas_used = 31_500 },
    };
    for (cases) |case| {
        var db = Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(reader.bytes, .{ .balance = 0, .code_hash = try db.set_code(&sload), .storage_root = @as([32]u8, @splat(0)), .nonce = 1 });
        try db.set_account(sender.bytes, .{ .balance = ETHER, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 0 });
        var host = Host.init(testing.allocator, &db, .{ .chain_id = 8453, .number = 1, .timestamp = timestamp, .gas_limit = 30_000_000, .coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS, .base_fee = 0 });
        defer host.deinit();
        const tx = executor.Transaction{ .sender = sender, .envelope = &.{ 0x01, 0x07 }, .gas_limit = 100_000, .base_fee = 0, .to = case.to, .access_list = case.list };
        const result = try executor.executeBase(&host, L1BlockInfo.empty(), 8453, timestamp, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
        try testing.expectEqual(deposits.Outcome.success, result.outcome);
        try testing.expectEqual(case.gas_used, result.gas_used);
        try testing.expectEqual(@as(u64, 1), try db.get_nonce(sender.bytes));

        // One gas below the intrinsic cost is a rejection that changes nothing.
        var short = tx;
        short.nonce = 1;
        short.gas_limit = 21_000 + 2_400 * @as(u64, case.list.len) - 1;
        for (case.list) |entry| short.gas_limit += 1_900 * @as(u64, entry.storage_keys.len);
        if (case.list.len == 0) continue;
        try testing.expectError(error.IntrinsicGasTooLow, executor.executeBase(&host, L1BlockInfo.empty(), 8453, timestamp, short, constants.SEQUENCER_FEE_VAULT_ADDRESS));
        try testing.expectEqual(@as(u64, 1), try db.get_nonce(sender.bytes));
        try testing.expectEqual(@as(usize, 0), db.snapshot_depth());
    }
}

test "EIP-2930 access list on a type-2 transaction: charged, warmed and paid at the effective price" {
    const schedule = hardforks.MAINNET;
    const sender = Address.fromU256(0xA11CE);
    // PUSH1 0 SLOAD STOP
    const sload = [_]u8{ 0x60, 0x00, 0x54, 0x00 };
    const reader = Address.fromU256(0xC0DE);
    const one_key = [_]u256{0};
    const list = [_]executor.AccessListEntry{.{ .address = reader, .storage_keys = &one_key }};
    const cases = [_]struct { timestamp: u64, spec: OpSpecId }{
        .{ .timestamp = schedule.canyon, .spec = .CANYON },
        .{ .timestamp = schedule.ecotone, .spec = .ECOTONE },
        .{ .timestamp = schedule.isthmus, .spec = .ISTHMUS },
        .{ .timestamp = schedule.jovian, .spec = .JOVIAN },
    };
    for (cases) |case| {
        try testing.expectEqual(case.spec, try schedule.specAt(case.timestamp));
        var db = Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(reader.bytes, .{ .balance = 0, .code_hash = try db.set_code(&sload), .storage_root = @as([32]u8, @splat(0)), .nonce = 1 });
        try db.set_account(sender.bytes, .{ .balance = ETHER, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 0 });
        const base_fee: u64 = 1_000;
        var host = Host.init(testing.allocator, &db, .{ .chain_id = 8453, .number = 1, .timestamp = case.timestamp, .gas_limit = 30_000_000, .coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS, .base_fee = base_fee });
        defer host.deinit();
        var info = L1BlockInfo.empty();
        info.operator_fee_scalar = 0;
        info.operator_fee_constant = 0;
        const tx = executor.Transaction{
            .sender = sender,
            .envelope = &.{ 0x02, 0x08 },
            .gas_limit = 100_000,
            .fee = .{ .dynamic = .{ .max_fee_per_gas = 5_000, .max_priority_fee_per_gas = 500 } },
            .base_fee = base_fee,
            .to = reader,
            .access_list = &list,
        };
        const result = try executor.executeBase(&host, info, 8453, case.timestamp, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
        try testing.expectEqual(deposits.Outcome.success, result.outcome);
        // 21,000 + 2,400 + 1,900 + PUSH1 3 + warm SLOAD 100.
        try testing.expectEqual(@as(u64, 25_403), result.gas_used);
        try testing.expectEqual(ETHER - 25_403 * 1_500, try db.get_balance(sender.bytes));
        try testing.expectEqual(@as(u256, 25_403 * 500), try db.get_balance(constants.SEQUENCER_FEE_VAULT_ADDRESS.bytes));
        try testing.expectEqual(@as(u256, 25_403 * 1_000), try db.get_balance(constants.BASE_FEE_VAULT_ADDRESS.bytes));
    }
}

test "EIP-7702 type-4 on Isthmus and Jovian: delegation applied, delegated code runs, refund for an existing authority" {
    const crypto = primitives.crypto.Crypto;
    const schedule = hardforks.MAINNET;
    const key: crypto.PrivateKey = @as([32]u8, @splat(0x42));
    const authority = (try crypto.unaudited_getPublicKey(key)).toAddress();
    const sponsor = Address.fromU256(0xA11CE);
    // PUSH1 1 PUSH1 0 SSTORE STOP
    const store_one = [_]u8{ 0x60, 0x01, 0x60, 0x00, 0x55, 0x00 };
    const delegate = Address.fromU256(0xDE1E);
    const cases = [_]struct { timestamp: u64, spec: OpSpecId }{
        .{ .timestamp = schedule.isthmus, .spec = .ISTHMUS },
        .{ .timestamp = schedule.jovian, .spec = .JOVIAN },
    };
    for (cases) |case| {
        try testing.expectEqual(case.spec, try schedule.specAt(case.timestamp));
        var db = Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(delegate.bytes, .{ .balance = 0, .code_hash = try db.set_code(&store_one), .storage_root = @as([32]u8, @splat(0)), .nonce = 1 });
        try db.set_account(sponsor.bytes, .{ .balance = ETHER, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 0 });
        // The authority exists, so its tuple earns PER_EMPTY_ACCOUNT_COST - PER_AUTH_BASE_COST.
        try db.set_account(authority.bytes, .{ .balance = 1, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 3 });
        var host = Host.init(testing.allocator, &db, .{ .chain_id = 8453, .number = 1, .timestamp = case.timestamp, .gas_limit = 30_000_000, .coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS, .base_fee = 0 });
        defer host.deinit();
        var info = L1BlockInfo.empty();
        info.operator_fee_scalar = 0;
        info.operator_fee_constant = 0;
        var auth = try primitives.Authorization.createAuthorization(testing.allocator, 8453, delegate, 3, key);
        auth.v -= 27; // voltaire signs with v = 27 + y_parity; the tuple carries y_parity
        const auths = [_]executor.Authorization{auth};
        const tx = executor.Transaction{
            .sender = sponsor,
            .envelope = &.{ 0x04, 0x09 },
            .gas_limit = 200_000,
            .fee = .{ .dynamic = .{ .max_fee_per_gas = 0, .max_priority_fee_per_gas = 0 } },
            .base_fee = 0,
            .to = authority,
            .authorization_list = &auths,
        };
        const result = try executor.executeBase(&host, info, 8453, case.timestamp, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
        try testing.expectEqual(deposits.Outcome.success, result.outcome);
        // 21,000 + 25,000 + PUSH1 3 + PUSH1 3 + SSTORE 22,100 = 68,106, less the
        // 12,500 authorization refund (below the 68,106 / 5 cap).
        try testing.expectEqual(@as(u64, 68_106 - 12_500), result.gas_used);
        const account = (try db.get_account(authority.bytes)).?;
        try testing.expectEqual(@as(u64, 4), account.nonce);
        try testing.expectEqual(delegate, account.delegated_address.?);
        try testing.expectEqual(@as(u256, 1), try db.get_storage(authority.bytes, 0));
        try testing.expectEqual(@as(u256, 0), try db.get_storage(delegate.bytes, 0));
        try testing.expectEqual(@as(u64, 1), try db.get_nonce(sponsor.bytes));
        try testing.expectEqual(@as(usize, 0), db.snapshot_depth());
    }
}

test "EIP-7702 self-sponsored authorization sees the incremented sender nonce" {
    const crypto = primitives.crypto.Crypto;
    const schedule = hardforks.MAINNET;
    const key: crypto.PrivateKey = @as([32]u8, @splat(0x44));
    const sender = (try crypto.unaudited_getPublicKey(key)).toAddress();
    // PUSH1 1 PUSH1 0 SSTORE STOP
    const store_one = [_]u8{ 0x60, 0x01, 0x60, 0x00, 0x55, 0x00 };
    const delegate = Address.fromU256(0xDE1E);
    var db = Database.init(testing.allocator);
    defer db.deinit();
    try db.set_account(delegate.bytes, .{ .balance = 0, .code_hash = try db.set_code(&store_one), .storage_root = @as([32]u8, @splat(0)), .nonce = 1 });
    try db.set_account(sender.bytes, .{ .balance = ETHER, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 5 });
    var host = Host.init(testing.allocator, &db, .{ .chain_id = 8453, .number = 1, .timestamp = schedule.isthmus, .gas_limit = 30_000_000, .coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS, .base_fee = 0 });
    defer host.deinit();
    var info = L1BlockInfo.empty();
    info.operator_fee_scalar = 0;
    info.operator_fee_constant = 0;
    // Chain ID 0 is valid on every chain. Tuple nonce 6 = transaction nonce 5 + 1.
    var auth = try primitives.Authorization.createAuthorization(testing.allocator, 0, delegate, 6, key);
    auth.v -= 27;
    const auths = [_]executor.Authorization{auth};
    const tx = executor.Transaction{
        .sender = sender,
        .envelope = &.{ 0x04, 0x0a },
        .gas_limit = 200_000,
        .fee = .{ .dynamic = .{ .max_fee_per_gas = 0, .max_priority_fee_per_gas = 0 } },
        .base_fee = 0,
        .nonce = 5,
        .to = sender,
        .authorization_list = &auths,
    };
    const result = try executor.executeBase(&host, info, 8453, schedule.isthmus, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
    try testing.expectEqual(deposits.Outcome.success, result.outcome);
    try testing.expectEqual(@as(u64, 68_106 - 12_500), result.gas_used);
    const account = (try db.get_account(sender.bytes)).?;
    try testing.expectEqual(@as(u64, 7), account.nonce);
    try testing.expectEqual(delegate, account.delegated_address.?);
    try testing.expectEqual(@as(u256, 1), try db.get_storage(sender.bytes, 0));
}

test "EIP-7702 invalid authorizations are skipped but still pay intrinsic gas" {
    const crypto = primitives.crypto.Crypto;
    const schedule = hardforks.MAINNET;
    const key: crypto.PrivateKey = @as([32]u8, @splat(0x42));
    const authority = (try crypto.unaudited_getPublicKey(key)).toAddress();
    const sponsor = Address.fromU256(0xA11CE);
    const delegate = Address.fromU256(0xDE1E);
    const target = Address.fromU256(0xB0B);
    var db = Database.init(testing.allocator);
    defer db.deinit();
    try db.set_account(sponsor.bytes, .{ .balance = ETHER, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 0 });
    try db.set_account(authority.bytes, .{ .balance = 1, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 3 });
    var host = Host.init(testing.allocator, &db, .{ .chain_id = 8453, .number = 1, .timestamp = schedule.jovian, .gas_limit = 30_000_000, .coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS, .base_fee = 0 });
    defer host.deinit();
    var info = L1BlockInfo.empty();
    info.operator_fee_scalar = 0;
    info.operator_fee_constant = 0;
    // Wrong chain ID, then a nonce the authority does not have.
    var wrong_chain = try primitives.Authorization.createAuthorization(testing.allocator, 999, delegate, 3, key);
    wrong_chain.v -= 27;
    var wrong_nonce = try primitives.Authorization.createAuthorization(testing.allocator, 8453, delegate, 4, key);
    wrong_nonce.v -= 27;
    const auths = [_]executor.Authorization{ wrong_chain, wrong_nonce };
    const tx = executor.Transaction{
        .sender = sponsor,
        .envelope = &.{ 0x04, 0x0b },
        .gas_limit = 100_000,
        .fee = .{ .dynamic = .{ .max_fee_per_gas = 0, .max_priority_fee_per_gas = 0 } },
        .base_fee = 0,
        .to = target,
        .authorization_list = &auths,
    };
    const result = try executor.executeBase(&host, info, 8453, schedule.jovian, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
    try testing.expectEqual(deposits.Outcome.success, result.outcome);
    // 21,000 + 2 * 25,000; a skipped tuple earns no refund.
    try testing.expectEqual(@as(u64, 71_000), result.gas_used);
    const account = (try db.get_account(authority.bytes)).?;
    try testing.expectEqual(@as(u64, 3), account.nonce);
    try testing.expect(account.delegated_address == null);
    try testing.expectEqual(@as(u64, 1), try db.get_nonce(sponsor.bytes));

    // One gas below 21,000 + 2 * 25,000 is a rejection.
    var short = tx;
    short.nonce = 1;
    short.gas_limit = 70_999;
    try testing.expectError(error.IntrinsicGasTooLow, executor.executeBase(&host, info, 8453, schedule.jovian, short, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    try testing.expectEqual(@as(u64, 1), try db.get_nonce(sponsor.bytes));
}

test "EIP-7702 delegation and authority nonce persist when the execution reverts" {
    const crypto = primitives.crypto.Crypto;
    const schedule = hardforks.MAINNET;
    const key: crypto.PrivateKey = @as([32]u8, @splat(0x42));
    const authority = (try crypto.unaudited_getPublicKey(key)).toAddress();
    const sponsor = Address.fromU256(0xA11CE);
    // PUSH1 1 PUSH1 0 SSTORE PUSH1 0 PUSH1 0 REVERT
    const store_then_revert = [_]u8{ 0x60, 0x01, 0x60, 0x00, 0x55, 0x60, 0x00, 0x60, 0x00, 0xfd };
    const delegate = Address.fromU256(0xDE1E);
    var db = Database.init(testing.allocator);
    defer db.deinit();
    try db.set_account(delegate.bytes, .{ .balance = 0, .code_hash = try db.set_code(&store_then_revert), .storage_root = @as([32]u8, @splat(0)), .nonce = 1 });
    try db.set_account(sponsor.bytes, .{ .balance = ETHER, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 0 });
    try db.set_account(authority.bytes, .{ .balance = 1, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 3 });
    var host = Host.init(testing.allocator, &db, .{ .chain_id = 8453, .number = 1, .timestamp = schedule.isthmus, .gas_limit = 30_000_000, .coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS, .base_fee = 0 });
    defer host.deinit();
    var info = L1BlockInfo.empty();
    info.operator_fee_scalar = 0;
    info.operator_fee_constant = 0;
    var auth = try primitives.Authorization.createAuthorization(testing.allocator, 8453, delegate, 3, key);
    auth.v -= 27;
    const auths = [_]executor.Authorization{auth};
    const tx = executor.Transaction{
        .sender = sponsor,
        .envelope = &.{ 0x04, 0x0c },
        .gas_limit = 200_000,
        .fee = .{ .dynamic = .{ .max_fee_per_gas = 0, .max_priority_fee_per_gas = 0 } },
        .base_fee = 0,
        .value = 7,
        .to = authority,
        .authorization_list = &auths,
    };
    const result = try executor.executeBase(&host, info, 8453, schedule.isthmus, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
    try testing.expectEqual(deposits.Outcome.revert, result.outcome);
    // 21,000 + 25,000 + 3 + 3 + 22,100 + 3 + 3 = 68,112. The authorization refund
    // applies to a reverted transaction too.
    try testing.expectEqual(@as(u64, 68_112 - 12_500), result.gas_used);
    const account = (try db.get_account(authority.bytes)).?;
    try testing.expectEqual(@as(u64, 4), account.nonce);
    try testing.expectEqual(delegate, account.delegated_address.?);
    // The frame's storage write and value transfer are undone.
    try testing.expectEqual(@as(u256, 0), try db.get_storage(authority.bytes, 0));
    try testing.expectEqual(@as(u256, 1), account.balance);
    try testing.expectEqual(ETHER, try db.get_balance(sponsor.bytes));
    try testing.expectEqual(@as(u64, 1), try db.get_nonce(sponsor.bytes));
    try testing.expectEqual(@as(usize, 0), db.snapshot_depth());
}

test "EIP-7702 type-4 is rejected before Isthmus without touching state" {
    const crypto = primitives.crypto.Crypto;
    const schedule = hardforks.MAINNET;
    const key: crypto.PrivateKey = @as([32]u8, @splat(0x42));
    const authority = (try crypto.unaudited_getPublicKey(key)).toAddress();
    const sponsor = Address.fromU256(0xA11CE);
    const delegate = Address.fromU256(0xDE1E);
    var auth = try primitives.Authorization.createAuthorization(testing.allocator, 8453, delegate, 0, key);
    auth.v -= 27;
    const auths = [_]executor.Authorization{auth};
    const cases = [_]struct { timestamp: u64, spec: OpSpecId }{
        .{ .timestamp = schedule.ecotone, .spec = .ECOTONE },
        .{ .timestamp = schedule.fjord, .spec = .FJORD },
        .{ .timestamp = schedule.granite, .spec = .GRANITE },
        .{ .timestamp = schedule.holocene, .spec = .HOLOCENE },
    };
    for (cases) |case| {
        try testing.expectEqual(case.spec, try schedule.specAt(case.timestamp));
        var db = Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(sponsor.bytes, .{ .balance = ETHER, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 0 });
        var host = Host.init(testing.allocator, &db, .{ .chain_id = 8453, .number = 1, .timestamp = case.timestamp, .gas_limit = 30_000_000, .coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS, .base_fee = 0 });
        defer host.deinit();
        const tx = executor.Transaction{
            .sender = sponsor,
            .envelope = &.{ 0x04, 0x0d },
            .gas_limit = 200_000,
            .fee = .{ .dynamic = .{ .max_fee_per_gas = 0, .max_priority_fee_per_gas = 0 } },
            .base_fee = 0,
            .to = authority,
            .authorization_list = &auths,
        };
        try testing.expectError(error.TxTypeNotSupported, executor.executeBase(&host, L1BlockInfo.empty(), 8453, case.timestamp, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
        try testing.expect(!db.account_exists(authority.bytes));
        try testing.expectEqual(@as(u64, 0), try db.get_nonce(sponsor.bytes));
        try testing.expectEqual(@as(usize, 0), db.snapshot_depth());
    }
}

test "EIP-3860 init code limit applies from Canyon only; calldata has no size cap" {
    const sender = Address.fromU256(0xA11CE);
    // 49,153 zero bytes: STOP at once, deploying empty code.
    const oversized = try testing.allocator.alloc(u8, 49_153);
    defer testing.allocator.free(oversized);
    @memset(oversized, 0);
    const cases = [_]struct { spec: OpSpecId, len: usize, gas_used: ?u64 }{
        // Regolith (Ethereum MERGE) has no init code limit or word cost:
        // 53,000 + 49,153 * 4.
        .{ .spec = .REGOLITH, .len = 49_153, .gas_used = 249_612 },
        .{ .spec = .CANYON, .len = 49_153, .gas_used = null },
        // Jovian (Prague) checks the limit, not just the 21,000 + 49,153 * 10 floor.
        .{ .spec = .JOVIAN, .len = 49_153, .gas_used = null },
        // At the limit Canyon pays the EIP-3860 words: 53,000 + 49,152 * 4 + 1,536 * 2.
        .{ .spec = .CANYON, .len = 49_152, .gas_used = 252_680 },
    };
    for (cases) |case| {
        var db = Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(sender.bytes, .{ .balance = ETHER, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 0 });
        var host = Host.init(testing.allocator, &db, .{ .chain_id = 10, .number = 1, .timestamp = 1, .gas_limit = 30_000_000, .coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS, .base_fee = 0 });
        defer host.deinit();
        var info = L1BlockInfo.empty();
        info.operator_fee_scalar = 0;
        info.operator_fee_constant = 0;
        const tx = executor.Transaction{ .sender = sender, .envelope = &.{ 0x01, 0x0e }, .gas_limit = 600_000, .base_fee = 0, .is_call = false, .input = oversized[0..case.len] };
        if (case.gas_used) |gas_used| {
            const result = try executor.execute(&host, info, case.spec, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
            try testing.expectEqual(deposits.Outcome.success, result.outcome);
            try testing.expectEqual(gas_used, result.gas_used);
            try testing.expectEqual(@as(u64, 1), try db.get_nonce(sender.bytes));
        } else {
            try testing.expectError(error.CreateInitCodeSizeLimit, executor.execute(&host, info, case.spec, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
            try testing.expectEqual(@as(u64, 0), try db.get_nonce(sender.bytes));
        }
        try testing.expectEqual(@as(usize, 0), db.snapshot_depth());
    }

    // Calldata above 4 MiB executes: 21,000 + 4,194,305 * 4 (no EIP-7623 floor on Ecotone).
    const calldata = try testing.allocator.alloc(u8, 4 * 1024 * 1024 + 1);
    defer testing.allocator.free(calldata);
    @memset(calldata, 0);
    var db = Database.init(testing.allocator);
    defer db.deinit();
    try db.set_account(sender.bytes, .{ .balance = ETHER, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 0 });
    var host = Host.init(testing.allocator, &db, .{ .chain_id = 10, .number = 1, .timestamp = 1, .gas_limit = 30_000_000, .coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS, .base_fee = 0 });
    defer host.deinit();
    const tx = executor.Transaction{ .sender = sender, .envelope = &.{ 0x01, 0x0f }, .gas_limit = 17_000_000, .base_fee = 0, .to = Address.fromU256(0xB0B), .input = calldata };
    const result = try executor.execute(&host, L1BlockInfo.empty(), .ECOTONE, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
    try testing.expectEqual(deposits.Outcome.success, result.outcome);
    try testing.expectEqual(@as(u64, 21_000 + 4_194_305 * 4), result.gas_used);
}

test "BLOBBASEFEE defaults to 1 from Ecotone on; an explicit block value wins" {
    const schedule = hardforks.MAINNET;
    // BLOBBASEFEE PUSH1 0 SSTORE STOP
    const code = [_]u8{ 0x4a, 0x60, 0x00, 0x55, 0x00 };
    const target = Address.fromU256(0xC0DE);
    const sender = Address.fromU256(0xA11CE);
    const cases = [_]struct { timestamp: u64, spec: OpSpecId, block_value: ?u64, expected: u256 }{
        .{ .timestamp = schedule.ecotone, .spec = .ECOTONE, .block_value = null, .expected = 1 },
        .{ .timestamp = schedule.fjord, .spec = .FJORD, .block_value = null, .expected = 1 },
        .{ .timestamp = schedule.isthmus, .spec = .ISTHMUS, .block_value = null, .expected = 1 },
        .{ .timestamp = schedule.jovian, .spec = .JOVIAN, .block_value = null, .expected = 1 },
        .{ .timestamp = schedule.jovian, .spec = .JOVIAN, .block_value = 7, .expected = 7 },
    };
    for (cases) |case| {
        try testing.expectEqual(case.spec, try schedule.specAt(case.timestamp));
        var db = Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(target.bytes, .{ .balance = 0, .code_hash = try db.set_code(&code), .storage_root = @as([32]u8, @splat(0)), .nonce = 1 });
        try db.set_account(sender.bytes, .{ .balance = ETHER, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 0 });
        var host = Host.init(testing.allocator, &db, .{ .chain_id = 8453, .number = 1, .timestamp = case.timestamp, .gas_limit = 30_000_000, .coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS, .base_fee = 0, .blob_base_fee = case.block_value });
        defer host.deinit();
        var info = L1BlockInfo.empty();
        info.operator_fee_scalar = 0;
        info.operator_fee_constant = 0;
        const tx = executor.Transaction{ .sender = sender, .envelope = &.{ 0x01, 0x10 }, .gas_limit = 100_000, .base_fee = 0, .to = target };
        const result = try executor.executeBase(&host, info, 8453, case.timestamp, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
        try testing.expectEqual(deposits.Outcome.success, result.outcome);
        try testing.expectEqual(case.expected, try db.get_storage(target.bytes, 0));
    }
}

test "a recursive call chain runs on the frame stack and keeps every frame's write" {
    // SLOAD(0) + 1 -> SSTORE(0); CALL(GAS, ADDRESS, 0, 0, 0, 0, 0); STOP
    const code = [_]u8{
        0x60, 0x00, 0x54, 0x60, 0x01, 0x01, 0x60, 0x00, 0x55,
        0x60, 0x00, 0x80, 0x80, 0x80, 0x80, 0x30, 0x5a, 0xf1,
        0x00,
    };
    const target = Address.fromU256(0xC0DE);
    const sender = Address.fromU256(0xA11CE);
    var db = Database.init(testing.allocator);
    defer db.deinit();
    try db.set_account(target.bytes, .{ .balance = 0, .code_hash = try db.set_code(&code), .storage_root = @as([32]u8, @splat(0)), .nonce = 1 });
    try db.set_account(sender.bytes, .{ .balance = ETHER, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .nonce = 0 });
    var host = Host.init(testing.allocator, &db, .{ .chain_id = 10, .number = 1, .timestamp = 1, .gas_limit = 30_000_000, .coinbase = constants.SEQUENCER_FEE_VAULT_ADDRESS, .base_fee = 0 });
    defer host.deinit();
    // Each frame reserves its EVM memory buffer; the Debug test allocator commits all
    // of it, so the chain is kept short here.
    const tx = executor.Transaction{ .sender = sender, .envelope = &.{ 0x01, 0x11 }, .gas_limit = 60_000, .base_fee = 0, .to = target };
    const result = try executor.execute(&host, L1BlockInfo.empty(), .ECOTONE, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
    try testing.expectEqual(deposits.Outcome.success, result.outcome);
    // EIP-150 forwards 63/64 of the gas at each level; 60,000 gas runs out after
    // 32 frames, each of which incremented the counter.
    try testing.expectEqual(@as(u256, 32), try db.get_storage(target.bytes, 0));
    try testing.expectEqual(@as(usize, 0), db.snapshot_depth());
}

test "touched empty fee recipient is pruned only after OP fee settlement" {
    const timestamp = hardforks.MAINNET.ecotone;
    const miner = constants.SEQUENCER_FEE_VAULT_ADDRESS;
    const sender = Address.fromU256(256);
    for ([_]u64{ 0, 1 }) |tip| {
        var db = Database.init(testing.allocator);
        defer db.deinit();
        try db.set_balance(sender.bytes, ETHER);
        try db.set_account(miner.bytes, Account.zero());
        try db.set_storage(miner.bytes, 1, 17);
        var host = Host.init(testing.allocator, &db, .{ .chain_id = 8453, .number = 1, .timestamp = timestamp, .gas_limit = 1_000_000, .coinbase = miner, .base_fee = 0 });
        defer host.deinit();
        const tx = executor.Transaction{ .sender = sender, .envelope = &.{1}, .gas_limit = 21_000, .fee = .{ .legacy = tip }, .base_fee = 0, .to = miner };
        const result = try executor.executeBase(&host, L1BlockInfo.empty(), 8453, timestamp, tx, miner);
        try testing.expectEqual(deposits.Outcome.success, result.outcome);
        try testing.expectEqual(tip != 0, db.account_exists(miner.bytes));
        try testing.expectEqual(@as(u256, 21_000) * tip, try db.get_balance(miner.bytes));
        try testing.expectEqual(@as(u256, if (tip == 0) 0 else 17), try db.get_storage(miner.bytes, 1));
    }
}
