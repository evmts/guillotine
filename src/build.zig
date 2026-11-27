const std = @import("std");

pub fn createExecutable(
    b: *std.Build,
    exe_mod: *std.Build.Module,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "Guillotine",
        .root_module = exe_mod,
        // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .use_llvm = true,
    });

    b.installArtifact(exe);
    return exe;
}

pub fn createRunStep(b: *std.Build, exe: *std.Build.Step.Compile) *std.Build.Step {
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
    return run_step;
}
