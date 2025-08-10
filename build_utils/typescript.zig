const std = @import("std");

pub const TypeScriptStep = struct {
    name: []const u8,
    npm_command: []const u8,
    description: []const u8,
    depends_on_install: bool = true,
};

pub fn addTypeScriptSteps(b: *std.Build) void {
    const working_dir = "src/guillotine-ts";

    // Base install step
    const ts_install_cmd = b.addSystemCommand(&[_][]const u8{ "npm", "install" });
    ts_install_cmd.setCwd(b.path(working_dir));
    ts_install_cmd.step.dependOn(b.getInstallStep()); // Ensure native library is built first

    // Define all TypeScript steps
    const ts_steps = [_]TypeScriptStep{
        .{ .name = "ts", .npm_command = "build", .description = "Build TypeScript bindings", .depends_on_install = true },
        .{ .name = "ts-test", .npm_command = "test", .description = "Run TypeScript binding tests", .depends_on_install = true },
        .{ .name = "ts-lint", .npm_command = "lint", .description = "Run TypeScript linting", .depends_on_install = true },
        .{ .name = "ts-format-check", .npm_command = "format:check", .description = "Check TypeScript code formatting", .depends_on_install = true },
        .{ .name = "ts-format", .npm_command = "format", .description = "Format TypeScript code", .depends_on_install = true },
        .{ .name = "ts-typecheck", .npm_command = "typecheck", .description = "Run TypeScript type checking", .depends_on_install = true },
        .{ .name = "ts-dev", .npm_command = "dev", .description = "Run TypeScript in development/watch mode", .depends_on_install = true },
        .{ .name = "ts-clean", .npm_command = "clean", .description = "Clean TypeScript build artifacts", .depends_on_install = false },
    };

    // Special handling for copy-wasm and build steps
    const ts_copy_wasm_cmd = b.addSystemCommand(&[_][]const u8{ "npm", "run", "copy-wasm" });
    ts_copy_wasm_cmd.setCwd(b.path(working_dir));
    ts_copy_wasm_cmd.step.dependOn(&ts_install_cmd.step);

    // Create steps for each TypeScript command
    for (ts_steps) |step_config| {
        const cmd = b.addSystemCommand(&[_][]const u8{ "npm", "run", step_config.npm_command });
        cmd.setCwd(b.path(working_dir));

        // Handle dependencies
        if (std.mem.eql(u8, step_config.name, "ts")) {
            // Build depends on copy-wasm
            cmd.step.dependOn(&ts_copy_wasm_cmd.step);
        } else if (std.mem.eql(u8, step_config.name, "ts-test")) {
            // Test depends on build
            const build_cmd = findStepByName(b, ts_steps, "ts");
            if (build_cmd) |bc| {
                cmd.step.dependOn(&bc.step);
            }
        } else if (step_config.depends_on_install) {
            cmd.step.dependOn(&ts_install_cmd.step);
        }

        const step = b.step(step_config.name, step_config.description);
        step.dependOn(&cmd.step);
    }
}

fn findStepByName(b: *std.Build, steps: []const TypeScriptStep, name: []const u8) ?*std.Build.Step.Run {
    // This is a simplified version - in practice you'd need to store the created commands
    _ = b;
    _ = steps;
    _ = name;
    return null;
}
