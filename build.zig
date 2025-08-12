const std = @import("std");
const asset_generator = @import("build_utils/asset_generator.zig");
const rust_build = @import("build_utils/rust_build.zig");
const tests = @import("build_utils/tests.zig");
const wasm = @import("build_utils/wasm.zig");
const devtool = @import("build_utils/devtool.zig");
const typescript = @import("build_utils/typescript.zig");

pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // Custom build option to disable precompiles
    const no_precompiles = b.option(bool, "no_precompiles", "Disable all EVM precompiles for minimal build") orelse false;

    // Detect Ubuntu native build (has Rust library linking issues)
    const force_bn254 = b.option(bool, "force_bn254", "Force BN254 even on Ubuntu") orelse false;
    const is_ubuntu_native = target.result.os.tag == .linux and target.result.cpu.arch == .x86_64 and !force_bn254;

    // Disable BN254 on Ubuntu native builds to avoid Rust library linking issues
    const no_bn254 = no_precompiles or is_ubuntu_native;

    // Create build options module
    const build_options = b.addOptions();
    build_options.addOption(bool, "no_precompiles", no_precompiles);
    build_options.addOption(bool, "no_bn254", no_bn254);
    // Compile-time tracing toggle (no runtime checks). Usage: zig build -Denable-tracing=true
    const enable_tracing = b.option(bool, "enable-tracing", "Enable EVM instruction tracing (compile-time)") orelse false;
    build_options.addOption(bool, "enable_tracing", enable_tracing);
    const build_options_mod = build_options.createModule();

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addIncludePath(b.path("src/bn254_wrapper"));
    lib_mod.addImport("build_options", build_options_mod);

    // Create primitives module
    const primitives_mod = b.createModule(.{
        .root_source_file = b.path("src/primitives/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create crypto module
    const crypto_mod = b.createModule(.{
        .root_source_file = b.path("src/crypto/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    crypto_mod.addImport("primitives", primitives_mod);

    // Create utils module
    const utils_mod = b.createModule(.{
        .root_source_file = b.path("src/utils.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create the trie module
    const trie_mod = b.createModule(.{
        .root_source_file = b.path("src/trie/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    trie_mod.addImport("primitives", primitives_mod);
    trie_mod.addImport("utils", utils_mod);

    // Create the provider module
    const provider_mod = b.createModule(.{
        .root_source_file = b.path("src/provider/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    provider_mod.addImport("primitives", primitives_mod);

    // BN254 Rust library integration for ECMUL and ECPAIRING precompiles
    // Uses arkworks ecosystem for production-grade elliptic curve operations
    // Skip on Ubuntu native builds due to Rust library linking issues

    // Determine the Rust target triple based on the Zig target
    // Always specify explicit Rust target for consistent library format
    const rust_target = switch (target.result.os.tag) {
        .linux => switch (target.result.cpu.arch) {
            .x86_64 => "x86_64-unknown-linux-gnu",
            .aarch64 => "aarch64-unknown-linux-gnu",
            else => null,
        },
        .macos => switch (target.result.cpu.arch) {
            .x86_64 => "x86_64-apple-darwin",
            .aarch64 => "aarch64-apple-darwin",
            else => null,
        },
        else => null,
    };

    // Single workspace build command that builds all Rust crates at once
    const workspace_build_step = if (rust_target != null) blk: {
        const rust_cmd = b.addSystemCommand(&[_][]const u8{
            "cargo",     "build",
            "--profile", if (optimize == .Debug) "dev" else "release",
        });
        if (rust_target) |target_triple| {
            rust_cmd.addArgs(&[_][]const u8{ "--target", target_triple });
        }
        break :blk rust_cmd;
    } else null;

    // Create BN254 library that depends on workspace build
    const bn254_lib = if (!no_bn254 and rust_target != null) blk: {
        const lib = b.addStaticLibrary(.{
            .name = "bn254_wrapper",
            .target = target,
            .optimize = optimize,
        });

        const profile_dir = if (optimize == .Debug) "debug" else "release";
        const lib_path = if (rust_target) |target_triple|
            b.fmt("target/{s}/{s}/libbn254_wrapper.a", .{ target_triple, profile_dir })
        else
            b.fmt("target/{s}/libbn254_wrapper.a", .{profile_dir});

        lib.addObjectFile(b.path(lib_path));
        lib.linkLibC();
        lib.addIncludePath(b.path("src/bn254_wrapper"));

        // Make sure workspace builds first
        if (workspace_build_step) |build_step| {
            lib.step.dependOn(&build_step.step);
        }

        break :blk lib;
    } else null;

    // C-KZG-4844 Zig bindings from evmts/c-kzg-4844
    const c_kzg_dep = b.dependency("c_kzg_4844", .{
        .target = target,
        .optimize = optimize,
    });

    const c_kzg_lib = c_kzg_dep.artifact("c_kzg_4844");
    primitives_mod.linkLibrary(c_kzg_lib);

    // Create the main evm module that exports everything
    const evm_mod = b.createModule(.{
        .root_source_file = b.path("src/evm/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    evm_mod.addImport("primitives", primitives_mod);
    evm_mod.addImport("crypto", crypto_mod);
    evm_mod.addImport("build_options", build_options_mod);

    // Link BN254 Rust library to EVM module (native targets only, if enabled)
    if (bn254_lib) |lib| {
        evm_mod.linkLibrary(lib);
        evm_mod.addIncludePath(b.path("src/bn254_wrapper"));
    }

    // Link c-kzg library to EVM module
    evm_mod.linkLibrary(c_kzg_lib);

    // Create REVM library that depends on workspace build
    const revm_lib = if (rust_target != null) blk: {
        const lib = b.addStaticLibrary(.{
            .name = "revm_wrapper",
            .target = target,
            .optimize = optimize,
        });

        const profile_dir = if (optimize == .Debug) "debug" else "release";
        const lib_path = if (rust_target) |target_triple|
            b.fmt("target/{s}/{s}/librevm_wrapper.a", .{ target_triple, profile_dir })
        else
            b.fmt("target/{s}/librevm_wrapper.a", .{profile_dir});

        lib.addObjectFile(b.path(lib_path));
        lib.linkLibC();
        lib.addIncludePath(b.path("src/revm_wrapper"));

        // Make sure workspace builds first
        if (workspace_build_step) |build_step| {
            lib.step.dependOn(&build_step.step);
        }

        break :blk lib;
    } else null;

    // Create REVM module
    const revm_mod = b.createModule(.{
        .root_source_file = b.path("src/revm_wrapper/revm.zig"),
        .target = target,
        .optimize = optimize,
    });
    revm_mod.addImport("primitives", primitives_mod);

    // Link REVM Rust library if available
    if (revm_lib) |lib| {
        revm_mod.linkLibrary(lib);
        revm_mod.addIncludePath(b.path("src/revm_wrapper"));
    }

    // EVM Benchmark Rust crate integration - removed guillotine-rs

    // Add Rust Foundry wrapper integration
    // TODO: Fix Rust integration - needs proper zabi dependency
    // const rust_build = @import("src/compilers/rust_build.zig");
    // const rust_step = rust_build.add_rust_integration(b, target, optimize) catch |err| {
    //     std.debug.print("Failed to add Rust integration: {}\n", .{err});
    //     return;
    // };

    // Create compilers module
    const compilers_mod = b.createModule(.{
        .root_source_file = b.path("src/compilers/package.zig"),
        .target = target,
        .optimize = optimize,
    });
    compilers_mod.addImport("primitives", primitives_mod);
    compilers_mod.addImport("evm", evm_mod);

    // Add modules to lib_mod so tests can access them
    lib_mod.addImport("primitives", primitives_mod);
    lib_mod.addImport("crypto", crypto_mod);
    lib_mod.addImport("evm", evm_mod);
    lib_mod.addImport("provider", provider_mod);
    lib_mod.addImport("compilers", compilers_mod);
    lib_mod.addImport("trie", trie_mod);
    if (revm_lib != null) {
        lib_mod.addImport("revm", revm_mod);
    }

    const exe_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    exe_mod.addImport("Guillotine_lib", lib_mod);
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "Guillotine",
        .root_module = lib_mod,
    });

    // Link BN254 Rust library to the library artifact (if enabled)
    if (bn254_lib) |bn254| {
        lib.linkLibrary(bn254);
        lib.addIncludePath(b.path("src/bn254_wrapper"));
    }

    // Note: c-kzg is now available as a module import, no need to link to main library

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // Create shared library for Python FFI
    const shared_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "Guillotine",
        .root_module = lib_mod,
    });

    // Link BN254 Rust library to the shared library artifact (if enabled)
    if (bn254_lib) |bn254| {
        shared_lib.linkLibrary(bn254);
        shared_lib.addIncludePath(b.path("src/bn254_wrapper"));
    }

    b.installArtifact(shared_lib);

    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    const exe = b.addExecutable(.{
        .name = "Guillotine",
        .root_module = exe_mod,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // Add evm_test_runner executable
    const evm_test_runner = b.addExecutable(.{
        .name = "evm_test_runner",
        .root_source_file = b.path("src/evm_test_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    evm_test_runner.root_module.addImport("evm", evm_mod);
    evm_test_runner.root_module.addImport("primitives", primitives_mod);
    b.installArtifact(evm_test_runner);

    // WASM library build optimized for size
    const wasm_target = wasm.setupWasmTarget(b);
    const wasm_optimize = optimize;

    // Create WASM-specific modules with minimal dependencies
    const wasm_primitives_mod = wasm.createWasmModule(b, "src/primitives/root.zig", wasm_target, wasm_optimize);
    // Note: WASM build excludes c-kzg-4844 (not available for WASM)

    const wasm_crypto_mod = wasm.createWasmModule(b, "src/crypto/root.zig", wasm_target, wasm_optimize);
    wasm_crypto_mod.addImport("primitives", wasm_primitives_mod);

    const wasm_evm_mod = wasm.createWasmModule(b, "src/evm/root.zig", wasm_target, wasm_optimize);
    wasm_evm_mod.addImport("primitives", wasm_primitives_mod);
    wasm_evm_mod.addImport("crypto", wasm_crypto_mod);
    wasm_evm_mod.addImport("build_options", build_options_mod);
    // Note: WASM build uses pure Zig implementations for BN254 operations

    // Main WASM build (includes both primitives and EVM)
    const wasm_lib_mod = wasm.createWasmModule(b, "src/root.zig", wasm_target, wasm_optimize);
    wasm_lib_mod.addImport("primitives", wasm_primitives_mod);
    wasm_lib_mod.addImport("evm", wasm_evm_mod);

    const wasm_lib_build = wasm.buildWasmExecutable(b, .{
        .name = "guillotine",
        .root_source_file = "src/root.zig",
        .dest_sub_path = "guillotine.wasm",
    }, wasm_lib_mod);

    // Primitives-only WASM build
    const wasm_primitives_lib_mod = wasm.createWasmModule(b, "src/primitives_c.zig", wasm_target, wasm_optimize);
    wasm_primitives_lib_mod.addImport("primitives", wasm_primitives_mod);

    const wasm_primitives_build = wasm.buildWasmExecutable(b, .{
        .name = "guillotine-primitives",
        .root_source_file = "src/primitives_c.zig",
        .dest_sub_path = "guillotine-primitives.wasm",
    }, wasm_primitives_lib_mod);

    // EVM-only WASM build
    const wasm_evm_lib_mod = wasm.createWasmModule(b, "src/evm_c.zig", wasm_target, wasm_optimize);
    wasm_evm_lib_mod.addImport("primitives", wasm_primitives_mod);
    wasm_evm_lib_mod.addImport("evm", wasm_evm_mod);

    const wasm_evm_build = wasm.buildWasmExecutable(b, .{
        .name = "guillotine-evm",
        .root_source_file = "src/evm_c.zig",
        .dest_sub_path = "guillotine-evm.wasm",
    }, wasm_evm_lib_mod);

    // Add step to report WASM bundle sizes for all three builds
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

    // Debug WASM build for analysis
    const wasm_debug_mod = wasm.createWasmModule(b, "src/root.zig", wasm_target, .Debug);
    wasm_debug_mod.addImport("primitives", wasm_primitives_mod);
    wasm_debug_mod.addImport("evm", wasm_evm_mod);

    const wasm_debug_build = wasm.buildWasmExecutable(b, .{
        .name = "guillotine-debug",
        .root_source_file = "src/root.zig",
        .dest_sub_path = "../bin/guillotine-debug.wasm",
        .debug_build = true,
    }, wasm_debug_mod);

    const wasm_debug_step = b.step("wasm-debug", "Build debug WASM for analysis");
    wasm_debug_step.dependOn(&wasm_debug_build.install.step);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Devtool executable
    // Add webui dependency
    const webui = b.dependency("webui", .{
        .target = target,
        .optimize = optimize,
        .dynamic = false,
        .@"enable-tls" = false,
        .verbose = .err,
    });

    // First, check if npm is installed and build the Solid app
    const npm_check = b.addSystemCommand(&[_][]const u8{ "which", "npm" });
    npm_check.addCheck(.{ .expect_stdout_match = "npm" });

    // Install npm dependencies for devtool
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

    const devtool_mod = b.createModule(.{
        .root_source_file = b.path("src/devtool/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    devtool_mod.addImport("Guillotine_lib", lib_mod);
    devtool_mod.addImport("evm", evm_mod);
    devtool_mod.addImport("primitives", primitives_mod);
    devtool_mod.addImport("provider", provider_mod);

    const devtool_exe = b.addExecutable(.{
        .name = "guillotine-devtool",
        .root_module = devtool_mod,
    });
    devtool_exe.addIncludePath(webui.path("src"));
    devtool_exe.addIncludePath(webui.path("include"));

    // Add native menu implementation on macOS
    if (target.result.os.tag == .macos) {
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
    }

    // Link webui library
    devtool_exe.linkLibrary(webui.artifact("webui"));

    // Link external libraries if needed for WebUI
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

    // Add build-only step for devtool
    const build_devtool_step = b.step("build-devtool", "Build the Ethereum devtool (without running)");
    build_devtool_step.dependOn(b.getInstallStep());

    // macOS app bundle creation
    if (target.result.os.tag == .macos) {
        // Create app bundle structure
        const bundle_dir = "macos/GuillotineDevtool.app/Contents/MacOS";
        const mkdir_bundle = b.addSystemCommand(&[_][]const u8{
            "mkdir", "-p", bundle_dir,
        });

        // Copy executable to app bundle
        const copy_to_bundle = b.addSystemCommand(&[_][]const u8{
            "cp", "-f", "zig-out/bin/guillotine-devtool", bundle_dir,
        });
        copy_to_bundle.step.dependOn(&devtool_exe.step);
        copy_to_bundle.step.dependOn(&mkdir_bundle.step);

        // Create macOS app bundle step
        const macos_app_step = b.step("macos-app", "Create macOS app bundle");
        macos_app_step.dependOn(&copy_to_bundle.step);

        // Create DMG installer step
        const create_dmg = b.addSystemCommand(&[_][]const u8{
            "scripts/create-dmg-fancy.sh",
        });
        create_dmg.step.dependOn(&copy_to_bundle.step);

        const dmg_step = b.step("macos-dmg", "Create macOS DMG installer");
        dmg_step.dependOn(&create_dmg.step);
    }

    // Crash Debug executable (only if source exists)
    const have_crash_debug = blk: {
        std.fs.cwd().access("src/crash-debug.zig", .{}) catch break :blk false;
        break :blk true;
    };
    if (have_crash_debug) {
        const crash_debug_exe = b.addExecutable(.{
            .name = "crash-debug",
            .root_source_file = b.path("src/crash-debug.zig"),
            .target = target,
            .optimize = .Debug, // Use Debug for better diagnostics
        });
        crash_debug_exe.root_module.addImport("evm", evm_mod);
        crash_debug_exe.root_module.addImport("primitives", primitives_mod);
        b.installArtifact(crash_debug_exe);

        const run_crash_debug_cmd = b.addRunArtifact(crash_debug_exe);
        const crash_debug_step = b.step("crash-debug", "Run crash debugging tool");
        crash_debug_step.dependOn(&run_crash_debug_cmd.step);
    }

    // Simple Crash Test executable (only if source exists)
    const have_simple_crash = blk: {
        std.fs.cwd().access("src/simple-crash-test.zig", .{}) catch break :blk false;
        break :blk true;
    };
    if (have_simple_crash) {
        const simple_crash_test_exe = b.addExecutable(.{
            .name = "simple-crash-test",
            .root_source_file = b.path("src/simple-crash-test.zig"),
            .target = target,
            .optimize = .Debug,
        });
        simple_crash_test_exe.root_module.addImport("evm", evm_mod);
        simple_crash_test_exe.root_module.addImport("primitives", primitives_mod);
        b.installArtifact(simple_crash_test_exe);

        const run_simple_crash_test_cmd = b.addRunArtifact(simple_crash_test_exe);
        const simple_crash_test_step = b.step("simple-crash-test", "Run simple crash test");
        simple_crash_test_step.dependOn(&run_simple_crash_test_cmd.step);
    }

    // EVM Benchmark Runner executable (always optimized for benchmarks)
    const evm_runner_exe = b.addExecutable(.{
        .name = "evm-runner",
        .root_source_file = b.path("bench/official/evms/zig/src/main.zig"),
        .target = target,
        .optimize = .ReleaseFast, // Always use ReleaseFast for benchmarks
    });
    evm_runner_exe.root_module.addImport("evm", evm_mod);
    evm_runner_exe.root_module.addImport("primitives", primitives_mod);

    b.installArtifact(evm_runner_exe);

    const run_evm_runner_cmd = b.addRunArtifact(evm_runner_exe);
    if (b.args) |args| {
        run_evm_runner_cmd.addArgs(args);
    }

    const evm_runner_step = b.step("evm-runner", "Run the EVM benchmark runner");
    evm_runner_step.dependOn(&run_evm_runner_cmd.step);

    const build_evm_runner_step = b.step("build-evm-runner", "Build the EVM benchmark runner");
    build_evm_runner_step.dependOn(&b.addInstallArtifact(evm_runner_exe, .{}).step);

    // Benchmark Orchestrator executable
    const clap_dep = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });

    const orchestrator_exe = b.addExecutable(.{
        .name = "orchestrator",
        .root_source_file = b.path("bench/official/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    orchestrator_exe.root_module.addImport("clap", clap_dep.module("clap"));

    b.installArtifact(orchestrator_exe);

    const run_orchestrator_cmd = b.addRunArtifact(orchestrator_exe);
    if (b.args) |args| {
        run_orchestrator_cmd.addArgs(args);
    }

    const orchestrator_step = b.step("orchestrator", "Run the benchmark orchestrator");
    orchestrator_step.dependOn(&run_orchestrator_cmd.step);

    const build_orchestrator_step = b.step("build-orchestrator", "Build the benchmark orchestrator");
    build_orchestrator_step.dependOn(&b.addInstallArtifact(orchestrator_exe, .{}).step);

    // Add poop benchmark runner and step
    const poop_runner_exe = b.addExecutable(.{
        .name = "poop-runner",
        .root_source_file = b.path("bench/poop_runner.zig"),
        .target = target,
        .optimize = .ReleaseFast, // Always use ReleaseFast for benchmarks
    });

    b.installArtifact(poop_runner_exe);

    const run_poop_cmd = b.addRunArtifact(poop_runner_exe);
    run_poop_cmd.step.dependOn(build_evm_runner_step); // Ensure evm-runner is built
    if (b.args) |args| {
        run_poop_cmd.addArgs(args);
    }

    const poop_step = b.step("poop", "Run poop benchmark on snailtracer (Linux only)");
    poop_step.dependOn(&run_poop_cmd.step);

    // Add a comparison step with default --js-runs=1 and --js-internal-runs=1
    const run_comparison_cmd = b.addRunArtifact(orchestrator_exe);
    run_comparison_cmd.addArg("--compare");
    run_comparison_cmd.addArg("--js-runs");
    run_comparison_cmd.addArg("1");
    run_comparison_cmd.addArg("--js-internal-runs");
    run_comparison_cmd.addArg("1");
    run_comparison_cmd.addArg("--export");
    run_comparison_cmd.addArg("markdown");
    if (b.args) |args| {
        run_comparison_cmd.addArgs(args);
    }

    const compare_step = b.step("bench-compare", "Run EVM comparison benchmarks with --js-runs=1 --js-internal-runs=1 by default");
    compare_step.dependOn(&run_comparison_cmd.step);

    // Build Go (geth) runner
    const geth_runner_build = b.addSystemCommand(&[_][]const u8{ "go", "build", "-o", "runner", "runner.go" });
    geth_runner_build.setCwd(b.path("bench/official/evms/geth"));

    // Build evmone runner using CMake
    const evmone_cmake_configure = b.addSystemCommand(&[_][]const u8{ "cmake", "-S", "bench/official/evms/evmone", "-B", "bench/official/evms/evmone/build", "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" });
    evmone_cmake_configure.setCwd(b.path(""));

    const evmone_cmake_build = b.addSystemCommand(&[_][]const u8{ "cmake", "--build", "bench/official/evms/evmone/build", "--parallel" });
    evmone_cmake_build.setCwd(b.path(""));
    evmone_cmake_build.step.dependOn(&evmone_cmake_configure.step);

    // Make benchmark targets depend on runner builds
    orchestrator_step.dependOn(&geth_runner_build.step);
    orchestrator_step.dependOn(&evmone_cmake_build.step);
    build_orchestrator_step.dependOn(&geth_runner_build.step);
    build_orchestrator_step.dependOn(&evmone_cmake_build.step);
    compare_step.dependOn(&geth_runner_build.step);
    compare_step.dependOn(&evmone_cmake_build.step);

    // Static library for opcode testing FFI
    const opcode_test_lib = b.addStaticLibrary(.{
        .name = "guillotine_opcode_test",
        .root_source_file = b.path("src/evm_opcode_test_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    opcode_test_lib.root_module.addImport("evm", evm_mod);
    opcode_test_lib.root_module.addImport("primitives", primitives_mod);
    opcode_test_lib.root_module.addImport("crypto", crypto_mod);
    opcode_test_lib.root_module.addImport("build_options", build_options_mod);

    // Link BN254 library if available
    if (bn254_lib) |bn254| {
        opcode_test_lib.linkLibrary(bn254);
        opcode_test_lib.addIncludePath(b.path("src/bn254_wrapper"));
    }

    b.installArtifact(opcode_test_lib);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Add Memory tests
    const memory_test = b.addTest(.{
        .name = "memory-test",
        .root_source_file = b.path("test/evm/memory_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    memory_test.root_module.addImport("evm", evm_mod);
    memory_test.root_module.addImport("primitives", primitives_mod);

    const run_memory_test = b.addRunArtifact(memory_test);
    const memory_test_step = b.step("test-memory", "Run Memory tests");
    memory_test_step.dependOn(&run_memory_test.step);

    // Add Memory Leak tests
    const memory_leak_test = b.addTest(.{
        .name = "memory-leak-test",
        .root_source_file = b.path("test/evm/memory_leak_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    memory_leak_test.root_module.addImport("evm", evm_mod);
    memory_leak_test.root_module.addImport("primitives", primitives_mod);

    const run_memory_leak_test = b.addRunArtifact(memory_leak_test);
    const memory_leak_test_step = b.step("test-memory-leak", "Run Memory leak prevention tests");
    memory_leak_test_step.dependOn(&run_memory_leak_test.step);

    // Add Stack tests
    const stack_test = b.addTest(.{
        .name = "stack-test",
        .root_source_file = b.path("test/evm/stack_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    stack_test.root_module.addImport("evm", evm_mod);

    const run_stack_test = b.addRunArtifact(stack_test);
    const stack_test_step = b.step("test-stack", "Run Stack tests");
    stack_test_step.dependOn(&run_stack_test.step);

    // Add new EVM tests
    const newevm_test = b.addTest(.{
        .name = "newevm-test",
        .root_source_file = b.path("src/evm/newevm_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    newevm_test.root_module.addImport("evm", evm_mod);
    newevm_test.root_module.addImport("primitives", primitives_mod);

    const run_newevm_test = b.addRunArtifact(newevm_test);
    const newevm_test_step = b.step("test-newevm", "Run new EVM tests");
    newevm_test_step.dependOn(&run_newevm_test.step);

    // Add arithmetic opcode tests for new EVM
    const newevm_arithmetic_test = b.addTest(.{
        .name = "newevm-arithmetic-test",
        .root_source_file = b.path("test/evm/opcodes/arithmetic_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    newevm_arithmetic_test.root_module.addImport("evm", evm_mod);
    newevm_arithmetic_test.root_module.addImport("primitives", primitives_mod);

    const run_newevm_arithmetic_test = b.addRunArtifact(newevm_arithmetic_test);
    newevm_test_step.dependOn(&run_newevm_arithmetic_test.step);

    // Add bitwise opcode tests for new EVM
    const newevm_bitwise_test = b.addTest(.{
        .name = "newevm-bitwise-test",
        .root_source_file = b.path("test/evm/opcodes/bitwise_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    newevm_bitwise_test.root_module.addImport("evm", evm_mod);
    newevm_bitwise_test.root_module.addImport("primitives", primitives_mod);

    const run_newevm_bitwise_test = b.addRunArtifact(newevm_bitwise_test);
    newevm_test_step.dependOn(&run_newevm_bitwise_test.step);

    // Add comparison opcode tests for new EVM
    const newevm_comparison_test = b.addTest(.{
        .name = "newevm-comparison-test",
        .root_source_file = b.path("test/evm/opcodes/comparison_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    newevm_comparison_test.root_module.addImport("evm", evm_mod);
    newevm_comparison_test.root_module.addImport("primitives", primitives_mod);

    const run_newevm_comparison_test = b.addRunArtifact(newevm_comparison_test);
    newevm_test_step.dependOn(&run_newevm_comparison_test.step);

    // Add block opcode tests for new EVM
    const newevm_block_test = b.addTest(.{
        .name = "newevm-block-test",
        .root_source_file = b.path("test/evm/opcodes/block_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    newevm_block_test.root_module.addImport("evm", evm_mod);
    newevm_block_test.root_module.addImport("primitives", primitives_mod);

    const run_newevm_block_test = b.addRunArtifact(newevm_block_test);
    newevm_test_step.dependOn(&run_newevm_block_test.step);

    // Add stack opcode tests for new EVM
    const newevm_stack_test = b.addTest(.{
        .name = "newevm-stack-test",
        .root_source_file = b.path("test/evm/opcodes/stack_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    newevm_stack_test.root_module.addImport("evm", evm_mod);
    newevm_stack_test.root_module.addImport("primitives", primitives_mod);

    const run_newevm_stack_test = b.addRunArtifact(newevm_stack_test);
    newevm_test_step.dependOn(&run_newevm_stack_test.step);

    // Add Stack validation tests
    const stack_validation_test = b.addTest(.{
        .name = "stack-validation-test",
        .root_source_file = b.path("test/evm/stack_validation_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    stack_validation_test.root_module.stack_check = false;
    stack_validation_test.root_module.addImport("evm", evm_mod);

    const run_stack_validation_test = b.addRunArtifact(stack_validation_test);
    const stack_validation_test_step = b.step("test-stack-validation", "Run Stack validation tests");
    stack_validation_test_step.dependOn(&run_stack_validation_test.step);

    // Add Jump table tests
    const jump_table_test = b.addTest(.{
        .name = "jump-table-test",
        .root_source_file = b.path("test/evm/jump_table_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    jump_table_test.root_module.stack_check = false;
    jump_table_test.root_module.addImport("primitives", primitives_mod);
    jump_table_test.root_module.addImport("evm", evm_mod);

    const run_jump_table_test = b.addRunArtifact(jump_table_test);
    const jump_table_test_step = b.step("test-jump-table", "Run Jump table tests");
    jump_table_test_step.dependOn(&run_jump_table_test.step);

    // Add Config tests
    const config_test = b.addTest(.{
        .name = "config-test",
        .root_source_file = b.path("test/evm/config_simple_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    config_test.root_module.stack_check = false;
    config_test.root_module.addImport("primitives", primitives_mod);
    config_test.root_module.addImport("evm", evm_mod);

    const run_config_test = b.addRunArtifact(config_test);
    const config_test_step = b.step("test-config", "Run Config tests");
    config_test_step.dependOn(&run_config_test.step);

    // Add Opcodes tests
    const opcodes_test = b.addTest(.{
        .name = "opcodes-test",
        .root_source_file = b.path("test/evm/opcodes/opcodes_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    opcodes_test.root_module.stack_check = false;
    opcodes_test.root_module.addImport("primitives", primitives_mod);
    opcodes_test.root_module.addImport("evm", evm_mod);

    const run_opcodes_test = b.addRunArtifact(opcodes_test);
    const opcodes_test_step = b.step("test-opcodes", "Run Opcodes tests");
    opcodes_test_step.dependOn(&run_opcodes_test.step);

    // Benchmark Runner test removed - file no longer exists

    // Add Minimal Call Test
    const minimal_call_test = b.addTest(.{
        .name = "minimal-call-test",
        .root_source_file = b.path("test/evm/minimal_call_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    minimal_call_test.root_module.stack_check = false;
    minimal_call_test.root_module.addImport("primitives", primitives_mod);
    minimal_call_test.root_module.addImport("evm", evm_mod);

    const run_minimal_call_test = b.addRunArtifact(minimal_call_test);
    const minimal_call_test_step = b.step("test-minimal-call", "Run Minimal Call test");
    minimal_call_test_step.dependOn(&run_minimal_call_test.step);

    // Add Debug Analysis Test
    const debug_analysis_test = b.addTest(.{
        .name = "debug-analysis-test",
        .root_source_file = b.path("test/evm/debug_analysis_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    debug_analysis_test.root_module.stack_check = false;
    debug_analysis_test.root_module.addImport("primitives", primitives_mod);
    debug_analysis_test.root_module.addImport("evm", evm_mod);

    const run_debug_analysis_test = b.addRunArtifact(debug_analysis_test);
    const debug_analysis_test_step = b.step("test-debug-analysis", "Run Debug Analysis test");
    debug_analysis_test_step.dependOn(&run_debug_analysis_test.step);

    // Add Super Minimal Test
    const super_minimal_test = b.addTest(.{
        .name = "super-minimal-test",
        .root_source_file = b.path("test/evm/super_minimal_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    super_minimal_test.root_module.stack_check = false;
    super_minimal_test.root_module.addImport("primitives", primitives_mod);
    super_minimal_test.root_module.addImport("evm", evm_mod);

    const run_super_minimal_test = b.addRunArtifact(super_minimal_test);
    const super_minimal_test_step = b.step("test-super-minimal", "Run Super Minimal test");
    super_minimal_test_step.dependOn(&run_super_minimal_test.step);

    // Add Generated Opcode Comparison tests
    const opcode_comparison_test = b.addTest(.{
        .name = "opcode-comparison-test",
        .root_source_file = b.path("test/evm/opcodes/generated_opcode_comparison_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    opcode_comparison_test.root_module.stack_check = false;
    opcode_comparison_test.root_module.addImport("primitives", primitives_mod);
    opcode_comparison_test.root_module.addImport("evm", evm_mod);
    opcode_comparison_test.root_module.addImport("Address", primitives_mod);
    opcode_comparison_test.root_module.addImport("crypto", crypto_mod);
    opcode_comparison_test.root_module.addImport("build_options", build_options_mod);

    const run_opcode_comparison_test = b.addRunArtifact(opcode_comparison_test);
    const opcode_comparison_test_step = b.step("test-opcode-comparison", "Run opcode comparison tests");
    opcode_comparison_test_step.dependOn(&run_opcode_comparison_test.step);

    // Add VM opcode tests
    const vm_opcode_test = b.addTest(.{
        .name = "vm-opcode-test",
        .root_source_file = b.path("test/evm/vm_opcode_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    vm_opcode_test.root_module.stack_check = false;
    vm_opcode_test.root_module.addImport("primitives", primitives_mod);
    vm_opcode_test.root_module.addImport("evm", evm_mod);

    const run_vm_opcode_test = b.addRunArtifact(vm_opcode_test);
    const vm_opcode_test_step = b.step("test-vm-opcodes", "Run VM opcode tests");
    vm_opcode_test_step.dependOn(&run_vm_opcode_test.step);

    // Add Integration tests
    const integration_test = b.addTest(.{
        .name = "integration-test",
        .root_source_file = b.path("test/evm/integration/package.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    integration_test.root_module.stack_check = false;
    integration_test.root_module.addImport("primitives", primitives_mod);
    integration_test.root_module.addImport("evm", evm_mod);

    const run_integration_test = b.addRunArtifact(integration_test);
    const integration_test_step = b.step("test-integration", "Run Integration tests");
    integration_test_step.dependOn(&run_integration_test.step);

    // Add comprehensive EVM tests package
    const evm_package_test = b.addTest(.{
        .name = "evm-package-test",
        .root_source_file = b.path("test/evm/package.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    evm_package_test.root_module.stack_check = false;
    evm_package_test.root_module.addImport("primitives", primitives_mod);
    evm_package_test.root_module.addImport("evm", evm_mod);
    evm_package_test.root_module.addImport("Address", primitives_mod);

    const run_evm_package_test = b.addRunArtifact(evm_package_test);
    const evm_package_test_step = b.step("test-evm-all", "Run all EVM tests via package");
    evm_package_test_step.dependOn(&run_evm_package_test.step);

    // Add comprehensive opcodes tests package
    const opcodes_package_test = b.addTest(.{
        .name = "opcodes-package-test",
        .root_source_file = b.path("test/evm/opcodes/package.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    opcodes_package_test.root_module.stack_check = false;
    opcodes_package_test.root_module.addImport("primitives", primitives_mod);
    opcodes_package_test.root_module.addImport("evm", evm_mod);

    const run_opcodes_package_test = b.addRunArtifact(opcodes_package_test);
    const opcodes_package_test_step = b.step("test-opcodes-all", "Run all opcode tests via package");
    opcodes_package_test_step.dependOn(&run_opcodes_package_test.step);

    // Add differential tests package
    const differential_test = b.addTest(.{
        .name = "differential-test",
        .root_source_file = b.path("test/differential/package.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    differential_test.root_module.stack_check = false;
    differential_test.root_module.addImport("primitives", primitives_mod);
    differential_test.root_module.addImport("evm", evm_mod);
    differential_test.root_module.addImport("revm", revm_mod);

    // Link REVM Rust library for differential tests if available
    if (revm_lib) |revm_library| {
        differential_test.linkLibrary(revm_library);
        differential_test.addIncludePath(b.path("src/revm_wrapper"));
        differential_test.linkLibC();

        // Link the compiled Rust dynamic library (needed on macOS for c++/Security deps)
        const revm_rust_target_dir = if (optimize == .Debug) "debug" else "release";
        const revm_dylib_path = if (rust_target) |target_triple|
            b.fmt("target/{s}/{s}/librevm_wrapper.dylib", .{ target_triple, revm_rust_target_dir })
        else
            b.fmt("target/{s}/librevm_wrapper.dylib", .{revm_rust_target_dir});
        differential_test.addObjectFile(b.path(revm_dylib_path));

        // Platform-specific system libs/frameworks for REVM
        if (target.result.os.tag == .linux) {
            differential_test.linkSystemLibrary("m");
            differential_test.linkSystemLibrary("pthread");
            differential_test.linkSystemLibrary("dl");
        } else if (target.result.os.tag == .macos) {
            differential_test.linkSystemLibrary("c++");
            differential_test.linkFramework("Security");
            differential_test.linkFramework("SystemConfiguration");
            differential_test.linkFramework("CoreFoundation");
        }

        // Ensure Rust library is built before running tests
        differential_test.step.dependOn(&revm_library.step);
    }

    const run_differential_test = b.addRunArtifact(differential_test);
    const differential_test_step = b.step("test-differential", "Run differential tests");
    differential_test_step.dependOn(&run_differential_test.step);

    // Add specific STATICCALL test for debugging
    const staticcall_test = b.addTest(.{
        .name = "staticcall-debug-test",
        .root_source_file = b.path("test/differential/system_differential_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .filters = &.{"STATICCALL opcode enforces read-only execution"},
    });
    staticcall_test.root_module.stack_check = false;
    staticcall_test.root_module.addImport("primitives", primitives_mod);
    staticcall_test.root_module.addImport("evm", evm_mod);
    staticcall_test.root_module.addImport("revm", revm_mod);

    if (revm_lib) |revm_library| {
        staticcall_test.linkLibrary(revm_library);
        staticcall_test.addIncludePath(b.path("src/revm_wrapper"));
        staticcall_test.linkLibC();

        // Link the compiled Rust dynamic library (needed on macOS for c++/Security deps)
        const revm_rust_target_dir = if (optimize == .Debug) "debug" else "release";
        const revm_dylib_path = if (rust_target) |target_triple|
            b.fmt("target/{s}/{s}/librevm_wrapper.dylib", .{ target_triple, revm_rust_target_dir })
        else
            b.fmt("target/{s}/librevm_wrapper.dylib", .{revm_rust_target_dir});
        staticcall_test.addObjectFile(b.path(revm_dylib_path));

        // Platform-specific system libs/frameworks for REVM
        if (target.result.os.tag == .linux) {
            staticcall_test.linkSystemLibrary("m");
            staticcall_test.linkSystemLibrary("pthread");
            staticcall_test.linkSystemLibrary("dl");
        } else if (target.result.os.tag == .macos) {
            staticcall_test.linkSystemLibrary("c++");
            staticcall_test.linkFramework("Security");
            staticcall_test.linkFramework("SystemConfiguration");
            staticcall_test.linkFramework("CoreFoundation");
        }

        // Ensure Rust library is built before running tests
        staticcall_test.step.dependOn(&revm_library.step);
    }

    const run_staticcall_test = b.addRunArtifact(staticcall_test);
    const staticcall_test_step = b.step("test-staticcall", "Run isolated STATICCALL test with debug logging");
    staticcall_test_step.dependOn(&run_staticcall_test.step);

    // Add system differential test as separate target (temporarily excluded from main suite due to STATICCALL issue)
    const system_differential_test = b.addTest(.{
        .name = "system-differential-test",
        .root_source_file = b.path("test/differential/system_differential_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    system_differential_test.root_module.stack_check = false;
    system_differential_test.root_module.addImport("primitives", primitives_mod);
    system_differential_test.root_module.addImport("evm", evm_mod);
    system_differential_test.root_module.addImport("revm", revm_mod);

    if (revm_lib) |revm_library| {
        system_differential_test.linkLibrary(revm_library);
        system_differential_test.addIncludePath(b.path("src/revm_wrapper"));
        system_differential_test.linkLibC();

        // Link the compiled Rust dynamic library (needed on macOS for c++/Security deps)
        const revm_rust_target_dir = if (optimize == .Debug) "debug" else "release";
        const revm_dylib_path = if (rust_target) |target_triple|
            b.fmt("target/{s}/{s}/librevm_wrapper.dylib", .{ target_triple, revm_rust_target_dir })
        else
            b.fmt("target/{s}/librevm_wrapper.dylib", .{revm_rust_target_dir});
        system_differential_test.addObjectFile(b.path(revm_dylib_path));

        // Platform-specific system libs/frameworks for REVM
        if (target.result.os.tag == .linux) {
            system_differential_test.linkSystemLibrary("m");
            system_differential_test.linkSystemLibrary("pthread");
            system_differential_test.linkSystemLibrary("dl");
        } else if (target.result.os.tag == .macos) {
            system_differential_test.linkSystemLibrary("c++");
            system_differential_test.linkFramework("Security");
            system_differential_test.linkFramework("SystemConfiguration");
            system_differential_test.linkFramework("CoreFoundation");
        }

        // Ensure Rust library is built before running tests
        system_differential_test.step.dependOn(&revm_library.step);
    }

    const run_system_differential_test = b.addRunArtifact(system_differential_test);
    const system_differential_test_step = b.step("test-system-differential", "Run system differential tests");
    system_differential_test_step.dependOn(&run_system_differential_test.step);

    // Add comprehensive ALL tests package
    const all_tests_package = b.addTest(.{
        .name = "all-tests-package",
        .root_source_file = b.path("test/package.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    all_tests_package.root_module.stack_check = false;
    all_tests_package.root_module.addImport("primitives", primitives_mod);
    all_tests_package.root_module.addImport("evm", evm_mod);
    all_tests_package.root_module.addImport("Address", primitives_mod);
    all_tests_package.root_module.addImport("revm", revm_mod);

    const run_all_tests_package = b.addRunArtifact(all_tests_package);
    const all_tests_package_step = b.step("test-all-comprehensive", "Run ALL tests via package system");
    all_tests_package_step.dependOn(&run_all_tests_package.step);

    // Add benchmark fixture tests
    const thousand_hashes_test = b.addTest(.{
        .name = "thousand-hashes-test",
        .root_source_file = b.path("test/1000_hashes.zig"),
        .target = target,
        .optimize = optimize,
    });
    thousand_hashes_test.root_module.addImport("evm", evm_mod);
    thousand_hashes_test.root_module.addImport("primitives", primitives_mod);
    const run_thousand_hashes_test = b.addRunArtifact(thousand_hashes_test);
    const thousand_hashes_test_step = b.step("test-thousand-hashes", "Run thousand hashes benchmark test");
    thousand_hashes_test_step.dependOn(&run_thousand_hashes_test.step);

    const snailtracer_test = b.addTest(.{
        .name = "snailtracer-test",
        .root_source_file = b.path("test/snailtracer_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    snailtracer_test.root_module.addImport("evm", evm_mod);
    snailtracer_test.root_module.addImport("primitives", primitives_mod);
    const run_snailtracer_test = b.addRunArtifact(snailtracer_test);
    const snailtracer_test_step = b.step("test-snailtracer", "Run snailtracer benchmark test");
    snailtracer_test_step.dependOn(&run_snailtracer_test.step);

    const erc20_bench_test = b.addTest(.{
        .name = "erc20-bench-test",
        .root_source_file = b.path("test/erc20_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    erc20_bench_test.root_module.addImport("evm", evm_mod);
    erc20_bench_test.root_module.addImport("primitives", primitives_mod);
    const run_erc20_bench_test = b.addRunArtifact(erc20_bench_test);
    const erc20_bench_test_step = b.step("test-erc20-bench", "Run ERC20 benchmark test");
    erc20_bench_test_step.dependOn(&run_erc20_bench_test.step);

    // (removed temporary minimal dynamic JUMP reproduction target)

    // Add Gas Accounting tests
    const gas_test = b.addTest(.{
        .name = "gas-test",
        .root_source_file = b.path("test/evm/gas/gas_accounting_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    gas_test.root_module.stack_check = false;
    gas_test.root_module.addImport("primitives", primitives_mod);
    gas_test.root_module.addImport("evm", evm_mod);

    const run_gas_test = b.addRunArtifact(gas_test);
    const gas_test_step = b.step("test-gas", "Run Gas Accounting tests");
    gas_test_step.dependOn(&run_gas_test.step);

    // Add Static Call Protection tests
    const static_protection_test = b.addTest(.{
        .name = "static-protection-test",
        .root_source_file = b.path("test/evm/static_call_protection_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    static_protection_test.root_module.stack_check = false;
    static_protection_test.root_module.addImport("primitives", primitives_mod);
    static_protection_test.root_module.addImport("evm", evm_mod);

    const run_static_protection_test = b.addRunArtifact(static_protection_test);
    const static_protection_test_step = b.step("test-static-protection", "Run Static Call Protection tests");
    static_protection_test_step.dependOn(&run_static_protection_test.step);

    // Add Precompile SHA256 tests (only if precompiles are enabled)
    var run_sha256_test: ?*std.Build.Step.Run = null;
    if (!no_precompiles) {
        const sha256_test = b.addTest(.{
            .name = "sha256-test",
            .root_source_file = b.path("test/evm/precompiles/sha256_test.zig"),
            .target = target,
            .optimize = optimize,
        });
        sha256_test.root_module.stack_check = false;
        sha256_test.root_module.addImport("primitives", primitives_mod);
        sha256_test.root_module.addImport("evm", evm_mod);

        run_sha256_test = b.addRunArtifact(sha256_test);
        const sha256_test_step = b.step("test-sha256", "Run SHA256 precompile tests");
        sha256_test_step.dependOn(&run_sha256_test.?.step);
    }

    // Add RIPEMD160 precompile tests (only if precompiles are enabled)
    var run_ripemd160_test: ?*std.Build.Step.Run = null;
    if (!no_precompiles) {
        const ripemd160_test = b.addTest(.{
            .name = "ripemd160-test",
            .root_source_file = b.path("test/evm/precompiles/ripemd160_test.zig"),
            .target = target,
            .optimize = optimize,
        });
        ripemd160_test.root_module.stack_check = false;
        ripemd160_test.root_module.addImport("primitives", primitives_mod);
        ripemd160_test.root_module.addImport("evm", evm_mod);

        run_ripemd160_test = b.addRunArtifact(ripemd160_test);
        const ripemd160_test_step = b.step("test-ripemd160", "Run RIPEMD160 precompile tests");
        ripemd160_test_step.dependOn(&run_ripemd160_test.?.step);
    }

    // Add BLAKE2f tests
    const blake2f_test = b.addTest(.{
        .name = "blake2f-test",
        .root_source_file = b.path("test/evm/precompiles/blake2f_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    blake2f_test.root_module.stack_check = false;
    blake2f_test.root_module.addImport("primitives", primitives_mod);
    blake2f_test.root_module.addImport("evm", evm_mod);
    const run_blake2f_test = b.addRunArtifact(blake2f_test);
    const blake2f_test_step = b.step("test-blake2f", "Run BLAKE2f precompile tests");
    blake2f_test_step.dependOn(&run_blake2f_test.step);

    // Add BN254 Rust wrapper tests (only if BN254 is enabled)
    const run_bn254_rust_test = if (bn254_lib) |bn254_library| blk: {
        const bn254_rust_test = b.addTest(.{
            .name = "bn254-rust-test",
            .root_source_file = b.path("test/evm/precompiles/bn254_rust_test.zig"),
            .target = target,
            .optimize = optimize,
        });
        bn254_rust_test.root_module.stack_check = false;
        bn254_rust_test.root_module.addImport("primitives", primitives_mod);
        bn254_rust_test.root_module.addImport("evm", evm_mod);
        // Link BN254 Rust library to tests
        bn254_rust_test.linkLibrary(bn254_library);
        bn254_rust_test.addIncludePath(b.path("src/bn254_wrapper"));

        const run_test = b.addRunArtifact(bn254_rust_test);
        const test_step_bn254 = b.step("test-bn254-rust", "Run BN254 Rust wrapper precompile tests");
        test_step_bn254.dependOn(&run_test.step);

        break :blk run_test;
    } else null;

    // Add E2E Simple tests
    const e2e_simple_test = b.addTest(.{
        .name = "e2e-simple-test",
        .root_source_file = b.path("test/evm/e2e_simple_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    e2e_simple_test.root_module.stack_check = false;
    e2e_simple_test.root_module.addImport("primitives", primitives_mod);
    e2e_simple_test.root_module.addImport("evm", evm_mod);

    const run_e2e_simple_test = b.addRunArtifact(e2e_simple_test);
    const e2e_simple_test_step = b.step("test-e2e-simple", "Run E2E simple tests");
    e2e_simple_test_step.dependOn(&run_e2e_simple_test.step);

    // Add E2E Error Handling tests
    const e2e_error_test = b.addTest(.{
        .name = "e2e-error-test",
        .root_source_file = b.path("test/evm/e2e_error_handling_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    e2e_error_test.root_module.stack_check = false;
    e2e_error_test.root_module.addImport("primitives", primitives_mod);
    e2e_error_test.root_module.addImport("evm", evm_mod);

    const run_e2e_error_test = b.addRunArtifact(e2e_error_test);
    const e2e_error_test_step = b.step("test-e2e-error", "Run E2E error handling tests");
    e2e_error_test_step.dependOn(&run_e2e_error_test.step);

    // Add E2E Data Structures tests
    const e2e_data_test = b.addTest(.{
        .name = "e2e-data-test",
        .root_source_file = b.path("test/evm/e2e_data_structures_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    e2e_data_test.root_module.stack_check = false;
    e2e_data_test.root_module.addImport("primitives", primitives_mod);
    e2e_data_test.root_module.addImport("evm", evm_mod);

    const run_e2e_data_test = b.addRunArtifact(e2e_data_test);
    const e2e_data_test_step = b.step("test-e2e-data", "Run E2E data structures tests");
    e2e_data_test_step.dependOn(&run_e2e_data_test.step);

    // Add E2E Inheritance tests
    const e2e_inheritance_test = b.addTest(.{
        .name = "e2e-inheritance-test",
        .root_source_file = b.path("test/evm/e2e_inheritance_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    e2e_inheritance_test.root_module.stack_check = false;
    e2e_inheritance_test.root_module.addImport("primitives", primitives_mod);
    e2e_inheritance_test.root_module.addImport("evm", evm_mod);

    const run_e2e_inheritance_test = b.addRunArtifact(e2e_inheritance_test);
    const e2e_inheritance_test_step = b.step("test-e2e-inheritance", "Run E2E inheritance tests");
    e2e_inheritance_test_step.dependOn(&run_e2e_inheritance_test.step);

    // Add Compiler tests
    const compiler_test = b.addTest(.{
        .name = "compiler-test",
        .root_source_file = b.path("src/compilers/compiler.zig"),
        .target = target,
        .optimize = optimize,
    });
    compiler_test.root_module.addImport("primitives", primitives_mod);
    compiler_test.root_module.addImport("evm", evm_mod);

    // TODO: Re-enable when Rust integration is fixed
    // // Make the compiler test depend on the Rust build
    // compiler_test.step.dependOn(rust_step);

    // // Link the Rust library to the compiler test
    // compiler_test.addObjectFile(b.path("zig-out/lib/libfoundry_wrapper.a"));
    // compiler_test.linkLibC();

    // // Link system libraries required by Rust static lib
    // if (target.result.os.tag == .linux) {
    //     compiler_test.linkSystemLibrary("unwind");
    //     compiler_test.linkSystemLibrary("gcc_s");
    // } else if (target.result.os.tag == .macos) {
    //     compiler_test.linkFramework("CoreFoundation");
    //     compiler_test.linkFramework("Security");
    // }

    const run_compiler_test = b.addRunArtifact(compiler_test);
    const compiler_test_step = b.step("test-compiler", "Run Compiler tests");
    compiler_test_step.dependOn(&run_compiler_test.step);

    // Add Devtool tests
    const devtool_test = b.addTest(.{
        .name = "devtool-test",
        .root_source_file = b.path("src/devtool/evm.zig"),
        .target = target,
        .optimize = optimize,
    });
    devtool_test.root_module.addImport("evm", evm_mod);
    devtool_test.root_module.addImport("primitives", primitives_mod);

    const run_devtool_test = b.addRunArtifact(devtool_test);
    const devtool_test_step = b.step("test-devtool", "Run Devtool tests");
    devtool_test_step.dependOn(&run_devtool_test.step);

    // Add SnailShellBenchmark test
    const snail_shell_benchmark_test = b.addTest(.{
        .name = "snail-shell-benchmark-test",
        .root_source_file = b.path("src/solidity/snail_shell_benchmark_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    snail_shell_benchmark_test.root_module.addImport("primitives", primitives_mod);
    snail_shell_benchmark_test.root_module.addImport("evm", evm_mod);

    const run_snail_shell_benchmark_test = b.addRunArtifact(snail_shell_benchmark_test);
    const snail_shell_benchmark_test_step = b.step("test-benchmark", "Run SnailShellBenchmark tests");
    snail_shell_benchmark_test_step.dependOn(&run_snail_shell_benchmark_test.step);

    // Add BN254 fuzz tests
    const bn254_fuzz_test = b.addTest(.{
        .name = "bn254-fuzz-test",
        .root_source_file = b.path("src/crypto/bn254/fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    bn254_fuzz_test.root_module.addImport("primitives", primitives_mod);

    const run_bn254_fuzz_test = b.addRunArtifact(bn254_fuzz_test);
    if (b.args) |args| {
        run_bn254_fuzz_test.addArgs(args);
    }
    const bn254_fuzz_test_step = b.step("fuzz-bn254", "Run BN254 fuzz tests (use: zig build fuzz-bn254 -- --fuzz)");
    bn254_fuzz_test_step.dependOn(&run_bn254_fuzz_test.step);

    // Add ECMUL precompile fuzz tests
    const ecmul_fuzz_test = b.addTest(.{
        .name = "ecmul-fuzz-test",
        .root_source_file = b.path("src/evm/precompiles/ecmul_fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    ecmul_fuzz_test.root_module.addImport("primitives", primitives_mod);
    ecmul_fuzz_test.root_module.addImport("crypto", crypto_mod);
    ecmul_fuzz_test.root_module.addImport("evm", evm_mod);

    const run_ecmul_fuzz_test = b.addRunArtifact(ecmul_fuzz_test);
    if (b.args) |args| {
        run_ecmul_fuzz_test.addArgs(args);
    }
    const ecmul_fuzz_test_step = b.step("fuzz-ecmul", "Run ECMUL precompile fuzz tests (use: zig build fuzz-ecmul -- --fuzz)");
    ecmul_fuzz_test_step.dependOn(&run_ecmul_fuzz_test.step);

    // Add ECPAIRING precompile fuzz tests
    const ecpairing_fuzz_test = b.addTest(.{
        .name = "ecpairing-fuzz-test",
        .root_source_file = b.path("src/evm/precompiles/ecpairing_fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    ecpairing_fuzz_test.root_module.addImport("primitives", primitives_mod);
    ecpairing_fuzz_test.root_module.addImport("crypto", crypto_mod);
    ecpairing_fuzz_test.root_module.addImport("evm", evm_mod);

    const run_ecpairing_fuzz_test = b.addRunArtifact(ecpairing_fuzz_test);
    if (b.args) |args| {
        run_ecpairing_fuzz_test.addArgs(args);
    }
    const ecpairing_fuzz_test_step = b.step("fuzz-ecpairing", "Run ECPAIRING precompile fuzz tests (use: zig build fuzz-ecpairing -- --fuzz)");
    ecpairing_fuzz_test_step.dependOn(&run_ecpairing_fuzz_test.step);

    // Add BN254 comparison fuzz test (Zig vs Rust)
    const bn254_comparison_fuzz_test = b.addTest(.{
        .name = "bn254-comparison-fuzz-test",
        .root_source_file = b.path("test/fuzz/bn254_comparison_fuzz_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    bn254_comparison_fuzz_test.root_module.addImport("primitives", primitives_mod);
    bn254_comparison_fuzz_test.root_module.addImport("crypto", crypto_mod);
    bn254_comparison_fuzz_test.root_module.addImport("evm", evm_mod);
    if (bn254_lib) |bn254| {
        bn254_comparison_fuzz_test.linkLibrary(bn254);
    }

    const run_bn254_comparison_fuzz_test = b.addRunArtifact(bn254_comparison_fuzz_test);
    if (b.args) |args| {
        run_bn254_comparison_fuzz_test.addArgs(args);
    }
    const bn254_comparison_fuzz_test_step = b.step("fuzz-compare", "Run BN254 comparison fuzz tests (use: zig build fuzz-compare -- --fuzz)");
    bn254_comparison_fuzz_test_step.dependOn(&run_bn254_comparison_fuzz_test.step);

    // Add a master fuzz test step that runs all fuzz tests
    const fuzz_all_step = b.step("fuzz", "Run all fuzz tests (use: zig build fuzz -- --fuzz)");
    fuzz_all_step.dependOn(&run_bn254_fuzz_test.step);
    fuzz_all_step.dependOn(&run_ecmul_fuzz_test.step);
    fuzz_all_step.dependOn(&run_ecpairing_fuzz_test.step);
    fuzz_all_step.dependOn(&run_bn254_comparison_fuzz_test.step);

    // Add Constructor Bug test
    const constructor_bug_test = b.addTest(.{
        .name = "constructor-bug-test",
        .root_source_file = b.path("test/evm/constructor_bug_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    constructor_bug_test.root_module.addImport("primitives", primitives_mod);
    constructor_bug_test.root_module.addImport("evm", evm_mod);
    const run_constructor_bug_test = b.addRunArtifact(constructor_bug_test);
    const constructor_bug_test_step = b.step("test-constructor-bug", "Run Constructor Bug test");
    constructor_bug_test_step.dependOn(&run_constructor_bug_test.step);

    // Add Solidity Constructor test
    const solidity_constructor_test = b.addTest(.{
        .name = "solidity-constructor-test",
        .root_source_file = b.path("test/evm/solidity_constructor_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    solidity_constructor_test.root_module.addImport("primitives", primitives_mod);
    solidity_constructor_test.root_module.addImport("evm", evm_mod);
    const run_solidity_constructor_test = b.addRunArtifact(solidity_constructor_test);
    const solidity_constructor_test_step = b.step("test-solidity-constructor", "Run Solidity Constructor test");
    solidity_constructor_test_step.dependOn(&run_solidity_constructor_test.step);

    // Add RETURN opcode bug test
    const return_opcode_bug_test = b.addTest(.{
        .name = "return-opcode-bug-test",
        .root_source_file = b.path("test/evm/return_opcode_bug_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    return_opcode_bug_test.root_module.addImport("primitives", primitives_mod);
    return_opcode_bug_test.root_module.addImport("evm", evm_mod);
    const run_return_opcode_bug_test = b.addRunArtifact(return_opcode_bug_test);
    const return_opcode_bug_test_step = b.step("test-return-opcode-bug", "Run RETURN opcode bug test");
    return_opcode_bug_test_step.dependOn(&run_return_opcode_bug_test.step);

    const contract_call_test = b.addTest(.{
        .name = "contract-call-test",
        .root_source_file = b.path("test/evm/contract_call_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    contract_call_test.root_module.addImport("primitives", primitives_mod);
    contract_call_test.root_module.addImport("evm", evm_mod);
    const run_contract_call_test = b.addRunArtifact(contract_call_test);
    const contract_call_test_step = b.step("test-contract-call", "Run Contract Call tests");
    contract_call_test_step.dependOn(&run_contract_call_test.step);

    // Hardfork tests removed - provider implementation is broken

    // Add DELEGATECALL test
    const delegatecall_test = b.addTest(.{
        .name = "delegatecall-test",
        .root_source_file = b.path("test/evm/opcodes/delegatecall_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    delegatecall_test.root_module.addImport("primitives", primitives_mod);
    delegatecall_test.root_module.addImport("evm", evm_mod);
    const run_delegatecall_test = b.addRunArtifact(delegatecall_test);
    const delegatecall_test_step = b.step("test-delegatecall", "Run DELEGATECALL tests");
    delegatecall_test_step.dependOn(&run_delegatecall_test.step);

    // Add BN254 individual test targets
    const bn254_fp_test = b.addTest(.{
        .name = "bn254-fp-test",
        .root_source_file = b.path("src/crypto/bn254/FpMont.zig"),
        .target = target,
        .optimize = optimize,
    });
    bn254_fp_test.root_module.addImport("primitives", primitives_mod);
    const run_bn254_fp_test = b.addRunArtifact(bn254_fp_test);
    const bn254_fp_test_step = b.step("test-bn254-fp", "Run BN254 Fp tests");
    bn254_fp_test_step.dependOn(&run_bn254_fp_test.step);

    const bn254_fr_test = b.addTest(.{
        .name = "bn254-fr-test",
        .root_source_file = b.path("src/crypto/bn254/Fr.zig"),
        .target = target,
        .optimize = optimize,
    });
    bn254_fr_test.root_module.addImport("primitives", primitives_mod);
    const run_bn254_fr_test = b.addRunArtifact(bn254_fr_test);
    const bn254_fr_test_step = b.step("test-bn254-fr", "Run BN254 Fr tests");
    bn254_fr_test_step.dependOn(&run_bn254_fr_test.step);

    const bn254_fp2_test = b.addTest(.{
        .name = "bn254-fp2-test",
        .root_source_file = b.path("src/crypto/bn254/Fp2Mont.zig"),
        .target = target,
        .optimize = optimize,
    });
    bn254_fp2_test.root_module.addImport("primitives", primitives_mod);
    const run_bn254_fp2_test = b.addRunArtifact(bn254_fp2_test);
    const bn254_fp2_test_step = b.step("test-bn254-fp2", "Run BN254 Fp2 tests");
    bn254_fp2_test_step.dependOn(&run_bn254_fp2_test.step);

    const bn254_fp6_test = b.addTest(.{
        .name = "bn254-fp6-test",
        .root_source_file = b.path("src/crypto/bn254/Fp6Mont.zig"),
        .target = target,
        .optimize = optimize,
    });
    bn254_fp6_test.root_module.addImport("primitives", primitives_mod);
    const run_bn254_fp6_test = b.addRunArtifact(bn254_fp6_test);
    const bn254_fp6_test_step = b.step("test-bn254-fp6", "Run BN254 Fp6 tests");
    bn254_fp6_test_step.dependOn(&run_bn254_fp6_test.step);

    const bn254_fp12_test = b.addTest(.{
        .name = "bn254-fp12-test",
        .root_source_file = b.path("src/crypto/bn254/Fp12Mont.zig"),
        .target = target,
        .optimize = optimize,
    });
    bn254_fp12_test.root_module.addImport("primitives", primitives_mod);
    const run_bn254_fp12_test = b.addRunArtifact(bn254_fp12_test);
    const bn254_fp12_test_step = b.step("test-bn254-fp12", "Run BN254 Fp12 tests");
    bn254_fp12_test_step.dependOn(&run_bn254_fp12_test.step);

    const bn254_g1_test = b.addTest(.{
        .name = "bn254-g1-test",
        .root_source_file = b.path("src/crypto/bn254/G1.zig"),
        .target = target,
        .optimize = optimize,
    });
    bn254_g1_test.root_module.addImport("primitives", primitives_mod);
    const run_bn254_g1_test = b.addRunArtifact(bn254_g1_test);
    const bn254_g1_test_step = b.step("test-bn254-g1", "Run BN254 G1 tests");
    bn254_g1_test_step.dependOn(&run_bn254_g1_test.step);

    const bn254_g2_test = b.addTest(.{
        .name = "bn254-g2-test",
        .root_source_file = b.path("src/crypto/bn254/G2.zig"),
        .target = target,
        .optimize = optimize,
    });
    bn254_g2_test.root_module.addImport("primitives", primitives_mod);
    const run_bn254_g2_test = b.addRunArtifact(bn254_g2_test);
    const bn254_g2_test_step = b.step("test-bn254-g2", "Run BN254 G2 tests");
    bn254_g2_test_step.dependOn(&run_bn254_g2_test.step);

    const bn254_pairing_test = b.addTest(.{
        .name = "bn254-pairing-test",
        .root_source_file = b.path("src/crypto/bn254/pairing.zig"),
        .target = target,
        .optimize = optimize,
    });
    bn254_pairing_test.root_module.addImport("primitives", primitives_mod);
    const run_bn254_pairing_test = b.addRunArtifact(bn254_pairing_test);
    const bn254_pairing_test_step = b.step("test-bn254-pairing", "Run BN254 pairing tests");
    bn254_pairing_test_step.dependOn(&run_bn254_pairing_test.step);

    // Add combined E2E test step
    const e2e_all_test_step = b.step("test-e2e", "Run all E2E tests");
    e2e_all_test_step.dependOn(&run_e2e_simple_test.step);
    e2e_all_test_step.dependOn(&run_e2e_error_test.step);
    e2e_all_test_step.dependOn(&run_e2e_data_test.step);
    e2e_all_test_step.dependOn(&run_e2e_inheritance_test.step);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_memory_test.step);
    test_step.dependOn(&run_stack_test.step);
    test_step.dependOn(&run_newevm_test.step);
    test_step.dependOn(&run_stack_validation_test.step);
    test_step.dependOn(&run_jump_table_test.step);
    test_step.dependOn(&run_config_test.step);
    test_step.dependOn(&run_differential_test.step);
    test_step.dependOn(&run_staticcall_test.step);
    // benchmark runner test removed - file no longer exists

    // Add inline ops test
    const inline_ops_test = b.addTest(.{
        .name = "inline-ops-test",
        .root_source_file = b.path("test/evm/inline_ops_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    inline_ops_test.root_module.stack_check = false;
    inline_ops_test.root_module.addImport("primitives", primitives_mod);
    inline_ops_test.root_module.addImport("evm", evm_mod);
    const run_inline_ops_test = b.addRunArtifact(inline_ops_test);

    // Instruction tests moved to test/evm/instruction_test.zig to avoid circular dependencies
    // The tests are included via the regular test/evm test suite

    const inline_ops_test_step = b.step("test-inline-ops", "Run inline ops performance tests");
    inline_ops_test_step.dependOn(&run_inline_ops_test.step);

    // Block metadata heap test removed - file no longer exists

    // Code analysis optimized test removed - file no longer exists

    test_step.dependOn(&run_blake2f_test.step);
    if (run_bn254_rust_test) |bn254_test| {
        test_step.dependOn(&bn254_test.step);
    }

    // Add SHA256 and RIPEMD160 tests if precompiles are enabled
    if (run_sha256_test) |sha256_test| {
        test_step.dependOn(&sha256_test.step);
    }
    if (run_ripemd160_test) |ripemd160_test| {
        test_step.dependOn(&ripemd160_test.step);
    }

    // Add REVM wrapper tests if available
    if (revm_lib != null) {
        const revm_test = b.addTest(.{
            .name = "revm-test",
            .root_source_file = b.path("src/revm_wrapper/test_revm_wrapper.zig"),
            .target = target,
            .optimize = optimize,
        });
        revm_test.root_module.addImport("primitives", primitives_mod);
        revm_test.linkLibrary(revm_lib.?);
        revm_test.addIncludePath(b.path("src/revm_wrapper"));
        revm_test.linkLibC();

        // Link the compiled Rust dynamic library
        const revm_rust_target_dir = if (optimize == .Debug) "debug" else "release";
        const revm_dylib_path = if (rust_target) |target_triple|
            b.fmt("target/{s}/{s}/librevm_wrapper.dylib", .{ target_triple, revm_rust_target_dir })
        else
            b.fmt("target/{s}/librevm_wrapper.dylib", .{revm_rust_target_dir});
        revm_test.addObjectFile(b.path(revm_dylib_path));

        // Link additional libraries needed by revm
        if (target.result.os.tag == .linux) {
            revm_test.linkSystemLibrary("m");
            revm_test.linkSystemLibrary("pthread");
            revm_test.linkSystemLibrary("dl");
        } else if (target.result.os.tag == .macos) {
            revm_test.linkSystemLibrary("c++");
            revm_test.linkFramework("Security");
            revm_test.linkFramework("SystemConfiguration");
            revm_test.linkFramework("CoreFoundation");
        }

        // Make sure the test depends on the Rust library being built
        revm_test.step.dependOn(&revm_lib.?.step);

        const run_revm_test = b.addRunArtifact(revm_test);
        test_step.dependOn(&run_revm_test.step);

        // Also add a separate step for revm tests
        const revm_test_step = b.step("test-revm", "Run REVM wrapper tests");
        revm_test_step.dependOn(&run_revm_test.step);
    }

    test_step.dependOn(&run_return_opcode_bug_test.step);
    // Hardfork tests removed completely

    // Add all BN254 tests to main test step
    test_step.dependOn(&run_bn254_fp_test.step);
    test_step.dependOn(&run_bn254_fr_test.step);
    test_step.dependOn(&run_bn254_fp2_test.step);
    test_step.dependOn(&run_bn254_fp6_test.step);
    test_step.dependOn(&run_bn254_fp12_test.step);
    test_step.dependOn(&run_bn254_g1_test.step);
    test_step.dependOn(&run_bn254_g2_test.step);
    test_step.dependOn(&run_bn254_pairing_test.step);

    // Add comprehensive test packages to main test step

    // Add ERC20 deployment hang test
    const erc20_deployment_test = b.addTest(.{
        .name = "erc20-deployment-test",
        .root_source_file = b.path("test/evm/erc20_deployment_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    erc20_deployment_test.root_module.addImport("evm", evm_mod);
    erc20_deployment_test.root_module.addImport("primitives", primitives_mod);
    const run_erc20_deployment_test = b.addRunArtifact(erc20_deployment_test);
    test_step.dependOn(&run_erc20_deployment_test.step);

    // Add benchmark tests to main test step
    test_step.dependOn(&run_thousand_hashes_test.step);
    test_step.dependOn(&run_snailtracer_test.step);
    test_step.dependOn(&run_erc20_bench_test.step);

    // Add orchestrator tests
    const orchestrator_test = b.addTest(.{
        .name = "orchestrator-test",
        .root_source_file = b.path("bench/official/src/Orchestrator.zig"),
        .target = target,
        .optimize = optimize,
    });
    orchestrator_test.root_module.addImport("clap", clap_dep.module("clap"));
    const run_orchestrator_test = b.addRunArtifact(orchestrator_test);
    test_step.dependOn(&run_orchestrator_test.step);

    // Add main orchestrator tests
    const orchestrator_main_test = b.addTest(.{
        .name = "orchestrator-main-test",
        .root_source_file = b.path("bench/official/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    orchestrator_main_test.root_module.addImport("clap", clap_dep.module("clap"));
    const run_orchestrator_main_test = b.addRunArtifact(orchestrator_main_test);
    test_step.dependOn(&run_orchestrator_main_test.step);

    // Add EVM runner tests
    const evm_runner_test = b.addTest(.{
        .name = "evm-runner-test",
        .root_source_file = b.path("bench/official/evms/zig/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    evm_runner_test.root_module.addImport("evm", evm_mod);
    evm_runner_test.root_module.addImport("primitives", primitives_mod);
    const run_evm_runner_test = b.addRunArtifact(evm_runner_test);
    test_step.dependOn(&run_evm_runner_test.step);

    // Add ERC20 mint debug test
    const erc20_mint_debug_test = b.addTest(.{
        .name = "erc20-mint-debug-test",
        .root_source_file = b.path("test/evm/erc20_mint_debug_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    erc20_mint_debug_test.root_module.addImport("primitives", primitives_mod);
    erc20_mint_debug_test.root_module.addImport("evm", evm_mod);
    erc20_mint_debug_test.root_module.addImport("Address", primitives_mod);
    const run_erc20_mint_debug_test = b.addRunArtifact(erc20_mint_debug_test);
    const erc20_mint_debug_test_step = b.step("test-erc20-debug", "Run ERC20 mint test with full debug logging");
    erc20_mint_debug_test_step.dependOn(&run_erc20_mint_debug_test.step);

    // Add constructor REVERT test
    const constructor_revert_test = b.addTest(.{
        .name = "constructor-revert-test",
        .root_source_file = b.path("test/evm/constructor_revert_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    // b.step("test-constructor-revert", "Run constructor REVERT test").dependOn(&constructor_revert_test.step);

    constructor_revert_test.root_module.addImport("primitives", primitives_mod);
    constructor_revert_test.root_module.addImport("evm", evm_mod);
    constructor_revert_test.root_module.addImport("Address", primitives_mod);
    const run_constructor_revert_test = b.addRunArtifact(constructor_revert_test);
    const constructor_revert_test_step = b.step("test-constructor-revert", "Run constructor REVERT test");
    constructor_revert_test_step.dependOn(&run_constructor_revert_test.step);
    test_step.dependOn(&run_constructor_revert_test.step);

    // Add ERC20 constructor debug test
    const erc20_constructor_debug_test = b.addTest(.{
        .name = "erc20-constructor-debug-test",
        .root_source_file = b.path("test/evm/erc20_constructor_debug_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    erc20_constructor_debug_test.root_module.addImport("primitives", primitives_mod);
    erc20_constructor_debug_test.root_module.addImport("evm", evm_mod);
    erc20_constructor_debug_test.root_module.addImport("Address", primitives_mod);
    const run_erc20_constructor_debug_test = b.addRunArtifact(erc20_constructor_debug_test);
    const erc20_constructor_debug_test_step = b.step("test-erc20-constructor", "Run ERC20 constructor debug test");
    erc20_constructor_debug_test_step.dependOn(&run_erc20_constructor_debug_test.step);

    // Add trace ERC20 constructor test
    const trace_erc20_test = b.addTest(.{
        .name = "trace-erc20-test",
        .root_source_file = b.path("test/evm/trace_erc20_constructor_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    trace_erc20_test.root_module.addImport("primitives", primitives_mod);
    trace_erc20_test.root_module.addImport("evm", evm_mod);
    trace_erc20_test.root_module.addImport("Address", primitives_mod);
    const run_trace_erc20_test = b.addRunArtifact(trace_erc20_test);
    const trace_erc20_test_step = b.step("test-trace-erc20", "Trace ERC20 constructor execution");
    trace_erc20_test_step.dependOn(&run_trace_erc20_test.step);

    // Add string storage test
    const string_storage_test = b.addTest(.{
        .name = "string-storage-test",
        .root_source_file = b.path("test/evm/string_storage_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    string_storage_test.root_module.addImport("evm", evm_mod);
    string_storage_test.root_module.addImport("Address", primitives_mod);

    const run_string_storage_test = b.addRunArtifact(string_storage_test);
    const string_storage_test_step = b.step("test-string-storage", "Run string storage tests");
    string_storage_test_step.dependOn(&run_string_storage_test.step);

    // Add JUMPI bug test
    const jumpi_bug_test = b.addTest(.{
        .name = "jumpi-bug-test",
        .root_source_file = b.path("test/evm/jumpi_bug_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    jumpi_bug_test.root_module.addImport("evm", evm_mod);
    jumpi_bug_test.root_module.addImport("Address", primitives_mod);

    const run_jumpi_bug_test = b.addRunArtifact(jumpi_bug_test);
    test_step.dependOn(&run_jumpi_bug_test.step);

    // Add EIP-2929 warm/cold access test
    const jumpi_bug_test_step = b.step("test-jumpi", "Run JUMPI bug test");
    jumpi_bug_test_step.dependOn(&run_jumpi_bug_test.step);

    // Add block execution ERC20 test
    const block_execution_erc20_test = b.addTest(.{
        .name = "block-execution-erc20-test",
        .root_source_file = b.path("test/evm/block_execution_erc20_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    block_execution_erc20_test.root_module.addImport("evm", evm_mod);
    block_execution_erc20_test.root_module.addImport("primitives", primitives_mod);

    const run_block_execution_erc20_test = b.addRunArtifact(block_execution_erc20_test);
    const block_execution_erc20_test_step = b.step("test-block-execution-erc20", "Run block execution ERC20 test");
    block_execution_erc20_test_step.dependOn(&run_block_execution_erc20_test.step);

    // Add simple block execution test
    const block_execution_simple_test = b.addTest(.{
        .name = "block-execution-simple-test",
        .root_source_file = b.path("test/evm/block_execution_simple.zig"),
        .target = target,
        .optimize = optimize,
    });
    block_execution_simple_test.root_module.addImport("evm", evm_mod);
    block_execution_simple_test.root_module.addImport("primitives", primitives_mod);

    const run_block_execution_simple_test = b.addRunArtifact(block_execution_simple_test);
    test_step.dependOn(&run_block_execution_simple_test.step);
    const block_execution_simple_test_step = b.step("test-block-execution-simple", "Run simple block execution test");
    block_execution_simple_test_step.dependOn(&run_block_execution_simple_test.step);

    // TRACER REMOVED: Commenting out tracer tests until tracer is reimplemented
    // See: https://github.com/evmts/guillotine/issues/325
    // const tracer_test = b.addTest(.{
    //     .name = "tracer-test",
    //     .root_source_file = b.path("test/evm/tracer_test.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // tracer_test.root_module.addImport("evm", evm_mod);
    // tracer_test.root_module.addImport("Address", primitives_mod);
    //
    // const run_tracer_test = b.addRunArtifact(tracer_test);
    // test_step.dependOn(&run_tracer_test.step);
    // const tracer_test_step = b.step("test-tracer", "Run tracer test");
    // tracer_test_step.dependOn(&run_tracer_test.step);

    // Add compare execution test
    // TODO: Re-enable when tracer is reimplemented
    // const compare_test = b.addTest(.{
    //     .name = "compare-test",
    //     .root_source_file = b.path("test/evm/compare_execution.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // compare_test.root_module.addImport("evm", evm_mod);
    // compare_test.root_module.addImport("primitives", primitives_mod);

    // const run_compare_test = b.addRunArtifact(compare_test);
    // test_step.dependOn(&run_compare_test.step);
    // const compare_test_step = b.step("test-compare", "Run execution comparison test");
    // compare_test_step.dependOn(&run_compare_test.step);

    // Add comprehensive opcode comparison executable
    const comprehensive_compare = b.addExecutable(.{
        .name = "comprehensive-opcode-comparison",
        .root_source_file = b.path("test/evm/comprehensive_opcode_comparison.zig"),
        .target = target,
        .optimize = optimize,
    });
    comprehensive_compare.root_module.addImport("evm", evm_mod);
    comprehensive_compare.root_module.addImport("primitives", primitives_mod);
    comprehensive_compare.root_module.addImport("Address", primitives_mod);
    comprehensive_compare.root_module.addImport("revm", revm_mod);

    // Link REVM wrapper library if available
    if (revm_lib) |revm_library| {
        comprehensive_compare.linkLibrary(revm_library);
        comprehensive_compare.addIncludePath(b.path("src/revm_wrapper"));
        comprehensive_compare.linkLibC();

        // Link the compiled Rust dynamic library
        const revm_rust_target_dir = if (optimize == .Debug) "debug" else "release";
        const revm_dylib_path = if (rust_target) |target_triple|
            b.fmt("target/{s}/{s}/librevm_wrapper.dylib", .{ target_triple, revm_rust_target_dir })
        else
            b.fmt("target/{s}/librevm_wrapper.dylib", .{revm_rust_target_dir});
        comprehensive_compare.addObjectFile(b.path(revm_dylib_path));

        // Link additional libraries needed by revm
        if (target.result.os.tag == .linux) {
            comprehensive_compare.linkSystemLibrary("m");
            comprehensive_compare.linkSystemLibrary("pthread");
            comprehensive_compare.linkSystemLibrary("dl");
        } else if (target.result.os.tag == .macos) {
            comprehensive_compare.linkSystemLibrary("c++");
            comprehensive_compare.linkFramework("Security");
            comprehensive_compare.linkFramework("CoreFoundation");
        }
    }

    // Link BN254 library if available (required by REVM)
    if (bn254_lib) |bn254_library| {
        comprehensive_compare.linkLibrary(bn254_library);
        comprehensive_compare.addIncludePath(b.path("src/bn254_wrapper"));
    }

    const run_comprehensive_compare = b.addRunArtifact(comprehensive_compare);
    const comprehensive_compare_step = b.step("run-comprehensive-compare", "Run comprehensive opcode comparison");
    comprehensive_compare_step.dependOn(&run_comprehensive_compare.step);

    // Add ERC20 trace test
    const erc20_trace_test = b.addTest(.{
        .name = "erc20-trace-test",
        .root_source_file = b.path("test/evm/trace_erc20_constructor.zig"),
        .target = target,
        .optimize = optimize,
    });
    erc20_trace_test.root_module.addImport("evm", evm_mod);
    erc20_trace_test.root_module.addImport("primitives", primitives_mod);

    const run_erc20_trace_test = b.addRunArtifact(erc20_trace_test);
    const erc20_trace_test_step = b.step("test-erc20-trace", "Run ERC20 constructor trace test");
    erc20_trace_test_step.dependOn(&run_erc20_trace_test.step);

    // TODO: Re-enable when Rust integration is fixed
    // test_step.dependOn(&run_compiler_test.step);
    // test_step.dependOn(&run_snail_tracer_test.step);

    // Add Fuzz Testing using test configuration data
    // Removed duplicate - fuzz step already defined above

    // Create fuzz tests from configuration
    for (tests.fuzz_tests) |test_info| {
        const fuzz_test = b.addTest(.{
            .name = test_info.name,
            .root_source_file = b.path(test_info.source_file),
            .target = target,
            .optimize = optimize,
        });
        fuzz_test.root_module.addImport("evm", evm_mod);

        // Some fuzz tests also need primitives
        if (std.mem.indexOf(u8, test_info.name, "arithmetic") != null or
            std.mem.indexOf(u8, test_info.name, "bitwise") != null or
            std.mem.indexOf(u8, test_info.name, "comparison") != null or
            std.mem.indexOf(u8, test_info.name, "control") != null or
            std.mem.indexOf(u8, test_info.name, "crypto") != null or
            std.mem.indexOf(u8, test_info.name, "environment") != null or
            std.mem.indexOf(u8, test_info.name, "storage") != null or
            std.mem.indexOf(u8, test_info.name, "state") != null)
        {
            fuzz_test.root_module.addImport("primitives", primitives_mod);
        }

        const run_fuzz_test = b.addRunArtifact(fuzz_test);
        if (b.args) |args| {
            run_fuzz_test.addArgs(args);
        }
        fuzz_all_step.dependOn(&run_fuzz_test.step);

        // Create individual test step if specified
        if (test_info.step_name) |step_name| {
            const individual_step = b.step(
                step_name,
                test_info.step_desc orelse "Run test",
            );
            individual_step.dependOn(&run_fuzz_test.step);
        }
    }

    // Documentation generation step
    const docs_step = b.step("docs", "Generate and install documentation");
    const docs_install = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&docs_install.step);

    // Python bindings build step
    const python_build_cmd = b.addSystemCommand(&[_][]const u8{ "python3", "build.py" });
    python_build_cmd.setCwd(b.path("src/guillotine-py"));
    python_build_cmd.step.dependOn(b.getInstallStep()); // Ensure native library is built first

    const python_build_step = b.step("python", "Build Python bindings");
    python_build_step.dependOn(&python_build_cmd.step);

    // Python development install step
    const python_dev_cmd = b.addSystemCommand(&[_][]const u8{ "python3", "build.py", "--dev" });
    python_dev_cmd.setCwd(b.path("src/guillotine-py"));
    python_dev_cmd.step.dependOn(b.getInstallStep());

    const python_dev_step = b.step("python-dev", "Build and install Python bindings in development mode");
    python_dev_step.dependOn(&python_dev_cmd.step);

    // Python tests step
    const python_test_cmd = b.addSystemCommand(&[_][]const u8{ "python3", "-m", "pytest", "tests/", "-v" });
    python_test_cmd.setCwd(b.path("src/guillotine-py"));
    python_test_cmd.step.dependOn(&python_build_cmd.step);

    const python_test_step = b.step("python-test", "Run Python binding tests");
    python_test_step.dependOn(&python_test_cmd.step);

    // Python examples step
    const python_examples_cmd = b.addSystemCommand(&[_][]const u8{ "python3", "examples.py" });
    python_examples_cmd.setCwd(b.path("src/guillotine-py"));
    python_examples_cmd.step.dependOn(&python_build_cmd.step);

    const python_examples_step = b.step("python-examples", "Run Python binding examples");
    python_examples_step.dependOn(&python_examples_cmd.step);

    // Swift build commands
    addSwiftSteps(b);

    // Go build commands
    addGoSteps(b);

    // TypeScript build commands
    addTypeScriptSteps(b);
}

fn addSwiftSteps(b: *std.Build) void {
    // Swift build step
    const swift_build_cmd = b.addSystemCommand(&[_][]const u8{ "swift", "build" });
    swift_build_cmd.setCwd(b.path("src/guillotine-swift"));
    swift_build_cmd.step.dependOn(b.getInstallStep()); // Ensure native library is built first

    const swift_build_step = b.step("swift", "Build Swift bindings");
    swift_build_step.dependOn(&swift_build_cmd.step);

    // Swift test step
    const swift_test_cmd = b.addSystemCommand(&[_][]const u8{ "swift", "test" });
    swift_test_cmd.setCwd(b.path("src/guillotine-swift"));
    swift_test_cmd.step.dependOn(&swift_build_cmd.step);

    const swift_test_step = b.step("swift-test", "Run Swift binding tests");
    swift_test_step.dependOn(&swift_test_cmd.step);

    // Swift package validation step
    const swift_validate_cmd = b.addSystemCommand(&[_][]const u8{ "swift", "package", "validate" });
    swift_validate_cmd.setCwd(b.path("src/guillotine-swift"));

    const swift_validate_step = b.step("swift-validate", "Validate Swift package");
    swift_validate_step.dependOn(&swift_validate_cmd.step);
}

fn addGoSteps(b: *std.Build) void {
    // Go mod tidy step to download dependencies
    const go_mod_tidy_cmd = b.addSystemCommand(&[_][]const u8{ "go", "mod", "tidy" });
    go_mod_tidy_cmd.setCwd(b.path("src/guillotine-go"));
    go_mod_tidy_cmd.step.dependOn(b.getInstallStep()); // Ensure native library is built first

    // Go build step
    const go_build_cmd = b.addSystemCommand(&[_][]const u8{ "go", "build", "./..." });
    go_build_cmd.setCwd(b.path("src/guillotine-go"));
    go_build_cmd.step.dependOn(&go_mod_tidy_cmd.step);

    const go_build_step = b.step("go", "Build Go bindings");
    go_build_step.dependOn(&go_build_cmd.step);

    // Go test step
    const go_test_cmd = b.addSystemCommand(&[_][]const u8{ "go", "test", "./..." });
    go_test_cmd.setCwd(b.path("src/guillotine-go"));
    go_test_cmd.step.dependOn(&go_build_cmd.step);

    const go_test_step = b.step("go-test", "Run Go binding tests");
    go_test_step.dependOn(&go_test_cmd.step);

    // Go vet step for code analysis
    const go_vet_cmd = b.addSystemCommand(&[_][]const u8{ "go", "vet", "./..." });
    go_vet_cmd.setCwd(b.path("src/guillotine-go"));
    go_vet_cmd.step.dependOn(&go_build_cmd.step);

    const go_vet_step = b.step("go-vet", "Run Go code analysis");
    go_vet_step.dependOn(&go_vet_cmd.step);

    // Go format check step
    const go_fmt_check_cmd = b.addSystemCommand(&[_][]const u8{ "sh", "-c", "test -z \"$(gofmt -l .)\" || (echo 'Code is not formatted. Run: go fmt ./...' && exit 1)" });
    go_fmt_check_cmd.setCwd(b.path("src/guillotine-go"));

    const go_fmt_check_step = b.step("go-fmt-check", "Check Go code formatting");
    go_fmt_check_step.dependOn(&go_fmt_check_cmd.step);

    // Go format step
    const go_fmt_cmd = b.addSystemCommand(&[_][]const u8{ "go", "fmt", "./..." });
    go_fmt_cmd.setCwd(b.path("src/guillotine-go"));

    const go_fmt_step = b.step("go-fmt", "Format Go code");
    go_fmt_step.dependOn(&go_fmt_cmd.step);
}

fn addTypeScriptSteps(b: *std.Build) void {
    // TypeScript install dependencies step
    const ts_install_cmd = b.addSystemCommand(&[_][]const u8{ "npm", "install" });
    ts_install_cmd.setCwd(b.path("src/guillotine-ts"));
    ts_install_cmd.step.dependOn(b.getInstallStep()); // Ensure native library is built first

    // Copy WASM files step
    const ts_copy_wasm_cmd = b.addSystemCommand(&[_][]const u8{ "npm", "run", "copy-wasm" });
    ts_copy_wasm_cmd.setCwd(b.path("src/guillotine-ts"));
    ts_copy_wasm_cmd.step.dependOn(&ts_install_cmd.step);

    // TypeScript build step
    const ts_build_cmd = b.addSystemCommand(&[_][]const u8{ "npm", "run", "build" });
    ts_build_cmd.setCwd(b.path("src/guillotine-ts"));
    ts_build_cmd.step.dependOn(&ts_copy_wasm_cmd.step);

    const ts_build_step = b.step("ts", "Build TypeScript bindings");
    ts_build_step.dependOn(&ts_build_cmd.step);

    // TypeScript test step
    const ts_test_cmd = b.addSystemCommand(&[_][]const u8{ "npm", "test" });
    ts_test_cmd.setCwd(b.path("src/guillotine-ts"));
    ts_test_cmd.step.dependOn(&ts_build_cmd.step);

    const ts_test_step = b.step("ts-test", "Run TypeScript binding tests");
    ts_test_step.dependOn(&ts_test_cmd.step);

    // TypeScript lint step
    const ts_lint_cmd = b.addSystemCommand(&[_][]const u8{ "npm", "run", "lint" });
    ts_lint_cmd.setCwd(b.path("src/guillotine-ts"));
    ts_lint_cmd.step.dependOn(&ts_install_cmd.step);

    const ts_lint_step = b.step("ts-lint", "Run TypeScript linting");
    ts_lint_step.dependOn(&ts_lint_cmd.step);

    // TypeScript format check step
    const ts_format_check_cmd = b.addSystemCommand(&[_][]const u8{ "npm", "run", "format:check" });
    ts_format_check_cmd.setCwd(b.path("src/guillotine-ts"));
    ts_format_check_cmd.step.dependOn(&ts_install_cmd.step);

    const ts_format_check_step = b.step("ts-format-check", "Check TypeScript code formatting");
    ts_format_check_step.dependOn(&ts_format_check_cmd.step);

    // TypeScript format step
    const ts_format_cmd = b.addSystemCommand(&[_][]const u8{ "npm", "run", "format" });
    ts_format_cmd.setCwd(b.path("src/guillotine-ts"));
    ts_format_cmd.step.dependOn(&ts_install_cmd.step);

    const ts_format_step = b.step("ts-format", "Format TypeScript code");
    ts_format_step.dependOn(&ts_format_cmd.step);

    // TypeScript type check step
    const ts_typecheck_cmd = b.addSystemCommand(&[_][]const u8{ "npm", "run", "typecheck" });
    ts_typecheck_cmd.setCwd(b.path("src/guillotine-ts"));
    ts_typecheck_cmd.step.dependOn(&ts_install_cmd.step);

    const ts_typecheck_step = b.step("ts-typecheck", "Run TypeScript type checking");
    ts_typecheck_step.dependOn(&ts_typecheck_cmd.step);

    // TypeScript development step (watch mode)
    const ts_dev_cmd = b.addSystemCommand(&[_][]const u8{ "npm", "run", "dev" });
    ts_dev_cmd.setCwd(b.path("src/guillotine-ts"));
    ts_dev_cmd.step.dependOn(&ts_install_cmd.step);

    const ts_dev_step = b.step("ts-dev", "Run TypeScript in development/watch mode");
    ts_dev_step.dependOn(&ts_dev_cmd.step);

    // TypeScript clean step
    const ts_clean_cmd = b.addSystemCommand(&[_][]const u8{ "npm", "run", "clean" });
    ts_clean_cmd.setCwd(b.path("src/guillotine-ts"));

    const ts_clean_step = b.step("ts-clean", "Clean TypeScript build artifacts");
    ts_clean_step.dependOn(&ts_clean_cmd.step);
}
