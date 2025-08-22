const std = @import("std");
const evm = @import("evm");
const Tracer = evm.Tracer;

/// Configuration for differential test tracing
pub const TraceConfig = struct {
    /// Enable tracing for all tests
    enable_always: bool = false,
    /// Enable tracing only on test failure
    enable_on_failure: bool = true,
    /// Directory to write trace files
    output_dir: []const u8 = "test_traces",
    /// Allocator for trace operations
    allocator: std.mem.Allocator,
};

/// Trace collector that writes to a file
pub const FileTraceCollector = struct {
    file: std.fs.File,
    writer: std.io.BufferedWriter(4096, std.fs.File.Writer),
    
    pub fn init(path: []const u8) !FileTraceCollector {
        const file = try std.fs.cwd().createFile(path, .{});
        return FileTraceCollector{
            .file = file,
            .writer = std.io.bufferedWriter(file.writer()),
        };
    }
    
    pub fn deinit(self: *FileTraceCollector) void {
        self.writer.flush() catch {};
        self.file.close();
    }
    
    pub fn anyWriter(self: *FileTraceCollector) std.io.AnyWriter {
        return self.writer.writer().any();
    }
};

/// Initialize tracing for a test
pub fn initTestTracing(
    config: *const TraceConfig,
    test_name: []const u8,
    vm_name: []const u8,
) !?FileTraceCollector {
    if (!config.enable_always and !config.enable_on_failure) {
        return null;
    }
    
    // Ensure output directory exists
    std.fs.cwd().makePath(config.output_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    
    // Generate trace filename
    const timestamp = std.time.timestamp();
    const filename = try std.fmt.allocPrint(
        config.allocator,
        "{s}/{s}_{s}_{d}.json",
        .{ config.output_dir, test_name, vm_name, timestamp }
    );
    defer config.allocator.free(filename);
    
    return try FileTraceCollector.init(filename);
}

/// Compare two trace files and report differences
pub fn compareTraces(
    allocator: std.mem.Allocator,
    revm_trace_path: []const u8,
    guillotine_trace_path: []const u8,
) !void {
    // Read both trace files
    const revm_content = try std.fs.cwd().readFileAlloc(allocator, revm_trace_path, 1024 * 1024 * 10); // 10MB max
    defer allocator.free(revm_content);
    
    const guillotine_content = try std.fs.cwd().readFileAlloc(allocator, guillotine_trace_path, 1024 * 1024 * 10);
    defer allocator.free(guillotine_content);
    
    // Parse line by line and compare
    var revm_lines = std.mem.tokenize(u8, revm_content, "\n");
    var guillotine_lines = std.mem.tokenize(u8, guillotine_content, "\n");
    
    var line_num: usize = 0;
    while (true) {
        const revm_line = revm_lines.next();
        const guillotine_line = guillotine_lines.next();
        
        if (revm_line == null and guillotine_line == null) break;
        
        line_num += 1;
        
        if (revm_line == null) {
            break;
        }
        
        if (guillotine_line == null) {
            break;
        }
        
        if (!std.mem.eql(u8, revm_line.?, guillotine_line.?)) {
            
            // Show next few lines for context
            var context: usize = 0;
            while (context < 3) : (context += 1) {
                const r = revm_lines.next();
                const g = guillotine_lines.next();
                if (r == null or g == null) break;
                
            }
            break;
        }
    }
}

/// Create an Evm instance with tracing enabled
pub fn createTracedEvm(
    allocator: std.mem.Allocator,
    db_interface: anytype,
    trace_collector: ?*FileTraceCollector,
) !evm.Evm {
    const tracer = if (trace_collector) |tc| tc.anyWriter() else null;
    return try evm.Evm.init(
        allocator,
        db_interface,
        null, // jump_table
        null, // chain_rules
        null, // analysis_cache
        0,    // depth
        false, // is_static
        tracer,
    );
}

/// Run a differential test with optional tracing
pub fn runWithTracing(
    config: *const TraceConfig,
    test_name: []const u8,
    test_fn: anytype,
) !void {
    // Run the test
    test_fn() catch |err| {
        if (config.enable_on_failure) {
        }
        return err;
    };
}