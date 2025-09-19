const std = @import("std");

pub fn createDevtoolExecutable(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lib_mod: *std.Build.Module,
    evm_mod: *std.Build.Module,
    primitives_mod: *std.Build.Module,
    provider_mod: *std.Build.Module,
    generate_assets_step: *std.Build.Step,
) *std.Build.Step.Compile {
    const devtool_mod = b.createModule(.{
        .root_source_file = b.path("src/devtool/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    devtool_mod.addImport("Guillotine_lib", lib_mod);
    devtool_mod.addImport("evm", evm_mod);
    devtool_mod.addImport("primitives", primitives_mod);
    devtool_mod.addImport("provider", provider_mod);

    // Force LLVM backend on x86_64 to maintain tail call optimization for EVM dispatch performance
    const use_llvm = if (target.result.cpu.arch == .x86_64) true else null;
    
    const exe = b.addExecutable(.{
        .name = "guillotine-devtool",
        .root_module = devtool_mod,
        .use_llvm = use_llvm,
    });
    
    // macOS-specific Swift integration
    if (target.result.os.tag == .macos) {
        const swift_compile = b.addSystemCommand(&[_][]const u8{
            "swiftc",
            "-emit-library",
            "-parse-as-library",
            "-target",
            "arm64-apple-macosx15.0",
            "-o",
            "zig-out/libnative_menu_swift.dylib",
            "src/devtool/native_menu.swift",
        });

        const mkdir_cmd = b.addSystemCommand(&[_][]const u8{
            "mkdir", "-p", "zig-out",
        });
        swift_compile.step.dependOn(&mkdir_cmd.step);

        exe.addLibraryPath(b.path("zig-out"));
        exe.linkSystemLibrary("native_menu_swift");
        exe.step.dependOn(&swift_compile.step);

        exe.addLibraryPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx" });
        exe.addLibraryPath(.{ .cwd_relative = "/usr/lib/swift" });
        
        exe.linkFramework("WebKit");
        exe.linkFramework("AppKit");
        exe.linkFramework("Foundation");
    }

    exe.linkLibC();
    exe.step.dependOn(generate_assets_step);

    return exe;
}

pub fn createDevtoolSteps(b: *std.Build, exe: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    const run_devtool_cmd = b.addRunArtifact(exe);
    run_devtool_cmd.step.dependOn(b.getInstallStep());

    const devtool_step = b.step("devtool", "Build and run the Ethereum devtool");
    devtool_step.dependOn(&run_devtool_cmd.step);

    const build_devtool_step = b.step("build-devtool", "Build the Ethereum devtool (without running)");
    build_devtool_step.dependOn(b.getInstallStep());

    // macOS app bundle creation
    if (target.result.os.tag == .macos) {
        const bundle_dir = "macos/GuillotineDevtool.app/Contents/MacOS";
        const mkdir_bundle = b.addSystemCommand(&[_][]const u8{
            "mkdir", "-p", bundle_dir,
        });

        const copy_to_bundle = b.addSystemCommand(&[_][]const u8{
            "cp", "-f", "zig-out/bin/guillotine-devtool", bundle_dir,
        });
        copy_to_bundle.step.dependOn(&exe.step);
        copy_to_bundle.step.dependOn(&mkdir_bundle.step);

        const macos_app_step = b.step("macos-app", "Create macOS app bundle");
        macos_app_step.dependOn(&copy_to_bundle.step);

        const create_dmg = b.addSystemCommand(&[_][]const u8{
            "scripts/create-dmg-fancy.sh",
        });
        create_dmg.step.dependOn(&copy_to_bundle.step);

        const dmg_step = b.step("macos-dmg", "Create macOS DMG installer");
        dmg_step.dependOn(&create_dmg.step);
    }
}