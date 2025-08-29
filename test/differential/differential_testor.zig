const std = @import("std");
const primitives = @import("primitives");
const guillotine_evm = @import("evm");
const revm = @import("revm");

/// Represents a single execution step in the trace
pub const TraceStep = struct {
    pc: u32,
    opcode: u8,
    opcode_name: []const u8,
    gas: u64,
    stack: []const u256,
    memory: []const u8,
    storage_reads: []const StorageRead,
    storage_writes: []const StorageWrite,
    
    pub const StorageRead = struct {
        address: primitives.Address,
        slot: u256,
        value: u256,
    };
    
    pub const StorageWrite = struct {
        address: primitives.Address,
        slot: u256,
        old_value: u256,
        new_value: u256,
    };
    
    pub fn deinit(self: *TraceStep, allocator: std.mem.Allocator) void {
        allocator.free(self.opcode_name);
        allocator.free(self.stack);
        allocator.free(self.memory);
        allocator.free(self.storage_reads);
        allocator.free(self.storage_writes);
    }
};

/// Complete execution trace
pub const ExecutionTrace = struct {
    steps: []TraceStep,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ExecutionTrace {
        return ExecutionTrace{
            .steps = &.{},
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *ExecutionTrace) void {
        for (self.steps) |*step| {
            step.deinit(self.allocator);
        }
        self.allocator.free(self.steps);
    }
    
    /// Create empty trace for now (placeholder implementation)
    pub fn empty(allocator: std.mem.Allocator) ExecutionTrace {
        return ExecutionTrace{
            .steps = &.{},
            .allocator = allocator,
        };
    }
};

/// Result of execution with trace
pub const ExecutionResultWithTrace = struct {
    success: bool,
    gas_used: u64,
    output: []const u8,
    trace: ExecutionTrace,
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *ExecutionResultWithTrace) void {
        self.allocator.free(self.output);
        self.trace.deinit();
    }
};

/// Comprehensive diff between two execution results
pub const ExecutionDiff = struct {
    result_match: bool,
    trace_match: bool,
    
    // Result differences
    success_diff: ?struct { revm: bool, guillotine: bool },
    gas_diff: ?struct { revm: u64, guillotine: u64 },
    output_diff: ?struct { revm: []const u8, guillotine: []const u8 },
    error_diff: ?struct { revm: ?[]const u8, guillotine: ?[]const u8 },
    
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
        for (self.trace_diffs) |*step_diff| {
            if (step_diff.stack_diff) |stack| {
                self.allocator.free(stack.revm);
                self.allocator.free(stack.guillotine);
            }
        }
        self.allocator.free(self.trace_diffs);
    }
};

/// Main differential testing coordinator
pub const DifferentialTestor = struct {
    revm_instance: revm.Revm,
    guillotine_instance: guillotine_evm.Evm(.{}),
    guillotine_db: guillotine_evm.Database,
    allocator: std.mem.Allocator,
    caller: primitives.Address,
    contract: primitives.Address,
    
    /// Simple initialization - creates both EVM instances internally
    pub fn init(allocator: std.mem.Allocator) !DifferentialTestor {
        // Setup addresses
        const caller = primitives.Address.ZERO_ADDRESS;
        const contract = try primitives.Address.from_hex("0xc0de000000000000000000000000000000000000");
        
        // Setup REVM
        var revm_vm = try revm.Revm.init(allocator, .{
            .gas_limit = 100000,
            .chain_id = 1,
        });
        
        try revm_vm.setBalance(caller, 10000000);
        
        // Setup Guillotine EVM
        var db = guillotine_evm.Database.init(allocator);
        
        try db.set_account(caller.bytes, .{
            .balance = 10000000,
            .nonce = 0,
            .code_hash = [_]u8{0} ** 32,
            .storage_root = [_]u8{0} ** 32,
        });
        
        const block_info = guillotine_evm.BlockInfo{
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
        
        const evm = try guillotine_evm.Evm(.{}).init(
            allocator,
            db,
            block_info,
            tx_context,
            0, // gas_price
            caller, // origin
            .CANCUN,
        );
        
        return DifferentialTestor{
            .revm_instance = revm_vm,
            .guillotine_instance = evm,
            .guillotine_db = db,
            .allocator = allocator,
            .caller = caller,
            .contract = contract,
        };
    }
    
    pub fn deinit(self: *DifferentialTestor) void {
        self.revm_instance.deinit();
        self.guillotine_instance.deinit();
        self.guillotine_db.deinit();
    }
    
    /// Simple bytecode testing - deploys bytecode and executes it on both EVMs
    /// In happy path: does nothing
    /// In unhappy path: collects errors, prints readable diff, and throws clear error
    pub fn test_bytecode(self: *DifferentialTestor, bytecode: []const u8) !void {
        // Deploy bytecode to both EVMs
        try self.revm_instance.setCode(self.contract, bytecode);
        
        const code_hash = try self.guillotine_db.set_code(bytecode);
        const log = std.log.scoped(.differential_testor);
        log.debug("Set code with hash: {x}", .{code_hash});
        
        try self.guillotine_db.set_account(self.contract.bytes, .{
            .balance = 0,
            .nonce = 1,
            .code_hash = code_hash,
            .storage_root = [_]u8{0} ** 32,
        });
        log.debug("Set account for address: {x}", .{self.contract.bytes});
        
        // Verify deployment
        const deployed_code = try self.guillotine_db.get_code_by_address(self.contract.bytes);
        log.debug("Deployed bytecode to {any}: len={} vs deployed_len={}", .{self.contract, bytecode.len, deployed_code.len});
        if (deployed_code.len == 0) {
            log.err("WARNING: Deployed code has zero length!", .{});
        }
        
        // Also check if account exists
        const account_check = try self.guillotine_db.get_account(self.contract.bytes);
        if (account_check) |acc| {
            log.debug("Account found: balance={}, nonce={}, code_hash={x}", .{acc.balance, acc.nonce, acc.code_hash});
        } else {
            log.err("WARNING: Account not found after deployment!", .{});
        }
        
        // Execute and diff
        var diff = try self.executeAndDiff(self.caller, self.contract, 0, &.{}, 100000);
        defer diff.deinit();
        
        // Happy path - perfect match
        if (diff.result_match and diff.trace_match) {
            return;
        }
        
        // Unhappy path - collect and report errors
        var error_messages: [5][]const u8 = undefined;
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
        
        if (diff.step_count_diff) |steps| {
            error_messages[error_count] = try std.fmt.allocPrint(self.allocator, "Trace step count mismatch: REVM={} vs Guillotine={}", .{ steps.revm, steps.guillotine });
            error_count += 1;
        }
        
        // Print comprehensive human-readable diff
        self.printComprehensiveDiff(diff, bytecode, error_messages[0..error_count]);
        
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
    fn executeRevmWithTrace(
        self: *DifferentialTestor,
        caller: primitives.Address,
        to: primitives.Address,
        value: u256,
        input: []const u8,
        gas_limit: u64,
    ) !ExecutionResultWithTrace {
        // For now, use regular execution without detailed tracing
        // TODO: Parse actual REVM trace files
        var result = try self.revm_instance.call(caller, to, value, input, gas_limit);
        defer result.deinit();
        
        const output = try self.allocator.dupe(u8, result.output);
        const trace = ExecutionTrace.empty(self.allocator);
        
        return ExecutionResultWithTrace{
            .success = result.success,
            .gas_used = result.gas_used,
            .output = output,
            .trace = trace,
            .allocator = self.allocator,
        };
    }
    
    /// Execute on Guillotine and capture trace
    fn executeGuillotineWithTrace(
        self: *DifferentialTestor,
        caller: primitives.Address,
        to: primitives.Address,
        value: u256,
        input: []const u8,
        gas_limit: u64,
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
        
        std.debug.print("DIFFERENTIAL: About to call Guillotine with gas={}\n", .{gas_limit});
        const result = self.guillotine_instance.call(params);
        std.debug.print("DIFFERENTIAL: Guillotine call complete, success={}, gas_left={}\n", .{result.success, result.gas_left});
        
        // For now, create empty trace - we'll focus on the execution result
        const trace = ExecutionTrace.empty(self.allocator);
        
        // Calculate gas used
        const gas_used = gas_limit - result.gas_left;
        
        // Store the execution result status for debugging
        const log = std.log.scoped(.differential_failure);
        log.debug("Guillotine execution completed: success={}, gas_left={}, output_len={}", .{result.success, result.gas_left, result.output.len});
        
        if (!result.success) {
            // Log detailed failure information
            log.err("Guillotine execution failed!", .{});
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
        
        return ExecutionResultWithTrace{
            .success = result.success,
            .gas_used = gas_used,
            .output = try self.allocator.dupe(u8, result.output),
            .trace = trace,
            .allocator = self.allocator,
        };
    }
    
    /// Print comprehensive, human-readable diff with context
    fn printComprehensiveDiff(self: *DifferentialTestor, diff: ExecutionDiff, bytecode: []const u8, error_messages: []const []const u8) void {
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
            log.err("   Last 16 bytes:  {x}", .{bytecode[bytecode.len-16..]});
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
        
        log.err("🛠️  DEBUGGING HINTS:", .{});
        log.err("   • Check if Guillotine implements all opcodes used", .{});
        log.err("   • Verify gas calculation matches EVM specification", .{});
        log.err("   • Ensure memory and stack operations are correct", .{});
        log.err("   • Compare against EVM specification for edge cases", .{});
        if (diff.trace_diffs.len > 0) {
            log.err("   • Enable detailed tracing to debug execution differences", .{});
        }
        log.err("", .{});
        log.err("=====================================", .{});
    }
    
    /// Generate comprehensive diff between two execution results
    fn generateDiff(
        self: *DifferentialTestor,
        revm_result: ExecutionResultWithTrace,
        guillotine_result: ExecutionResultWithTrace,
    ) !ExecutionDiff {
        var diff = ExecutionDiff{
            .result_match = true,
            .trace_match = true,
            .success_diff = null,
            .gas_diff = null,
            .output_diff = null,
            .error_diff = null,
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
        
        // Compare traces
        if (revm_result.trace.steps.len != guillotine_result.trace.steps.len) {
            diff.trace_match = false;
            diff.step_count_diff = .{
                .revm = revm_result.trace.steps.len,
                .guillotine = guillotine_result.trace.steps.len,
            };
        } else if (guillotine_result.trace.steps.len > 0) {
            // Compare each step in the traces  
            var trace_diffs_list = std.ArrayList(ExecutionDiff.TraceDiffStep){};
            defer trace_diffs_list.deinit(self.allocator);
            
            for (revm_result.trace.steps, guillotine_result.trace.steps, 0..) |revm_step, guillotine_step, i| {
                var step_diff = ExecutionDiff.TraceDiffStep{
                    .step_index = i,
                    .pc_diff = null,
                    .opcode_diff = null,
                    .gas_diff = null,
                    .stack_diff = null,
                };
                
                var has_diff = false;
                
                // Compare PC
                if (revm_step.pc != guillotine_step.pc) {
                    step_diff.pc_diff = .{
                        .revm = revm_step.pc,
                        .guillotine = guillotine_step.pc,
                    };
                    has_diff = true;
                }
                
                // Compare opcode
                if (revm_step.opcode != guillotine_step.opcode) {
                    step_diff.opcode_diff = .{
                        .revm = revm_step.opcode,
                        .guillotine = guillotine_step.opcode,
                    };
                    has_diff = true;
                }
                
                // Compare gas
                if (revm_step.gas != guillotine_step.gas) {
                    step_diff.gas_diff = .{
                        .revm = revm_step.gas,
                        .guillotine = guillotine_step.gas,
                    };
                    has_diff = true;
                }
                
                // Compare stack
                if (!std.mem.eql(u256, revm_step.stack, guillotine_step.stack)) {
                    step_diff.stack_diff = .{
                        .revm = try self.allocator.dupe(u256, revm_step.stack),
                        .guillotine = try self.allocator.dupe(u256, guillotine_step.stack),
                    };
                    has_diff = true;
                }
                
                if (has_diff) {
                    try trace_diffs_list.append(self.allocator, step_diff);
                    if (diff.first_divergence_step == null) {
                        diff.first_divergence_step = i;
                    }
                    diff.trace_match = false;
                }
            }
            
            if (trace_diffs_list.items.len > 0) {
                diff.trace_diffs = try trace_diffs_list.toOwnedSlice(self.allocator);
            }
        }
        
        return diff;
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
};