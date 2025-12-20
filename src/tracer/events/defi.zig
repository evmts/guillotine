const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address.Address;

/// Swap detection for DEX interactions
pub const SwapDetected = struct {
    dex_address: Address,
    token_in: Address,
    token_out: Address,
    amount_in: u256,
    amount_out: u256,
    caller: Address,
};

/// Flash loan detection
pub const FlashLoan = struct {
    lender: Address,
    borrower: Address,
    token: Address,
    amount: u256,
    fee: u256,
};

/// Arbitrage opportunity detection
pub const ArbitrageOpportunity = struct {
    path: []const Address,
    profit: u256,
    gas_cost: u64,
    block_number: u64,
};

/// Sandwich attack detection
pub const SandwichAttack = struct {
    attacker: Address,
    victim_tx: [32]u8,
    front_run_tx: [32]u8,
    back_run_tx: [32]u8,
    profit: u256,
};

/// Uniswap protocol detected
pub const UniswapDetected = struct {
    contract: Address,
    version: UniswapVersion,
    contract_type: UniswapContractType,
    token0: ?Address,
    token1: ?Address,
    fee_tier: ?u24,
    liquidity: ?u256,
};

/// Compound protocol detected
pub const CompoundDetected = struct {
    contract: Address,
    contract_type: CompoundContractType,
    underlying_asset: ?Address,
    comptroller: ?Address,
    interest_rate_model: ?Address,
};

/// Aave protocol detected
pub const AaveDetected = struct {
    contract: Address,
    version: AaveVersion,
    contract_type: AaveContractType,
    asset: ?Address,
    pool: ?Address,
    oracle: ?Address,
};

/// MakerDAO protocol detected
pub const MakerDetected = struct {
    contract: Address,
    contract_type: MakerContractType,
    ilk: ?[32]u8,
    gem: ?Address,
    vat: ?Address,
    join_adapter: ?Address,
};

/// Curve protocol detected
pub const CurveDetected = struct {
    contract: Address,
    pool_type: CurvePoolType,
    tokens: []const Address,
    amplification: ?u256,
    fee: ?u256,
    admin_fee: ?u256,
};

// Supporting types
pub const UniswapVersion = enum {
    v1,
    v2,
    v3,
    v4,
    unknown,
};

pub const UniswapContractType = enum {
    factory,
    router,
    pool,
    position_manager,
    swap_router,
    quoter,
    oracle,
    staker,
};

pub const CompoundContractType = enum {
    comptroller,
    ctoken,
    underlying,
    interest_rate_model,
    oracle,
    governance,
    timelock,
};

pub const AaveVersion = enum {
    v1,
    v2,
    v3,
    unknown,
};

pub const AaveContractType = enum {
    pool,
    pool_configurator,
    oracle,
    atoken,
    debt_token,
    interest_rate_strategy,
    collector,
    incentives,
};

pub const MakerContractType = enum {
    vat,
    dai,
    mkr,
    pot,
    jug,
    cat,
    dog,
    vow,
    flap,
    flop,
    flip,
    clip,
    join,
    proxy_registry,
    ds_proxy,
};

pub const CurvePoolType = enum {
    plain,
    lending,
    meta,
    crypto,
    tricrypto,
    factory,
    factory_meta,
    stable_ng,
};