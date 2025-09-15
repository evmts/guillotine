const std = @import("std");

pub fn createPythonSteps(b: *std.Build) void {
    const python_build_cmd = b.addSystemCommand(&[_][]const u8{ "python3", "build.py" });
    python_build_cmd.setCwd(b.path("sdks/python"));
    python_build_cmd.step.dependOn(b.getInstallStep());

    const python_build_step = b.step("python", "Build Python bindings");
    python_build_step.dependOn(&python_build_cmd.step);

    const python_dev_cmd = b.addSystemCommand(&[_][]const u8{ "python3", "build.py", "--dev" });
    python_dev_cmd.setCwd(b.path("sdks/python"));
    python_dev_cmd.step.dependOn(b.getInstallStep());

    const python_dev_step = b.step("python-dev", "Build and install Python bindings in development mode");
    python_dev_step.dependOn(&python_dev_cmd.step);

    const python_test_cmd = b.addSystemCommand(&[_][]const u8{ "python3", "-m", "pytest", "tests/", "-v" });
    python_test_cmd.setCwd(b.path("sdks/python"));
    python_test_cmd.step.dependOn(&python_build_cmd.step);

    const python_test_step = b.step("python-test", "Run Python binding tests");
    python_test_step.dependOn(&python_test_cmd.step);

    const python_examples_cmd = b.addSystemCommand(&[_][]const u8{ "python3", "examples.py" });
    python_examples_cmd.setCwd(b.path("sdks/python"));
    python_examples_cmd.step.dependOn(&python_build_cmd.step);

    const python_examples_step = b.step("python-examples", "Run Python binding examples");
    python_examples_step.dependOn(&python_examples_cmd.step);
}