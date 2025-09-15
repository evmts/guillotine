# CLAUDE.md - CLI Module

## MISSION CRITICAL: User Interface Safety and Security
**CLI vulnerabilities enable attacks/system compromise.** Validate all inputs, handle errors securely.

## Command-Line Security
- **Input Validation**: Sanitize all user arguments/files
- **Path Traversal Prevention**: Validate paths, prevent "../" attacks
- **Resource Limits**: File size, execution time limits
- **Privilege Management**: Run with minimal privileges
- **Error Handling**: Never expose sensitive system info

## Key Responsibilities
- **EVM Execution**: Safe bytecode execution
- **File Operations**: Secure bytecode/config file handling
- **Network Interface**: Safe blockchain node communication
- **Debugging Tools**: Secure debugging capabilities
- **Configuration**: Secure config data handling

## Critical Safety Patterns

**Input Validation**:
```zig
fn validate_file_path(path: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, path, "..") != null) return CliError.InvalidPath;
    if (!is_safe_path(path)) return CliError.ForbiddenPath;
    return path;
}

fn read_bytecode_file(path: []const u8) ![]u8 {
    const MAX_SIZE = 1024 * 1024; // 1MB limit
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return CliError.FileNotFound,
        error.AccessDenied => return CliError.AccessDenied,
        else => return CliError.FileError,
    };
    defer file.close();
    const size = try file.getEndPos();
    if (size > MAX_SIZE) return CliError.FileTooLarge;
    return try file.readToEndAlloc(allocator, size);
}
```

**Execution Safety**:
```zig
fn execute_user_bytecode(bytecode: []const u8, args: ExecutionArgs) !ExecutionResult {
    try validate_bytecode(bytecode);
    const config = EvmConfig{
        .gas_limit = @min(args.gas_limit, MAX_ALLOWED_GAS),
        .memory_limit = MAX_ALLOWED_MEMORY,
        .call_depth_limit = MAX_CALL_DEPTH,
        .execution_timeout = EXECUTION_TIMEOUT,
    };
    return try evm.execute(bytecode, config);
}
```

## Command Structure
**Commands**: run, trace, debug, analyze, test, help, version
**Parsing**: ComptimeStringMap for safe command parsing

## Error Handling (CRITICAL)
```zig
fn handle_execution_error(err: anyerror) void {
    switch (err) {
        CliError.FileNotFound => std.debug.print("Error: File not found\n", .{}),
        CliError.InvalidBytecode => std.debug.print("Error: Invalid bytecode\n", .{}),
        CliError.GasExhausted => std.debug.print("Error: Out of gas\n", .{}),
        else => {
            std.debug.print("Error: Operation failed\n", .{}); // Generic - no internal details
            log.err("Internal CLI error: {}", .{err});
        },
    }
}
```

## Resource Limits
```zig
const ResourceLimits = struct {
    const MAX_ALLOWED_GAS = 50_000_000;           // 50M gas
    const MAX_ALLOWED_MEMORY = 256 * 1024 * 1024; // 256MB
    const MAX_CALL_DEPTH = 1024;                  // EVM standard
    const EXECUTION_TIMEOUT = 30 * 1000;          // 30s
    const MAX_FILE_SIZE = 10 * 1024 * 1024;      // 10MB
};
```

## Testing & Security
- **Fuzzing**: Malformed/edge-case inputs
- **Path Traversal**: Directory traversal prevention
- **Resource Limits**: Validate all limits enforced
- **Error Handling**: No sensitive info leakage
- **Security Audit**: Regular CLI security review

## Emergency Procedures
- Security incident isolation/analysis
- Resource exhaustion handling
- Input validation bypass investigation
- Privilege escalation monitoring

**CLI is primary attack surface. All user input is malicious until proven safe.**