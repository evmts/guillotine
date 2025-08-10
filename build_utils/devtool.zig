const std = @import("std");
const asset_generator = @import("asset_generator.zig");

pub const DevtoolConfig = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lib_mod: *std.Build.Module,
    evm_mod: *std.Build.Module,
    primitives_mod: *std.Build.Module,
    provider_mod: *std.Build.Module,
    webui_dep: *std.Build.Dependency,
};

pub fn setupDevtool(b: *std.Build, config: DevtoolConfig) struct {
    exe: *std.Build.Step.Compile,
    run_cmd: *std.Build.Step.Run,
} {
    // Check for npm
    const npm_check = b.addSystemCommand(&[_][]const u8{ "which", "npm" });
    npm_check.addCheck(.{ .expect_stdout_match = "npm" });

    // Install npm dependencies
    const npm_install = b.addSystemCommand(&[_][]const u8{ "npm", "install" });
    npm_install.setCwd(b.path("src/devtool"));
    npm_install.step.dependOn(&npm_check.step);

    // Build the Solid app
    const npm_build = b.addSystemCommand(&[_][]const u8{ "npm", "run", "build" });
    npm_build.setCwd(b.path("src/devtool"));
    npm_build.step.dependOn(&npm_install.step);

    // Generate assets from the built Solid app
    const generate_assets = asset_generator.GenerateAssetsStep.init(b, "src/devtool/dist", "src/devtool/assets.zig");
    generate_assets.step.dependOn(&npm_build.step);

    // Create devtool module
    const devtool_mod = b.createModule(.{
        .root_source_file = b.path("src/devtool/main.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });
    devtool_mod.addImport("Guillotine_lib", config.lib_mod);
    devtool_mod.addImport("evm", config.evm_mod);
    devtool_mod.addImport("primitives", config.primitives_mod);
    devtool_mod.addImport("provider", config.provider_mod);

    // Create executable
    const devtool_exe = b.addExecutable(.{
        .name = "guillotine-devtool",
        .root_module = devtool_mod,
    });
    devtool_exe.addIncludePath(config.webui_dep.path("src"));
    devtool_exe.addIncludePath(config.webui_dep.path("include"));

    // Platform-specific setup
    setupPlatformSpecific(b, config.target, devtool_exe);

    // Link webui library
    devtool_exe.linkLibrary(config.webui_dep.artifact("webui"));

    // Link external libraries
    devtool_exe.linkLibC();
    if (config.target.result.os.tag == .macos) {
        devtool_exe.linkFramework("WebKit");
        devtool_exe.linkFramework("AppKit");
        devtool_exe.linkFramework("Foundation");
    }

    // Make devtool build depend on asset generation
    devtool_exe.step.dependOn(&generate_assets.step);

    // Create run command
    const run_devtool_cmd = b.addRunArtifact(devtool_exe);
    run_devtool_cmd.step.dependOn(b.getInstallStep());

    return .{
        .exe = devtool_exe,
        .run_cmd = run_devtool_cmd,
    };
}

fn setupPlatformSpecific(b: *std.Build, target: std.Build.ResolvedTarget, exe: *std.Build.Step.Compile) void {
    // Add native menu implementation on macOS
    if (target.result.os.tag == .macos) {
        // Compile Swift native menu
        const swift_compile = b.addSystemCommand(&[_][]const u8{
            "swiftc",
            "-emit-library",
            "-emit-module",
            "-static",
            "-whole-module-optimization",
            "-O",
            "-target",
            "arm64-apple-macosx15.0",
            "-o",
            "zig-out/libnative_menu_swift.dylib",
            "src/devtool/native_menu.swift",
        });

        // Ensure output directory exists
        const mkdir_cmd = b.addSystemCommand(&[_][]const u8{ "mkdir", "-p", "zig-out" });
        swift_compile.step.dependOn(&mkdir_cmd.step);

        // Link the compiled Swift dynamic library
        exe.addLibraryPath(b.path("zig-out"));
        exe.linkSystemLibrary("native_menu_swift");
        exe.step.dependOn(&swift_compile.step);

        // Add Swift runtime library search paths
        exe.addLibraryPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx" });
        exe.addLibraryPath(.{ .cwd_relative = "/usr/lib/swift" });
    }
}

pub fn createMacOSAppBundle(b: *std.Build, exe: *std.Build.Step.Compile) void {
    if (b.host.result.os.tag == .macos) {
        const bundle_dir = "zig-out/Guillotine DevTool.app/Contents/MacOS";

        // Create app bundle structure
        const mkdir_bundle = b.addSystemCommand(&[_][]const u8{
            "mkdir", "-p", bundle_dir,
        });

        // Copy executable to app bundle
        const copy_to_bundle = b.addSystemCommand(&[_][]const u8{
            "cp", "-f", "zig-out/bin/guillotine-devtool", bundle_dir,
        });
        copy_to_bundle.step.dependOn(&exe.step);
        copy_to_bundle.step.dependOn(&mkdir_bundle.step);

        // Create Info.plist
        const info_plist_content =
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            \\<plist version="1.0">
            \\<dict>
            \\    <key>CFBundleExecutable</key>
            \\    <string>guillotine-devtool</string>
            \\    <key>CFBundleIdentifier</key>
            \\    <string>com.guillotine.devtool</string>
            \\    <key>CFBundleName</key>
            \\    <string>Guillotine DevTool</string>
            \\    <key>CFBundlePackageType</key>
            \\    <string>APPL</string>
            \\    <key>CFBundleShortVersionString</key>
            \\    <string>1.0</string>
            \\    <key>CFBundleVersion</key>
            \\    <string>1</string>
            \\    <key>LSMinimumSystemVersion</key>
            \\    <string>15.0</string>
            \\    <key>NSHighResolutionCapable</key>
            \\    <true/>
            \\</dict>
            \\</plist>
        ;

        const write_plist = b.addWriteFile("Guillotine DevTool.app/Contents/Info.plist", info_plist_content);
        copy_to_bundle.step.dependOn(&write_plist.step);

        const app_bundle_step = b.step("app-bundle", "Create macOS app bundle for devtool");
        app_bundle_step.dependOn(&copy_to_bundle.step);
    }
}
