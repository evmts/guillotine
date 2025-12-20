const std = @import("std");
const builtin = @import("builtin");

pub const FileWatcher = struct {
    allocator: std.mem.Allocator,
    watched_paths: std.ArrayList([]const u8),
    last_check: i128,
    poll_interval_ms: u64,

    pub fn init(allocator: std.mem.Allocator, poll_interval_ms: u64) FileWatcher {
        return .{
            .allocator = allocator,
            .watched_paths = std.ArrayList([]const u8){},
            .last_check = std.time.nanoTimestamp(),
            .poll_interval_ms = poll_interval_ms,
        };
    }

    pub fn deinit(self: *FileWatcher) void {
        for (self.watched_paths.items) |path| {
            self.allocator.free(path);
        }
        self.watched_paths.deinit(self.allocator);
    }

    pub fn addPath(self: *FileWatcher, path: []const u8) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        try self.watched_paths.append(self.allocator, owned_path);
    }

    pub fn addGlob(self: *FileWatcher, glob_pattern: []const u8) !void {
        // For simplicity, just watch common source directories
        // In a real implementation, would use actual glob matching
        if (std.mem.indexOf(u8, glob_pattern, "**/*.zig") != null) {
            try self.addPath("src");
            try self.addPath("test");
        }
    }

    pub fn checkForChanges(self: *FileWatcher) !bool {
        // Simple polling-based implementation
        // Checks if any files in watched paths have been modified since last check

        const now = std.time.nanoTimestamp();
        const elapsed_ms = @divTrunc(now - self.last_check, std.time.ns_per_ms);

        if (elapsed_ms < self.poll_interval_ms) {
            return false;
        }

        var changed = false;

        for (self.watched_paths.items) |path| {
            if (try self.checkPathModified(path, self.last_check)) {
                changed = true;
            }
        }

        if (changed) {
            self.last_check = now;
        }

        return changed;
    }

    fn checkPathModified(self: *FileWatcher, path: []const u8, since: i128) !bool {
        const cwd = std.fs.cwd();

        // Try to open as directory first
        var dir = cwd.openDir(path, .{ .iterate = true }) catch |err| {
            // If it's not a directory, check it as a file
            if (err == error.NotDir) {
                return try self.checkFileModified(path, since);
            }
            return false;
        };
        defer dir.close();

        // Recursively check all files in directory
        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".zig")) {
                const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.path });
                defer self.allocator.free(full_path);

                if (try self.checkFileModified(full_path, since)) {
                    return true;
                }
            }
        }

        return false;
    }

    fn checkFileModified(self: *FileWatcher, path: []const u8, since: i128) !bool {
        _ = self;
        const cwd = std.fs.cwd();
        const file = cwd.openFile(path, .{}) catch return false;
        defer file.close();

        const stat = try file.stat();

        // Convert mtime to nanoseconds
        const mtime_ns: i128 = @as(i128, @intCast(stat.mtime)) * std.time.ns_per_s;

        return mtime_ns > since;
    }

    pub fn waitForChange(self: *FileWatcher) !void {
        while (true) {
            if (try self.checkForChanges()) {
                return;
            }
            std.Thread.sleep(self.poll_interval_ms * std.time.ns_per_ms);
        }
    }
};

pub fn watchAndRun(
    allocator: std.mem.Allocator,
    watch_paths: []const []const u8,
    comptime runFn: fn () anyerror!void,
) !void {
    var watcher = FileWatcher.init(allocator, 500); // 500ms poll interval
    defer watcher.deinit();

    for (watch_paths) |path| {
        try watcher.addPath(path);
    }

    // Initial run
    try runFn();

    // Watch loop
    while (true) {
        try watcher.waitForChange();

        // Debounce - wait a bit for multiple file changes to settle
        std.Thread.sleep(200 * std.time.ns_per_ms);

        // Clear any additional changes during debounce
        _ = try watcher.checkForChanges();

        std.debug.print("\n\n{s}File changes detected, re-running tests...{s}\n\n", .{
            "\x1b[36m",
            "\x1b[0m",
        });

        try runFn();
    }
}
