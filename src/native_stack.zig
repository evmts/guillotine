//! Bounds of the calling thread's native stack, and a persistent large-stack worker.
//!
//! The EVM interpreter recurses once per call depth. Knowing where the native stack
//! ends lets the EVM run a transaction on the caller's stack and move to a dedicated
//! large stack only when a call chain is deep enough to need it. `Worker` owns that
//! large stack: one thread, created once and reused for every job.
const std = @import("std");
const builtin = @import("builtin");

/// True when `lowAddress` can report the stack bounds on this target.
pub const supported = builtin.link_libc and (builtin.os.tag == .linux or builtin.os.tag.isDarwin());

extern "c" fn pthread_getattr_np(thread: std.c.pthread_t, attr: *std.c.pthread_attr_t) c_int;
extern "c" fn pthread_attr_getstack(
    attr: *const std.c.pthread_attr_t,
    stack_address: *?*anyopaque,
    stack_size: *usize,
) c_int;
extern "c" fn pthread_get_stackaddr_np(thread: std.c.pthread_t) ?*anyopaque;
extern "c" fn pthread_get_stacksize_np(thread: std.c.pthread_t) usize;
extern "c" fn getauxval(kind: c_ulong) c_ulong;
extern "c" fn fork() c_int;

/// `AT_EXECFN`: address of the executable path string the kernel copies to the very
/// top of the main thread's stack mapping.
const at_execfn = 31;

/// Stack size assumed for the main thread when `RLIMIT_STACK` is unlimited.
pub const unlimited_main_stack = 8 * 1024 * 1024;

/// Upper bound on the main thread stack size used for the low address. A smaller
/// size only makes the reported low address higher, which is conservative.
const max_main_stack = 256 * 1024 * 1024;

/// Per-thread cache of the stack's low address.
///
/// A thread's stack does not move, so the address is looked up once per thread.
/// The one event that invalidates it is `fork`: the child's only thread keeps
/// the thread-local value but may now be the process's main thread, whose stack
/// is found differently. A `pthread_atfork` child handler advances
/// `fork_generation`, and a cache entry is valid only for the generation it was
/// made in. That check is two loads; asking the kernel for the thread id on
/// every call, which is what the cache was keyed by before, is a system call
/// per transaction.
threadlocal var cached_low: usize = 0;
threadlocal var cached_generation: u32 = 0;
/// Thread id the entry was made for. Read only when no fork handler could be
/// registered, where it is the fallback key.
threadlocal var cached_tid: i32 = 0;

/// Number of times this process has been the child of a `fork` since the handler
/// was registered.
var fork_generation = std.atomic.Value(u32).init(0);

const ForkHandler = enum(u8) { unregistered, registered, unavailable };
var fork_handler = std.atomic.Value(ForkHandler).init(.unregistered);

extern "c" fn pthread_atfork(
    prepare: ?*const fn () callconv(.c) void,
    parent: ?*const fn () callconv(.c) void,
    child: ?*const fn () callconv(.c) void,
) c_int;

fn noteForkChild() callconv(.c) void {
    _ = fork_generation.fetchAdd(1, .monotonic);
}

/// True when a fork handler keeps `fork_generation` current. Registers it on first
/// use. Two threads that race here may both register; the handler only counts, so
/// a second registration is harmless.
fn forkHandlerRegistered() bool {
    switch (fork_handler.load(.acquire)) {
        .registered => return true,
        .unavailable => return false,
        .unregistered => {},
    }
    const registered = pthread_atfork(null, null, &noteForkChild) == 0;
    fork_handler.store(if (registered) .registered else .unavailable, .release);
    return registered;
}

/// Lowest address of the calling thread's stack, or null when it cannot be determined.
pub fn lowAddress() ?usize {
    if (comptime !supported) return null;
    if (comptime builtin.os.tag.isDarwin()) {
        const thread = std.c.pthread_self();
        const top = @intFromPtr(pthread_get_stackaddr_np(thread) orelse return null);
        const size = pthread_get_stacksize_np(thread);
        if (size == 0 or size > top) return null;
        return top - size;
    }

    if (forkHandlerRegistered()) {
        const generation = fork_generation.load(.monotonic);
        if (cached_low != 0 and cached_generation == generation) return cached_low;
        const low = queryLinux(std.os.linux.gettid()) orelse return null;
        cached_generation = generation;
        cached_low = low;
        return low;
    }

    // No fork handler: key the cache by thread id, which a fork changes.
    const tid = std.os.linux.gettid();
    if (cached_tid == tid and cached_low != 0) return cached_low;
    const low = queryLinux(tid) orelse return null;
    cached_tid = tid;
    cached_low = low;
    return low;
}

/// Ask the system for the low address of the stack of thread `tid`, the caller.
fn queryLinux(tid: i32) ?usize {
    return if (tid == std.os.linux.getpid()) queryLinuxMainThread() else queryLinuxThread();
}

/// The main thread's stack is the kernel's grow-down `[stack]` mapping. glibc's
/// `pthread_getattr_np` parses /proc/self/maps for it and musl probes it with
/// `mremap`, which can report a wrong, tiny size. The kernel lets the mapping grow
/// until it spans `RLIMIT_STACK` bytes below its top, so the low address is
/// `top - soft limit`. The top is found from `AT_EXECFN`: the kernel stores the
/// executable path string followed by one pointer-sized end marker at the very top.
fn queryLinuxMainThread() ?usize {
    const limits = std.posix.getrlimit(.STACK) catch |err| switch (err) {
        error.Unexpected => return null,
    };
    const soft: u64 = if (limits.cur == std.posix.RLIM.INFINITY) unlimited_main_stack else limits.cur;
    const size: usize = @intCast(@min(soft, max_main_stack));

    const execfn = getauxval(at_execfn);
    if (execfn == 0) return null;
    const path: [*:0]const u8 = @ptrFromInt(execfn);
    const path_end, const overflow = @addWithOverflow(@as(usize, execfn), std.mem.len(path) + 1 + @sizeOf(usize));
    if (overflow != 0) return null;
    const top = std.mem.alignForward(usize, path_end, std.heap.pageSize());

    const here = @frameAddress();
    if (here >= top or size >= top) return null;
    const low = top - size;
    if (here <= low) return null;
    return low;
}

fn queryLinuxThread() ?usize {
    var attr: std.c.pthread_attr_t = undefined;
    if (pthread_getattr_np(std.c.pthread_self(), &attr) != 0) return null;
    defer _ = std.c.pthread_attr_destroy(&attr);
    var stack_address: ?*anyopaque = null;
    var stack_size: usize = 0;
    if (pthread_attr_getstack(&attr, &stack_address, &stack_size) != 0) return null;
    const low = @intFromPtr(stack_address orelse return null);
    if (stack_size == 0) return null;
    return low;
}

/// A persistent thread with a large stack that runs one job at a time.
///
/// The EVM is single-threaded: `run` blocks its caller until the job finishes, so
/// the worker only ever borrows the caller's turn. Handshake on one futex word:
///
///   caller: idle -> pending, wake      worker: wait while idle
///   worker: run job, pending -> done, wake
///   caller: wait while pending, done -> idle
pub const Worker = struct {
    const State = enum(u32) { idle, pending, done, shutdown };

    allocator: std.mem.Allocator,
    thread: std.Thread,
    state: std.atomic.Value(State),
    /// Set while a job is submitted or running. A second `run` (nested or
    /// concurrent) fails with `error.WorkerBusy` instead of deadlocking.
    busy: std.atomic.Value(bool),
    context: *anyopaque,
    func: *const fn (*anyopaque) void,

    fn io() std.Io {
        return std.Io.Threaded.global_single_threaded.io();
    }

    fn noop(context: *anyopaque) void {
        _ = context;
    }

    /// Heap-allocated, so the pointer is stable even if the owning Evm struct is moved.
    pub fn create(allocator: std.mem.Allocator, stack_size: usize) !*Worker {
        if (comptime builtin.single_threaded) return error.ThreadsUnavailable;
        const self = try allocator.create(Worker);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .thread = undefined,
            .state = .init(.idle),
            .busy = .init(false),
            .context = self,
            .func = noop,
        };
        self.thread = try std.Thread.spawn(.{ .stack_size = stack_size }, loop, .{self});
        return self;
    }

    fn loop(self: *Worker) void {
        while (true) {
            const state = self.state.load(.acquire);
            switch (state) {
                .idle, .done => io().futexWaitUncancelable(State, &self.state.raw, state),
                .pending => {
                    self.func(self.context);
                    self.state.store(.done, .release);
                    io().futexWake(State, &self.state.raw, 1);
                },
                .shutdown => return,
            }
        }
    }

    /// Runs `func(context)` on the worker thread and blocks until it returns.
    /// Only one job runs at a time because the EVM is single-threaded.
    /// Re-entrant use from inside a job running on the worker must be rejected with an error, not deadlock.
    pub fn run(self: *Worker, context: *anyopaque, func: *const fn (*anyopaque) void) error{WorkerBusy}!void {
        if (self.busy.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.WorkerBusy;
        defer self.busy.store(false, .release);

        self.context = context;
        self.func = func;
        self.state.store(.pending, .release);
        io().futexWake(State, &self.state.raw, 1);
        while (true) {
            const state = self.state.load(.acquire);
            if (state == .done) break;
            io().futexWaitUncancelable(State, &self.state.raw, state);
        }
        self.state.store(.idle, .release);
    }

    /// Signals shutdown, joins the thread, and frees the worker. Must not be called
    /// while a `run` is in progress (the EVM calls it only from `deinit`).
    pub fn destroy(self: *Worker) void {
        self.state.store(.shutdown, .release);
        io().futexWake(State, &self.state.raw, 1);
        self.thread.join();
        self.allocator.destroy(self);
    }
};

test "the current frame lies above the reported stack low address" {
    if (!supported) return;
    const low = lowAddress() orelse return error.TestUnexpectedResult;
    const here = @frameAddress();
    try std.testing.expect(here > low);
    // No thread stack in practice is larger than 1 GiB.
    try std.testing.expect(here - low < 1024 * 1024 * 1024);
    try std.testing.expectEqual(low, lowAddress().?);
}

test "repeated lookups reuse the per-thread entry of the current fork generation" {
    if (comptime !supported or builtin.os.tag != .linux) return error.SkipZigTest;
    const low = lowAddress() orelse return error.TestUnexpectedResult;
    try std.testing.expect(forkHandlerRegistered());
    try std.testing.expectEqual(low, cached_low);
    try std.testing.expectEqual(fork_generation.load(.monotonic), cached_generation);

    // A stale generation, as a forked child would see it, forces a fresh lookup
    // that finds the same stack.
    cached_generation -%= 1;
    cached_low = 1;
    try std.testing.expectEqual(low, lowAddress().?);
    try std.testing.expectEqual(low, cached_low);
    try std.testing.expectEqual(fork_generation.load(.monotonic), cached_generation);
}

test "a forked child advances the fork generation and looks its stack up again" {
    if (comptime !supported or builtin.os.tag != .linux) return error.SkipZigTest;
    _ = lowAddress() orelse return error.TestUnexpectedResult;
    const generation = fork_generation.load(.monotonic);

    const pid = fork();
    try std.testing.expect(pid >= 0);
    if (pid == 0) {
        // In the child: the handler ran, so the inherited entry is stale, and a
        // fresh lookup is either unavailable or below the current frame.
        var ok = fork_generation.load(.monotonic) == generation +% 1 and cached_generation == generation;
        if (lowAddress()) |low| ok = ok and @frameAddress() > low and cached_generation == generation +% 1;
        std.c._exit(if (ok) 0 else 1);
    }
    var status: c_int = 0;
    try std.testing.expectEqual(pid, std.c.waitpid(pid, &status, 0));
    // Exited normally (low seven bits clear) with status 0.
    try std.testing.expectEqual(@as(c_int, 0), status & 0x7f);
    try std.testing.expectEqual(@as(c_int, 0), (status >> 8) & 0xff);
    // The parent's generation is untouched.
    try std.testing.expectEqual(generation, fork_generation.load(.monotonic));
}

test "a spawned thread reports its own stack bounds, not the main thread's" {
    if (!supported) return;
    const Probe = struct {
        low: ?usize = null,
        again: ?usize = null,
        here: usize = 0,
        fn run(self: *@This()) void {
            self.here = @frameAddress();
            self.low = lowAddress();
            self.again = lowAddress();
        }
    };
    var probe: Probe = .{};
    const thread = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, Probe.run, .{&probe});
    thread.join();
    const low = probe.low orelse return error.TestUnexpectedResult;
    try std.testing.expect(probe.here > low);
    // The thread was given a 1 MiB stack, so its low bound is within a few MiB of it.
    try std.testing.expect(probe.here - low < 4 * 1024 * 1024);
    try std.testing.expectEqual(probe.low, probe.again);
    const main_low = lowAddress() orelse return error.TestUnexpectedResult;
    try std.testing.expect(main_low != low);
}

test "the Linux main thread low address is the stack top minus RLIMIT_STACK" {
    if (!supported or builtin.os.tag != .linux) return;
    if (std.os.linux.gettid() != std.os.linux.getpid()) return;
    const low = lowAddress() orelse return error.TestUnexpectedResult;
    const limits = try std.posix.getrlimit(.STACK);
    const soft: u64 = if (limits.cur == std.posix.RLIM.INFINITY) unlimited_main_stack else limits.cur;
    const size: usize = @intCast(@min(soft, max_main_stack));
    const here = @frameAddress();
    // The top lies above the current frame and within the size of the stack.
    try std.testing.expect(here > low);
    try std.testing.expect(here - low <= size);
    try std.testing.expect(here - low > size - 1024 * 1024);
}

test "Worker runs a job on a different thread with a deep stack" {
    if (builtin.single_threaded) return;
    const Job = struct {
        caller_tid: std.Thread.Id,
        worker_tid: std.Thread.Id = 0,
        depth_reached: usize = 0,

        noinline fn recurse(depth: usize) usize {
            // About 4 KiB per frame: 8192 levels need about 32 MiB of stack.
            var pad: [4096]u8 = undefined;
            const volatile_pad: *volatile [4096]u8 = &pad;
            volatile_pad[0] = @truncate(depth);
            if (depth == 0) return volatile_pad[0];
            return recurse(depth - 1) + volatile_pad[0] - volatile_pad[0] + 1;
        }

        fn run(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.worker_tid = std.Thread.getCurrentId();
            self.depth_reached = recurse(8192);
        }
    };
    var worker = try Worker.create(std.testing.allocator, 64 * 1024 * 1024);
    defer worker.destroy();
    var job: Job = .{ .caller_tid = std.Thread.getCurrentId() };
    try worker.run(&job, Job.run);
    try std.testing.expect(job.worker_tid != job.caller_tid);
    try std.testing.expectEqual(@as(usize, 8192), job.depth_reached);
}

test "Worker reuses one thread for many sequential jobs" {
    if (builtin.single_threaded) return;
    const Job = struct {
        tid: std.Thread.Id = 0,
        count: usize = 0,
        fn run(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.tid = std.Thread.getCurrentId();
            self.count += 1;
        }
    };
    var worker = try Worker.create(std.testing.allocator, 1024 * 1024);
    defer worker.destroy();
    var job: Job = .{};
    try worker.run(&job, Job.run);
    const first_tid = job.tid;
    var i: usize = 1;
    while (i < 1000) : (i += 1) {
        try worker.run(&job, Job.run);
        try std.testing.expectEqual(first_tid, job.tid);
    }
    try std.testing.expectEqual(@as(usize, 1000), job.count);
    try std.testing.expect(first_tid != std.Thread.getCurrentId());
}

test "Worker destroy joins cleanly with and without jobs" {
    if (builtin.single_threaded) return;
    const idle = try Worker.create(std.testing.allocator, 1024 * 1024);
    idle.destroy();

    const Job = struct {
        ran: bool = false,
        fn run(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.ran = true;
        }
    };
    const used = try Worker.create(std.testing.allocator, 1024 * 1024);
    var job: Job = .{};
    try used.run(&job, Job.run);
    used.destroy();
    try std.testing.expect(job.ran);
}

test "Worker rejects a nested run with WorkerBusy instead of deadlocking" {
    if (builtin.single_threaded) return;
    const Job = struct {
        worker: *Worker,
        nested_result: ?error{WorkerBusy}!void = null,
        inner_ran: bool = false,
        fn inner(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.inner_ran = true;
        }
        fn outer(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.nested_result = self.worker.run(self, inner);
        }
    };
    var worker = try Worker.create(std.testing.allocator, 1024 * 1024);
    defer worker.destroy();
    var job: Job = .{ .worker = worker };
    try worker.run(&job, Job.outer);
    try std.testing.expectError(error.WorkerBusy, job.nested_result.?);
    try std.testing.expect(!job.inner_ran);
    // The worker stays usable after rejecting the nested run.
    try worker.run(&job, Job.inner);
    try std.testing.expect(job.inner_ran);
}
