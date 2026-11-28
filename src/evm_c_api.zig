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
//! - Threads. Any function may be called from any thread at any time. An entry point
//!   borrows its handle under the registry lock and holds the borrow until it returns;
//!   `guillotine_evm_destroy` and `guillotine_cleanup` take the handle out of the
//!   registry at once and free it only when no borrow is left, so a call in progress
//!   on another thread finishes on a live EVM. Calls on one handle run one at a time
//!   (an EVM is single-threaded); calls on different handles run in parallel.
//! - `guillotine_call` commits its state changes only together with its result: when
//!   the result cannot be allocated it returns NULL and the call is rolled back.
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
pub const bytecode_c = @import("bytecode/bytecode_c.zig");
const log = std.log.scoped(.c_api);

const MainnetEvm = evm.MainnetEvm;
const TracerEvm = evm.MainnetEvmWithTracer;
const TestEvm = evm.TestEvm;
const CallTracerEvm = evm.Evm(.{ .InspectorType = evm.CallTracer });
const HostCallbackEvm = evm.Evm(.{ .DatabaseType = evm.CallbackHostDb });
const ShanghaiEvm = evm.Evm(.{ .eips = .{ .hardfork = .SHANGHAI } });
const CancunEvm = evm.Evm(.{ .eips = .{ .hardfork = .CANCUN } });
const PragueEvm = evm.Evm(.{ .eips = .{ .hardfork = .PRAGUE } });
const Database = evm.Database;
const CallbackHostDb = evm.CallbackHostDb;
const GuillotineHostVTable = evm.GuillotineHostVTable;
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
    call_tracer = 3,
};

/// Full Ethereum transaction parameters for `guillotine_execute_tx`.
pub const TxParamsFFI = extern struct {
    tx_type: u8,
    from: [20]u8,
    to: [20]u8,
    has_to: bool,
    nonce: u64,
    has_nonce: bool,
    gas_limit: u64,
    value: [32]u8,
    gas_price: [32]u8,
    max_fee_per_gas: [32]u8,
    has_max_fee: bool,
    max_priority_fee_per_gas: [32]u8,
    input: ?[*]const u8,
    input_len: usize,
    disable_balance_check: bool,
};

/// One EIP-2930 access list entry for `guillotine_set_access_list`.
pub const AccessListEntryFFI = extern struct {
    address: [20]u8,
    /// `storage_keys_len` big-endian 32-byte keys; may be NULL when the length is 0.
    storage_keys: ?[*]const [32]u8,
    storage_keys_len: usize,
};

/// One EIP-7702 authorization tuple for `guillotine_set_authorization_list`.
pub const AuthorizationFFI = extern struct {
    chain_id: u64,
    address: [20]u8,
    nonce: u64,
    /// Signature parity: 0 or 1. Any other value makes the tuple invalid (skipped).
    y_parity: u8,
    r: [32]u8,
    s: [32]u8,
};

/// `guillotine_set_trace_limits` value that removes a bound.
pub const trace_unlimited: u64 = std.math.maxInt(u64);

/// Most ancestor hashes BLOCKHASH can reach.
pub const max_block_hashes: usize = 256;

// The structs above the extension types are frozen: a host compiled against an older
// header passes them by pointer, so no field may move. New data travels through the
// additive setters below instead. These are the LP64 layouts of every released header.
comptime {
    if (@sizeOf(usize) == 8) {
        const pins = .{
            .{ BlockInfoFFI, 104, "prev_randao", 72 },
            .{ CallParams, 136, "salt", 97 },
            .{ TxParamsFFI, 232, "disable_balance_check", 224 },
            .{ EvmResult, 144, "trace_json_len", 136 },
            .{ AccessListEntryFFI, 40, "storage_keys_len", 32 },
            .{ AuthorizationFFI, 112, "s", 73 },
        };
        for (pins) |pin| {
            if (@sizeOf(pin[0]) != pin[1] or @offsetOf(pin[0], pin[2]) != pin[3]) {
                @compileError("C ABI layout changed: " ++ @typeName(pin[0]));
            }
        }
    }
}

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

/// One registered handle: the concrete EVM instance and the bookkeeping that keeps it
/// alive while an entry point uses it.
///
/// Lifetime. An entry point borrows the box with `acquireHandle` and returns it with
/// `releaseHandle`. `borrows` counts the entry points between the two, and `retired`
/// is set once the handle has left the registry (`guillotine_evm_destroy`,
/// `guillotine_cleanup`). Both are read and written only under `registry_mutex`.
/// The box is torn down by whoever observes `retired` with `borrows == 0`: the
/// destroyer when nobody is inside, otherwise the last borrower on its way out. No
/// thread ever waits for another one to leave, so nothing can deadlock, and no
/// thread can free a box that another is still using.
///
/// Exclusion. An EVM is single-threaded. `use` serializes the entry points of one
/// handle, so concurrent calls on the same handle queue up instead of racing.
const HandleBox = struct {
    variant: Variant,
    call_tracer: ?*evm.CallTracer = null,
    ext: Extensions = .{},
    borrows: usize = 0,
    retired: bool = false,
    retired_next: ?*HandleBox = null,
    use: std.Io.Mutex = .init,

    const Variant = union(enum) {
        mainnet: *MainnetEvm,
        mainnet_with_tracer: *TracerEvm,
        test_mode: *TestEvm,
        call_tracer: *CallTracerEvm,
        host_callback: *HostCallbackEvm,
        shanghai: *ShanghaiEvm,
        cancun: *CancunEvm,
        prague: *PragueEvm,
    };
    const VariantTag = std.meta.Tag(Variant);
};

/// Owned copies of the block and transaction fields that the frozen structs
/// (`BlockInfoFFI`, `CallParams`, `TxParamsFFI`) have no room for. The EVM borrows
/// these slices, so they live in the handle and are freed with it or when replaced.
const Extensions = struct {
    /// Ancestor hashes, newest first: entry `i` is block `number - 1 - i`.
    block_hashes: [][32]u8 = &.{},
    blob_hashes: [][32]u8 = &.{},
    max_fee_per_blob_gas: ?u256 = null,
    /// The same list in the two shapes its consumers take (`Evm.call` reads the
    /// transaction context, `tx_runner` a `Transaction`). Both share the key slices.
    access_list: []evm.AccessListEntry = &.{},
    tx_access_list: []evm.tx_runner.AccessListEntry = &.{},
    authorizations: []evm.Authorization = &.{},

    fn freeAccessList(self: *Extensions) void {
        for (self.access_list) |entry| ffi_allocator.free(entry.storage_keys);
        ffi_allocator.free(self.access_list);
        ffi_allocator.free(self.tx_access_list);
        self.access_list = &.{};
        self.tx_access_list = &.{};
    }

    fn deinit(self: *Extensions) void {
        self.freeAccessList();
        ffi_allocator.free(self.block_hashes);
        ffi_allocator.free(self.blob_hashes);
        ffi_allocator.free(self.authorizations);
        self.* = .{};
    }
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

/// Borrow a live handle for the duration of one entry point. Sets an error and
/// returns null for NULL, unknown, or destroyed handles. The borrow is counted under
/// the registry lock, in the same critical section as the lookup, so a concurrent
/// destroy either removes the handle before the lookup (and the caller gets null)
/// or sees the borrow and leaves the teardown to `releaseHandle`. Every successful
/// call must be paired with `releaseHandle`.
fn acquireHandle(handle: ?*EvmHandle) ?*HandleBox {
    const h = handle orelse {
        setError("EVM handle is NULL", .{});
        return null;
    };
    const box = blk: {
        lockRegistry();
        defer unlockRegistry();
        const found = handle_registry.get(@intFromPtr(h)) orelse {
            setError("Invalid or destroyed EVM handle", .{});
            return null;
        };
        found.borrows += 1;
        break :blk found;
    };
    // Taken after the registry lock is released: a long call on this handle must
    // not stall lookups of other handles.
    std.Io.Threaded.mutexLockUncancelable(&box.use);
    return box;
}

/// Return a handle borrowed with `acquireHandle`. Tears the box down when it was
/// retired while borrowed and this was the last borrow.
fn releaseHandle(box: *HandleBox) void {
    std.Io.Threaded.mutexUnlock(&box.use);
    const last = blk: {
        lockRegistry();
        defer unlockRegistry();
        box.borrows -= 1;
        break :blk box.retired and box.borrows == 0;
    };
    if (last) destroyBox(box);
}

/// Take a handle that has left the registry out of service. Returns true when the
/// caller must destroy it now; false when a borrower will. Requires `registry_mutex`.
fn retireLocked(box: *HandleBox) bool {
    box.retired = true;
    return box.borrows == 0;
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

fn EvmOf(comptime tag: HandleBox.VariantTag) type {
    return std.meta.Child(@FieldType(HandleBox.Variant, @tagName(tag)));
}

/// Allocate a fresh database and EVM for `tag`. On error nothing leaks.
fn createBox(comptime tag: HandleBox.VariantTag, info: *const BlockInfoFFI) !*HandleBox {
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
        // This ABI has no fee fields: every call is priced at zero, like `eth_call`
        // without a gas price. A block base fee above zero would otherwise make
        // every call an invalid transaction (EIP-1559).
        .allow_gas_price_below_base_fee = true,
    }, 0, Address.ZERO_ADDRESS);
    errdefer instance.deinit();
    // `Evm.init` returns by value, so the arena's tracer pointer still refers to init's
    // stack frame. Point it at the heap copy before the arena can call back into it.
    instance.call_arena.tracer = @ptrCast(&instance.tracer);
    // Also set at run time, for builds whose root file is not this one (tests).
    instance.tracer.embedded = true;

    var ct_ptr: ?*evm.CallTracer = null;
    if (comptime tag == .call_tracer) {
        const ct = try ffi_allocator.create(evm.CallTracer);
        ct.* = evm.CallTracer.init(ffi_allocator);
        instance.setInspector(ct);
        ct_ptr = ct;
    }
    errdefer if (ct_ptr) |ct| {
        ct.deinit();
        ffi_allocator.destroy(ct);
    };

    const box = try ffi_allocator.create(HandleBox);
    box.* = .{
        .variant = @unionInit(HandleBox.Variant, @tagName(tag), instance),
        .call_tracer = ct_ptr,
    };
    if (builtin.is_test) _ = test_hooks.live_boxes.fetchAdd(1, .monotonic);
    return box;
}

fn createHostBox(info: *const BlockInfoFFI, vtable: GuillotineHostVTable, user_ctx: ?*anyopaque) !*HandleBox {
    const chain_id = std.math.cast(ChainId, info.chain_id) orelse return error.ChainIdOutOfRange;
    try evm.kzg_setup.init();

    const db = try ffi_allocator.create(CallbackHostDb);
    errdefer ffi_allocator.destroy(db);
    db.* = CallbackHostDb.init(ffi_allocator, vtable, user_ctx);
    errdefer db.deinit();

    const instance = try ffi_allocator.create(HostCallbackEvm);
    errdefer ffi_allocator.destroy(instance);
    instance.* = try HostCallbackEvm.init(ffi_allocator, db, toBlockInfo(info), .{
        .gas_limit = info.gas_limit,
        .coinbase = Address{ .bytes = info.coinbase },
        .chain_id = chain_id,
        .blob_versioned_hashes = &.{},
        .blob_base_fee = 0,
        .allow_gas_price_below_base_fee = true,
    }, 0, Address.ZERO_ADDRESS);
    errdefer instance.deinit();
    instance.call_arena.tracer = @ptrCast(&instance.tracer);
    instance.tracer.embedded = true;

    const box = try ffi_allocator.create(HandleBox);
    box.* = .{ .variant = .{ .host_callback = instance } };
    if (builtin.is_test) _ = test_hooks.live_boxes.fetchAdd(1, .monotonic);
    return box;
}

/// Native stack for building an EVM. `Evm.init` returns the EVM by value, and loading
/// the KZG trusted setup is deep, so creation needs far more stack than a host thread
/// may have (a 512 KiB pthread overflows in Debug builds).
const create_stack_size = 16 * 1024 * 1024;

/// Run `createBox` on a thread with `create_stack_size` of stack and wait for it, so
/// handle creation works from any caller stack. The EVM is built directly in heap
/// memory by that thread; only a pointer comes back.
fn createBoxOnLargeStack(comptime tag: HandleBox.VariantTag, info: *const BlockInfoFFI) !*HandleBox {
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

fn createHostBoxOnLargeStack(
    info: *const BlockInfoFFI,
    vtable: GuillotineHostVTable,
    user_ctx: ?*anyopaque,
) !*HandleBox {
    if (comptime builtin.single_threaded or builtin.target.cpu.arch.isWasm()) {
        return createHostBox(info, vtable, user_ctx);
    }
    const Job = struct {
        info: *const BlockInfoFFI,
        vtable: GuillotineHostVTable,
        user_ctx: ?*anyopaque,
        result: anyerror!*HandleBox = error.CreateDidNotRun,
        fn run(job: *@This()) void {
            job.result = createHostBox(job.info, job.vtable, job.user_ctx);
        }
    };
    var job = Job{ .info = info, .vtable = vtable, .user_ctx = user_ctx };
    const thread = try std.Thread.spawn(.{ .stack_size = create_stack_size }, Job.run, .{&job});
    thread.join();
    return job.result;
}

/// Free a box and its EVM. The box must be out of the registry and unborrowed.
fn destroyBox(box: *HandleBox) void {
    if (box.call_tracer) |ct| {
        ct.deinit();
        ffi_allocator.destroy(ct);
    }
    switch (box.variant) {
        inline else => |instance| {
            const db = instance.database;
            instance.deinit();
            db.deinit();
            ffi_allocator.destroy(db);
            ffi_allocator.destroy(instance);
        },
    }
    box.ext.deinit();
    ffi_allocator.destroy(box);
    if (builtin.is_test) _ = test_hooks.live_boxes.fetchSub(1, .monotonic);
}

fn registerBox(box: *HandleBox) ?*EvmHandle {
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

fn reportCreateError(info: *const BlockInfoFFI, err: anyerror) ?*EvmHandle {
    switch (err) {
        error.ChainIdOutOfRange => setError(
            "chain_id {d} exceeds the supported maximum {d}",
            .{ info.chain_id, std.math.maxInt(ChainId) },
        ),
        else => setError("Failed to create EVM: {s}", .{@errorName(err)}),
    }
    return null;
}

fn createHandle(block_info: ?*const BlockInfoFFI, config: EvmConfiguration) ?*EvmHandle {
    const info = block_info orelse {
        setError("block_info is NULL", .{});
        return null;
    };
    const box = switch (config) {
        .mainnet => createBoxOnLargeStack(.mainnet, info),
        .mainnet_with_tracer => createBoxOnLargeStack(.mainnet_with_tracer, info),
        .test_mode => createBoxOnLargeStack(.test_mode, info),
        .call_tracer => createBoxOnLargeStack(.call_tracer, info),
    } catch |err| return reportCreateError(info, err);
    return registerBox(box);
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
/// Handles used after cleanup are rejected as invalid. A handle that another thread
/// is using at this moment leaves the registry now and is freed when that thread's
/// call returns.
export fn guillotine_cleanup() void {
    var to_destroy: ?*HandleBox = null;
    {
        lockRegistry();
        defer unlockRegistry();
        var it = handle_registry.valueIterator();
        while (it.next()) |box_ptr| {
            const box = box_ptr.*;
            // Unborrowed boxes cannot be reached any more: chain them intrusively
            // and destroy them outside `registry_mutex` with zero heap allocation.
            if (retireLocked(box)) {
                box.retired_next = to_destroy;
                to_destroy = box;
            }
        }
        handle_registry.deinit(ffi_allocator);
        handle_registry = .empty;
        initialized = false;
    }
    while (to_destroy) |box| {
        to_destroy = box.retired_next;
        destroyBox(box);
    }
}

/// Create an EVM with configuration 0 (mainnet), 1 (structLogs tracer), 2 (test mode), or 3 (call tracer).
export fn guillotine_evm_create_with_config(block_info: ?*const BlockInfoFFI, config: u8) ?*EvmHandle {
    const tag = std.enums.fromInt(EvmConfiguration, config) orelse {
        setError("Invalid EVM configuration {d} (expected 0, 1, 2, or 3)", .{config});
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

/// Create a mainnet EVM with the structured `CallTracer` inspector attached.
export fn guillotine_evm_create_call_tracer(block_info: ?*const BlockInfoFFI) ?*EvmHandle {
    return createHandle(block_info, .call_tracer);
}

/// Create an EVM targeting a specific Ethereum hardfork (`15=SHANGHAI, 16=CANCUN, 17=PRAGUE, 18=OSAKA`).
export fn guillotine_evm_create_with_fork(block_info: ?*const BlockInfoFFI, hardfork_id: u8) ?*EvmHandle {
    const info = block_info orelse {
        setError("block_info is NULL", .{});
        return null;
    };
    const box = switch (hardfork_id) {
        15 => createBoxOnLargeStack(.shanghai, info),
        16 => createBoxOnLargeStack(.cancun, info),
        17 => createBoxOnLargeStack(.prague, info),
        18 => createBoxOnLargeStack(.mainnet, info),
        else => {
            setError(
                "Unsupported hardfork_id {d} (expected 15=SHANGHAI, 16=CANCUN, 17=PRAGUE, 18=OSAKA)",
                .{hardfork_id},
            );
            return null;
        },
    } catch |err| return reportCreateError(info, err);
    return registerBox(box);
}

/// Create an Osaka mainnet EVM backed by caller-provided C state callbacks (`GuillotineHostVTable`).
export fn guillotine_evm_create_with_host(
    block_info: ?*const BlockInfoFFI,
    vtable: ?*const GuillotineHostVTable,
    user_ctx: ?*anyopaque,
) ?*EvmHandle {
    const info = block_info orelse {
        setError("block_info is NULL", .{});
        return null;
    };
    const vt = vtable orelse {
        setError("vtable is NULL", .{});
        return null;
    };
    const box = createHostBoxOnLargeStack(info, vt.*, user_ctx) catch |err| return reportCreateError(info, err);
    return registerBox(box);
}

/// Update block context on an existing handle without recreating it or dropping `DispatchCache`.
export fn guillotine_set_block_info(handle: ?*EvmHandle, block_info: ?*const BlockInfoFFI) bool {
    const box = acquireHandle(handle) orelse return false;
    defer releaseHandle(box);
    const info = block_info orelse {
        setError("block_info is NULL", .{});
        return false;
    };
    _ = std.math.cast(ChainId, info.chain_id) orelse {
        setError("chain_id {d} exceeds the supported maximum {d}", .{ info.chain_id, std.math.maxInt(ChainId) });
        return false;
    };
    const blk = toBlockInfo(info);
    switch (box.variant) {
        inline else => |instance| instance.setBlockInfo(blk),
    }
    // The new block starts without the extension fields: ancestor hashes are relative
    // to the block number, and the blob base fee belongs to the block it was set for.
    ffi_allocator.free(box.ext.block_hashes);
    box.ext.block_hashes = &.{};
    return true;
}

// ============================================================================
// BLOCK AND TRANSACTION EXTENSIONS
// ============================================================================

/// Set the block's blob base fee (EIP-4844, the BLOBBASEFEE opcode, EIP-7516) as a
/// big-endian u256. Lasts until the next `guillotine_set_block_info`, which resets it to 0.
export fn guillotine_set_blob_base_fee(handle: ?*EvmHandle, blob_base_fee: ?*const [32]u8) bool {
    const box = acquireHandle(handle) orelse return false;
    defer releaseHandle(box);
    const bytes = blob_base_fee orelse {
        setError("blob_base_fee is NULL", .{});
        return false;
    };
    const fee = std.mem.readInt(u256, bytes, .big);
    switch (box.variant) {
        inline else => |instance| {
            var info = instance.block_info;
            info.blob_base_fee = std.math.cast(@TypeOf(info.blob_base_fee), fee) orelse {
                setError("blob_base_fee does not fit this EVM's base fee type", .{});
                return false;
            };
            instance.setBlockInfo(info);
        },
    }
    return true;
}

/// Point every variant's BLOCKHASH source at the handle's current hash list.
fn publishBlockHashes(box: *HandleBox) void {
    switch (box.variant) {
        inline else => |instance| instance.block_info.block_hashes = box.ext.block_hashes,
    }
}

fn currentBlockNumber(box: *HandleBox) u64 {
    return switch (box.variant) {
        inline else => |instance| instance.block_info.number,
    };
}

/// Replace the ancestor hashes BLOCKHASH reads. `hashes[i]` is the hash of block
/// `number - 1 - i` (newest first); `count` is at most 256. Blocks without an entry
/// read as zero. `count` 0 clears the list. On failure the previous list is kept.
export fn guillotine_set_block_hashes(handle: ?*EvmHandle, hashes: ?[*]const [32]u8, count: usize) bool {
    const box = acquireHandle(handle) orelse return false;
    defer releaseHandle(box);
    if (count > max_block_hashes) {
        setError("block hash count {d} exceeds the BLOCKHASH window of {d}", .{ count, max_block_hashes });
        return false;
    }
    const source: []const [32]u8 = if (count == 0) &.{} else (hashes orelse {
        setError("hashes is NULL but count is {d}", .{count});
        return false;
    })[0..count];
    const copy = ffi_allocator.dupe([32]u8, source) catch |err| {
        setError("Failed to copy block hashes: {s}", .{@errorName(err)});
        return false;
    };
    const previous = box.ext.block_hashes;
    box.ext.block_hashes = copy;
    publishBlockHashes(box);
    ffi_allocator.free(previous);
    return true;
}

/// Set the hash BLOCKHASH returns for one ancestor. `block_number` must be one of the
/// 256 blocks before the handle's current block number; anything else is rejected,
/// because BLOCKHASH could never return it. Other ancestors keep their hashes.
export fn guillotine_set_block_hash(handle: ?*EvmHandle, block_number: u64, hash: ?*const [32]u8) bool {
    const box = acquireHandle(handle) orelse return false;
    defer releaseHandle(box);
    const value = hash orelse {
        setError("hash is NULL", .{});
        return false;
    };
    const current = currentBlockNumber(box);
    if (block_number >= current or current - block_number > max_block_hashes) {
        setError("block {d} is outside the BLOCKHASH window of block {d}", .{ block_number, current });
        return false;
    }
    const index: usize = @intCast(current - 1 - block_number);
    if (index >= box.ext.block_hashes.len) {
        const previous = box.ext.block_hashes;
        const grown = ffi_allocator.alloc([32]u8, index + 1) catch |err| {
            setError("Failed to grow block hashes: {s}", .{@errorName(err)});
            return false;
        };
        @memcpy(grown[0..previous.len], previous);
        @memset(grown[previous.len..], @as([32]u8, @splat(0)));
        box.ext.block_hashes = grown;
        publishBlockHashes(box);
        ffi_allocator.free(previous);
    }
    box.ext.block_hashes[index] = value.*;
    return true;
}

/// Set the blob versioned hashes BLOBHASH reads (EIP-4844). They apply to every later
/// `guillotine_call` and `guillotine_simulate`, and to `guillotine_execute_tx` when
/// `tx_type` is 3. `count` 0 clears them. On failure the previous hashes are kept.
export fn guillotine_set_blob_hashes(handle: ?*EvmHandle, hashes: ?[*]const [32]u8, count: usize) bool {
    const box = acquireHandle(handle) orelse return false;
    defer releaseHandle(box);
    const source: []const [32]u8 = if (count == 0) &.{} else (hashes orelse {
        setError("hashes is NULL but count is {d}", .{count});
        return false;
    })[0..count];
    const copy = ffi_allocator.dupe([32]u8, source) catch |err| {
        setError("Failed to copy blob hashes: {s}", .{@errorName(err)});
        return false;
    };
    const previous = box.ext.blob_hashes;
    box.ext.blob_hashes = copy;
    switch (box.variant) {
        inline else => |instance| instance.context.blob_versioned_hashes = copy,
    }
    ffi_allocator.free(previous);
    return true;
}

/// Set the EIP-4844 fee cap per unit of blob gas (big-endian u256) for later
/// `guillotine_execute_tx` calls with `tx_type` 3: a cap below the block's blob base
/// fee rejects the transaction, and the sender must afford every blob at the cap.
/// NULL removes the cap and with it both checks.
export fn guillotine_set_max_fee_per_blob_gas(handle: ?*EvmHandle, max_fee: ?*const [32]u8) bool {
    const box = acquireHandle(handle) orelse return false;
    defer releaseHandle(box);
    box.ext.max_fee_per_blob_gas = if (max_fee) |bytes| std.mem.readInt(u256, bytes, .big) else null;
    return true;
}

const AccessLists = struct {
    call: []evm.AccessListEntry,
    tx: []evm.tx_runner.AccessListEntry,
};

/// Copy an FFI access list into C-allocator memory. On error nothing is kept.
fn copyAccessList(entries: []const AccessListEntryFFI) error{ OutOfMemory, NullStorageKeys }!AccessLists {
    const call = try ffi_allocator.alloc(evm.AccessListEntry, entries.len);
    errdefer ffi_allocator.free(call);
    const tx = try ffi_allocator.alloc(evm.tx_runner.AccessListEntry, entries.len);
    errdefer ffi_allocator.free(tx);
    var copied: usize = 0;
    errdefer for (call[0..copied]) |entry| ffi_allocator.free(entry.storage_keys);
    for (entries, call, tx) |entry, *call_entry, *tx_entry| {
        const raw: []const [32]u8 = if (entry.storage_keys_len == 0)
            &.{}
        else
            (entry.storage_keys orelse return error.NullStorageKeys)[0..entry.storage_keys_len];
        const keys = try ffi_allocator.alloc(u256, raw.len);
        for (keys, raw) |*key, *bytes| key.* = std.mem.readInt(u256, bytes, .big);
        const address = Address{ .bytes = entry.address };
        call_entry.* = .{ .address = address, .storage_keys = keys };
        tx_entry.* = .{ .address = address, .storage_keys = keys };
        copied += 1;
    }
    return .{ .call = call, .tx = tx };
}

/// Set the EIP-2930 access list of later transactions. Every address and storage key
/// starts those transactions warm and is charged intrinsic gas (2,400 per address,
/// 1,900 per key). It applies to `guillotine_call` and `guillotine_simulate`, and to
/// `guillotine_execute_tx` when `tx_type` is 1 or higher. `count` 0 clears the list.
/// On failure the previous list is kept.
export fn guillotine_set_access_list(handle: ?*EvmHandle, entries: ?[*]const AccessListEntryFFI, count: usize) bool {
    const box = acquireHandle(handle) orelse return false;
    defer releaseHandle(box);
    const source: []const AccessListEntryFFI = if (count == 0) &.{} else (entries orelse {
        setError("entries is NULL but count is {d}", .{count});
        return false;
    })[0..count];
    const lists = copyAccessList(source) catch |err| {
        setError("Failed to copy the access list: {s}", .{@errorName(err)});
        return false;
    };
    box.ext.freeAccessList();
    box.ext.access_list = lists.call;
    box.ext.tx_access_list = lists.tx;
    return true;
}

/// Set the EIP-7702 authorization list of later transactions. The tuples are applied
/// before execution as the EIP specifies: an invalid tuple is skipped, not an error.
/// It applies to `guillotine_call` and `guillotine_simulate` (which then run as
/// set-code transactions: Prague or later, and never a CREATE), and to
/// `guillotine_execute_tx` when `tx_type` is 4. `count` 0 clears the list.
/// On failure the previous list is kept.
export fn guillotine_set_authorization_list(
    handle: ?*EvmHandle,
    authorizations: ?[*]const AuthorizationFFI,
    count: usize,
) bool {
    const box = acquireHandle(handle) orelse return false;
    defer releaseHandle(box);
    const source: []const AuthorizationFFI = if (count == 0) &.{} else (authorizations orelse {
        setError("authorizations is NULL but count is {d}", .{count});
        return false;
    })[0..count];
    const copy = ffi_allocator.alloc(evm.Authorization, source.len) catch |err| {
        setError("Failed to copy the authorization list: {s}", .{@errorName(err)});
        return false;
    };
    for (copy, source) |*dst, src| dst.* = .{
        .chain_id = src.chain_id,
        .address = Address{ .bytes = src.address },
        .nonce = src.nonce,
        .v = src.y_parity,
        .r = src.r,
        .s = src.s,
    };
    ffi_allocator.free(box.ext.authorizations);
    box.ext.authorizations = copy;
    return true;
}

/// Forget the addresses and storage slots that calls on this handle touched so far,
/// so the next result's `accessed_*` lists and `guillotine_dump_state` start from the
/// state the host set up. Accounts configured through `guillotine_set_*` stay in the
/// dump. No account, storage slot or code is changed.
export fn guillotine_reset_touched(handle: ?*EvmHandle) bool {
    const box = acquireHandle(handle) orelse return false;
    defer releaseHandle(box);
    switch (box.variant) {
        inline else => |instance| instance.resetTouched(),
    }
    return true;
}

/// Bound the structLogs capture of a tracing handle. Capture stops at `max_steps`
/// records or `max_bytes` bytes of retained trace data (each record and the stack copy
/// it holds), whichever comes first, and
/// the trace reports `"truncated":true`; execution and its result are unaffected.
/// `trace_unlimited` (UINT64_MAX) removes a bound. Fails on a handle without the
/// structLogs tracer.
export fn guillotine_set_trace_limits(handle: ?*EvmHandle, max_steps: u64, max_bytes: u64) bool {
    const box = acquireHandle(handle) orelse return false;
    defer releaseHandle(box);
    switch (box.variant) {
        .mainnet_with_tracer => |instance| {
            instance.tracer.config.max_steps = traceLimit(max_steps);
            instance.tracer.config.max_bytes = traceLimit(max_bytes);
            return true;
        },
        else => {
            setError("guillotine_set_trace_limits needs a tracing handle", .{});
            return false;
        },
    }
}

fn traceLimit(limit: u64) ?usize {
    if (limit == trace_unlimited) return null;
    return std.math.cast(usize, limit) orelse std.math.maxInt(usize);
}

/// Free a handle and all of its state. NULL is a no-op; an unknown or already destroyed
/// handle is reported through `guillotine_get_last_error` and otherwise ignored.
/// The handle is invalid as soon as this returns. If another thread is inside a call
/// on it, that call finishes on the still-live EVM and frees it on return.
export fn guillotine_evm_destroy(handle: ?*EvmHandle) void {
    const h = handle orelse return;
    const box = blk: {
        lockRegistry();
        defer unlockRegistry();
        const entry = handle_registry.fetchRemove(@intFromPtr(h)) orelse {
            setError("guillotine_evm_destroy: invalid or already destroyed handle", .{});
            return;
        };
        if (!retireLocked(entry.value)) return;
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
        .code => |c| {
            // New code replaces any EIP-7702 delegation. `set_account` restores one
            // when `c` is itself a designator.
            account.delegated_address = null;
            account.code_hash = try instance.database.set_code(c);
        },
    }
    try instance.database.set_account(address, account);
    // Track the address so guillotine_dump_state reports it.
    try instance.touched_addresses.put(Address{ .bytes = address }, {});
}

fn applyEdit(handle: ?*EvmHandle, address: ?*const [20]u8, edit: AccountEdit) bool {
    const box = acquireHandle(handle) orelse return false;
    defer releaseHandle(box);
    const addr = address orelse {
        setError("address is NULL", .{});
        return false;
    };
    switch (box.variant) {
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

export fn guillotine_get_nonce(handle: ?*EvmHandle, address: ?*const [20]u8, nonce_out: ?*u64) bool {
    const box = acquireHandle(handle) orelse return false;
    defer releaseHandle(box);
    const addr = address orelse {
        setError("address is NULL", .{});
        return false;
    };
    const out = nonce_out orelse {
        setError("nonce_out is NULL", .{});
        return false;
    };
    const acc = switch (box.variant) {
        inline else => |instance| instance.database.get_account(addr.*),
    } catch |err| {
        setError("Failed to get nonce: {s}", .{@errorName(err)});
        return false;
    };
    out.* = if (acc) |a| a.nonce else 0;
    return true;
}

export fn guillotine_set_code(handle: ?*EvmHandle, address: ?*const [20]u8, code: ?[*]const u8, code_len: usize) bool {
    const slice = inputSlice(code, code_len, "code") orelse return false;
    return applyEdit(handle, address, .{ .code = slice });
}

export fn guillotine_set_code_tracing(
    handle: ?*EvmHandle,
    address: ?*const [20]u8,
    code: ?[*]const u8,
    code_len: usize,
) bool {
    return guillotine_set_code(handle, address, code, code_len);
}

export fn guillotine_get_balance(handle: ?*EvmHandle, address: ?*const [20]u8, balance_out: ?*[32]u8) bool {
    const box = acquireHandle(handle) orelse return false;
    defer releaseHandle(box);
    const addr = address orelse {
        setError("address is NULL", .{});
        return false;
    };
    const out = balance_out orelse {
        setError("balance_out is NULL", .{});
        return false;
    };
    const balance = switch (box.variant) {
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
/// or have no code have empty code. The database stores a delegated account as
/// `delegated_address` without a code hash, so the designator is rebuilt in
/// `designator`, which the result then points into.
fn storedCode(
    instance: anytype,
    address: [20]u8,
    designator: *[evm.eips.DELEGATION_DESIGNATOR_LENGTH]u8,
) Database.Error![]const u8 {
    const account = try instance.database.get_account(address) orelse return &.{};
    if (account.get_effective_code_address()) |delegate| {
        designator.* = evm.eips.DELEGATION_PREFIX ++ delegate.bytes;
        return designator;
    }
    if (!Account.is_code_hash_present(account.code_hash)) return &.{};
    return instance.database.get_code(account.code_hash);
}

/// Copy the code stored under an account (what EXTCODECOPY reads; see `storedCode`).
/// Free a non-empty result with `guillotine_free_code`.
export fn guillotine_get_code(handle: ?*EvmHandle, address: ?*const [20]u8, code_out: ?*[*]u8, len_out: ?*usize) bool {
    const box = acquireHandle(handle) orelse return false;
    defer releaseHandle(box);
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
    var designator: [evm.eips.DELEGATION_DESIGNATOR_LENGTH]u8 = undefined;
    const code: []const u8 = switch (box.variant) {
        inline else => |instance| storedCode(instance, addr.*, &designator),
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

export fn guillotine_set_storage(
    handle: ?*EvmHandle,
    address: ?*const [20]u8,
    key: ?*const [32]u8,
    value: ?*const [32]u8,
) bool {
    const box = acquireHandle(handle) orelse return false;
    defer releaseHandle(box);
    if (address == null or key == null or value == null) {
        setError("address, key, and value must not be NULL", .{});
        return false;
    }
    const k = std.mem.readInt(u256, key.?, .big);
    const v = std.mem.readInt(u256, value.?, .big);
    switch (box.variant) {
        inline else => |instance| putStorage(instance, address.?.*, k, v) catch |err| {
            setError("Failed to set storage: {s}", .{@errorName(err)});
            return false;
        },
    }
    return true;
}

export fn guillotine_get_storage(
    handle: ?*EvmHandle,
    address: ?*const [20]u8,
    key: ?*const [32]u8,
    value_out: ?*[32]u8,
) bool {
    const box = acquireHandle(handle) orelse return false;
    defer releaseHandle(box);
    if (address == null or key == null or value_out == null) {
        setError("address, key, and value_out must not be NULL", .{});
        return false;
    }
    const k = std.mem.readInt(u256, key.?, .big);
    const value = switch (box.variant) {
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
        5 => .{ .create2 = .{
            .caller = caller,
            .value = value,
            .init_code = input,
            .salt = std.mem.readInt(u256, &p.salt, .big),
            .gas = p.gas,
        } },
        else => {
            setError("Invalid call type: {d}", .{p.call_type});
            return null;
        },
    };
}

const ExecMode = enum { call, simulate };

/// What a result reports about its structLogs trace.
const TraceStatus = struct {
    include: bool,
    truncated: bool = false,
    reason: []const u8 = "none",
};

/// Read the completeness of the trace the call that just returned captured.
fn traceStatus(instance: anytype, include_trace: bool) TraceStatus {
    if (!include_trace) return .{ .include = false };
    return .{
        .include = true,
        .truncated = instance.tracer.isTruncated(),
        .reason = @tagName(instance.tracer.truncationReason()),
    };
}

fn attachCallTraceJson(out: *EvmResult, call_tracer: ?*evm.CallTracer) !void {
    const ct = call_tracer orelse return;
    if (ct.oom) return error.OutOfMemory;
    const json = try ct.toJson(ffi_allocator);
    if (json.len == 0) {
        ffi_allocator.free(json);
        return;
    }
    if (out.trace_json_len > 0) ffi_allocator.free(out.trace_json[0..out.trace_json_len]);
    out.trace_json = json.ptr;
    out.trace_json_len = json.len;
}

fn execute(
    instance: anytype,
    p: *const CallParams,
    input: []const u8,
    mode: ExecMode,
    include_trace: bool,
    call_tracer: ?*evm.CallTracer,
    ext: *const Extensions,
) ?*EvmResult {
    const E = @TypeOf(instance.*);
    const call_params = buildCallParams(E, p, input) orelse return null;
    // Transaction admission, intrinsic gas included, is `Evm.call`'s alone: it rejects
    // a gas limit below the fork's intrinsic cost on every configuration, and a copy
    // of that rule here could only disagree with it.
    if (call_tracer) |ct| ct.clear();

    // The caller is the transaction origin for top-level calls and simulations alike
    // (ORIGIN opcode, nonce increment, fee accounting), for this call only.
    const saved_origin = instance.origin;
    instance.origin = Address{ .bytes = p.caller };
    defer instance.origin = saved_origin;

    // The handle's EIP-2930 and EIP-7702 lists travel with this call only.
    const saved_access_list = instance.context.access_list;
    const saved_authorizations = instance.context.authorization_list;
    const saved_set_code = instance.context.is_set_code_transaction;
    instance.context.access_list = ext.access_list;
    instance.context.authorization_list = ext.authorizations;
    instance.context.is_set_code_transaction = ext.authorizations.len != 0;
    defer {
        instance.context.access_list = saved_access_list;
        instance.context.authorization_list = saved_authorizations;
        instance.context.is_set_code_transaction = saved_set_code;
    }

    const database = instance.database;
    switch (mode) {
        .simulate => {
            // `simulate` runs on an ephemeral view of the database and discards it:
            // nothing is committed, whatever happens to the result afterwards.
            var result = instance.simulate(call_params);
            defer result.deinit(instance.allocator);
            const out = convertCallResult(result_allocator, &result, traceStatus(instance, include_trace)) catch |err| {
                setError("Failed to copy call result: {s}", .{@errorName(err)});
                return null;
            };
            attachCallTraceJson(out, call_tracer) catch |err| {
                freeResult(out);
                setError("Failed to serialize call trace: {s}", .{@errorName(err)});
                return null;
            };
            return out;
        },
        .call => {
            // `Evm.call` commits the transaction to the database before the C result
            // exists. Run it inside an outer snapshot, so that a result that cannot
            // be built takes the transaction back with it: a NULL return must mean
            // "nothing happened", or the host and the database disagree from then on.
            const depth = database.snapshot_depth();
            const snapshot = database.create_snapshot() catch |err| {
                setError("Failed to open the call snapshot: {s}", .{@errorName(err)});
                return null;
            };
            var result = instance.call(call_params);
            defer result.deinit(instance.allocator);
            const converted = convertCallResult(result_allocator, &result, traceStatus(instance, include_trace)) catch |err| {
                database.revert_to_depth(depth);
                setError("Failed to copy call result, call rolled back: {s}", .{@errorName(err)});
                return null;
            };
            attachCallTraceJson(converted, call_tracer) catch |err| {
                database.revert_to_depth(depth);
                freeResult(converted);
                setError("Failed to serialize call trace, call rolled back: {s}", .{@errorName(err)});
                return null;
            };
            database.commit_snapshot(snapshot) catch |err| {
                database.revert_to_depth(depth);
                freeResult(converted);
                setError("Failed to commit the call, call rolled back: {s}", .{@errorName(err)});
                return null;
            };
            return converted;
        },
    }
}

fn run(handle: ?*EvmHandle, params: ?*const CallParams, mode: ExecMode) ?*EvmResult {
    const box = acquireHandle(handle) orelse return null;
    defer releaseHandle(box);
    const p = params orelse {
        setError("params is NULL", .{});
        return null;
    };
    const input = inputSlice(p.input, p.input_len, "params.input") orelse return null;
    if (mode == .simulate and p.call_type != 0) {
        setError("Simulate only supports CALL type", .{});
        return null;
    }
    return switch (box.variant) {
        .mainnet_with_tracer => |instance| execute(instance, p, input, mode, true, null, &box.ext),
        .call_tracer => |instance| execute(instance, p, input, mode, false, box.call_tracer, &box.ext),
        inline else => |instance| execute(instance, p, input, mode, false, null, &box.ext),
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

fn convertTxResult(tx_res: *const evm.tx_runner.TxResult, call_tracer: ?*evm.CallTracer) !*EvmResult {
    const out = try ffi_allocator.create(EvmResult);
    out.* = emptyResult();
    errdefer freeResult(out);

    out.success = tx_res.success;
    out.gas_left = tx_res.gas_left;
    out.output = try dupeOrEmpty(ffi_allocator, u8, tx_res.output);
    out.output_len = tx_res.output.len;

    if (tx_res.logs.len > 0) {
        const logs = try ffi_allocator.alloc(LogEntry, tx_res.logs.len);
        for (logs) |*entry| entry.* = .{
            .address = @splat(0),
            .topics = emptyPtr([32]u8),
            .topics_len = 0,
            .data = emptyPtr(u8),
            .data_len = 0,
        };
        out.logs = logs.ptr;
        out.logs_len = logs.len;
        for (logs, tx_res.logs) |*entry, item| {
            entry.address = item.address.bytes;
            if (item.topics.len > 0) {
                const topics = try ffi_allocator.alloc([32]u8, item.topics.len);
                for (topics, item.topics) |*dst, topic| std.mem.writeInt(u256, dst, topic, .big);
                entry.topics = topics.ptr;
                entry.topics_len = topics.len;
            }
            entry.data = try dupeOrEmpty(ffi_allocator, u8, item.data);
            entry.data_len = item.data.len;
        }
    }
    if (tx_res.created_address) |addr| {
        out.created_address = addr.bytes;
        out.has_created_address = true;
    }
    try attachCallTraceJson(out, call_tracer);
    return out;
}

fn executeTxOnInstance(
    instance: anytype,
    p: *const TxParamsFFI,
    input: []const u8,
    call_tracer: ?*evm.CallTracer,
    ext: *const Extensions,
) ?*EvmResult {
    const E = @TypeOf(instance.*);
    if (call_tracer) |ct| ct.clear();
    // The runner installs this transaction's origin, gas price and context on the
    // EVM. They describe this transaction only: put the handle's own back afterwards,
    // so a later `guillotine_call` is not priced or validated as this transaction.
    const saved_origin = instance.origin;
    const saved_gas_price = instance.gas_price;
    const saved_context = instance.context;
    defer {
        instance.origin = saved_origin;
        instance.gas_price = saved_gas_price;
        instance.context = saved_context;
    }
    const tx = evm.tx_runner.Transaction{
        .tx_type = p.tx_type,
        .from = Address{ .bytes = p.from },
        .to = if (p.has_to) Address{ .bytes = p.to } else null,
        .nonce = if (p.has_nonce) p.nonce else null,
        .gas_limit = p.gas_limit,
        .value = std.mem.readInt(u256, &p.value, .big),
        .gas_price = std.mem.readInt(u256, &p.gas_price, .big),
        .max_fee_per_gas = if (p.has_max_fee) std.mem.readInt(u256, &p.max_fee_per_gas, .big) else null,
        .max_priority_fee_per_gas = std.mem.readInt(u256, &p.max_priority_fee_per_gas, .big),
        .input = input,
        // Each list rides only on the transaction types that carry it.
        .access_list = if (p.tx_type >= 1) ext.tx_access_list else &.{},
        .blob_hashes = if (p.tx_type == 3) ext.blob_hashes else &.{},
        .max_fee_per_blob_gas = if (p.tx_type == 3) ext.max_fee_per_blob_gas else null,
        .authorizations = if (p.tx_type == 4) ext.authorizations else &.{},
        .disable_balance_check = p.disable_balance_check,
    };
    const database = instance.database;
    const depth = database.snapshot_depth();
    const snapshot = database.create_snapshot() catch |err| {
        setError("Failed to open transaction snapshot: {s}", .{@errorName(err)});
        return null;
    };
    var tx_res = evm.tx_runner.executeTx(E, ffi_allocator, instance, tx) catch |err| {
        database.revert_to_depth(depth);
        setError("Transaction failed: {s}", .{@errorName(err)});
        return null;
    };
    defer tx_res.deinit(ffi_allocator);
    const converted = convertTxResult(&tx_res, call_tracer) catch |err| {
        database.revert_to_depth(depth);
        setError("Failed to copy transaction result, transaction rolled back: {s}", .{@errorName(err)});
        return null;
    };
    database.commit_snapshot(snapshot) catch |err| {
        database.revert_to_depth(depth);
        freeResult(converted);
        setError("Failed to commit transaction, transaction rolled back: {s}", .{@errorName(err)});
        return null;
    };
    return converted;
}

/// Execute a full Ethereum transaction (intrinsic gas, EIP-1559 fee validation,
/// EIP-7623 calldata floor, EIP-3529 refund cap, EIP-7825 gas cap, coinbase tip).
/// Free the result with `guillotine_free_result`.
export fn guillotine_execute_tx(handle: ?*EvmHandle, params: ?*const TxParamsFFI) ?*EvmResult {
    const box = acquireHandle(handle) orelse return null;
    defer releaseHandle(box);
    const p = params orelse {
        setError("params is NULL", .{});
        return null;
    };
    const input = inputSlice(p.input, p.input_len, "params.input") orelse return null;
    return switch (box.variant) {
        .call_tracer => |instance| executeTxOnInstance(instance, p, input, box.call_tracer, &box.ext),
        inline else => |instance| executeTxOnInstance(instance, p, input, null, &box.ext),
    };
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

/// Allocator of everything a call result copies into C memory. It is the C allocator.
/// A test build routes it through `test_hooks`, which can make one chosen allocation
/// fail; the memory still comes from the C allocator, so `freeResult` frees it as usual.
const result_allocator: std.mem.Allocator = if (builtin.is_test)
    .{ .ptr = undefined, .vtable = &test_hooks.vtable }
else
    ffi_allocator;

/// Fault injection for tests of this ABI. Nothing here exists in a non-test build.
pub const test_hooks = if (builtin.is_test) struct {
    /// When set, the allocation with this index (0 = the next one) made while a call
    /// result is copied into C memory fails, once. Per thread, so a test that
    /// injects a failure does not disturb calls on other threads.
    pub threadlocal var fail_result_allocation_at: ?usize = null;

    /// Handle boxes that exist right now: created and not yet torn down. A stress
    /// test reads it to prove that no box leaks and none is destroyed twice.
    pub var live_boxes: std.atomic.Value(usize) = .init(0);

    /// EVM state of a handle that the ABI has no getter for. A test compares two
    /// of these to prove that an entry point left the instance alone.
    pub const Observed = struct {
        origin: [20]u8,
        /// Length and hash of the EVM's return data, or null when it has none.
        return_data: ?struct { len: usize, hash: u64 },
        touched_addresses: usize,
        transaction_touched: usize,
        touched_storage_addresses: usize,
        touched_storage_slots: usize,
    };

    /// Read `Observed` from a live handle; null for a NULL or destroyed one.
    pub fn observe(handle: ?*EvmHandle) ?Observed {
        const box = acquireHandle(handle) orelse return null;
        defer releaseHandle(box);
        return switch (box.variant) {
            inline else => |instance| blk: {
                var slots: usize = 0;
                var it = instance.touched_storage.valueIterator();
                while (it.next()) |set| slots += set.count();
                break :blk Observed{
                    .origin = instance.origin.bytes,
                    .return_data = if (instance.return_data) |data|
                        .{ .len = data.len, .hash = std.hash.Wyhash.hash(0, data) }
                    else
                        null,
                    .touched_addresses = instance.touched_addresses.count(),
                    .transaction_touched = instance.transaction_touched.items.len,
                    .touched_storage_addresses = instance.touched_storage.count(),
                    .touched_storage_slots = slots,
                };
            },
        };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        if (fail_result_allocation_at) |remaining| {
            if (remaining == 0) {
                fail_result_allocation_at = null;
                return null;
            }
            fail_result_allocation_at = remaining - 1;
        }
        return ffi_allocator.rawAlloc(len, alignment, return_address);
    }

    fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        return ffi_allocator.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        return ffi_allocator.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        ffi_allocator.rawFree(memory, alignment, return_address);
    }
} else struct {};

/// Copy `items` with `allocator`, or return the shared empty pointer for none.
fn dupeOrEmpty(allocator: std.mem.Allocator, comptime T: type, items: []const T) ![*]const T {
    if (items.len == 0) return emptyPtr(T);
    return (try allocator.dupe(T, items)).ptr;
}

/// Owned NUL-terminated copy of `text`. Interior NULs become '?' so the C string
/// length equals the allocation length minus one (needed to free it exactly).
fn dupeCString(allocator: std.mem.Allocator, text: []const u8) ![*:0]const u8 {
    const copy = try allocator.allocSentinel(u8, text.len, 0);
    for (copy, text) |*dst, c| dst.* = if (c == 0) '?' else c;
    return copy.ptr;
}

/// Copy a CallResult into a C-allocated EvmResult. Every pointer is set before any
/// allocation that can fail, so `freeResult` releases a partial copy correctly.
/// `allocator` must hand out C-allocator memory (see `result_allocator`).
fn convertCallResult(allocator: std.mem.Allocator, result: anytype, trace_status: TraceStatus) !*EvmResult {
    const out = try allocator.create(EvmResult);
    out.* = emptyResult();
    errdefer freeResult(out);

    out.success = result.success;
    out.gas_left = result.gas_left;
    if (result.error_info) |info| out.error_message = try dupeCString(allocator, info);

    out.output = try dupeOrEmpty(allocator, u8, result.output);
    out.output_len = result.output.len;

    if (result.logs.len > 0) {
        const logs = try allocator.alloc(LogEntry, result.logs.len);
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
                const topics = try allocator.alloc([32]u8, item.topics.len);
                for (topics, item.topics) |*dst, topic| std.mem.writeInt(u256, dst, topic, .big);
                entry.topics = topics.ptr;
                entry.topics_len = topics.len;
            }
            entry.data = try dupeOrEmpty(allocator, u8, item.data);
            entry.data_len = item.data.len;
        }
    }

    if (result.selfdestructs.len > 0) {
        const records = try allocator.alloc(SelfDestructRecord, result.selfdestructs.len);
        for (records, result.selfdestructs) |*dst, sd| {
            dst.* = .{ .contract = sd.contract.bytes, .beneficiary = sd.beneficiary.bytes };
        }
        out.selfdestructs = records.ptr;
        out.selfdestructs_len = records.len;
    }

    if (result.accessed_addresses.len > 0) {
        const addresses = try allocator.alloc([20]u8, result.accessed_addresses.len);
        for (addresses, result.accessed_addresses) |*dst, a| dst.* = a.bytes;
        out.accessed_addresses = addresses.ptr;
        out.accessed_addresses_len = addresses.len;
    }

    if (result.accessed_storage.len > 0) {
        const slots = try allocator.alloc(StorageAccessRecord, result.accessed_storage.len);
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

    if (trace_status.include) {
        if (result.trace) |*trace| {
            const json = try writeTraceJson(allocator, trace, trace_status);
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

/// Serialize an execution trace as
/// `{"structLogs":[...],"truncated":<bool>,"truncationReason":"<reason>"}`.
/// `truncated` is true when a capture bound or an allocation failure dropped steps:
/// the listed steps are then a valid prefix of the execution, not all of it.
/// Caller owns the returned slice.
fn writeTraceJson(allocator: std.mem.Allocator, trace: anytype, status: TraceStatus) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"structLogs\":[");
    for (trace.steps, 0..) |step, i| {
        if (i > 0) try w.writeAll(",");
        try w.print(
            "{{\"pc\":{d},\"op\":\"{s}\",\"gas\":{d},\"gasCost\":{d},\"depth\":{d},\"stack\":[",
            .{ step.pc, step.opcode_name, step.gas, step.gas_cost, step.depth },
        );
        for (step.stack, 0..) |val, j| {
            if (j > 0) try w.writeAll(",");
            try w.print("\"0x{x}\"", .{val});
        }
        try w.print("],\"memSize\":{d}}}", .{step.mem_size});
    }
    try w.print("],\"truncated\":{},\"truncationReason\":\"{s}\"}}", .{ status.truncated, status.reason });
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
        acc.code = try dupeOrEmpty(ffi_allocator, u8, entry.value_ptr.code);
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
    const box = acquireHandle(handle) orelse return null;
    defer releaseHandle(box);
    return switch (box.variant) {
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
    return bytecode_c.evm_bytecode_pretty_print_with_allocator(
        ffi_allocator,
        bytes,
        data_len,
        buffer orelse &empty,
        buffer_len,
    );
}

fn dispatchPrettyPrint(bytes: []const u8) ![]u8 {
    const BytecodeType = evm.Bytecode(evm.BytecodeConfig{});
    var bytecode = try BytecodeType.init(ffi_allocator, bytes);
    defer bytecode.deinit();

    const FrameType = MainnetEvm.Frame;
    const DispatchType = FrameType.Dispatch;
    var schedule = try DispatchType.DispatchSchedule.init(ffi_allocator, bytecode, &FrameType.opcode_handlers, null);
    defer schedule.deinit();

    return evm.dispatch_pretty_print.pretty_print(
        ffi_allocator,
        schedule.items,
        &bytecode,
        FrameType,
        DispatchType.Item,
    );
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

test "evm_dispatch_pretty_print rejects empty bytecode gracefully" {
    var buf: [128]u8 = undefined;
    const written = evm_dispatch_pretty_print(null, 0, &buf, buf.len);
    try std.testing.expect(written > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..written], "Error:") != null);
}
