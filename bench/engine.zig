const std = @import("std");
const workloads = @import("workloads.zig");
const stats = @import("stats.zig");
const cli = @import("cli.zig");
const report = @import("report.zig");
const paths = @import("bench_options");

// The build helper rejects budgets above the Osaka+ transaction cap.
pub const gas_limit: u64 = paths.gas_limit;
pub const instruction_limit: u32 = 300_000_000;

/// Each instantiation uses the real public Guillotine API. Loop dispatch needs
/// a separately configured module because its selector is a build-time option.
pub fn Runner(comptime evm: type, comptime fusion: bool) type {
    return struct {
        const Self = @This();
        const hardfork = std.meta.stringToEnum(evm.Hardfork, paths.hardfork) orelse @compileError("unknown benchmark hardfork");
        const precompile_hardfork = std.meta.stringToEnum(evm.Primitives.Hardfork, paths.hardfork) orelse @compileError("hardfork is absent from Voltaire");
        const Evm = evm.Evm(.{
            .eips = .{ .hardfork = hardfork },
            .enable_fusion = fusion,
            .loop_quota = instruction_limit,
            .tracer_config = .disabled,
        });
        const SetupEvm = evm.Evm(.{
            .eips = .{ .hardfork = hardfork },
            .enable_fusion = false,
            .loop_quota = instruction_limit,
            .tracer_config = .disabled,
        });
        const Address = evm.Primitives.Address;
        const caller = Address.fromU256(0x1000);
        const contract = Address.fromU256(0x1001);
        const child = Address.fromU256(0x2000);

        allocator: std.mem.Allocator,
        // Heap allocated: EVM retains a pointer to database for its lifetime.
        database: *evm.Database,
        machine: *Evm,
        target: Address = contract,
        input: []const u8,
        stage: []const u8 = "setup",

        pub fn available(workload: workloads.Workload) ?[]const u8 {
            return switch (workload.source) {
                .clz => if (!hardfork.isAtLeast(.OSAKA)) "CLZ requires OSAKA or later" else if (@hasField(evm.Opcode, "CLZ")) null else "CLZ handler is absent from this checkout",
                .precompile => |address| if (evm.precompiles.isPrecompile(Address.fromU256(address), precompile_hardfork)) null else "precompile is not enabled for the selected hardfork in this checkout",
                .p256verify => if (!hardfork.isAtLeast(.OSAKA)) "P256VERIFY requires OSAKA or later" else if (@hasDecl(evm.precompiles, "p256verify")) null else "P256VERIFY precompile is absent from this checkout",
                else => null,
            };
        }

        pub fn init(allocator: std.mem.Allocator, io: std.Io, workload: workloads.Workload, row: *report.Row) !Self {
            const database = try allocator.create(evm.Database);
            errdefer allocator.destroy(database);
            database.* = evm.Database.init(allocator);
            errdefer database.deinit();
            try database.set_account(caller.bytes, .{
                .balance = std.math.maxInt(u256),
                .nonce = 0,
                .code_hash = @as([32]u8, @splat(0)),
                .storage_root = @as([32]u8, @splat(0)),
            });
            const hash = try database.set_code(&.{ 0x60, 42, 0x60, 0, 0x52, 0x60, 32, 0x60, 0, 0xf3 });
            try database.set_account(child.bytes, .{
                .balance = 0,
                .nonce = 1,
                .code_hash = hash,
                .storage_root = @as([32]u8, @splat(0)),
            });
            const machine = try allocator.create(Evm);
            errdefer allocator.destroy(machine);
            var block = evm.BlockInfo.init();
            block.gas_limit = gas_limit;
            block.number = 24_000_000;
            block.timestamp = 1_800_000_000;
            machine.* = try Evm.init(allocator, database, block, .{
                .gas_limit = gas_limit,
                .coinbase = block.coinbase,
                .chain_id = 1,
            }, 0, caller);
            errdefer machine.deinit();
            var self = Self{ .allocator = allocator, .database = database, .machine = machine, .input = workload.input };
            switch (workload.source) {
                .fixture => |name| {
                    row.stage = "fixture/read-initcode";
                    const initcode = try loadFixture(io, allocator, name, "bytecode.txt");
                    defer allocator.free(initcode);
                    // Surface validation errors that Evm.call otherwise reduces
                    // to success=false, without changing the fixture bytes.
                    row.stage = "fixture/validate-initcode";
                    var analyzed = try SetupEvm.Bytecode.init(allocator, initcode);
                    defer analyzed.deinit();
                    row.stage = "fixture/deploy";
                    // Constructor gas and bytecode preprocessing are setup costs.
                    // Constructor execution is untimed and always uses the
                    // same unfused engine, independent of the measured mode.
                    const setup = try allocator.create(SetupEvm);
                    defer allocator.destroy(setup);
                    setup.* = try SetupEvm.init(allocator, database, block, .{
                        .gas_limit = gas_limit,
                        .coinbase = block.coinbase,
                        .chain_id = 1,
                    }, 0, caller);
                    defer setup.deinit();
                    var deployment = setup.call(.{ .create = .{
                        .caller = caller,
                        .value = 0,
                        .init_code = initcode,
                        .gas = gas_limit,
                    } });
                    defer deployment.deinit(allocator);
                    if (!deployment.success) {
                        row.observed_gas_left = deployment.gas_left;
                        row.observed_output_bytes = deployment.output.len;
                        return error.DeploymentFailed;
                    }
                    self.target = deployment.created_address orelse return error.MissingCreatedAddress;
                    row.stage = "fixture/read-runtime";
                    const runtime = try database.get_code_by_address(self.target.bytes);
                    if (runtime.len == 0) return error.EmptyDeployedCode;
                    row.stage = "fixture/read-calldata";
                    self.input = try loadFixture(io, allocator, name, "calldata.txt");
                },
                .bytecode => |code| try self.install(code),
                .precompile => |address| self.target = Address.fromU256(address),
                .p256verify => self.target = Address.fromU256(0x100),
                .clz => {
                    if (comptime @hasField(evm.Opcode, "CLZ")) {
                        var code: std.ArrayList(u8) = .empty;
                        defer code.deinit(allocator);
                        for (0..workloads.repetitions) |_| try code.appendSlice(allocator, &.{ 0x60, 7, @intFromEnum(evm.Opcode.CLZ), 0x60, 0, 0x52 });
                        try code.appendSlice(allocator, &.{ 0x60, 32, 0x60, 0, 0xf3 });
                        try self.install(code.items);
                    } else return error.UnsupportedOpcode;
                },
            }
            if (workload.storage) {
                for (0..workloads.repetitions) |slot| try database.set_storage(self.target.bytes, slot, 7);
            }
            return self;
        }

        fn install(self: *Self, code: []const u8) !void {
            if (code.len == 0) return error.EmptyBytecode;
            const hash = try self.database.set_code(code);
            try self.database.set_account(self.target.bytes, .{
                .balance = 0,
                .nonce = 1,
                .code_hash = hash,
                .storage_root = @as([32]u8, @splat(0)),
            });
        }

        pub fn deinit(self: *Self, workload: workloads.Workload) void {
            if (workload.source == .fixture) self.allocator.free(self.input);
            self.machine.deinit();
            self.allocator.destroy(self.machine);
            self.database.deinit();
            self.allocator.destroy(self.database);
        }

        fn invoke(self: *Self) Evm.CallResult {
            return self.machine.simulate(.{ .call = .{
                .caller = caller,
                .to = self.target,
                .value = 0,
                .input = self.input,
                .gas = gas_limit,
            } });
        }

        fn validate(workload: workloads.Workload, result: Evm.CallResult) !void {
            if (!result.success) return error.ExecutionFailed;
            if (result.gas_left >= gas_limit) return error.NoGasConsumed;
            if (workload.output_len) |length| {
                if (result.output.len != length) return error.UnexpectedOutputLength;
            }
            if (workload.expected) |expected| {
                if (result.output.len != 32) return error.UnexpectedOutputLength;
                if (std.mem.readInt(u256, result.output[0..32], .big) != expected) return error.UnexpectedOutput;
            }
            // Curve operations must not silently take an infinity/empty-output path.
            switch (workload.source) {
                .precompile => |address| if (address == 1 or address == 6 or address == 7 or address == 0x12) {
                    var nonzero: u8 = 0;
                    for (result.output) |byte| nonzero |= byte;
                    if (nonzero == 0) return error.UnexpectedInfinity;
                },
                else => {},
            }
        }

        fn check(workload: workloads.Workload, result: Evm.CallResult, row: *report.Row) !void {
            validate(workload, result) catch |err| {
                row.observed_gas_left = result.gas_left;
                row.observed_output_bytes = result.output.len;
                return err;
            };
        }

        /// Validation is deliberately outside the timed region. Every sample
        /// must match the preflight gas and output, including after warmup.
        pub fn measure(self: *Self, io: std.Io, workload: workloads.Workload, options: cli.Options, row: *report.Row) !void {
            row.stage = null;
            self.stage = "preflight";
            var reference = self.invoke();
            defer reference.deinit(self.allocator);
            try check(workload, reference, row);
            const gas = gas_limit - reference.gas_left;
            self.stage = "warmup";
            for (0..options.warmup) |_| {
                var result = self.invoke();
                defer result.deinit(self.allocator);
                try check(workload, result, row);
                if (result.gas_left != reference.gas_left or !std.mem.eql(u8, result.output, reference.output)) return error.NonDeterministicExecution;
            }
            const samples = try self.allocator.alloc(u64, options.iterations);
            defer self.allocator.free(samples);
            self.stage = "measurement";
            for (samples, 0..) |*sample, index| {
                row.sample_index = index;
                const start = std.Io.Timestamp.now(io, .awake);
                var result = self.invoke();
                sample.* = @intCast(start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds);
                defer result.deinit(self.allocator);
                try check(workload, result, row);
                if (result.gas_left != reference.gas_left or !std.mem.eql(u8, result.output, reference.output)) return error.NonDeterministicExecution;
            }
            row.gas_used = gas;
            row.statistics = try stats.summarize(samples, workload.operations, gas);
            row.ns_per_op = row.statistics.?.median_ns / @as(f64, @floatFromInt(workload.operations));
            row.status = "ok";
            row.sample_index = null;
        }
    };
}

fn loadFixture(io: std.Io, allocator: std.mem.Allocator, name: []const u8, file: []const u8) ![]u8 {
    const path = try std.Io.Dir.path.join(allocator, &.{ paths.fixture_directory, name, file });
    defer allocator.free(path);
    const hex = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(hex);
    return workloads.decodeHex(allocator, hex);
}
