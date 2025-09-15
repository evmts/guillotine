const std = @import("std");

pub const WasmBuildConfig = struct {
    name: []const u8,
    root_source_file: []const u8,
    imports: []const ImportDef = &.{},
    dest_sub_path: []const u8,
    entry_disabled: bool = true,
    rdynamic: bool = true,
    debug_build: bool = false,
    single_threaded: bool = true,
};

pub const ImportDef = struct {
    name: []const u8,
    module_field: []const u8,
};

pub fn setupWasmTarget(b: *std.Build) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
}

pub fn createWasmModule(
    b: *std.Build,
    root_source_file: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
}

pub fn buildWasmExecutable(
    b: *std.Build,
    config: WasmBuildConfig,
    module: *std.Build.Module,
) struct { exe: *std.Build.Step.Compile, install: *std.Build.Step.InstallArtifact } {
    const exe = b.addExecutable(.{
        .name = config.name,
        .root_module = module,
    });
    
    if (config.entry_disabled) {
        exe.entry = .disabled;
    }
    exe.rdynamic = config.rdynamic;
    
    const install = b.addInstallArtifact(exe, .{ .dest_sub_path = config.dest_sub_path });
    
    return .{ .exe = exe, .install = install };
}

pub fn addWasmSizeReportStep(
    b: *std.Build,
    wasm_files: []const []const u8,
    dependencies: []const *std.Build.Step,
) *std.Build.Step.Run {
    var cmd = std.ArrayList([]const u8).empty;
    cmd.append(b.allocator, "sh") catch @panic("OOM");
    cmd.append(b.allocator, "-c") catch @panic("OOM");
    
    var script = std.ArrayList(u8).empty;
    script.appendSlice(b.allocator, "echo '\\n=== WASM Bundle Size Report ===' && ") catch @panic("OOM");
    
    for (wasm_files) |file| {
        const name = std.fs.path.stem(file);
        const seg1 = std.fmt.allocPrint(b.allocator, "echo '{s} WASM build:' && ", .{name}) catch @panic("OOM");
        defer b.allocator.free(seg1);
        script.appendSlice(b.allocator, seg1) catch @panic("OOM");
        const seg2 = std.fmt.allocPrint(b.allocator, "ls -lh zig-out/bin/{s} | awk '{{print \"  Size: \" $5}}' && ", .{file}) catch @panic("OOM");
        defer b.allocator.free(seg2);
        script.appendSlice(b.allocator, seg2) catch @panic("OOM");
    }
    
    script.appendSlice(b.allocator, "echo '=== End Report ===\\n'") catch @panic("OOM");
    cmd.append(b.allocator, script.items) catch @panic("OOM");
    
    const size_step = b.addSystemCommand(cmd.items);
    for (dependencies) |dep| {
        size_step.step.dependOn(dep);
    }
    
    return size_step;
}
