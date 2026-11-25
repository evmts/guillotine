//! C ABI for the Guillotine EVM. The matching header is `sdks/c/include/guillotine.h`;
//! the Bun SDK binds the same symbols in `sdks/typescript/src/native/library.ts`.
//!
//! Handle model:
//! - Every `guillotine_evm_create*` call allocates a fresh `Database` and EVM inside a
//!   tagged `HandleBox`. Nothing is pooled, so no state crosses handles.
//! - A handle is an opaque token, not an address: the Nth handle created by the process
//!   is the value N (1, 2, 3, ...) and a value is never issued twice, so a destroyed
//!   handle can never alias a newer one even when the allocator reuses its memory.
//! - Live handles are kept in a registry keyed by token. Every entry point looks the
//!   token up before touching anything, so NULL, foreign, or destroyed handles fail with
//!   an error instead of being dereferenced. Destroying a handle twice is reported, not
//!   a double free.
//! - Entry points dispatch on the box tag, so any handle works with any function
//!   (the `*_tracing` variants are kept as aliases for existing callers).
//! - All memory handed to the caller comes from `std.heap.c_allocator` and may be freed
//!   from any thread with the matching `guillotine_free_*` function.
//! - A single handle must not be used by two threads at the same time.
//!
//! Errors: functions return NULL/false and record a message readable with
//! `guillotine_get_last_error()` (thread-local, valid until the next failing call on
//! the same thread). `EvmResult.error_message` is an owned copy freed with the result.

const std = @import("std");
const builtin = @import("builtin");
const evm = @import("evm");

pub const std_options: std.Options = .{
    // Suppress debug logs.
    .log_level = .warn,
    // No per-thread alternate signal stack. The default reserves 262 KiB of
    // thread-local storage in every thread of the host process, which no longer fits
    // in a 256 KiB pthread stack.
    .signal_stack_size = null,
};

/// Read by src/tracer/tracer.zig: this library runs inside a host process, so a failed
/// tracer check is logged and counted, never a process abort, and no MinimalEvm sidecar
/// runs beside the EVM.
pub const guillotine_embedded = true;
const primitives = @import("voltaire");
const bytecode_c = @import("bytecode/bytecode_c.zig");
const log = std.log.scoped(.c_api);

const MainnetEvm = evm.MainnetEvm;
const TracerEvm = evm.MainnetEvmWithTracer;
const TestEvm = evm.TestEvm;
const Database = evm.Database;
const BlockInfo = evm.BlockInfo;
const TransactionContext = evm.TransactionContext;
const Account = evm.Account;
const Address = primitives.Address;

/// Every allocation returned across the ABI uses the process-wide C allocator, so a
/// result created on one thread can be freed on another.
const ffi_allocator = std.heap.c_allocator;

// ============================================================================
// ABI TYPES
// ============================================================================

/// Opaque handle for an EVM instance. Its value is a registry token (see the handle
/// model above), never a dereferenceable address.
pub const EvmHandle = opaque {};

/// Log entry for FFI
pub const LogEntry = extern struct {
    address: [20]u8,
    topics: [*]const [32]u8,
    topics_len: usize,
    data: [*]const u8,
    data_len: usize,
};

/// Self-destruct record for FFI
pub const SelfDestructRecord = extern struct {
    contract: [20]u8,
    beneficiary: [20]u8,
};

/// Storage access record for FFI
pub const StorageAccessRecord = extern struct {
    address: [20]u8,
    slot: [32]u8, // u256 big-endian
};

/// Result structure for FFI. Free with `guillotine_free_result`.
pub const EvmResult = extern struct {
    success: bool,
    gas_left: u64,
    output: [*]const u8,
    output_len: usize,
    /// Owned NUL-terminated copy of the failure reason; "" when none.
    error_message: [*:0]const u8,
    logs: [*]const LogEntry,
    logs_len: usize,
    selfdestructs: [*]const SelfDestructRecord,
    selfdestructs_len: usize,
    accessed_addresses: [*]const [20]u8,
    accessed_addresses_len: usize,
    accessed_storage: [*]const StorageAccessRecord,
    accessed_storage_len: usize,
    created_address: [20]u8, // zero unless has_created_address
    has_created_address: bool,
    /// `{"structLogs":[...]}` for tracing handles; empty otherwise.
    trace_json: [*]const u8,
    trace_json_len: usize,
};

/// Call parameters for FFI
pub const CallParams = extern struct {
    caller: [20]u8,
    to: [20]u8,
    value: [32]u8, // u256 big-endian
    input: ?[*]const u8,
    input_len: usize,
    gas: u64,
    call_type: u8, // 0=CALL, 1=CALLCODE, 2=DELEGATECALL, 3=STATICCALL, 4=CREATE, 5=CREATE2
    salt: [32]u8, // For CREATE2
};

/// Block info for FFI
pub const BlockInfoFFI = extern struct {
    number: u64,
    timestamp: u64,
    gas_limit: u64,
    coinbase: [20]u8,
    base_fee: u64,
    chain_id: u64,
    difficulty: u64,
    prev_randao: [32]u8,
};

/// EVM configuration selected at handle creation. Passed across the ABI as a raw u8.
pub const EvmConfiguration = enum(u8) {
    mainnet = 0,
    mainnet_with_tracer = 1,
    test_mode = 2,
};

/// State dump structures for FFI. Free with `guillotine_free_state_dump`.
pub const AccountStateFFI = extern struct {
    address: [20]u8,
    balance: [32]u8,
    nonce: u64,
    code: [*]const u8,
    code_len: usize,
    storage_keys: [*]const [32]u8,
    storage_values: [*]const [32]u8,
    storage_count: usize,
};

pub const StateDumpFFI = extern struct {
    accounts: [*]const AccountStateFFI,
    accounts_count: usize,
};

// ============================================================================
// EMPTY POINTERS AND ERRORS
// ============================================================================

/// Backing store for every zero-length array returned across the ABI. Aligned for all
/// element types, never written, and never freed (lengths of 0 are never freed).
const empty_storage: [64]u8 align(64) = @splat(0);
/// Writable zero-length code buffer for `guillotine_get_code` (never written: length 0).
var empty_code: [1]u8 align(64) = .{0};
const empty_cstr: [*:0]const u8 = "";

fn emptyPtr(comptime T: type) [*]const T {
    comptime if (@alignOf(T) > 64) @compileError("empty_storage alignment too small for " ++ @typeName(T));
    return @ptrCast(&empty_storage);
}

threadlocal var last_error_z: [257]u8 = @as([257]u8, @splat(0));

/// Record a message for `guillotine_get_last_error`. Messages longer than 256 bytes
/// are truncated and end in "...".
fn setError(comptime fmt: []const u8, args: anytype) void {
    const body = last_error_z[0 .. last_error_z.len - 1];
    var w: std.Io.Writer = .fixed(body);
    var end: usize = undefined;
    if (w.print(fmt, args)) |_| {
        end = w.end;
    } else |err| switch (err) {
        error.WriteFailed => {
            @memcpy(body[body.len - 3 ..], "...");
            end = body.len;
        },
    }
    last_error_z[end] = 0;
}

/// Return the input bytes, or null (with an error set) when `ptr` is NULL but `len` is not 0.
fn inputSlice(ptr: ?[*]const u8, len: usize, comptime what: []const u8) ?[]const u8 {
    if (len == 0) return &.{};
    const p = ptr orelse {
        setError(what ++ " is NULL but its length is {d}", .{len});
        return null;
    };
    return p[0..len];
}

// ============================================================================
// HANDLE REGISTRY
// ============================================================================

/// Tagged owner of one EVM instance. The active tag is the handle's configuration, and
/// every entry point dispatches on it, so a handle is never reinterpreted as another
/// EVM type.
const HandleBox = union(EvmConfiguration) {
    mainnet: *MainnetEvm,
    mainnet_with_tracer: *TracerEvm,
    test_mode: *TestEvm,
};

var registry_mutex: std.Io.Mutex = .init;
var initialized: bool = false;
/// Live handles by token. Lookups never dereference a caller-supplied value.
var handle_registry: std.AutoHashMapUnmanaged(usize, *HandleBox) = .empty;
/// Token of the next handle. Starts at 1 (0 is NULL) and only ever grows, across
/// `guillotine_cleanup` and `guillotine_init` too.
var next_handle_id: usize = 1;

fn lockRegistry() void {
    std.Io.Threaded.mutexLockUncancelable(&registry_mutex);
}

fn unlockRegistry() void {
    std.Io.Threaded.mutexUnlock(&registry_mutex);
}

/// Look up a live handle. Sets an error and returns null for NULL, unknown, or destroyed handles.
fn resolve(handle: ?*EvmHandle) ?*HandleBox {
    const h = handle orelse {
        setError("EVM handle is NULL", .{});
        return null;
    };
    lockRegistry();
    defer unlockRegistry();
    return handle_registry.get(@intFromPtr(h)) orelse {
        setError("Invalid or destroyed EVM handle", .{});
        return null;
    };
}

fn toBlockInfo(info: *const BlockInfoFFI) BlockInfo {
    return .{
        .number = info.number,
        .timestamp = info.timestamp,
        .gas_limit = info.gas_limit,
        .coinbase = Address{ .bytes = info.coinbase },
        .base_fee = info.base_fee,
        .difficulty = info.difficulty,
        .prev_randao = info.prev_randao,
        .chain_id = info.chain_id,
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };
}

/// The width of `TransactionContext.chain_id` (the CHAINID opcode source). Chain ids
/// that do not fit are rejected rather than truncated.
const ChainId = @FieldType(TransactionContext, "chain_id");

fn EvmOf(comptime tag: EvmConfiguration) type {
    return std.meta.Child(@FieldType(HandleBox, @tagName(tag)));
}

/// Allocate a fresh database and EVM for `tag`. On error nothing leaks.
fn createBox(comptime tag: EvmConfiguration, info: *const BlockInfoFFI) !*HandleBox {
    const E = EvmOf(tag);
    const chain_id = std.math.cast(ChainId, info.chain_id) orelse return error.ChainIdOutOfRange;

    // The KZG point evaluation precompile (0x0A) needs the trusted setup. Loading it is
    // idempotent and thread-safe.
    try evm.kzg_setup.init();

    const db = try ffi_allocator.create(Database);
    errdefer ffi_allocator.destroy(db);
    db.* = Database.init(ffi_allocator);
    errdefer db.deinit();

    const instance = try ffi_allocator.create(E);
    errdefer ffi_allocator.destroy(instance);
    instance.* = try E.init(ffi_allocator, db, toBlockInfo(info), .{
        .gas_limit = info.gas_limit,
        .coinbase = Address{ .bytes = info.coinbase },
        .chain_id = chain_id,
        .blob_versioned_hashes = &.{},
        .blob_base_fee = 0,
    }, 0, Address.ZERO_ADDRESS);
    errdefer instance.deinit();
    // `Evm.init` returns by value, so the arena's tracer pointer still refers to init's
    // stack frame. Point it at the heap copy before the arena can call back into it.
    instance.call_arena.tracer = @ptrCast(&instance.tracer);
    // Also set at run time, for builds whose root file is not this one (tests).
    instance.tracer.embedded = true;

    const box = try ffi_allocator.create(HandleBox);
    box.* = @unionInit(HandleBox, @tagName(tag), instance);
    return box;
}

/// Native stack for building an EVM. `Evm.init` returns the EVM by value, and loading
/// the KZG trusted setup is deep, so creation needs far more stack than a host thread
/// may have (a 512 KiB pthread overflows in Debug builds).
const create_stack_size = 16 * 1024 * 1024;

/// Run `createBox` on a thread with `create_stack_size` of stack and wait for it, so
/// handle creation works from any caller stack. The EVM is built directly in heap
/// memory by that thread; only a pointer comes back.
fn createBoxOnLargeStack(comptime tag: EvmConfiguration, info: *const BlockInfoFFI) !*HandleBox {
    // A target without threads has no other stack to move to.
    if (comptime builtin.single_threaded or builtin.target.cpu.arch.isWasm()) return createBox(tag, info);

    const Job = struct {
        info: *const BlockInfoFFI,
        result: anyerror!*HandleBox = error.CreateDidNotRun,
        fn run(job: *@This()) void {
            job.result = createBox(tag, job.info);
        }
    };
    var job = Job{ .info = info };
    const thread = try std.Thread.spawn(.{ .stack_size = create_stack_size }, Job.run, .{&job});
    thread.join();
    return job.result;
}

fn destroyBox(box: *HandleBox) void {
    switch (box.*) {
        inline else => |instance| {
            const db = instance.database;
            instance.deinit();
            db.deinit();
            ffi_allocator.destroy(db);
            ffi_allocator.destroy(instance);
        },
    }
    ffi_allocator.destroy(box);
}

fn createHandle(block_info: ?*const BlockInfoFFI, config: EvmConfiguration) ?*EvmHandle {
    const info = block_info orelse {
        setError("block_info is NULL", .{});
        return null;
    };
    const box = switch (config) {
        inline else => |tag| createBoxOnLargeStack(tag, info),
    } catch |err| {
        switch (err) {
            error.ChainIdOutOfRange => setError("chain_id {d} exceeds the supported maximum {d}", .{ info.chain_id, std.math.maxInt(ChainId) }),
            else => setError("Failed to create EVM: {s}", .{@errorName(err)}),
        }
        return null;
    };

    lockRegistry();
    defer unlockRegistry();
    if (!initialized) {
        destroyBox(box);
        setError("FFI not initialized. Call guillotine_init() first", .{});
        return null;
    }
    const id = next_handle_id;
    if (id == std.math.maxInt(usize)) {
        destroyBox(box);
        setError("EVM handle tokens are exhausted", .{});
        return null;
    }
    handle_registry.put(ffi_allocator, id, box) catch |err| {
        destroyBox(box);
        setError("Failed to register handle: {s}", .{@errorName(err)});
        return null;
    };
    next_handle_id = id + 1;
    return @ptrFromInt(id);
}

// ============================================================================
// LIFECYCLE
// ============================================================================

/// Enable handle creation. Idempotent and infallible.
export fn guillotine_init() void {
    lockRegistry();
    defer unlockRegistry();
    initialized = true;
}

/// Destroy every live handle and disable handle creation until the next `guillotine_init`.
/// Handles used after cleanup are rejected as invalid.
export fn guillotine_cleanup() void {
    lockRegistry();
    defer unlockRegistry();
    var it = handle_registry.valueIterator();
    while (it.next()) |box| destroyBox(box.*);
    handle_registry.deinit(ffi_allocator);
    handle_registry = .empty;
    initialized = false;
}

/// Create an EVM with configuration 0 (mainnet), 1 (mainnet with tracer), or 2 (test mode).
export fn guillotine_evm_create_with_config(block_info: ?*const BlockInfoFFI, config: u8) ?*EvmHandle {
    const tag = std.enums.fromInt(EvmConfiguration, config) orelse {
        setError("Invalid EVM configuration {d} (expected 0, 1, or 2)", .{config});
        return null;
    };
    return createHandle(block_info, tag);
}

export fn guillotine_evm_create(block_info: ?*const BlockInfoFFI) ?*EvmHandle {
    return createHandle(block_info, .mainnet);
}

export fn guillotine_evm_create_mainnet(block_info: ?*const BlockInfoFFI) ?*EvmHandle {
    return createHandle(block_info, .mainnet);
}

export fn guillotine_evm_create_tracing(block_info: ?*const BlockInfoFFI) ?*EvmHandle {
    return createHandle(block_info, .mainnet_with_tracer);
}

export fn guillotine_evm_create_test(block_info: ?*const BlockInfoFFI) ?*EvmHandle {
    return createHandle(block_info, .test_mode);
}

/// Free a handle and all of its state. NULL is a no-op; an unknown or already destroyed
/// handle is reported through `guillotine_get_last_error` and otherwise ignored.
export fn guillotine_evm_destroy(handle: ?*EvmHandle) void {
    const h = handle orelse return;
    const box = blk: {
        lockRegistry();
        defer unlockRegistry();
        const entry = handle_registry.fetchRemove(@intFromPtr(h)) orelse {
            setError("guillotine_evm_destroy: invalid or already destroyed handle", .{});
            return;
        };
        break :blk entry.value;
    };
    destroyBox(box);
}

/// Alias of `guillotine_evm_destroy`.
export fn guillotine_evm_destroy_tracing(handle: ?*EvmHandle) void {
    guillotine_evm_destroy(handle);
}

// ============================================================================
// STATE ACCESS
// ============================================================================

const AccountEdit = union(enum) {
    balance: u256,
    nonce: u64,
    code: []const u8,
};

fn editAccount(instance: anytype, address: [20]u8, edit: AccountEdit) !void {
    var account = try instance.database.get_account(address) orelse Account.zero();
    switch (edit) {
        .balance => |b| account.balance = b,
        .nonce => |n| account.nonce = n,
        .code => |c| account.code_hash = try instance.database.set_code(c),
    }
    try instance.database.set_account(address, account);
    // Track the address so guillotine_dump_state reports it.
    try instance.touched_addresses.put(Address{ .bytes = address }, {});
}

fn applyEdit(handle: ?*EvmHandle, address: ?*const [20]u8, edit: AccountEdit) bool {
    const box = resolve(handle) orelse return false;
    const addr = address orelse {
        setError("address is NULL", .{});
        return false;
    };
    switch (box.*) {
        inline else => |instance| editAccount(instance, addr.*, edit) catch |err| {
            setError("Failed to update account {s}: {s}", .{ @tagName(edit), @errorName(err) });
            return false;
        },
    }
    return true;
}

export fn guillotine_set_balance(handle: ?*EvmHandle, address: ?*const [20]u8, balance: ?*const [32]u8) bool {
    const b = balance orelse {
        setError("balance is NULL", .{});
        return false;
    };
    return applyEdit(handle, address, .{ .balance = std.mem.readInt(u256, b, .big) });
}

export fn guillotine_set_balance_tracing(handle: ?*EvmHandle, address: ?*const [20]u8, balance: ?*const [32]u8) bool {
    return guillotine_set_balance(handle, address, balance);
}

export fn guillotine_set_nonce(handle: ?*EvmHandle, address: ?*const [20]u8, nonce: u64) bool {
    return applyEdit(handle, address, .{ .nonce = nonce });
}

export fn guillotine_set_nonce_tracing(handle: ?*EvmHandle, address: ?*const [20]u8, nonce: u64) bool {
    return guillotine_set_nonce(handle, address, nonce);
}

export fn guillotine_set_code(handle: ?*EvmHandle, address: ?*const [20]u8, code: ?[*]const u8, code_len: usize) bool {
    const slice = inputSlice(code, code_len, "code") orelse return false;
    return applyEdit(handle, address, .{ .code = slice });
}

export fn guillotine_set_code_tracing(handle: ?*EvmHandle, address: ?*const [20]u8, code: ?[*]const u8, code_len: usize) bool {
    return guillotine_set_code(handle, address, code, code_len);
}

export fn guillotine_get_balance(handle: ?*EvmHandle, address: ?*const [20]u8, balance_out: ?*[32]u8) bool {
    const box = resolve(handle) orelse return false;
    const addr = address orelse {
        setError("address is NULL", .{});
        return false;
    };
    const out = balance_out orelse {
        setError("balance_out is NULL", .{});
        return false;
    };
    const balance = switch (box.*) {
        inline else => |instance| instance.database.get_balance(addr.*),
    } catch |err| {
        setError("Failed to get balance: {s}", .{@errorName(err)});
        return false;
    };
    std.mem.writeInt(u256, out, balance, .big);
    return true;
}

/// Code stored under `address` itself: for an EIP-7702 delegated account that is the
/// 23-byte delegation designator, not the delegate's code. Accounts that do not exist
/// or have no code have empty code.
fn storedCode(instance: anytype, address: [20]u8) Database.Error![]const u8 {
    const account = try instance.database.get_account(address) orelse return &.{};
    if (!Account.is_code_hash_present(account.code_hash)) return &.{};
    return instance.database.get_code(account.code_hash);
}

/// Copy the code stored under an account (what EXTCODECOPY reads; see `storedCode`).
/// Free a non-empty result with `guillotine_free_code`.
export fn guillotine_get_code(handle: ?*EvmHandle, address: ?*const [20]u8, code_out: ?*[*]u8, len_out: ?*usize) bool {
    const box = resolve(handle) orelse return false;
    const addr = address orelse {
        setError("address is NULL", .{});
        return false;
    };
    const out = code_out orelse {
        setError("code_out is NULL", .{});
        return false;
    };
    const len = len_out orelse {
        setError("len_out is NULL", .{});
        return false;
    };
    const code: []const u8 = switch (box.*) {
        inline else => |instance| storedCode(instance, addr.*),
    } catch |err| {
        setError("Failed to get code: {s}", .{@errorName(err)});
        return false;
    };
    if (code.len == 0) {
        out.* = &empty_code;
        len.* = 0;
        return true;
    }
    const copy = ffi_allocator.dupe(u8, code) catch |err| {
        setError("Failed to allocate code buffer: {s}", .{@errorName(err)});
        return false;
    };
    out.* = copy.ptr;
    len.* = copy.len;
    return true;
}

export fn guillotine_free_code(code: ?[*]u8, len: usize) void {
    if (len == 0) return;
    const p = code orelse return;
    ffi_allocator.free(p[0..len]);
}

fn putStorage(instance: anytype, address: [20]u8, key: u256, value: u256) !void {
    try instance.database.set_storage(address, key, value);
    try instance.touched_addresses.put(Address{ .bytes = address }, {});
}

export fn guillotine_set_storage(handle: ?*EvmHandle, address: ?*const [20]u8, key: ?*const [32]u8, value: ?*const [32]u8) bool {
    const box = resolve(handle) orelse return false;
    if (address == null or key == null or value == null) {
        setError("address, key, and value must not be NULL", .{});
        return false;
    }
    const k = std.mem.readInt(u256, key.?, .big);
    const v = std.mem.readInt(u256, value.?, .big);
    switch (box.*) {
        inline else => |instance| putStorage(instance, address.?.*, k, v) catch |err| {
            setError("Failed to set storage: {s}", .{@errorName(err)});
            return false;
        },
    }
    return true;
}

export fn guillotine_get_storage(handle: ?*EvmHandle, address: ?*const [20]u8, key: ?*const [32]u8, value_out: ?*[32]u8) bool {
    const box = resolve(handle) orelse return false;
    if (address == null or key == null or value_out == null) {
        setError("address, key, and value_out must not be NULL", .{});
        return false;
    }
    const k = std.mem.readInt(u256, key.?, .big);
    const value = switch (box.*) {
        inline else => |instance| instance.database.get_storage(address.?.*, k),
    } catch |err| {
        setError("Failed to get storage: {s}", .{@errorName(err)});
        return false;
    };
    std.mem.writeInt(u256, value_out.?, value, .big);
    return true;
}

// ============================================================================
// EXECUTION
// ============================================================================

fn buildCallParams(comptime E: type, p: *const CallParams, input: []const u8) ?E.CallParams {
    const caller = Address{ .bytes = p.caller };
    const to = Address{ .bytes = p.to };
    const value = std.mem.readInt(u256, &p.value, .big);
    return switch (p.call_type) {
        0 => .{ .call = .{ .caller = caller, .to = to, .value = value, .input = input, .gas = p.gas } },
        1 => .{ .callcode = .{ .caller = caller, .to = to, .value = value, .input = input, .gas = p.gas } },
        2 => .{ .delegatecall = .{ .caller = caller, .to = to, .input = input, .gas = p.gas } },
        3 => .{ .staticcall = .{ .caller = caller, .to = to, .input = input, .gas = p.gas } },
        4 => .{ .create = .{ .caller = caller, .value = value, .init_code = input, .gas = p.gas } },
        5 => .{ .create2 = .{ .caller = caller, .value = value, .init_code = input, .salt = std.mem.readInt(u256, &p.salt, .big), .gas = p.gas } },
        else => {
            setError("Invalid call type: {d}", .{p.call_type});
            return null;
        },
    };
}

const ExecMode = enum { call, simulate };

fn execute(instance: anytype, p: *const CallParams, input: []const u8, mode: ExecMode, include_trace: bool) ?*EvmResult {
    const E = @TypeOf(instance.*);
    const call_params = buildCallParams(E, p, input) orelse return null;
    // `Evm.call` subtracts the intrinsic cost from the gas limit. An EVM built with gas
    // checks disabled (test mode) skips the comparison that makes the subtraction safe,
    // so a limit below the intrinsic cost is rejected here, with the result every other
    // configuration returns for it: failure with no gas left.
    const is_create = call_params.isCreate();
    const eips = evm.Eips{ .hardfork = instance.get_hardfork() };
    const initial_gas = eips.intrinsic_gas_cost(is_create) + eips.calldata_gas_cost(eips.tokens_in_calldata(input), is_create, input.len);
    if (p.gas < initial_gas) {
        var rejected = E.CallResult.failed(0);
        return convertCallResult(&rejected, false) catch |err| {
            setError("Failed to copy call result: {s}", .{@errorName(err)});
            return null;
        };
    }
    // The caller is the transaction origin for top-level calls and simulations alike
    // (ORIGIN opcode, nonce increment, fee accounting).
    instance.origin = Address{ .bytes = p.caller };
    var result = switch (mode) {
        .call => instance.call(call_params),
        .simulate => instance.simulate(call_params),
    };
    defer result.deinit(instance.allocator);
    return convertCallResult(&result, include_trace) catch |err| {
        setError("Failed to copy call result: {s}", .{@errorName(err)});
        return null;
    };
}

fn run(handle: ?*EvmHandle, params: ?*const CallParams, mode: ExecMode) ?*EvmResult {
    const box = resolve(handle) orelse return null;
    const p = params orelse {
        setError("params is NULL", .{});
        return null;
    };
    const input = inputSlice(p.input, p.input_len, "params.input") orelse return null;
    if (mode == .simulate and p.call_type != 0) {
        setError("Simulate only supports CALL type", .{});
        return null;
    }
    return switch (box.*) {
        .mainnet => |instance| execute(instance, p, input, mode, false),
        .mainnet_with_tracer => |instance| execute(instance, p, input, mode, true),
        .test_mode => |instance| execute(instance, p, input, mode, false),
    };
}

/// Execute a call and commit its state changes. Free the result with `guillotine_free_result`.
export fn guillotine_call(handle: ?*EvmHandle, params: ?*const CallParams) ?*EvmResult {
    return run(handle, params, .call);
}

/// Alias of `guillotine_call`; tracing handles always include `trace_json`.
export fn guillotine_call_tracing(handle: ?*EvmHandle, params: ?*const CallParams) ?*EvmResult {
    return run(handle, params, .call);
}

/// Execute a CALL without committing database changes.
export fn guillotine_simulate(handle: ?*EvmHandle, params: ?*const CallParams) ?*EvmResult {
    return run(handle, params, .simulate);
}

fn emptyResult() EvmResult {
    return .{
        .success = false,
        .gas_left = 0,
        .output = emptyPtr(u8),
        .output_len = 0,
        .error_message = empty_cstr,
        .logs = emptyPtr(LogEntry),
        .logs_len = 0,
        .selfdestructs = emptyPtr(SelfDestructRecord),
        .selfdestructs_len = 0,
        .accessed_addresses = emptyPtr([20]u8),
        .accessed_addresses_len = 0,
        .accessed_storage = emptyPtr(StorageAccessRecord),
        .accessed_storage_len = 0,
        .created_address = Address.ZERO_ADDRESS.bytes,
        .has_created_address = false,
        .trace_json = emptyPtr(u8),
        .trace_json_len = 0,
    };
}

/// Copy `items` with the C allocator, or return the shared empty pointer for none.
fn dupeOrEmpty(comptime T: type, items: []const T) ![*]const T {
    if (items.len == 0) return emptyPtr(T);
    return (try ffi_allocator.dupe(T, items)).ptr;
}

/// Owned NUL-terminated copy of `text`. Interior NULs become '?' so the C string
/// length equals the allocation length minus one (needed to free it exactly).
fn dupeCString(text: []const u8) ![*:0]const u8 {
    const copy = try ffi_allocator.allocSentinel(u8, text.len, 0);
    for (copy, text) |*dst, c| dst.* = if (c == 0) '?' else c;
    return copy.ptr;
}

/// Copy a CallResult into a C-allocated EvmResult. Every pointer is set before any
/// allocation that can fail, so `freeResult` releases a partial copy correctly.
fn convertCallResult(result: anytype, include_trace: bool) !*EvmResult {
    const out = try ffi_allocator.create(EvmResult);
    out.* = emptyResult();
    errdefer freeResult(out);

    out.success = result.success;
    out.gas_left = result.gas_left;
    if (result.error_info) |info| out.error_message = try dupeCString(info);

    out.output = try dupeOrEmpty(u8, result.output);
    out.output_len = result.output.len;

    if (result.logs.len > 0) {
        const logs = try ffi_allocator.alloc(LogEntry, result.logs.len);
        for (logs, result.logs) |*entry, item| entry.* = .{
            .address = item.address.bytes,
            .topics = emptyPtr([32]u8),
            .topics_len = 0,
            .data = emptyPtr(u8),
            .data_len = 0,
        };
        out.logs = logs.ptr;
        out.logs_len = logs.len;
        for (logs, result.logs) |*entry, item| {
            if (item.topics.len > 0) {
                const topics = try ffi_allocator.alloc([32]u8, item.topics.len);
                for (topics, item.topics) |*dst, topic| std.mem.writeInt(u256, dst, topic, .big);
                entry.topics = topics.ptr;
                entry.topics_len = topics.len;
            }
            entry.data = try dupeOrEmpty(u8, item.data);
            entry.data_len = item.data.len;
        }
    }

    if (result.selfdestructs.len > 0) {
        const records = try ffi_allocator.alloc(SelfDestructRecord, result.selfdestructs.len);
        for (records, result.selfdestructs) |*dst, sd| dst.* = .{ .contract = sd.contract.bytes, .beneficiary = sd.beneficiary.bytes };
        out.selfdestructs = records.ptr;
        out.selfdestructs_len = records.len;
    }

    if (result.accessed_addresses.len > 0) {
        const addresses = try ffi_allocator.alloc([20]u8, result.accessed_addresses.len);
        for (addresses, result.accessed_addresses) |*dst, a| dst.* = a.bytes;
        out.accessed_addresses = addresses.ptr;
        out.accessed_addresses_len = addresses.len;
    }

    if (result.accessed_storage.len > 0) {
        const slots = try ffi_allocator.alloc(StorageAccessRecord, result.accessed_storage.len);
        for (slots, result.accessed_storage) |*dst, access| {
            dst.address = access.address.bytes;
            std.mem.writeInt(u256, &dst.slot, access.slot, .big);
        }
        out.accessed_storage = slots.ptr;
        out.accessed_storage_len = slots.len;
    }

    if (result.created_address) |addr| {
        out.created_address = addr.bytes;
        out.has_created_address = true;
    }

    if (include_trace) {
        if (result.trace) |*trace| {
            const json = try writeTraceJson(ffi_allocator, trace);
            if (json.len == 0) {
                ffi_allocator.free(json);
            } else {
                out.trace_json = json.ptr;
                out.trace_json_len = json.len;
            }
        }
    }
    return out;
}

/// Serialize an execution trace as `{"structLogs":[...]}`. Caller owns the returned slice.
fn writeTraceJson(allocator: std.mem.Allocator, trace: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"structLogs\":[");
    for (trace.steps, 0..) |step, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"pc\":{d},\"op\":\"{s}\",\"gas\":{d},\"gasCost\":{d},\"depth\":{d},\"stack\":[", .{ step.pc, step.opcode_name, step.gas, step.gas_cost, step.depth });
        for (step.stack, 0..) |val, j| {
            if (j > 0) try w.writeAll(",");
            try w.print("\"0x{x}\"", .{val});
        }
        try w.print("],\"memSize\":{d}}}", .{step.mem_size});
    }
    try w.writeAll("]}");
    return out.toOwnedSlice();
}

fn freeResult(r: *EvmResult) void {
    if (r.error_message != empty_cstr) {
        const message = std.mem.span(r.error_message);
        ffi_allocator.free(message.ptr[0 .. message.len + 1]);
    }
    if (r.output_len > 0) ffi_allocator.free(r.output[0..r.output_len]);
    if (r.logs_len > 0) {
        for (r.logs[0..r.logs_len]) |entry| {
            if (entry.topics_len > 0) ffi_allocator.free(entry.topics[0..entry.topics_len]);
            if (entry.data_len > 0) ffi_allocator.free(entry.data[0..entry.data_len]);
        }
        ffi_allocator.free(r.logs[0..r.logs_len]);
    }
    if (r.selfdestructs_len > 0) ffi_allocator.free(r.selfdestructs[0..r.selfdestructs_len]);
    if (r.accessed_addresses_len > 0) ffi_allocator.free(r.accessed_addresses[0..r.accessed_addresses_len]);
    if (r.accessed_storage_len > 0) ffi_allocator.free(r.accessed_storage[0..r.accessed_storage_len]);
    if (r.trace_json_len > 0) ffi_allocator.free(r.trace_json[0..r.trace_json_len]);
    ffi_allocator.destroy(r);
}

/// Free a result from `guillotine_call*` or `guillotine_simulate`. NULL is a no-op.
/// Safe to call from any thread.
export fn guillotine_free_result(result: ?*EvmResult) void {
    freeResult(result orelse return);
}

/// Free a buffer of `len` bytes allocated by this library. NULL or len 0 is a no-op.
export fn guillotine_free_output(output: ?[*]u8, len: usize) void {
    if (len == 0) return;
    const p = output orelse return;
    ffi_allocator.free(p[0..len]);
}

/// Last error recorded on the calling thread; "" if none.
export fn guillotine_get_last_error() [*:0]const u8 {
    return @ptrCast(&last_error_z);
}

// ============================================================================
// STATE DUMP
// ============================================================================

fn parseDumpAddress(text: []const u8) ![20]u8 {
    if (text.len != 42 or !std.mem.eql(u8, text[0..2], "0x")) return error.InvalidStateDumpAddress;
    var bytes: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, text[2..]) catch return error.InvalidStateDumpAddress;
    return bytes;
}

fn freeStateDump(d: *StateDumpFFI) void {
    for (d.accounts[0..d.accounts_count]) |acc| {
        if (acc.code_len > 0) ffi_allocator.free(acc.code[0..acc.code_len]);
        if (acc.storage_count > 0) {
            ffi_allocator.free(acc.storage_keys[0..acc.storage_count]);
            ffi_allocator.free(acc.storage_values[0..acc.storage_count]);
        }
    }
    if (d.accounts_count > 0) ffi_allocator.free(d.accounts[0..d.accounts_count]);
    ffi_allocator.destroy(d);
}

/// Convert the EVM's state dump into C-allocated arrays. Each account entry is zeroed
/// before any fallible copy, so `freeStateDump` releases a partial dump correctly.
fn dumpState(instance: anytype) !*StateDumpFFI {
    var dump = try instance.dumpState(ffi_allocator);
    defer dump.deinit(ffi_allocator);

    const out = try ffi_allocator.create(StateDumpFFI);
    out.* = .{ .accounts = emptyPtr(AccountStateFFI), .accounts_count = 0 };
    errdefer freeStateDump(out);

    const count = dump.accounts.count();
    if (count == 0) return out;
    const accounts = try ffi_allocator.alloc(AccountStateFFI, count);
    for (accounts) |*acc| acc.* = .{
        .address = @splat(0),
        .balance = @splat(0),
        .nonce = 0,
        .code = emptyPtr(u8),
        .code_len = 0,
        .storage_keys = emptyPtr([32]u8),
        .storage_values = emptyPtr([32]u8),
        .storage_count = 0,
    };
    out.accounts = accounts.ptr;
    out.accounts_count = count;

    var it = dump.accounts.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        const acc = &accounts[i];
        acc.address = try parseDumpAddress(entry.key_ptr.*);
        std.mem.writeInt(u256, &acc.balance, entry.value_ptr.balance, .big);
        acc.nonce = entry.value_ptr.nonce;
        acc.code = try dupeOrEmpty(u8, entry.value_ptr.code);
        acc.code_len = entry.value_ptr.code.len;

        const slots = entry.value_ptr.storage.count();
        if (slots == 0) continue;
        const keys = try ffi_allocator.alloc([32]u8, slots);
        const values = ffi_allocator.alloc([32]u8, slots) catch |err| {
            ffi_allocator.free(keys);
            return err;
        };
        var storage_it = entry.value_ptr.storage.iterator();
        var s: usize = 0;
        while (storage_it.next()) |slot| : (s += 1) {
            std.mem.writeInt(u256, &keys[s], slot.key_ptr.*, .big);
            std.mem.writeInt(u256, &values[s], slot.value_ptr.*, .big);
        }
        acc.storage_keys = keys.ptr;
        acc.storage_values = values.ptr;
        acc.storage_count = slots;
    }
    return out;
}

/// Dump every touched, non-empty account. Free with `guillotine_free_state_dump`.
export fn guillotine_dump_state(handle: ?*EvmHandle) ?*StateDumpFFI {
    const box = resolve(handle) orelse return null;
    return switch (box.*) {
        inline else => |instance| dumpState(instance),
    } catch |err| {
        setError("Failed to dump state: {s}", .{@errorName(err)});
        return null;
    };
}

/// Alias of `guillotine_dump_state`.
export fn guillotine_dump_state_test(handle: ?*EvmHandle) ?*StateDumpFFI {
    return guillotine_dump_state(handle);
}

export fn guillotine_free_state_dump(dump: ?*StateDumpFFI) void {
    freeStateDump(dump orelse return);
}

// ============================================================================
// BYTECODE API
// ============================================================================

pub const EVM_BYTECODE_SUCCESS = bytecode_c.EVM_BYTECODE_SUCCESS;
pub const EVM_BYTECODE_ERROR_NULL_POINTER = bytecode_c.EVM_BYTECODE_ERROR_NULL_POINTER;
pub const EVM_BYTECODE_ERROR_INVALID_BYTECODE = bytecode_c.EVM_BYTECODE_ERROR_INVALID_BYTECODE;
pub const EVM_BYTECODE_ERROR_OUT_OF_MEMORY = bytecode_c.EVM_BYTECODE_ERROR_OUT_OF_MEMORY;
pub const EVM_BYTECODE_ERROR_BYTECODE_TOO_LARGE = bytecode_c.EVM_BYTECODE_ERROR_BYTECODE_TOO_LARGE;
pub const EVM_BYTECODE_ERROR_INVALID_OPCODE = bytecode_c.EVM_BYTECODE_ERROR_INVALID_OPCODE;
pub const EVM_BYTECODE_ERROR_OUT_OF_BOUNDS = bytecode_c.EVM_BYTECODE_ERROR_OUT_OF_BOUNDS;

const BytecodeHandle = bytecode_c.CBytecodeHandle;

/// Copy and validate bytecode. Returns NULL (with `guillotine_get_last_error` set) on
/// invalid input; nothing leaks on failure.
export fn evm_bytecode_create(data: ?[*]const u8, data_len: usize) ?*BytecodeHandle {
    const slice = inputSlice(data, data_len, "data") orelse return null;
    return bytecode_c.createHandle(ffi_allocator, slice) catch |err| {
        setError("Invalid bytecode: {s}", .{@errorName(err)});
        return null;
    };
}

export fn evm_bytecode_destroy(handle: ?*BytecodeHandle) void {
    bytecode_c.evm_bytecode_destroy(handle);
}

export fn evm_bytecode_get_length(handle: ?*const BytecodeHandle) usize {
    return bytecode_c.evm_bytecode_get_length(handle);
}

export fn evm_bytecode_get_runtime_data(handle: ?*const BytecodeHandle, buffer: ?[*]u8, buffer_len: usize) usize {
    if (buffer_len == 0) return 0;
    const out = buffer orelse return 0;
    return bytecode_c.evm_bytecode_get_runtime_data(handle, out, buffer_len);
}

export fn evm_bytecode_get_opcode_at(handle: ?*const BytecodeHandle, position: usize) u8 {
    return bytecode_c.evm_bytecode_get_opcode_at(handle, position);
}

pub const CBasicBlock = bytecode_c.CBasicBlock;
pub const CFusionInfo = bytecode_c.CFusionInfo;
pub const CFusionType = bytecode_c.CFusionType;
pub const CJumpFusion = bytecode_c.CJumpFusion;
pub const CAdvancedFusion = bytecode_c.CAdvancedFusion;
pub const CBytecodeAnalysis = bytecode_c.CBytecodeAnalysis;

export fn evm_bytecode_analyze(handle: ?*const BytecodeHandle, analysis_out: ?*CBytecodeAnalysis) c_int {
    const out = analysis_out orelse return EVM_BYTECODE_ERROR_NULL_POINTER;
    return bytecode_c.evm_bytecode_analyze_with_allocator(ffi_allocator, handle, out);
}

export fn evm_bytecode_free_analysis(analysis: ?*CBytecodeAnalysis) void {
    bytecode_c.evm_bytecode_free_analysis_with_allocator(ffi_allocator, analysis orelse return);
}

export fn evm_bytecode_opcode_name(opcode_value: u8) [*:0]const u8 {
    return bytecode_c.evm_bytecode_opcode_name(opcode_value);
}

pub const COpcodeInfo = bytecode_c.COpcodeInfo;

export fn evm_bytecode_opcode_info(opcode_value: u8) COpcodeInfo {
    return bytecode_c.evm_bytecode_opcode_info(opcode_value);
}

export fn evm_bytecode_is_valid_opcode(opcode_value: u8) c_int {
    return bytecode_c.evm_bytecode_is_valid_opcode(opcode_value);
}

export fn evm_bytecode_error_string(error_code: c_int) [*:0]const u8 {
    return bytecode_c.evm_bytecode_error_string(error_code);
}

/// Copy `text` NUL-terminated into `buffer`. Returns bytes written including the NUL,
/// or the required size when `buffer_len` is 0.
fn copyText(text: []const u8, buffer: ?[*]u8, buffer_len: usize) usize {
    if (buffer_len == 0) return text.len + 1;
    const out = buffer orelse return 0;
    const n = @min(text.len, buffer_len - 1);
    @memcpy(out[0..n], text[0..n]);
    out[n] = 0;
    return n + 1;
}

/// Pretty print bytecode. Returns 0 on invalid input.
export fn evm_bytecode_pretty_print(data: ?[*]const u8, data_len: usize, buffer: ?[*]u8, buffer_len: usize) usize {
    if (data_len == 0) return 0;
    const bytes = data orelse return 0;
    if (buffer_len > 0 and buffer == null) return 0;
    var empty: [1]u8 = undefined;
    return bytecode_c.evm_bytecode_pretty_print_with_allocator(ffi_allocator, bytes, data_len, buffer orelse &empty, buffer_len);
}

fn dispatchPrettyPrint(bytes: []const u8) ![]u8 {
    const BytecodeType = evm.Bytecode(evm.BytecodeConfig{});
    var bytecode = try BytecodeType.init(ffi_allocator, bytes);
    defer bytecode.deinit();

    const FrameType = MainnetEvm.Frame;
    const DispatchType = FrameType.Dispatch;
    var schedule = try DispatchType.DispatchSchedule.init(ffi_allocator, bytecode, &FrameType.opcode_handlers, null);
    defer schedule.deinit();

    return evm.dispatch_pretty_print.pretty_print(ffi_allocator, schedule.items, &bytecode, FrameType, DispatchType.Item);
}

/// Pretty print the dispatch schedule built from `data`. On failure the buffer receives
/// an "Error: ..." line naming the failure.
export fn evm_dispatch_pretty_print(data: ?[*]const u8, data_len: usize, buffer: ?[*]u8, buffer_len: usize) usize {
    if (data_len == 0) return copyText("Error: No bytecode provided\n", buffer, buffer_len);
    const bytes = data orelse return copyText("Error: bytecode pointer is NULL\n", buffer, buffer_len);
    const output = dispatchPrettyPrint(bytes[0..data_len]) catch |err| {
        setError("Error: Failed to build dispatch schedule: {s}\n", .{@errorName(err)});
        return copyText(std.mem.span(guillotine_get_last_error()), buffer, buffer_len);
    };
    defer ffi_allocator.free(output);
    return copyText(output, buffer, buffer_len);
}
