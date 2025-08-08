const std = @import("std");
const asset_generator = @import("build_utils/asset_generator.zig");
const rust_build = @import("build_utils/rust_build.zig");
const tests = @import("build_utils/tests.zig");
const wasm = @import("build_utils/wasm.zig");
const devtool = @import("build_utils/devtool.zig");
const typescript = @import("build_utils/typescript.zig");

// Import the extracted build modules
const modules = @import("build_config/modules.zig");
const rust = @import("build_config/rust.zig");
const artifacts = @import("build_config/artifacts.zig");
const benchmarks = @import("build_config/benchmarks.zig");
const test_setup = @import("build_config/tests.zig");
const fuzzing = @import("build_config/fuzzing.zig");

pub fn build(b: *std.Build) void {
    // Standard target and optimization options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Custom build options
    const no_precompiles = b.option(bool, "no_precompiles", "Disable all EVM precompiles for minimal build") orelse false;
    const force_bn254 = b.option(bool, "force_bn254", "Force BN254 even on Ubuntu") orelse false;
    const is_ubuntu_native = target.result.os.tag == .linux and target.result.cpu.arch == .x86_64 and !force_bn254;
    const no_bn254 = no_precompiles or is_ubuntu_native;

    // Setup modules
    const module_config = modules.ModuleConfig{
        .target = target,
        .optimize = optimize,
        .no_precompiles = no_precompiles,
        .no_bn254 = no_bn254,
    };
    const mods = modules.createModules(b, module_config);

    // Setup Rust integration
    const rust_config = rust.RustConfig{
        .target = target,
        .optimize = optimize,
        .no_bn254 = no_bn254,
    };
    const rust_libs = rust.setupRustIntegration(b, rust_config);

    // Create REVM module if Rust is available
    const revm_mod = rust.createRevmModule(b, rust_config, mods.primitives, rust_libs.revm_lib);
    if (revm_mod) |mod| {
        mods.lib.addImport("revm", mod);
    }

    // C-KZG-4844 Zig bindings
    const c_kzg_dep = b.dependency("c_kzg_4844", .{
        .target = target,
        .optimize = optimize,
    });
    const c_kzg_lib = c_kzg_dep.artifact("c_kzg_4844");
    mods.primitives.linkLibrary(c_kzg_lib);

    // Link BN254 Rust library to EVM module
    if (rust_libs.bn254_lib) |lib| {
        mods.evm.linkLibrary(lib);
        mods.evm.addIncludePath(b.path("src/bn254_wrapper"));
    }

    // Link c-kzg library to EVM module
    mods.evm.linkLibrary(c_kzg_lib);

    // Build artifacts
    artifacts.buildArtifacts(b, mods, rust_libs, target, optimize);

    // Setup WASM builds
    setupWasmBuilds(b, optimize, mods.build_options);

    // Setup devtool
    setupDevtool(b, mods, target, optimize);

    // Setup debug and crash test executables
    setupDebugExecutables(b, mods, target);

    // Setup benchmarks
    benchmarks.setupBenchmarks(b, mods, target);

    // Setup tests
    test_setup.setupTests(b, mods, target, optimize);

    // Setup fuzzing
    fuzzing.setupFuzzing(b, mods, rust_libs, target, optimize);

    // Setup integration tests
    setupIntegrationTests(b, mods, target, optimize);

    // Setup special opcode test
    setupOpcodeRustTests(b, mods, target, optimize);
}

fn setupWasmBuilds(b: *std.Build, optimize: std.builtin.OptimizeMode, build_options_mod: *std.Build.Module) void {
    const wasm_target = wasm.setupWasmTarget(b);
    const wasm_optimize = optimize;

    // Create WASM modules
    const wasm_mods = modules.createWasmModules(b, wasm_target, wasm_optimize, build_options_mod);

    // Main WASM build
    const wasm_lib_build = wasm.buildWasmExecutable(b, .{
        .name = "guillotine",
        .root_source_file = "src/root.zig",
        .dest_sub_path = "guillotine.wasm",
    }, wasm_mods.lib);

    // Primitives-only WASM build
    const wasm_primitives_build = wasm.buildWasmExecutable(b, .{
        .name = "guillotine-primitives",
        .root_source_file = "src/primitives_c.zig",
        .dest_sub_path = "guillotine-primitives.wasm",
    }, wasm_mods.primitives_lib);

    // EVM-only WASM build
    const wasm_evm_build = wasm.buildWasmExecutable(b, .{
        .name = "guillotine-evm",
        .root_source_file = "src/evm_c.zig",
        .dest_sub_path = "guillotine-evm.wasm",
    }, wasm_mods.evm_lib);

    // Add step to report WASM bundle sizes
    const wasm_size_step = wasm.addWasmSizeReportStep(
        b,
        &[_][]const u8{ "guillotine.wasm", "guillotine-primitives.wasm", "guillotine-evm.wasm" },
        &[_]*std.Build.Step{
            &wasm_lib_build.install.step,
            &wasm_primitives_build.install.step,
            &wasm_evm_build.install.step,
        },
    );

    const wasm_step = b.step("wasm", "Build all WASM libraries and show bundle sizes");
    wasm_step.dependOn(&wasm_size_step.step);

    // Individual WASM build steps
    const wasm_primitives_step = b.step("wasm-primitives", "Build primitives-only WASM library");
    wasm_primitives_step.dependOn(&wasm_primitives_build.install.step);

    const wasm_evm_step = b.step("wasm-evm", "Build EVM-only WASM library");
    wasm_evm_step.dependOn(&wasm_evm_build.install.step);

    // Debug WASM build
    const wasm_debug_mod = wasm.createWasmModule(b, "src/root.zig", wasm_target, .Debug);
    wasm_debug_mod.addImport("primitives", wasm_mods.primitives);
    wasm_debug_mod.addImport("evm", wasm_mods.evm);

    const wasm_debug_build = wasm.buildWasmExecutable(b, .{
        .name = "guillotine-debug",
        .root_source_file = "src/root.zig",
        .dest_sub_path = "../bin/guillotine-debug.wasm",
        .debug_build = true,
    }, wasm_debug_mod);

    const wasm_debug_step = b.step("wasm-debug", "Build debug WASM for analysis");
    wasm_debug_step.dependOn(&wasm_debug_build.install.step);
}

fn setupDevtool(b: *std.Build, mods: modules.Modules, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    // Add webui dependency
    const webui = b.dependency("webui", .{
        .target = target,
        .optimize = optimize,
        .dynamic = false,
        .@"enable-tls" = false,
        .verbose = .err,
    });

    // Check and build npm dependencies
    const npm_check = b.addSystemCommand(&[_][]const u8{ "which", "npm" });
    npm_check.addCheck(.{ .expect_stdout_match = "npm" });

    const npm_install = b.addSystemCommand(&[_][]const u8{ "npm", "install" });
    npm_install.setCwd(b.path("src/devtool"));
    npm_install.step.dependOn(&npm_check.step);

    const npm_build = b.addSystemCommand(&[_][]const u8{ "npm", "run", "build" });
    npm_build.setCwd(b.path("src/devtool"));
    npm_build.step.dependOn(&npm_install.step);

    // Generate assets from the built Solid app
    const generate_assets = asset_generator.GenerateAssetsStep.init(b, "src/devtool/dist", "src/devtool/assets.zig");
    generate_assets.step.dependOn(&npm_build.step);

    const devtool_mod = b.createModule(.{
        .root_source_file = b.path("src/devtool/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    devtool_mod.addImport("Guillotine_lib", mods.lib);
    devtool_mod.addImport("evm", mods.evm);
    devtool_mod.addImport("primitives", mods.primitives);
    devtool_mod.addImport("provider", mods.provider);

    const devtool_exe = b.addExecutable(.{
        .name = "guillotine-devtool",
        .root_module = devtool_mod,
    });
    devtool_exe.addIncludePath(webui.path("src"));
    devtool_exe.addIncludePath(webui.path("include"));

    // Add native menu implementation on macOS
    if (target.result.os.tag == .macos) {
        setupMacOSDevtool(b, devtool_exe);
    }

    // Link webui library
    devtool_exe.linkLibrary(webui.artifact("webui"));

    // Link external libraries
    devtool_exe.linkLibC();
    if (target.result.os.tag == .macos) {
        devtool_exe.linkFramework("WebKit");
        devtool_exe.linkFramework("AppKit");
        devtool_exe.linkFramework("Foundation");
    }

    // Make devtool build depend on asset generation
    devtool_exe.step.dependOn(&generate_assets.step);

    // TEMPORARILY DISABLED: npm build failing
    // b.installArtifact(devtool_exe);

    const run_devtool_cmd = b.addRunArtifact(devtool_exe);
    run_devtool_cmd.step.dependOn(b.getInstallStep());

    const devtool_step = b.step("devtool", "Build and run the Ethereum devtool");
    devtool_step.dependOn(&run_devtool_cmd.step);

    const build_devtool_step = b.step("build-devtool", "Build the Ethereum devtool (without running)");
    build_devtool_step.dependOn(b.getInstallStep());
}

fn setupMacOSDevtool(b: *std.Build, devtool_exe: *std.Build.Step.Compile) void {
    // Compile Swift code to dynamic library
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

    // Create output directory
    const mkdir_cmd = b.addSystemCommand(&[_][]const u8{
        "mkdir", "-p", "zig-out",
    });
    swift_compile.step.dependOn(&mkdir_cmd.step);

    // Link the compiled Swift dynamic library
    devtool_exe.addLibraryPath(b.path("zig-out"));
    devtool_exe.linkSystemLibrary("native_menu_swift");
    devtool_exe.step.dependOn(&swift_compile.step);

    // Add Swift runtime library search paths
    devtool_exe.addLibraryPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx" });
    devtool_exe.addLibraryPath(.{ .cwd_relative = "/usr/lib/swift" });

    // macOS app bundle creation
    const bundle_dir = "macos/GuillotineDevtool.app/Contents/MacOS";
    const mkdir_bundle = b.addSystemCommand(&[_][]const u8{
        "mkdir", "-p", bundle_dir,
    });

    const copy_to_bundle = b.addSystemCommand(&[_][]const u8{
        "cp", "-f", "zig-out/bin/guillotine-devtool", bundle_dir,
    });
    copy_to_bundle.step.dependOn(&devtool_exe.step);
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

fn setupDebugExecutables(b: *std.Build, mods: modules.Modules, target: std.Build.ResolvedTarget) void {
    _ = b;
    _ = mods;
    _ = target;
    // Debug executables removed - source files don't exist
}

fn setupIntegrationTests(b: *std.Build, mods: modules.Modules, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    _ = b;
    _ = mods;
    _ = target;
    _ = optimize;
    // Integration tests removed - source files don't exist
}

fn setupOpcodeRustTests(b: *std.Build, mods: modules.Modules, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    _ = b;
    _ = mods;
    _ = target;
    _ = optimize;
    // Opcode Rust tests removed - source files don't exist
}