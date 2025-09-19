const std = @import("std");

pub fn createExecutable(
    b: *std.Build,
    exe_mod: *std.Build.Module,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "Guillotine",
        .root_module = exe_mod,
        .use_llvm = if (@import("builtin").target.cpu.arch == .x86_64) true else null,
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