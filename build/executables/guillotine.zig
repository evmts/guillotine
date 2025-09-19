const std = @import("std");

pub fn createExecutable(
    b: *std.Build,
    exe_mod: *std.Build.Module,
) *std.Build.Step.Compile {
    // Zig 0.15 switched from LLVM to Zig's self-hosted x86_64 backend, but it lacks tail call support.
    // Force LLVM backend on x86_64 to maintain tail call optimization for EVM dispatch performance
    const use_llvm = if (@import("builtin").target.cpu.arch == .x86_64) true else null;
    
    const exe = b.addExecutable(.{
        .name = "Guillotine",
        .root_module = exe_mod,
        .use_llvm = use_llvm,
    });

    b.installArtifact(exe);
    return exe;
}

pub fn createRunStep(b: *std.Build, exe: *std.Build.Step.Compile) *std.Build.Step {
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
    return run_step;
}