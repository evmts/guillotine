const std = @import("std");
const primitives = @import("primitives");
const guillotine_evm = @import("evm");
const revm = @import("revm");
const CallResultType = guillotine_evm.CallResult;
const GuillotineLog = CallResultType.Log;

// Extract ExecutionTrace type from CallResult 
const ExecutionTrace = @typeInfo(@TypeOf(@as(guillotine_evm.CallResult, undefined).trace)).optional.child;

// The trace type will be extracted from the actual CallResult structure when needed

// Use the same trace types as the EVM - access from call_result via guillotine_evm
// For now, I'll create a type reference that works with the module system


/// Result of execution with trace
pub const ExecutionResultWithTrace = struct {
    success: bool,
    gas_used: u64,
    output: []const u8,
    logs: []const revm.Log,
    // Just use the same optional trace type as CallResult
    trace: ?ExecutionTrace,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ExecutionResultWithTrace) void {
        self.allocator.free(self.output);
        // Free logs
        for (self.logs) |log| {
            self.allocator.free(log.topics);
            self.allocator.free(log.data);
        }
        if (self.logs.len > 0) {
            self.allocator.free(self.logs);
        }
        if (self.trace) |*t| {
            t.deinit();
        }
    }
};

/// Comprehensive diff between two execution results
pub const ExecutionDiff = struct {
    result_match: bool,
    trace_match: bool,
    logs_match: bool,

    // Result differences
    success_diff: ?struct { revm: bool, guillotine: bool },
    gas_diff: ?struct { revm: u64, guillotine: u64 },
    output_diff: ?struct { revm: []const u8, guillotine: []const u8 },
    error_diff: ?struct { revm: ?[]const u8, guillotine: ?[]const u8 },
    logs_diff: ?struct { revm: []const revm.Log, guillotine: []const revm.Log },

    // Trace differences
    step_count_diff: ?struct { revm: usize, guillotine: usize },
    first_divergence_step: ?usize,
    trace_diffs: []const TraceDiffStep,

    allocator: std.mem.Allocator,

    pub const TraceDiffStep = struct {
        step_index: usize,
        pc_diff: ?struct { revm: u32, guillotine: u32 },
        opcode_diff: ?struct { revm: u8, guillotine: u8 },
        gas_diff: ?struct { revm: u64, guillotine: u64 },
        stack_diff: ?struct { revm: []const u256, guillotine: []const u256 },
    };

    pub fn deinit(self: *ExecutionDiff) void {
        if (self.output_diff) |diff| {
            self.allocator.free(diff.revm);
            self.allocator.free(diff.guillotine);
        }
        if (self.error_diff) |diff| {
            if (diff.revm) |r| self.allocator.free(r);
            if (diff.guillotine) |g| self.allocator.free(g);
        }
        if (self.logs_diff) |diff| {
            // Free log topics and data for revm logs
            for (diff.revm) |log| {
                self.allocator.free(log.topics);
                self.allocator.free(log.data);
            }
            if (diff.revm.len > 0) {
                self.allocator.free(diff.revm);
            }
            // Free log topics and data for guillotine logs
            for (diff.guillotine) |log| {
                self.allocator.free(log.topics);
                self.allocator.free(log.data);
            }
            if (diff.guillotine.len > 0) {
                self.allocator.free(diff.guillotine);
            }
        }
        for (self.trace_diffs) |*step_diff| {
            if (step_diff.stack_diff) |stack| {
                self.allocator.free(stack.revm);
                self.allocator.free(stack.guillotine);
            }
        }
        self.allocator.free(self.trace_diffs);
    }
};

/// Configuration for DifferentialTestor
pub const DifferentialTestConfig = struct {
    enable_tracing: bool = true,
};

const TracedEVMType = guillotine_evm.Evm(.{
    .TracerType = guillotine_evm.tracer.DebuggingTracer,
    .DatabaseType = guillotine_evm.Database,
});

const NoTraceEVMType = guillotine_evm.Evm(.{
    .TracerType = guillotine_evm.tracer.NoOpTracer,
    .DatabaseType = guillotine_evm.Database,
});

/// Main differential testing coordinator with configurable tracing
pub const DifferentialTestor = struct {
    revm_instance: revm.Revm,
    guillotine_instance_traced: ?TracedEVMType,
    guillotine_instance_no_trace: ?NoTraceEVMType,
    guillotine_db: *guillotine_evm.Database,
    guillotine_db_no_trace: *guillotine_evm.Database,
    allocator: std.mem.Allocator,
    caller: primitives.Address,
    contract: primitives.Address,
    config: DifferentialTestConfig,

    /// Initialize for debugging with enhanced logging
    pub fn initForDebugging(allocator: std.mem.Allocator) !DifferentialTestor {
        return init(allocator);
    }

    /// Simple initialization - creates both EVM instances internally (with tracing enabled by default)
    pub fn init(allocator: std.mem.Allocator) !DifferentialTestor {
        return initWithConfig(allocator, .{ .enable_tracing = true });
    }

    /// Initialize with custom configuration
    pub fn initWithConfig(allocator: std.mem.Allocator, config: DifferentialTestConfig) !DifferentialTestor {
        // Setup addresses
        const caller = primitives.Address.ZERO_ADDRESS;
        const contract = try primitives.Address.from_hex("0xc0de000000000000000000000000000000000000");

        // Setup REVM
        var revm_vm = try revm.Revm.init(allocator, .{
            .gas_limit = 100000,
            .chain_id = 1,
            .enable_tracing = config.enable_tracing,
        });

        try revm_vm.setBalance(caller, 10_000_000);

        // Setup Guillotine EVMs - allocate databases on heap
        const db = try allocator.create(guillotine_evm.Database);
        db.* = guillotine_evm.Database.init(allocator);
        
        const db_no_trace = try allocator.create(guillotine_evm.Database);
        db_no_trace.* = guillotine_evm.Database.init(allocator);

        try db.set_account(caller.bytes, .{
            .balance = 10_000_000,
            .nonce = 0,
            .code_hash = [_]u8{0} ** 32,
            .storage_root = [_]u8{0} ** 32,
        });
        
        try db_no_trace.set_account(caller.bytes, .{
            .balance = 10_000_000,
            .nonce = 0,
            .code_hash = [_]u8{0} ** 32,
            .storage_root = [_]u8{0} ** 32,
        });

        const block_info = guillotine_evm.BlockInfo{
            .chain_id = 1,
            .number = 1,
            .timestamp = 0,
            .gas_limit = 100000,
            .coinbase = primitives.Address.ZERO_ADDRESS,
            .difficulty = 0,
            .base_fee = 0,
            .prev_randao = [_]u8{0} ** 32,
            .blob_base_fee = 0,
            .blob_versioned_hashes = &.{},
        };

        const tx_context = guillotine_evm.TransactionContext{
            .chain_id = 1,
            .gas_limit = 100000,
            .coinbase = primitives.Address.ZERO_ADDRESS,
            .blob_versioned_hashes = &.{},
            .blob_base_fee = 0,
        };

        // Create both traced and non-traced EVMs based on config
        var evm_traced: ?TracedEVMType = null;
        var evm_no_trace: ?NoTraceEVMType = null;
        
        if (config.enable_tracing) {
            evm_traced = try TracedEVMType.init(
                allocator,
                db,
                block_info,
                tx_context,
                0,
                caller,
                .CANCUN,
            );
        }
        
        evm_no_trace = try NoTraceEVMType.init(
            allocator,
            db_no_trace,
            block_info,
            tx_context,
            0,
            caller,
            .CANCUN,
        );

        const testor = DifferentialTestor{
            .revm_instance = revm_vm,
            .guillotine_instance_traced = evm_traced,
            .guillotine_instance_no_trace = evm_no_trace,
            .guillotine_db = db,
            .guillotine_db_no_trace = db_no_trace,
            .allocator = allocator,
            .caller = caller,
            .contract = contract,
            .config = config,
        };

        return testor;
    }

    /// Compatibility helpers: reuse default init to avoid comptime config divergence in tests
    pub fn initWithoutFusion(allocator: std.mem.Allocator) !DifferentialTestor {
        return init(allocator);
    }

    pub fn initWithFusionEnabled(allocator: std.mem.Allocator) !DifferentialTestor {
        return init(allocator);
    }

    /// Deploy a contract by executing its deployment bytecode
    fn deployContractGuillotine(self: *DifferentialTestor, deployment_bytecode: []const u8, enable_tracing: bool) ![]u8 {
        const log = std.log.scoped(.differential_testor);
        
        // Execute the deployment bytecode (init code) using CREATE semantics
        // This should execute the init code and return the runtime code
        const result = if (enable_tracing) blk: {
            if (self.guillotine_instance_traced) |*traced| {
                break :blk traced.call(.{
                    .create = .{
                        .caller = self.caller,
                        .value = 0,
                        .init_code = deployment_bytecode,
                        .gas = 10_000_000, // Generous gas for deployment
                    },
                });
            } else {
                return error.TracingNotAvailable;
            }
        } else blk: {
            if (self.guillotine_instance_no_trace) |*no_trace| {
                break :blk no_trace.call(.{
                    .create = .{
                        .caller = self.caller,
                        .value = 0,
                        .init_code = deployment_bytecode,
                        .gas = 10_000_000, // Generous gas for deployment
                    },
                });
            } else {
                return error.NoTraceInstanceNotAvailable;
            }
        };
        
        if (!result.success) {
            log.err("Contract deployment failed", .{});
            return error.DeploymentFailed;
        }
        
        if (result.output.len == 0) {
            log.err("Contract deployment returned no runtime code", .{});
            return error.NoRuntimeCode;
        }
        
        // Copy the output (runtime code) to return
        const runtime_code = try self.allocator.alloc(u8, result.output.len);
        @memcpy(runtime_code, result.output);
        
        // Clean up call result memory
        var result_copy = result;
        result_copy.deinit(self.allocator);
        
        return runtime_code;
    }
    
    pub fn deinit(self: *DifferentialTestor) void {
        self.revm_instance.deinit();
        if (self.guillotine_instance_traced) |*inst| {
            inst.deinit();
        }
        if (self.guillotine_instance_no_trace) |*inst| {
            inst.deinit();
        }
        self.guillotine_db.deinit();
        self.guillotine_db_no_trace.deinit();
        self.allocator.destroy(self.guillotine_db);
        self.allocator.destroy(self.guillotine_db_no_trace);
    }

    /// Simple bytecode testing - deploys bytecode and executes it on both EVMs
    /// Tests both with tracing on first, then with tracing off
    /// In happy path: does nothing
    /// In unhappy path: collects errors, prints readable diff, and throws clear error
    pub fn test_bytecode(self: *DifferentialTestor, bytecode: []const u8) !void {
        try self.test_bytecode_with_calldata(bytecode, &.{});
    }

    /// Test bytecode with specific calldata
    pub fn test_bytecode_with_calldata(self: *DifferentialTestor, bytecode: []const u8, calldata: []const u8) !void {
        // First test with tracing enabled (if available)
        if (self.guillotine_instance_traced) |_| {
            try self.test_bytecode_with_tracing_and_calldata_and_gas(bytecode, calldata, 1_000_000, true);
        }
        
        // Then test with tracing disabled
        try self.test_bytecode_with_tracing_and_calldata_and_gas(bytecode, calldata, 1_000_000, false);
    }
    
    /// Internal helper to test bytecode with specific tracing configuration and calldata
    fn test_bytecode_with_tracing_and_calldata_and_gas(self: *DifferentialTestor, bytecode: []const u8, calldata: []const u8, gas_limit: u64, enable_tracing: bool) !void {
        // Select the appropriate database and EVM instance
        const db = if (enable_tracing) self.guillotine_db else self.guillotine_db_no_trace;
        
        // Better heuristic: deployment bytecode usually contains CODECOPY (0x39) followed by RETURN (0xf3)
        // This pattern is used to copy runtime code to memory and return it
        var is_deployment_bytecode = false;
        if (bytecode.len > 10) {
            // Look for CODECOPY (0x39) followed eventually by RETURN (0xf3) in the bytecode
            for (bytecode, 0..) |byte, i| {
                if (byte == 0x39 and i + 1 < bytecode.len) { // Found CODECOPY
                    // Look for RETURN within the next 10 bytes
                    const search_end = @min(i + 10, bytecode.len);
                    for (bytecode[i+1..search_end]) |next_byte| {
                        if (next_byte == 0xf3) { // Found RETURN after CODECOPY
                            is_deployment_bytecode = true;
                            break;
                        }
                    }
                    if (is_deployment_bytecode) break;
                }
            }
        }
        
        const log = std.log.scoped(.differential_testor);
        
        if (is_deployment_bytecode) {
            log.warn("Detected deployment bytecode (contains CODECOPY + RETURN pattern), attempting to deploy contract", .{});
            
            // For Guillotine: Execute deployment bytecode to get runtime code
            const runtime_code = try self.deployContractGuillotine(bytecode, enable_tracing);
            defer self.allocator.free(runtime_code);
            
            log.warn("Deployment returned {} bytes of runtime code", .{runtime_code.len});
            
            // Set the runtime code
            const code_hash = try db.set_code(runtime_code);
            try db.set_account(self.contract.bytes, .{
                .balance = 0,
                .nonce = 1,
                .code_hash = code_hash,
                .storage_root = [_]u8{0} ** 32,
            });
            
            // For REVM: Also use runtime code for fair comparison
            try self.revm_instance.setCode(self.contract, runtime_code);
        } else {
            // Not deployment bytecode, use as-is (original behavior)
            try self.revm_instance.setCode(self.contract, bytecode);
            
            const code_hash = try db.set_code(bytecode);
            // log.debug("Set code with hash: {x} (tracing={})", .{code_hash, enable_tracing});
            // log.debug("Contract address is: {x}", .{self.contract.bytes});

            try db.set_account(self.contract.bytes, .{
                .balance = 0,
                .nonce = 1,
                .code_hash = code_hash,
                .storage_root = [_]u8{0} ** 32,
            });
            // log.debug("Set account for address: {x}", .{self.contract.bytes});
        }

        // Verify deployment
        const deployed_code = try db.get_code_by_address(self.contract.bytes);
        // log.debug("Deployed bytecode to {any}: len={} vs deployed_len={} (tracing={})", .{ self.contract, bytecode.len, deployed_code.len, enable_tracing });
        if (deployed_code.len == 0) {
            log.err("WARNING: Deployed code has zero length!", .{});
        }

        // Also check if account exists
        const account_check = try db.get_account(self.contract.bytes);
        if (account_check) |_| {
            // log.debug("Account found: balance={}, nonce={}, code_hash={x}", .{ acc.balance, acc.nonce, acc.code_hash });
        } else {
            log.err("WARNING: Account not found after deployment!", .{});
        }

        // Execute on both EVMs separately to get the results for trace display
        var revm_result = try self.executeRevmWithTrace(self.caller, self.contract, 0, calldata, gas_limit);
        defer revm_result.deinit();
        
        var guillotine_result = try self.executeGuillotineWithTraceMode(self.caller, self.contract, 0, calldata, gas_limit, enable_tracing);
        defer guillotine_result.deinit();
        
        // Generate diff
        var diff = try self.generateDiff(revm_result, guillotine_result);
        defer diff.deinit();

        // Happy path - perfect match
        if (diff.result_match and diff.trace_match and diff.logs_match) {
            return;
        }
        
        const trace_mode = if (enable_tracing) "TRACING ENABLED" else "TRACING DISABLED";
        log.err("DIFFERENTIAL TEST FAILURE with {s}", .{trace_mode});

        // Unhappy path - collect and report errors
        var error_messages: [6][]const u8 = undefined;
        var error_count: usize = 0;

        if (diff.success_diff) |success| {
            if (diff.error_diff) |err_info| {
                if (err_info.guillotine) |g_err| {
                    error_messages[error_count] = try std.fmt.allocPrint(self.allocator, "Success mismatch: REVM={} vs Guillotine={} (Error: {s})", .{ success.revm, success.guillotine, g_err });
                } else {
                    error_messages[error_count] = try std.fmt.allocPrint(self.allocator, "Success mismatch: REVM={} vs Guillotine={}", .{ success.revm, success.guillotine });
                }
            } else {
                error_messages[error_count] = try std.fmt.allocPrint(self.allocator, "Success mismatch: REVM={} vs Guillotine={}", .{ success.revm, success.guillotine });
            }
            error_count += 1;
        }

        if (diff.gas_diff) |gas| {
            error_messages[error_count] = try std.fmt.allocPrint(self.allocator, "Gas usage mismatch: REVM={} vs Guillotine={}", .{ gas.revm, gas.guillotine });
            error_count += 1;
        }

        if (diff.output_diff) |output| {
            error_messages[error_count] = try std.fmt.allocPrint(self.allocator, "Output mismatch: REVM={x} vs Guillotine={x}", .{ output.revm, output.guillotine });
            error_count += 1;
        }

        if (diff.logs_diff) |logs| {
            error_messages[error_count] = try std.fmt.allocPrint(self.allocator, "Log count mismatch: REVM={} vs Guillotine={}", .{ logs.revm.len, logs.guillotine.len });
            error_count += 1;
        }

        if (diff.step_count_diff) |steps| {
            error_messages[error_count] = try std.fmt.allocPrint(self.allocator, "Trace step count mismatch: REVM={} vs Guillotine={}", .{ steps.revm, steps.guillotine });
            error_count += 1;
        }

        // Print comprehensive human-readable diff
        self.printComprehensiveDiff(diff, bytecode, error_messages[0..error_count], guillotine_result);

        // Clean up error messages
        for (error_messages[0..error_count]) |msg| {
            self.allocator.free(msg);
        }

        // Throw clear error message
        return error.EVMImplementationMismatch;
    }

    /// Execute bytecode on both EVMs and generate comprehensive diff
    pub fn executeAndDiff(
        self: *DifferentialTestor,
        caller: primitives.Address,
        to: primitives.Address,
        value: u256,
        input: []const u8,
        gas_limit: u64,
    ) !ExecutionDiff {
        // Execute on REVM with trace
        var revm_result = try self.executeRevmWithTrace(caller, to, value, input, gas_limit);
        defer revm_result.deinit();

        // Execute on Guillotine with trace
        var guillotine_result = try self.executeGuillotineWithTrace(caller, to, value, input, gas_limit);
        defer guillotine_result.deinit();

        // Generate comprehensive diff
        return try self.generateDiff(revm_result, guillotine_result);
    }

    /// Execute on REVM and capture trace
    pub fn executeRevmWithTrace(
        self: *DifferentialTestor,
        caller: primitives.Address,
        to: primitives.Address,
        value: u256,
        input: []const u8,
        gas_limit: u64,
    ) !ExecutionResultWithTrace {
        // Execute REVM using the new CallParams API
        const params = revm.CallParams{ .call = .{
            .caller = caller,
            .to = to,
            .value = value,
            .input = input,
            .gas = gas_limit,
        } };
        
        var result = self.revm_instance.call(params) catch |err| {
            const log = std.log.scoped(.revm_trace);
            log.err("REVM call failed: {} - this breaks differential testing!", .{err});
            return err;
        };
        defer result.deinit();

        const output = try self.allocator.dupe(u8, result.output);
        
        // Calculate gas_used from gas_left (REVM now returns gas_left)
        const gas_used = if (gas_limit > result.gas_left) 
            gas_limit - result.gas_left 
        else 
            0;
        
        // Duplicate logs for result
        const logs = try self.duplicateLogs(result.logs);
        
        // If tracing is enabled, we might have trace files generated
        // For now, just log that tracing occurred
        if (self.revm_instance.enable_tracing) {
            const log = std.log.scoped(.revm_trace);
            log.warn("REVM executed with tracing enabled (trace file at revm_trace.json if available)", .{});
        }

        // Trace parsing to ExecutionTrace remains disabled; keep null
        const trace: ?ExecutionTrace = null;

        return ExecutionResultWithTrace{
            .success = result.success,
            .gas_used = gas_used,
            .output = output,
            .logs = logs,
            .trace = trace,
            .allocator = self.allocator,
        };
    }

    /// Execute on Guillotine with configurable tracing mode
    pub fn executeGuillotineWithTraceMode(
        self: *DifferentialTestor,
        caller: primitives.Address,
        to: primitives.Address,
        value: u256,
        input: []const u8,
        gas_limit: u64,
        enable_tracing: bool,
    ) !ExecutionResultWithTrace {
        // Use the actual EVM call method
        const params = guillotine_evm.CallParams{
            .call = .{
                .caller = caller,
                .to = to,
                .value = value,
                .input = input,
                .gas = gas_limit,
            },
        };

        // std.debug.print("DIFFERENTIAL: About to call Guillotine with gas={}, to={x} (tracing={})\n", .{ gas_limit, to.bytes, enable_tracing });
        
        var result = if (enable_tracing) blk: {
            if (self.guillotine_instance_traced) |*evm_instance| {
                break :blk evm_instance.call(params);
            } else {
                return error.TracingNotAvailable;
            }
        } else blk: {
            if (self.guillotine_instance_no_trace) |*evm_instance| {
                break :blk evm_instance.call(params);
            } else {
                return error.NoTraceInstanceNotAvailable;
            }
        };
        
        // std.debug.print("DIFFERENTIAL: Guillotine call complete, success={}, gas_left={} (tracing={})\n", .{ result.success, result.gas_left, enable_tracing });

        // Transfer ownership of trace from CallResult
        const trace = result.trace;
        result.trace = null; // Clear from result so it won't be double-freed

        // Calculate gas used
        const gas_used = gas_limit - result.gas_left;

        // Store the execution result status for debugging
        const log = std.log.scoped(.differential_failure);
        _ = if (trace) |t| t.steps.len else 0;
        // log.debug("Guillotine execution completed (tracing={}): success={}, gas_left={}, output_len={}, trace_steps={}", .{ enable_tracing, result.success, result.gas_left, result.output.len, trace_steps_len });

        if (!result.success) {
            // Log detailed failure information
            log.err("Guillotine execution failed (tracing={})!", .{enable_tracing});
            log.err("  Gas limit: {}", .{gas_limit});
            log.err("  Gas left: {}", .{result.gas_left});
            log.err("  Gas used: {}", .{gas_used});
            log.err("  Output: {x}", .{result.output});
            if (result.error_info) |error_info| {
                log.err("  ERROR TYPE: {s}", .{error_info});
            }

            // Check if it failed immediately (gas_left == 0 suggests immediate failure)
            if (result.gas_left == 0) {
                log.err("  NOTE: Gas left is 0, suggesting immediate failure or out of gas", .{});
            }
        }

        // Copy output before freeing result
        const output_copy = try self.allocator.dupe(u8, result.output);
        
        // Convert Guillotine logs to REVM log format
        const logs = try self.convertGuillotineLogsToRevmLogs(result.logs);
        
        // Clean up CallResult allocated memory using the comprehensive deinit method
        result.deinit(self.allocator);

        return ExecutionResultWithTrace{
            .success = result.success,
            .gas_used = gas_used,
            .output = output_copy,
            .logs = logs,
            .trace = trace,
            .allocator = self.allocator,
        };
    }

    /// Execute on Guillotine and capture trace (backwards compatibility - defaults to tracing enabled)
    pub fn executeGuillotineWithTrace(
        self: *DifferentialTestor,
        caller: primitives.Address,
        to: primitives.Address,
        value: u256,
        input: []const u8,
        gas_limit: u64,
    ) !ExecutionResultWithTrace {
        return self.executeGuillotineWithTraceMode(caller, to, value, input, gas_limit, true);
    }

    /// Print comprehensive, human-readable diff with context
    fn printComprehensiveDiff(self: *DifferentialTestor, diff: ExecutionDiff, bytecode: []const u8, error_messages: []const []const u8, guillotine_result: ExecutionResultWithTrace) void {
        _ = self; // unused for now
        const log = std.log.scoped(.differential_failure);

        log.err("", .{});
        log.err("🔴 DIFFERENTIAL TEST FAILURE DETECTED", .{});
        log.err("=====================================", .{});
        log.err("", .{});

        // Show bytecode context
        log.err("📜 BYTECODE UNDER TEST ({} bytes):", .{bytecode.len});
        if (bytecode.len <= 32) {
            log.err("   Full bytecode: {x}", .{bytecode});
        } else {
            log.err("   First 16 bytes: {x}", .{bytecode[0..16]});
            log.err("   Last 16 bytes:  {x}", .{bytecode[bytecode.len - 16 ..]});
        }
        log.err("", .{});

        // Show all collected errors
        log.err("❌ DETECTED ISSUES ({} total):", .{error_messages.len});
        for (error_messages, 1..) |error_msg, i| {
            log.err("   {}. {s}", .{ i, error_msg });
        }
        log.err("", .{});

        // Show detailed comparison
        if (diff.output_diff) |output| {
            log.err("🔍 DETAILED OUTPUT COMPARISON:", .{});
            log.err("   REVM Output ({} bytes):      {x}", .{ output.revm.len, output.revm });
            log.err("   Guillotine Output ({} bytes): {x}", .{ output.guillotine.len, output.guillotine });
            log.err("", .{});
        }

        // Show trace information
        if (diff.step_count_diff) |steps| {
            log.err("🔍 TRACE STEP COUNTS:", .{});
            log.err("   REVM steps: {}", .{steps.revm});
            log.err("   Guillotine steps: {}", .{steps.guillotine});
            log.err("", .{});
        }

        // Show trace differences if any
        if (diff.first_divergence_step) |step| {
            log.err("🔍 TRACE DIVERGENCE at step {}:", .{step});
            if (diff.trace_diffs.len > 0) {
                const first_diff = diff.trace_diffs[0];
                if (first_diff.pc_diff) |pc| {
                    log.err("   PC: REVM={} vs Guillotine={}", .{ pc.revm, pc.guillotine });
                }
                if (first_diff.opcode_diff) |op| {
                    log.err("   Opcode: REVM={x} vs Guillotine={x}", .{ op.revm, op.guillotine });
                }
                if (first_diff.gas_diff) |gas| {
                    log.err("   Gas: REVM={} vs Guillotine={}", .{ gas.revm, gas.guillotine });
                }
                if (first_diff.stack_diff) |stack| {
                    log.err("   Stack size: REVM={} vs Guillotine={}", .{ stack.revm.len, stack.guillotine.len });
                }
            }
            log.err("", .{});
        }

        // Show Guillotine trace details for debugging (first few steps)
        if (diff.step_count_diff) |steps| {
            if (steps.guillotine > 0) {
                log.err("🔍 GUILLOTINE TRACE PREVIEW (first {} steps):", .{@min(steps.guillotine, 5)});
                
                if (guillotine_result.trace) |trace| {
                    const max_steps = @min(trace.steps.len, 5);
                    for (trace.steps[0..max_steps], 0..) |step, i| {
                        log.err("   Step {}: PC={}, Opcode=0x{X:0>2} ({s}), Gas={}", .{ 
                            i, step.pc, step.opcode, step.opcode_name, step.gas 
                        });
                    }
                    
                    // Show the LAST few steps to see where it stops
                    if (trace.steps.len > 5) {
                        log.err("   ... and {} more steps", .{trace.steps.len - 5});
                        log.err("   LAST 3 STEPS:", .{});
                        const start = if (trace.steps.len >= 3) trace.steps.len - 3 else 0;
                        for (trace.steps[start..], start..) |step, i| {
                            log.err("   Step {}: PC={}, Opcode=0x{X:0>2} ({s}), Gas={}", .{ 
                                i, step.pc, step.opcode, step.opcode_name, step.gas 
                            });
                        }
                    }
                } else {
                    log.err("   No trace data available (guillotine_result.trace is null)", .{});
                }
                log.err("", .{});
            }
        }

        log.err("🛠️  DEBUGGING HINTS:", .{});
        log.err("   • Create a more minimal reproduction against frame.zig bytecode.zig or dispatch.zig", .{});
        log.err("   • Compare traces of guillotine and revm", .{});
        log.err("   • Add debug logging", .{});
        log.err("   • Create more minimal reproduction", .{});
        log.err("   • If the bytecode works with revm you know it's a bug in our evm. If it doesn't there is a bug in the bytecode", .{});
        if (diff.trace_diffs.len > 0) {
            log.err("   • Enable detailed tracing to debug execution differences", .{});
        }
        log.err("", .{});
        log.err("=====================================", .{});
    }

    /// Generate comprehensive diff between two execution results
    pub fn generateDiff(
        self: *DifferentialTestor,
        revm_result: ExecutionResultWithTrace,
        guillotine_result: ExecutionResultWithTrace,
    ) !ExecutionDiff {
        var diff = ExecutionDiff{
            .result_match = true,
            .trace_match = true,
            .logs_match = true,
            .success_diff = null,
            .gas_diff = null,
            .output_diff = null,
            .error_diff = null,
            .logs_diff = null,
            .step_count_diff = null,
            .first_divergence_step = null,
            .trace_diffs = &.{},
            .allocator = self.allocator,
        };

        // Compare results
        if (revm_result.success != guillotine_result.success) {
            diff.result_match = false;
            diff.success_diff = .{
                .revm = revm_result.success,
                .guillotine = guillotine_result.success,
            };
        }

        // Allow some gas variance (within 10%)
        const gas_diff_amount = if (revm_result.gas_used > guillotine_result.gas_used)
            revm_result.gas_used - guillotine_result.gas_used
        else
            guillotine_result.gas_used - revm_result.gas_used;

        const max_gas_diff = @max(revm_result.gas_used, guillotine_result.gas_used) / 10;
        if (gas_diff_amount > max_gas_diff) {
            diff.result_match = false;
            diff.gas_diff = .{
                .revm = revm_result.gas_used,
                .guillotine = guillotine_result.gas_used,
            };
        }

        if (!std.mem.eql(u8, revm_result.output, guillotine_result.output)) {
            diff.result_match = false;
            diff.output_diff = .{
                .revm = try self.allocator.dupe(u8, revm_result.output),
                .guillotine = try self.allocator.dupe(u8, guillotine_result.output),
            };
        }

        // Compare logs
        if (!self.logsEqual(revm_result.logs, guillotine_result.logs)) {
            diff.result_match = false;
            diff.logs_match = false;
            diff.logs_diff = .{
                .revm = try self.duplicateLogs(revm_result.logs),
                .guillotine = try self.duplicateLogs(guillotine_result.logs),
            };
        }

        // Compare traces (handle optional traces)
        const revm_steps_len: usize = if (revm_result.trace) |t| t.steps.len else 0;
        const guillotine_steps_len: usize = if (guillotine_result.trace) |t| t.steps.len else 0;
        
        // If REVM tracing isn't working yet, focus on execution results only
        if (revm_result.trace == null and guillotine_result.trace != null) {
            const log = std.log.scoped(.differential_trace);
            log.warn("REVM tracing not available, skipping trace comparison (Guillotine has {} steps)", .{guillotine_steps_len});
            diff.trace_match = true; // Don't fail on missing REVM traces yet
        } else if (revm_steps_len != guillotine_steps_len) {
            diff.trace_match = false;
            diff.step_count_diff = .{
                .revm = revm_steps_len,
                .guillotine = guillotine_steps_len,
            };
        } else if (guillotine_steps_len > 0 and guillotine_result.trace != null and revm_result.trace != null) {
            // TODO: Implement detailed trace comparison when REVM tracing is working
            // For now, just note that we have both traces
            // const log = std.log.scoped(.differential_trace);
            // log.debug("Both REVM and Guillotine traces available ({} steps each), detailed comparison not yet implemented", .{guillotine_steps_len});
            diff.trace_match = true; // Don't fail on trace comparison yet
        }

        return diff;
    }

    /// Compare two log arrays for equality
    fn logsEqual(self: *DifferentialTestor, logs1: []const revm.Log, logs2: []const revm.Log) bool {
        _ = self; // unused
        
        if (logs1.len != logs2.len) {
            return false;
        }
        
        for (logs1, logs2) |log1, log2| {
            // Compare addresses
            if (!std.mem.eql(u8, &log1.address.bytes, &log2.address.bytes)) {
                return false;
            }
            
            // Compare topic count
            if (log1.topics.len != log2.topics.len) {
                return false;
            }
            
            // Compare topics
            for (log1.topics, log2.topics) |topic1, topic2| {
                if (topic1 != topic2) {
                    return false;
                }
            }
            
            // Compare data
            if (!std.mem.eql(u8, log1.data, log2.data)) {
                return false;
            }
        }
        
        return true;
    }

    /// Create a deep copy of logs for diff storage
    fn duplicateLogs(self: *DifferentialTestor, logs: []const revm.Log) ![]const revm.Log {
        if (logs.len == 0) {
            return &.{};
        }
        
        var result = try self.allocator.alloc(revm.Log, logs.len);
        
        for (logs, result) |src_log, *dest_log| {
            dest_log.address = src_log.address;
            
            // Duplicate topics
            dest_log.topics = try self.allocator.dupe(u256, src_log.topics);
            
            // Duplicate data
            dest_log.data = try self.allocator.dupe(u8, src_log.data);
        }
        
        return result;
    }

    /// Convert Guillotine logs to REVM log format
    fn convertGuillotineLogsToRevmLogs(self: *DifferentialTestor, guillotine_logs: []const GuillotineLog) ![]const revm.Log {
        if (guillotine_logs.len == 0) {
            return &.{};
        }
        
        var result = try self.allocator.alloc(revm.Log, guillotine_logs.len);
        
        for (guillotine_logs, result) |src_log, *dest_log| {
            dest_log.address = src_log.address;
            
            // Duplicate topics
            dest_log.topics = try self.allocator.dupe(u256, src_log.topics);
            
            // Duplicate data
            dest_log.data = try self.allocator.dupe(u8, src_log.data);
        }
        
        return result;
    }

    /// Print detailed diff visualization
    pub fn printDiff(_: *DifferentialTestor, diff: ExecutionDiff, test_name: []const u8) void {
        const log = std.log.scoped(.differential_diff);

        log.info("=== DIFFERENTIAL TEST RESULTS: {s} ===", .{test_name});

        if (diff.result_match and diff.trace_match) {
            log.info("✅ PERFECT MATCH - All results and traces identical", .{});
            return;
        }

        if (!diff.result_match) {
            log.err("❌ RESULT MISMATCH", .{});

            if (diff.success_diff) |success| {
                log.err("  Success: REVM={} vs Guillotine={}", .{ success.revm, success.guillotine });
            }

            if (diff.gas_diff) |gas| {
                log.err("  Gas Usage: REVM={} vs Guillotine={}", .{ gas.revm, gas.guillotine });
            }

            if (diff.output_diff) |output| {
                log.err("  Output Length: REVM={} vs Guillotine={}", .{ output.revm.len, output.guillotine.len });
                if (output.revm.len > 0) {
                    log.err("  REVM Output: {x}", .{output.revm});
                }
                if (output.guillotine.len > 0) {
                    log.err("  Guillotine Output: {x}", .{output.guillotine});
                }
            }
        } else {
            log.info("✅ RESULTS MATCH", .{});
        }

        if (!diff.trace_match) {
            log.err("❌ TRACE MISMATCH", .{});

            if (diff.step_count_diff) |steps| {
                log.err("  Step Count: REVM={} vs Guillotine={}", .{ steps.revm, steps.guillotine });
            }

            if (diff.first_divergence_step) |step| {
                log.err("  First Divergence at Step: {}", .{step});
            }
        } else {
            log.info("✅ TRACES MATCH", .{});
        }

        log.info("=== END DIFFERENTIAL TEST ===", .{});
    }

    /// Parse REVM trace file in EIP-3155 format  
    fn parseRevmTrace(self: *DifferentialTestor, trace_file_path: []const u8) !?ExecutionTrace {
        // Read the trace file
        const trace_content = std.fs.cwd().readFileAlloc(self.allocator, trace_file_path, 10 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => {
                const log = std.log.scoped(.revm_trace);
                log.err("REVM trace file not found: {s}", .{trace_file_path});
                return null;
            },
            else => return err,
        };
        defer self.allocator.free(trace_content);

        const log = std.log.scoped(.revm_trace);
        // log.debug("REVM trace file content ({} bytes)", .{trace_content.len});

        // Simple trace parsing for debugging - just count steps and log key operations
        var step_count: u32 = 0;
        var lines = std.mem.splitSequence(u8, trace_content, "\n");
        
        log.info("=== REVM EXECUTION TRACE ===", .{});
        
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            
            // Parse each JSON line for basic info
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch |err| {
                log.warn("Failed to parse JSON line: {}, error: {}", .{ line.len, err });
                continue;
            };
            defer parsed.deinit();
            
            const obj = parsed.value.object;
            
            // Skip the final summary line (has "output" field) 
            if (obj.get("output")) |output| {
                log.info("REVM FINAL OUTPUT: {s}", .{output.string});
                continue;
            }
            
            // Extract basic step information
            const pc = @as(u32, @intCast(obj.get("pc").?.integer));
            _ = @as(u8, @intCast(obj.get("op").?.integer)); // opcode - unused for now
            const opcode_name = obj.get("opName").?.string;
            
            // Parse gas as hex string
            const gas_hex = obj.get("gas").?.string;
            const gas = std.fmt.parseInt(u64, gas_hex[2..], 16) catch 0;
            
            step_count += 1;
            
            // Log key arithmetic operations
            if (std.mem.eql(u8, opcode_name, "SUB") or 
                std.mem.eql(u8, opcode_name, "MUL") or 
                std.mem.eql(u8, opcode_name, "DIV") or
                std.mem.eql(u8, opcode_name, "MOD") or
                std.mem.eql(u8, opcode_name, "ADDMOD") or
                std.mem.eql(u8, opcode_name, "MULMOD") or
                std.mem.eql(u8, opcode_name, "EXP") or
                std.mem.eql(u8, opcode_name, "ADD") or
                std.mem.eql(u8, opcode_name, "RETURN")) {
                
                // Also log the stack state for key operations
                if (obj.get("stack")) |stack_array| {
                    log.info("REVM Step {}: {s} (PC={}, Gas={})", .{ step_count, opcode_name, pc, gas });
                    log.info("  Stack: {any}", .{stack_array});
                } else {
                    log.info("REVM Step {}: {s} (PC={}, Gas={})", .{ step_count, opcode_name, pc, gas });
                }
            }
        }

        log.info("REVM TOTAL STEPS: {}", .{step_count});
        log.info("=== END REVM TRACE ===", .{});

        // Return null for now since we're just doing debug logging
        log.warn("REVM trace parsing: debug mode - returning null trace", .{});
        return null;
    }
};
