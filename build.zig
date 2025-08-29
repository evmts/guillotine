const std = @import("std");
const asset_generator = @import("build_utils/asset_generator.zig");
const rust_build = @import("build_utils/rust_build.zig");
const tests = @import("build_utils/tests.zig");
const wasm = @import("build_utils/wasm.zig");
const devtool = @import("build_utils/devtool.zig");
const typescript = @import("build_utils/typescript.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const no_precompiles = b.option(bool, "no_precompiles", "Disable all EVM precompiles for minimal build") orelse false;

    const force_bn254 = b.option(bool, "force_bn254", "Force BN254 even on Ubuntu") orelse false;
    const is_ubuntu_native = target.result.os.tag == .linux and target.result.cpu.arch == .x86_64 and !force_bn254;

    const no_bn254 = no_precompiles or is_ubuntu_native;

    const build_options = b.addOptions();
    build_options.addOption(bool, "no_precompiles", no_precompiles);
    build_options.addOption(bool, "no_bn254", no_bn254);
    const enable_tracing = b.option(bool, "enable-tracing", "Enable EVM instruction tracing (compile-time)") orelse false;
    build_options.addOption(bool, "enable_tracing", enable_tracing);
    const disable_tailcall_dispatch = b.option(bool, "disable-tailcall-dispatch", "Disable tailcall-based interpreter dispatch (use switch instead)") orelse true;
    build_options.addOption(bool, "disable_tailcall_dispatch", disable_tailcall_dispatch);
    const build_options_mod = build_options.createModule();

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addIncludePath(b.path("src/bn254_wrapper"));
    lib_mod.addImport("build_options", build_options_mod);

    const zbench_dep = b.dependency("zbench", .{
        .target = target,
        .optimize = optimize,
    });

    // Build blst assembly first
    const blst_build_cmd = b.addSystemCommand(&.{
        "sh", "-c", "cd lib/c-kzg-4844/blst && ./build.sh",
    });
    
    // Build blst library
    const blst_lib = b.addLibrary(.{
        .name = "blst",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    blst_lib.linkLibC();
    blst_lib.step.dependOn(&blst_build_cmd.step);
    
    // Add blst source files
    blst_lib.addCSourceFiles(.{
        .files = &.{
            "lib/c-kzg-4844/blst/src/server.c",
        },
        .flags = &.{"-std=c99", "-D__BLST_PORTABLE__", "-fno-sanitize=undefined"},
    });
    blst_lib.addAssemblyFile(b.path("lib/c-kzg-4844/blst/build/assembly.S"));
    blst_lib.addIncludePath(b.path("lib/c-kzg-4844/blst/bindings"));
    
    // Build c-kzg-4844 from source
    const c_kzg_lib = b.addLibrary(.{
        .name = "c-kzg-4844",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    c_kzg_lib.linkLibC();
    c_kzg_lib.linkLibrary(blst_lib);
    c_kzg_lib.addCSourceFiles(.{
        .files = &.{
            "lib/c-kzg-4844/src/ckzg.c",
        },
        .flags = &.{"-std=c99", "-fno-sanitize=undefined"},
    });
    c_kzg_lib.addIncludePath(b.path("lib/c-kzg-4844/src"));
    c_kzg_lib.addIncludePath(b.path("lib/c-kzg-4844/blst/bindings"));
    
    const c_kzg_mod = b.createModule(.{
        .root_source_file = b.path("lib/c-kzg-4844/bindings/zig/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    c_kzg_mod.linkLibrary(c_kzg_lib);
    c_kzg_mod.linkLibrary(blst_lib);
    c_kzg_mod.addIncludePath(b.path("lib/c-kzg-4844/src"));
    c_kzg_mod.addIncludePath(b.path("lib/c-kzg-4844/blst/bindings"));

    const primitives_mod = b.createModule(.{
        .root_source_file = b.path("src/primitives/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const crypto_mod = b.createModule(.{
        .root_source_file = b.path("src/crypto/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    crypto_mod.addImport("primitives", primitives_mod);
    crypto_mod.addImport("c_kzg", c_kzg_mod);

    const utils_mod = b.createModule(.{
        .root_source_file = b.path("src/utils.zig"),
        .target = target,
        .optimize = optimize,
    });

    const trie_mod = b.createModule(.{
        .root_source_file = b.path("src/trie/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    trie_mod.addImport("primitives", primitives_mod);
    trie_mod.addImport("utils", utils_mod);

    const provider_mod = b.createModule(.{
        .root_source_file = b.path("src/provider/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    provider_mod.addImport("primitives", primitives_mod);

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

    const bn254_lib = if (!no_bn254 and rust_target != null) blk: {
        const lib = b.addLibrary(.{
            .name = "bn254_wrapper",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
            }),
        });

        const profile_dir = if (optimize == .Debug) "debug" else "release";
        const lib_path = if (rust_target) |target_triple|
            b.fmt("target/{s}/{s}/libbn254_wrapper.a", .{ target_triple, profile_dir })
        else
            b.fmt("target/{s}/libbn254_wrapper.a", .{profile_dir});

        lib.addObjectFile(b.path(lib_path));
        lib.linkLibC();
        lib.addIncludePath(b.path("src/bn254_wrapper"));

        if (workspace_build_step) |build_step| {
            lib.step.dependOn(&build_step.step);
        }

        break :blk lib;
    } else null;

    const evm_mod = b.createModule(.{
        .root_source_file = b.path("src/evm/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    evm_mod.addImport("primitives", primitives_mod);
    evm_mod.addImport("crypto", crypto_mod);
    evm_mod.addImport("build_options", build_options_mod);
    evm_mod.addImport("zbench", zbench_dep.module("zbench"));
    evm_mod.addIncludePath(b.path("src/revm_wrapper"));

    if (bn254_lib) |bn254| {
        evm_mod.linkLibrary(bn254);
        evm_mod.addIncludePath(b.path("src/bn254_wrapper"));
    }

    const revm_lib = if (rust_target != null) blk: {
        const lib = b.addLibrary(.{
            .name = "revm_wrapper",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
            }),
        });

        const profile_dir = if (optimize == .Debug) "debug" else "release";
        const lib_path = if (rust_target) |target_triple|
            b.fmt("target/{s}/{s}/librevm_wrapper.a", .{ target_triple, profile_dir })
        else
            b.fmt("target/{s}/librevm_wrapper.a", .{profile_dir});

        lib.addObjectFile(b.path(lib_path));
        lib.linkLibC();
        lib.addIncludePath(b.path("src/revm_wrapper"));

        if (workspace_build_step) |build_step| {
            lib.step.dependOn(&build_step.step);
        }

        break :blk lib;
    } else null;

    const revm_mod = b.createModule(.{
        .root_source_file = b.path("src/revm_wrapper/revm.zig"),
        .target = target,
        .optimize = optimize,
    });
    revm_mod.addImport("primitives", primitives_mod);

    if (revm_lib) |revm| {
        revm_mod.linkLibrary(revm);
        revm_mod.addIncludePath(b.path("src/revm_wrapper"));
    }

    const compilers_mod = b.createModule(.{
        .root_source_file = b.path("src/compilers/package.zig"),
        .target = target,
        .optimize = optimize,
    });
    compilers_mod.addImport("primitives", primitives_mod);
    compilers_mod.addImport("evm", evm_mod);

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

    if (bn254_lib) |bn254| {
        lib.linkLibrary(bn254);
        lib.addIncludePath(b.path("src/bn254_wrapper"));
    }

    b.installArtifact(lib);

    const shared_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "Guillotine",
        .root_module = lib_mod,
    });

    if (bn254_lib) |bn254| {
        shared_lib.linkLibrary(bn254);
        shared_lib.addIncludePath(b.path("src/bn254_wrapper"));
    }

    b.installArtifact(shared_lib);

    const exe = b.addExecutable(.{
        .name = "Guillotine",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const wasm_target = wasm.setupWasmTarget(b);
    const wasm_optimize = optimize;

    const wasm_primitives_mod = wasm.createWasmModule(b, "src/primitives/root.zig", wasm_target, wasm_optimize);

    const wasm_crypto_mod = wasm.createWasmModule(b, "src/crypto/root.zig", wasm_target, wasm_optimize);
    wasm_crypto_mod.addImport("primitives", wasm_primitives_mod);

    const wasm_evm_mod = wasm.createWasmModule(b, "src/evm/root.zig", wasm_target, wasm_optimize);
    wasm_evm_mod.addImport("primitives", wasm_primitives_mod);
    wasm_evm_mod.addImport("crypto", wasm_crypto_mod);
    wasm_evm_mod.addImport("build_options", build_options_mod);

    const wasm_lib_mod = wasm.createWasmModule(b, "src/root.zig", wasm_target, wasm_optimize);
    wasm_lib_mod.addImport("primitives", wasm_primitives_mod);
    wasm_lib_mod.addImport("evm", wasm_evm_mod);

    const wasm_lib_build = wasm.buildWasmExecutable(b, .{
        .name = "guillotine",
        .root_source_file = "src/root.zig",
        .dest_sub_path = "guillotine.wasm",
    }, wasm_lib_mod);

    const wasm_primitives_lib_mod = wasm.createWasmModule(b, "src/primitives_c.zig", wasm_target, wasm_optimize);
    wasm_primitives_lib_mod.addImport("primitives", wasm_primitives_mod);

    const wasm_primitives_build = wasm.buildWasmExecutable(b, .{
        .name = "guillotine-primitives",
        .root_source_file = "src/primitives_c.zig",
        .dest_sub_path = "guillotine-primitives.wasm",
    }, wasm_primitives_lib_mod);

    const wasm_size_step = wasm.addWasmSizeReportStep(
        b,
        &[_][]const u8{ "guillotine.wasm", "guillotine-primitives.wasm" },
        &[_]*std.Build.Step{
            &wasm_lib_build.install.step,
            &wasm_primitives_build.install.step,
        },
    );

    const wasm_step = b.step("wasm", "Build all WASM libraries and show bundle sizes");
    wasm_step.dependOn(&wasm_size_step.step);

    const wasm_primitives_step = b.step("wasm-primitives", "Build primitives-only WASM library");
    wasm_primitives_step.dependOn(&wasm_primitives_build.install.step);

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

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const npm_check = b.addSystemCommand(&[_][]const u8{ "which", "npm" });
    npm_check.addCheck(.{ .expect_stdout_match = "npm" });

    const npm_install = b.addSystemCommand(&[_][]const u8{ "npm", "install" });
    npm_install.setCwd(b.path("src/devtool"));
    npm_install.step.dependOn(&npm_check.step);

    const npm_build = b.addSystemCommand(&[_][]const u8{ "npm", "run", "build" });
    npm_build.setCwd(b.path("src/devtool"));
    npm_build.step.dependOn(&npm_install.step);

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

        devtool_exe.addLibraryPath(b.path("zig-out"));
        devtool_exe.linkSystemLibrary("native_menu_swift");
        devtool_exe.step.dependOn(&swift_compile.step);

        devtool_exe.addLibraryPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx" });
        devtool_exe.addLibraryPath(.{ .cwd_relative = "/usr/lib/swift" });
    }

    devtool_exe.linkLibC();
    if (target.result.os.tag == .macos) {
        devtool_exe.linkFramework("WebKit");
        devtool_exe.linkFramework("AppKit");
        devtool_exe.linkFramework("Foundation");
    }

    devtool_exe.step.dependOn(&generate_assets.step);

    const run_devtool_cmd = b.addRunArtifact(devtool_exe);
    run_devtool_cmd.step.dependOn(b.getInstallStep());

    const devtool_step = b.step("devtool", "Build and run the Ethereum devtool");
    devtool_step.dependOn(&run_devtool_cmd.step);

    const build_devtool_step = b.step("build-devtool", "Build the Ethereum devtool (without running)");
    build_devtool_step.dependOn(b.getInstallStep());

    if (target.result.os.tag == .macos) {
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

    const have_crash_debug = blk: {
        std.fs.cwd().access("src/crash-debug.zig", .{}) catch break :blk false;
        break :blk true;
    };
    if (have_crash_debug) {
        const crash_debug_exe = b.addExecutable(.{
            .name = "crash-debug",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/crash-debug.zig"),
                .target = target,
            }),
        });
        crash_debug_exe.root_module.addImport("evm", evm_mod);
        crash_debug_exe.root_module.addImport("primitives", primitives_mod);
        b.installArtifact(crash_debug_exe);

        const run_crash_debug_cmd = b.addRunArtifact(crash_debug_exe);
        const crash_debug_step = b.step("crash-debug", "Run crash debugging tool");
        crash_debug_step.dependOn(&run_crash_debug_cmd.step);
    }

    const have_simple_crash = blk: {
        std.fs.cwd().access("src/simple-crash-test.zig", .{}) catch break :blk false;
        break :blk true;
    };
    if (have_simple_crash) {
        const simple_crash_test_exe = b.addExecutable(.{
            .name = "simple-crash-test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/simple-crash-test.zig"),
                .target = target,
                .optimize = .Debug,
            }),
        });
        simple_crash_test_exe.root_module.addImport("evm", evm_mod);
        simple_crash_test_exe.root_module.addImport("primitives", primitives_mod);
        b.installArtifact(simple_crash_test_exe);

        const run_simple_crash_test_cmd = b.addRunArtifact(simple_crash_test_exe);
        const simple_crash_test_step = b.step("simple-crash-test", "Run simple crash test");
        simple_crash_test_step.dependOn(&run_simple_crash_test_cmd.step);
    }

    const evm_runner_exe = b.addExecutable(.{
        .name = "evm-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/evms/zig/src/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    evm_runner_exe.root_module.addImport("evm", evm_mod);
    evm_runner_exe.root_module.addImport("primitives", primitives_mod);
    evm_runner_exe.linkLibrary(c_kzg_lib);
    evm_runner_exe.linkLibrary(blst_lib);
    evm_runner_exe.linkLibC();
    if (bn254_lib) |bn254| {
        evm_runner_exe.linkLibrary(bn254);
        evm_runner_exe.addIncludePath(b.path("src/bn254_wrapper"));
    }

    b.installArtifact(evm_runner_exe);

    const run_evm_runner_cmd = b.addRunArtifact(evm_runner_exe);
    if (b.args) |args| {
        run_evm_runner_cmd.addArgs(args);
    }

    const evm_runner_step = b.step("evm-runner", "Run the EVM benchmark runner");
    evm_runner_step.dependOn(&run_evm_runner_cmd.step);

    const build_evm_runner_step = b.step("build-evm-runner", "Build the EVM benchmark runner (ReleaseFast)");
    build_evm_runner_step.dependOn(&b.addInstallArtifact(evm_runner_exe, .{}).step);

    const evm_runner_small_exe = b.addExecutable(.{
        .name = "evm-runner-small",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/evms/zig/src/main.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
        }),
    });
    evm_runner_small_exe.root_module.addImport("evm", evm_mod);
    evm_runner_small_exe.root_module.addImport("primitives", primitives_mod);
    evm_runner_small_exe.linkLibrary(c_kzg_lib);
    evm_runner_small_exe.linkLibrary(blst_lib);
    evm_runner_small_exe.linkLibC();
    if (bn254_lib) |bn254| {
        evm_runner_small_exe.linkLibrary(bn254);
        evm_runner_small_exe.addIncludePath(b.path("src/bn254_wrapper"));
    }

    b.installArtifact(evm_runner_small_exe);

    const build_evm_runner_small_step = b.step("build-evm-runner-small", "Build the EVM benchmark runner (ReleaseSmall)");
    build_evm_runner_small_step.dependOn(&b.addInstallArtifact(evm_runner_small_exe, .{}).step);

    const debug_runner_exe = b.addExecutable(.{
        .name = "debug-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/evms/zig/src/debug.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    debug_runner_exe.root_module.addImport("evm", evm_mod);
    debug_runner_exe.root_module.addImport("primitives", primitives_mod);

    b.installArtifact(debug_runner_exe);

    const build_debug_runner_step = b.step("build-debug-runner", "Build the debug EVM runner");
    build_debug_runner_step.dependOn(&b.addInstallArtifact(debug_runner_exe, .{}).step);

    const poop_runner_exe = b.addExecutable(.{
        .name = "poop-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/poop_runner.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });

    b.installArtifact(poop_runner_exe);

    const run_poop_cmd = b.addRunArtifact(poop_runner_exe);
    run_poop_cmd.step.dependOn(build_evm_runner_step);
    if (b.args) |args| {
        run_poop_cmd.addArgs(args);
    }

    const poop_step = b.step("poop", "Run poop benchmark on snailtracer (Linux only)");
    poop_step.dependOn(&run_poop_cmd.step);

    const release_step = b.step("release", "Build release artifacts (evm-runner, evm-runner-small)");
    release_step.dependOn(build_evm_runner_step);
    release_step.dependOn(build_evm_runner_small_step);

    const geth_runner_build = b.addSystemCommand(&[_][]const u8{ "go", "build", "-o", "runner", "runner.go" });
    geth_runner_build.setCwd(b.path("bench/evms/geth"));

    const evmone_cmake_configure = b.addSystemCommand(&[_][]const u8{ "cmake", "-S", "bench/evms/evmone", "-B", "bench/evms/evmone/build", "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" });
    evmone_cmake_configure.setCwd(b.path(""));

    const evmone_cmake_build = b.addSystemCommand(&[_][]const u8{ "cmake", "--build", "bench/evms/evmone/build", "--parallel" });
    evmone_cmake_build.setCwd(b.path(""));
    evmone_cmake_build.step.dependOn(&evmone_cmake_configure.step);

    const opcode_test_lib = b.addLibrary(.{
        .name = "guillotine_opcode_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/evm_opcode_test_ffi.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    opcode_test_lib.root_module.addImport("evm", evm_mod);
    opcode_test_lib.root_module.addImport("primitives", primitives_mod);
    opcode_test_lib.root_module.addImport("crypto", crypto_mod);
    opcode_test_lib.root_module.addImport("build_options", build_options_mod);

    if (bn254_lib) |bn254| {
        opcode_test_lib.linkLibrary(bn254);
        opcode_test_lib.addIncludePath(b.path("src/bn254_wrapper"));
    }

    b.installArtifact(opcode_test_lib);

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const newevm_test = b.addTest(.{
        .name = "newevm-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/evm/newevm_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    newevm_test.root_module.addImport("evm", evm_mod);
    newevm_test.root_module.addImport("primitives", primitives_mod);

    const run_newevm_test = b.addRunArtifact(newevm_test);
    const newevm_test_step = b.step("test-newevm", "Run new EVM tests");
    newevm_test_step.dependOn(&run_newevm_test.step);

    const evm_core_test = b.addTest(.{
        .name = "evm-core-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/evm/evm.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    evm_core_test.root_module.addImport("evm", evm_mod);
    evm_core_test.root_module.addImport("primitives", primitives_mod);
    evm_core_test.root_module.addImport("crypto", crypto_mod);
    evm_core_test.root_module.addImport("build_options", build_options_mod);
    evm_core_test.addIncludePath(b.path("src/bn254_wrapper"));
    const run_evm_core_test = b.addRunArtifact(evm_core_test);
    const evm_core_test_step = b.step("test-evm-core", "Run evm.zig tests");
    evm_core_test_step.dependOn(&run_evm_core_test.step);

    const have_call_context = blk: {
        std.fs.cwd().access("src/evm/test_call_context.zig", .{}) catch break :blk false;
        break :blk true;
    };
    if (have_call_context) {
        const call_context_test = b.addTest(.{
            .name = "call-context-test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/evm/test_call_context.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        call_context_test.root_module.addImport("evm", evm_mod);
        call_context_test.root_module.addImport("primitives", primitives_mod);
        call_context_test.root_module.addImport("crypto", crypto_mod);
        call_context_test.root_module.addImport("build_options", build_options_mod);
        call_context_test.addIncludePath(b.path("src/bn254_wrapper"));
        const run_call_context_test = b.addRunArtifact(call_context_test);
        const call_context_test_step = b.step("test-call-context", "Run call context tests");
        call_context_test_step.dependOn(&run_call_context_test.step);
    }

    const frame_integration_test = b.addTest(.{
        .name = "frame-integration-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/evm/frame_integration_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    frame_integration_test.root_module.addImport("evm", evm_mod);
    frame_integration_test.root_module.addImport("primitives", primitives_mod);
    frame_integration_test.root_module.addImport("crypto", crypto_mod);
    frame_integration_test.root_module.addImport("build_options", build_options_mod);
    frame_integration_test.addIncludePath(b.path("src/bn254_wrapper"));
    const run_frame_integration_test = b.addRunArtifact(frame_integration_test);
    const frame_integration_test_step = b.step("test-frame-integration", "Run Frame integration tests");
    frame_integration_test_step.dependOn(&run_frame_integration_test.step);

    const frame_opcode_integration_test = b.addTest(.{
        .name = "frame-opcode-integration-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/evm/frame_opcode_integration_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    frame_opcode_integration_test.root_module.addImport("evm", evm_mod);
    frame_opcode_integration_test.root_module.addImport("primitives", primitives_mod);
    frame_opcode_integration_test.root_module.addImport("crypto", crypto_mod);
    frame_opcode_integration_test.root_module.addImport("build_options", build_options_mod);
    frame_opcode_integration_test.addIncludePath(b.path("src/bn254_wrapper"));
    const run_frame_opcode_integration_test = b.addRunArtifact(frame_opcode_integration_test);
    const frame_opcode_integration_test_step = b.step("test-frame-opcode-integration", "Run Frame opcode integration tests");
    frame_opcode_integration_test_step.dependOn(&run_frame_opcode_integration_test.step);

    const frame_host_test = b.addTest(.{
        .name = "frame-host-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/evm/frame_interpreter_host_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    frame_host_test.root_module.addImport("evm", evm_mod);
    frame_host_test.root_module.addImport("primitives", primitives_mod);
    frame_host_test.root_module.addImport("crypto", crypto_mod);
    frame_host_test.root_module.addImport("build_options", build_options_mod);
    const run_frame_host_test = b.addRunArtifact(frame_host_test);
    const frame_host_test_step = b.step("test-frame-host", "Run Frame host integration tests");
    frame_host_test_step.dependOn(&run_frame_host_test.step);

    const snapshot_propagation_test = b.addTest(.{
        .name = "snapshot-propagation-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/evm/snapshot_propagation_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    snapshot_propagation_test.root_module.addImport("evm", evm_mod);
    snapshot_propagation_test.root_module.addImport("primitives", primitives_mod);
    snapshot_propagation_test.root_module.addImport("crypto", crypto_mod);
    snapshot_propagation_test.root_module.addImport("build_options", build_options_mod);
    const run_snapshot_propagation_test = b.addRunArtifact(snapshot_propagation_test);
    const snapshot_propagation_test_step = b.step("test-snapshot-propagation", "Run snapshot propagation tests");
    snapshot_propagation_test_step.dependOn(&run_snapshot_propagation_test.step);

    const log_static_context_test = b.addTest(.{
        .name = "log-static-context-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/evm/log_static_context_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    log_static_context_test.root_module.addImport("evm", evm_mod);
    log_static_context_test.root_module.addImport("primitives", primitives_mod);
    log_static_context_test.root_module.addImport("crypto", crypto_mod);
    log_static_context_test.root_module.addImport("build_options", build_options_mod);
    const run_log_static_context_test = b.addRunArtifact(log_static_context_test);
    const log_static_context_test_step = b.step("test-log-static-context", "Run LOG static context tests");
    log_static_context_test_step.dependOn(&run_log_static_context_test.step);

    const gas_edge_case_test = b.addTest(.{
        .name = "gas-edge-case-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/evm/gas_edge_case_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    gas_edge_case_test.root_module.addImport("evm", evm_mod);
    gas_edge_case_test.root_module.addImport("primitives", primitives_mod);
    gas_edge_case_test.root_module.addImport("crypto", crypto_mod);
    gas_edge_case_test.root_module.addImport("build_options", build_options_mod);
    const run_gas_edge_case_test = b.addRunArtifact(gas_edge_case_test);
    const gas_edge_case_test_step = b.step("test-gas-edge-case", "Run gas edge case tests");
    gas_edge_case_test_step.dependOn(&run_gas_edge_case_test.step);

    const precompiles_test = b.addTest(.{
        .name = "precompiles-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/evm/precompiles_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    precompiles_test.root_module.addImport("evm", evm_mod);
    precompiles_test.root_module.addImport("primitives", primitives_mod);
    precompiles_test.root_module.addImport("crypto", crypto_mod);
    precompiles_test.linkLibrary(c_kzg_lib);
    precompiles_test.linkLibrary(blst_lib);
    precompiles_test.addIncludePath(b.path("lib/c-kzg-4844/src"));
    precompiles_test.addIncludePath(b.path("lib/c-kzg-4844/blst/bindings"));
    if (bn254_lib) |bn254_library| {
        precompiles_test.linkLibrary(bn254_library);
        precompiles_test.addIncludePath(b.path("src/bn254_wrapper"));
    }
    const run_precompiles_test = b.addRunArtifact(precompiles_test);
    const precompiles_test_step = b.step("test-precompiles", "Run precompiles integration tests");
    precompiles_test_step.dependOn(&run_precompiles_test.step);

    const precompiles_regression_test = b.addTest(.{
        .name = "precompiles-regression-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/evm/precompiles_regression_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    precompiles_regression_test.root_module.addImport("evm", evm_mod);
    precompiles_regression_test.root_module.addImport("primitives", primitives_mod);
    if (bn254_lib) |bn254_library| {
        precompiles_regression_test.linkLibrary(bn254_library);
        precompiles_regression_test.addIncludePath(b.path("src/bn254_wrapper"));
    }
    const run_precompiles_regression_test = b.addRunArtifact(precompiles_regression_test);
    const precompiles_regression_test_step = b.step("test-precompiles-regression", "Run precompiles regression tests");
    precompiles_regression_test_step.dependOn(&run_precompiles_regression_test.step);

    const compiler_test = b.addTest(.{
        .name = "compiler-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/compilers/compiler.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    compiler_test.root_module.addImport("primitives", primitives_mod);
    compiler_test.root_module.addImport("evm", evm_mod);

    const run_compiler_test = b.addRunArtifact(compiler_test);
    const compiler_test_step = b.step("test-compiler", "Run Compiler tests");
    compiler_test_step.dependOn(&run_compiler_test.step);

    const devtool_test = b.addTest(.{
        .name = "devtool-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/devtool/evm.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    devtool_test.root_module.addImport("evm", evm_mod);
    devtool_test.root_module.addImport("primitives", primitives_mod);

    const run_devtool_test = b.addRunArtifact(devtool_test);
    const devtool_test_step = b.step("test-devtool", "Run Devtool tests");
    devtool_test_step.dependOn(&run_devtool_test.step);

    const snail_shell_benchmark_test = b.addTest(.{
        .name = "snail-shell-benchmark-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/solidity/snail_shell_benchmark_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    snail_shell_benchmark_test.root_module.addImport("primitives", primitives_mod);
    snail_shell_benchmark_test.root_module.addImport("evm", evm_mod);

    const run_snail_shell_benchmark_test = b.addRunArtifact(snail_shell_benchmark_test);
    const snail_shell_benchmark_test_step = b.step("test-benchmark", "Run SnailShellBenchmark tests");
    snail_shell_benchmark_test_step.dependOn(&run_snail_shell_benchmark_test.step);

    const bn254_fuzz_test = b.addTest(.{
        .name = "bn254-fuzz-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/crypto/bn254/fuzz.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bn254_fuzz_test.root_module.addImport("primitives", primitives_mod);

    const run_bn254_fuzz_test = b.addRunArtifact(bn254_fuzz_test);
    if (b.args) |args| {
        run_bn254_fuzz_test.addArgs(args);
    }
    const bn254_fuzz_test_step = b.step("fuzz-bn254", "Run BN254 fuzz tests (use: zig build fuzz-bn254 -- --fuzz)");
    bn254_fuzz_test_step.dependOn(&run_bn254_fuzz_test.step);

    const test3 = b.addTest(.{
        .name = "test3",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/evm/evm/analysis3.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test3.root_module.addImport("evm", evm_mod);
    test3.root_module.addImport("primitives", primitives_mod);
    test3.root_module.addImport("build_options", build_options_mod);
    const run_test3 = b.addRunArtifact(test3);
    const test3_step = b.step("test3", "Run register-based EVM tests");
    test3_step.dependOn(&run_test3.step);

    const test_evm = b.addTest(.{
        .name = "test-evm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/evm/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_evm.root_module.addImport("primitives", primitives_mod);
    test_evm.root_module.addImport("evm", evm_mod);
    test_evm.root_module.addImport("build_options", build_options_mod);
    test_evm.root_module.addImport("crypto", crypto_mod);
    test_evm.root_module.addIncludePath(b.path("src/revm_wrapper"));

    if (revm_lib) |revm| {
        test_evm.linkLibrary(revm);
    }

    const run_test_evm = b.addRunArtifact(test_evm);
    const test_evm_step = b.step("test-evm-new", "Run EVM tests");
    test_evm_step.dependOn(&run_test_evm.step);

    const test_evm_call = b.addTest(.{
        .name = "test-evm-new-call",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_evm_call.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_evm_call.root_module.addImport("primitives", primitives_mod);
    test_evm_call.root_module.addImport("evm", evm_mod);
    test_evm_call.root_module.addImport("evm", evm_mod);
    test_evm_call.root_module.addImport("build_options", build_options_mod);
    test_evm_call.root_module.addImport("crypto", crypto_mod);
    test_evm_call.root_module.addIncludePath(b.path("src/revm_wrapper"));

    if (revm_lib) |revm| {
        test_evm_call.linkLibrary(revm);
    }

    const run_test_evm_call = b.addRunArtifact(test_evm_call);
    const test_evm_call_step = b.step("test-evm-new-call", "Run EVM call method tests");
    test_evm_call_step.dependOn(&run_test_evm_call.step);

    const test_evm_create = b.addTest(.{
        .name = "test-evm-new-create",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_evm_create.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_evm_create.root_module.addImport("primitives", primitives_mod);
    test_evm_create.root_module.addImport("evm", evm_mod);
    test_evm_create.root_module.addImport("evm", evm_mod);
    test_evm_create.root_module.addImport("build_options", build_options_mod);
    test_evm_create.root_module.addImport("crypto", crypto_mod);
    test_evm_create.root_module.addIncludePath(b.path("src/revm_wrapper"));

    if (revm_lib) |revm| {
        test_evm_create.linkLibrary(revm);
    }

    const run_test_evm_create = b.addRunArtifact(test_evm_create);
    const test_evm_create_step = b.step("test-evm-new-create", "Run EVM CREATE/CREATE2 tests");
    test_evm_create_step.dependOn(&run_test_evm_create.step);

    const have_evm_zbench_simple = blk: {
        std.fs.cwd().access("src/evm/bench/evm_zbench_simple.zig", .{}) catch break :blk false;
        break :blk true;
    };
    if (have_evm_zbench_simple) {
        const evm_bench_exe = b.addExecutable(.{
            .name = "evm-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/evm/bench/evm_zbench_simple.zig"),
                .target = target,
                .optimize = .ReleaseFast,
            }),
        });
        evm_bench_exe.root_module.addImport("zbench", zbench_dep.module("zbench"));
        evm_bench_exe.root_module.addImport("primitives", primitives_mod);
        evm_bench_exe.root_module.addImport("crypto", crypto_mod);

        b.installArtifact(evm_bench_exe);

        const run_evm_bench_cmd = b.addRunArtifact(evm_bench_exe);
        const evm_bench_step = b.step("evm-bench", "Run EVM zbench benchmarks");
        evm_bench_step.dependOn(&run_evm_bench_cmd.step);

        const build_evm_bench_step = b.step("build-evm-bench", "Build EVM zbench benchmarks");
        build_evm_bench_step.dependOn(&b.addInstallArtifact(evm_bench_exe, .{}).step);
    }

    const have_evm_zbench_comprehensive = blk: {
        std.fs.cwd().access("src/evm/bench/evm_zbench_comprehensive.zig", .{}) catch break :blk false;
        break :blk true;
    };
    if (have_evm_zbench_comprehensive) {
        const evm_comprehensive_bench_exe = b.addExecutable(.{
            .name = "evm-comprehensive-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/evm/bench/evm_zbench_comprehensive.zig"),
                .target = target,
                .optimize = .ReleaseFast,
            }),
        });
        evm_comprehensive_bench_exe.root_module.addImport("zbench", zbench_dep.module("zbench"));
        evm_comprehensive_bench_exe.root_module.addImport("primitives", primitives_mod);
        evm_comprehensive_bench_exe.root_module.addImport("crypto", crypto_mod);

        b.installArtifact(evm_comprehensive_bench_exe);

        const run_evm_comprehensive_bench_cmd = b.addRunArtifact(evm_comprehensive_bench_exe);
        const evm_comprehensive_bench_step = b.step("evm-comprehensive-bench", "Run EVM comprehensive performance benchmarks");
        evm_comprehensive_bench_step.dependOn(&run_evm_comprehensive_bench_cmd.step);

        const build_evm_comprehensive_bench_step = b.step("build-evm-comprehensive-bench", "Build EVM comprehensive benchmarks");
        build_evm_comprehensive_bench_step.dependOn(&b.addInstallArtifact(evm_comprehensive_bench_exe, .{}).step);
    }

    const have_evm_revm_zbench_comparison = blk: {
        std.fs.cwd().access("src/evm/bench/evm_revm_zbench_comparison.zig", .{}) catch break :blk false;
        break :blk true;
    };
    if (have_evm_revm_zbench_comparison) {
        const evm_revm_comparison_bench_exe = b.addExecutable(.{
            .name = "evm-revm-comparison-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/evm/bench/evm_revm_zbench_comparison.zig"),
                .target = target,
                .optimize = .ReleaseFast,
            }),
        });
        evm_revm_comparison_bench_exe.root_module.addImport("zbench", zbench_dep.module("zbench"));
        evm_revm_comparison_bench_exe.root_module.addImport("primitives", primitives_mod);
        evm_revm_comparison_bench_exe.root_module.addImport("evm", evm_mod);
        evm_revm_comparison_bench_exe.root_module.addImport("evm", evm_mod);
        evm_revm_comparison_bench_exe.root_module.addImport("revm", revm_mod);
        evm_revm_comparison_bench_exe.root_module.addImport("crypto", crypto_mod);

        const run_evm_revm_comparison_bench_cmd = b.addRunArtifact(evm_revm_comparison_bench_exe);
        const evm_revm_comparison_bench_step = b.step("evm-revm-comparison-bench", "Run EVM vs REVM comparison benchmarks");
        evm_revm_comparison_bench_step.dependOn(&run_evm_revm_comparison_bench_cmd.step);

        const build_evm_revm_comparison_bench_step = b.step("build-evm-revm-comparison-bench", "Build EVM vs REVM comparison benchmarks");
        build_evm_revm_comparison_bench_step.dependOn(&b.addInstallArtifact(evm_revm_comparison_bench_exe, .{}).step);
    }

    const have_simple_evm_revm = blk: {
        std.fs.cwd().access("src/evm/bench/simple_evm_revm_comparison.zig", .{}) catch break :blk false;
        break :blk true;
    };
    if (have_simple_evm_revm) {
        const simple_evm_revm_bench_exe = b.addExecutable(.{
            .name = "simple-evm-revm-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/evm/bench/simple_evm_revm_comparison.zig"),
                .target = target,
                .optimize = .ReleaseFast,
            }),
        });
        simple_evm_revm_bench_exe.root_module.addImport("zbench", zbench_dep.module("zbench"));
        simple_evm_revm_bench_exe.root_module.addImport("primitives", primitives_mod);
        simple_evm_revm_bench_exe.root_module.addImport("evm", evm_mod);
        simple_evm_revm_bench_exe.root_module.addImport("revm", revm_mod);
        simple_evm_revm_bench_exe.root_module.addImport("crypto", crypto_mod);

        const run_simple_evm_revm_bench_cmd = b.addRunArtifact(simple_evm_revm_bench_exe);
        const simple_evm_revm_bench_step = b.step("simple-evm-revm-bench", "Run simple EVM vs REVM comparison benchmarks");
        simple_evm_revm_bench_step.dependOn(&run_simple_evm_revm_bench_cmd.step);

        const build_simple_evm_revm_bench_step = b.step("build-simple-evm-revm-bench", "Build simple EVM vs REVM comparison benchmarks");
        build_simple_evm_revm_bench_step.dependOn(&b.addInstallArtifact(simple_evm_revm_bench_exe, .{}).step);
    }

    const have_comprehensive_bench = blk: {
        std.fs.cwd().access("src/evm/bench/comprehensive_evm_bench.zig", .{}) catch break :blk false;
        break :blk true;
    };
    if (have_comprehensive_bench) {
        const comprehensive_bench_exe = b.addExecutable(.{
            .name = "comprehensive-evm-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/evm/bench/comprehensive_evm_bench.zig"),
                .target = target,
                .optimize = .ReleaseFast,
            }),
        });
        comprehensive_bench_exe.root_module.addImport("zbench", zbench_dep.module("zbench"));
        comprehensive_bench_exe.root_module.addImport("primitives", primitives_mod);
        comprehensive_bench_exe.root_module.addImport("evm", evm_mod);
        comprehensive_bench_exe.root_module.addImport("evm", evm_mod);
        comprehensive_bench_exe.root_module.addImport("revm", revm_mod);
        comprehensive_bench_exe.root_module.addImport("crypto", crypto_mod);
        comprehensive_bench_exe.root_module.addImport("build_options", build_options_mod);

        b.installArtifact(comprehensive_bench_exe);

        const run_comprehensive_bench_cmd = b.addRunArtifact(comprehensive_bench_exe);
        const comprehensive_bench_step = b.step("comprehensive-evm-bench", "Run comprehensive EVM comparison benchmarks");
        comprehensive_bench_step.dependOn(&run_comprehensive_bench_cmd.step);

        const build_comprehensive_bench_step = b.step("build-comprehensive-evm-bench", "Build comprehensive EVM benchmarks");
        build_comprehensive_bench_step.dependOn(&b.addInstallArtifact(comprehensive_bench_exe, .{}).step);
    }

    // Bytecode benchmarks
    const bytecode_bench_exe = b.addExecutable(.{
        .name = "bytecode-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/evm/bytecode_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    bytecode_bench_exe.root_module.addImport("zbench", zbench_dep.module("zbench"));
    bytecode_bench_exe.root_module.addImport("primitives", primitives_mod);
    bytecode_bench_exe.root_module.addImport("evm", evm_mod);
    bytecode_bench_exe.root_module.addImport("crypto", crypto_mod);
    bytecode_bench_exe.root_module.addImport("build_options", build_options_mod);
    bytecode_bench_exe.linkLibrary(c_kzg_lib);
    bytecode_bench_exe.linkLibrary(blst_lib);
    bytecode_bench_exe.linkLibC();

    b.installArtifact(bytecode_bench_exe);

    const run_bytecode_bench_cmd = b.addRunArtifact(bytecode_bench_exe);
    const bytecode_bench_step = b.step("bytecode-bench", "Run bytecode analysis benchmarks");
    bytecode_bench_step.dependOn(&run_bytecode_bench_cmd.step);

    const build_bytecode_bench_step = b.step("build-bytecode-bench", "Build bytecode analysis benchmarks");
    build_bytecode_bench_step.dependOn(&b.addInstallArtifact(bytecode_bench_exe, .{}).step);

    // Simple bytecode benchmark
    const bytecode_bench_simple_exe = b.addExecutable(.{
        .name = "bytecode-bench-simple",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/evm/bytecode_bench_simple.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    bytecode_bench_simple_exe.root_module.addImport("primitives", primitives_mod);
    bytecode_bench_simple_exe.root_module.addImport("evm", evm_mod);
    bytecode_bench_simple_exe.root_module.addImport("crypto", crypto_mod);
    bytecode_bench_simple_exe.root_module.addImport("build_options", build_options_mod);

    const run_bytecode_bench_simple_cmd = b.addRunArtifact(bytecode_bench_simple_exe);
    const bytecode_bench_simple_step = b.step("bytecode-bench-simple", "Run simple bytecode benchmarks");
    bytecode_bench_simple_step.dependOn(&run_bytecode_bench_simple_cmd.step);
    

    // StackFrame benchmark vs REVM
    // TODO: Update stack_frame_bench.zig to work without Host
    // const stack_frame_bench_exe = b.addExecutable(.{
    //     .name = "stack-frame-bench",
    //     .root_module = b.createModule(.{
    //         .root_source_file = b.path("src/evm/stack_frame_bench.zig"),
    //         .target = target,
    //         .optimize = .ReleaseFast,
    //     }),
    // });
    // stack_frame_bench_exe.root_module.addImport("zbench", zbench_dep.module("zbench"));
    // stack_frame_bench_exe.root_module.addImport("primitives", primitives_mod);
    // stack_frame_bench_exe.root_module.addImport("evm", evm_mod);
    // stack_frame_bench_exe.root_module.addImport("crypto", crypto_mod);
    // stack_frame_bench_exe.root_module.addImport("build_options", build_options_mod);
    // stack_frame_bench_exe.root_module.addImport("revm", revm_mod);
    // stack_frame_bench_exe.linkLibrary(c_kzg_lib);
    // stack_frame_bench_exe.linkLibrary(blst_lib);
    // if (revm_lib) |revm| {
    //     stack_frame_bench_exe.linkLibrary(revm);
    // }
    // stack_frame_bench_exe.linkLibC();

    // b.installArtifact(stack_frame_bench_exe);

    // const run_stack_frame_bench_cmd = b.addRunArtifact(stack_frame_bench_exe);
    // const stack_frame_bench_step = b.step("stack-frame-bench", "Run StackFrame vs REVM benchmarks");
    // stack_frame_bench_step.dependOn(&run_stack_frame_bench_cmd.step);

    // const build_stack_frame_bench_step = b.step("build-stack-frame-bench", "Build StackFrame vs REVM benchmarks");
    // build_stack_frame_bench_step.dependOn(&b.addInstallArtifact(stack_frame_bench_exe, .{}).step);

    const cli_cmd = blk: {
        const exe_name = if (target.result.os.tag == .windows) "evm-debugger.exe" else "evm-debugger";

        const cmd = b.addSystemCommand(&[_][]const u8{ "go", "build", "-o", exe_name, "-ldflags", "-s -w", "." });
        cmd.setCwd(b.path("src/cli"));

        cmd.setEnvironmentVariable("CGO_ENABLED", "1");

        const goos = switch (target.result.os.tag) {
            .linux => "linux",
            .windows => "windows",
            .macos => "darwin",
            else => "linux",
        };

        const goarch = switch (target.result.cpu.arch) {
            .x86_64 => "amd64",
            .aarch64 => "arm64",
            .x86 => "386",
            else => "amd64",
        };

        cmd.setEnvironmentVariable("GOOS", goos);
        cmd.setEnvironmentVariable("GOARCH", goarch);

        const cflags = "-I../evm";
        cmd.setEnvironmentVariable("CGO_CFLAGS", cflags);

        break :blk cmd;
    };

    const cli_step = b.step("cli", "Build the EVM debugger CLI with EVM integration");
    cli_step.dependOn(&cli_cmd.step);

    const cli_clean_cmd = b.addSystemCommand(&[_][]const u8{ "go", "clean", "-cache" });
    cli_clean_cmd.setCwd(b.path("src/cli"));

    const clean_lib_cmd = b.addSystemCommand(&[_][]const u8{ "rm", "-rf", "zig-cache/lib", "src/cli/evm-debugger", "src/cli/evm-debugger.exe" });

    const cli_clean_step = b.step("cli-clean", "Clean CLI build artifacts and Go cache");
    cli_clean_step.dependOn(&cli_clean_cmd.step);
    cli_clean_step.dependOn(&clean_lib_cmd.step);

    const cli_run_cmd = b.addSystemCommand(&[_][]const u8{ "./evm-debugger", "--help" });
    cli_run_cmd.setCwd(b.path("src/cli"));
    cli_run_cmd.step.dependOn(&cli_cmd.step);

    const cli_run_step = b.step("cli-run", "Build and run the EVM debugger CLI");
    cli_run_step.dependOn(&cli_run_cmd.step);

    const bn254_fp_test = b.addTest(.{
        .name = "bn254-fp-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/crypto/bn254/FpMont.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bn254_fp_test.root_module.addImport("primitives", primitives_mod);
    const run_bn254_fp_test = b.addRunArtifact(bn254_fp_test);
    const bn254_fp_test_step = b.step("test-bn254-fp", "Run BN254 Fp tests");
    bn254_fp_test_step.dependOn(&run_bn254_fp_test.step);

    const bn254_fr_test = b.addTest(.{
        .name = "bn254-fr-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/crypto/bn254/Fr.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bn254_fr_test.root_module.addImport("primitives", primitives_mod);
    const run_bn254_fr_test = b.addRunArtifact(bn254_fr_test);
    const bn254_fr_test_step = b.step("test-bn254-fr", "Run BN254 Fr tests");
    bn254_fr_test_step.dependOn(&run_bn254_fr_test.step);

    const bn254_fp2_test = b.addTest(.{
        .name = "bn254-fp2-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/crypto/bn254/Fp2Mont.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bn254_fp2_test.root_module.addImport("primitives", primitives_mod);
    const run_bn254_fp2_test = b.addRunArtifact(bn254_fp2_test);
    const bn254_fp2_test_step = b.step("test-bn254-fp2", "Run BN254 Fp2 tests");
    bn254_fp2_test_step.dependOn(&run_bn254_fp2_test.step);

    const bn254_fp6_test = b.addTest(.{
        .name = "bn254-fp6-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/crypto/bn254/Fp6Mont.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bn254_fp6_test.root_module.addImport("primitives", primitives_mod);
    const run_bn254_fp6_test = b.addRunArtifact(bn254_fp6_test);
    const bn254_fp6_test_step = b.step("test-bn254-fp6", "Run BN254 Fp6 tests");
    bn254_fp6_test_step.dependOn(&run_bn254_fp6_test.step);

    const bn254_fp12_test = b.addTest(.{
        .name = "bn254-fp12-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/crypto/bn254/Fp12Mont.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bn254_fp12_test.root_module.addImport("primitives", primitives_mod);
    const run_bn254_fp12_test = b.addRunArtifact(bn254_fp12_test);
    const bn254_fp12_test_step = b.step("test-bn254-fp12", "Run BN254 Fp12 tests");
    bn254_fp12_test_step.dependOn(&run_bn254_fp12_test.step);

    const bn254_g1_test = b.addTest(.{
        .name = "bn254-g1-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/crypto/bn254/G1.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bn254_g1_test.root_module.addImport("primitives", primitives_mod);
    const run_bn254_g1_test = b.addRunArtifact(bn254_g1_test);
    const bn254_g1_test_step = b.step("test-bn254-g1", "Run BN254 G1 tests");
    bn254_g1_test_step.dependOn(&run_bn254_g1_test.step);

    const bn254_g2_test = b.addTest(.{
        .name = "bn254-g2-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/crypto/bn254/G2.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bn254_g2_test.root_module.addImport("primitives", primitives_mod);
    const run_bn254_g2_test = b.addRunArtifact(bn254_g2_test);
    const bn254_g2_test_step = b.step("test-bn254-g2", "Run BN254 G2 tests");
    bn254_g2_test_step.dependOn(&run_bn254_g2_test.step);

    const bn254_pairing_test = b.addTest(.{
        .name = "bn254-pairing-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/crypto/bn254/pairing.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bn254_pairing_test.root_module.addImport("primitives", primitives_mod);
    const run_bn254_pairing_test = b.addRunArtifact(bn254_pairing_test);
    const bn254_pairing_test_step = b.step("test-bn254-pairing", "Run BN254 pairing tests");
    bn254_pairing_test_step.dependOn(&run_bn254_pairing_test.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_precompiles_test.step);
    test_step.dependOn(&run_precompiles_regression_test.step);
    if (revm_lib != null) {
        const revm_test = b.addTest(.{
            .name = "revm-test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/revm_wrapper/test_revm_wrapper.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        revm_test.root_module.addImport("primitives", primitives_mod);
        revm_test.linkLibrary(revm_lib.?);
        revm_test.addIncludePath(b.path("src/revm_wrapper"));
        revm_test.linkLibC();

        const revm_rust_target_dir = if (optimize == .Debug) "debug" else "release";
        const revm_dylib_path = if (rust_target) |target_triple|
            b.fmt("target/{s}/{s}/librevm_wrapper.dylib", .{ target_triple, revm_rust_target_dir })
        else
            b.fmt("target/{s}/librevm_wrapper.dylib", .{revm_rust_target_dir});
        revm_test.addObjectFile(b.path(revm_dylib_path));

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

        revm_test.step.dependOn(&revm_lib.?.step);

        const run_revm_test = b.addRunArtifact(revm_test);
        test_step.dependOn(&run_revm_test.step);

        const revm_test_step = b.step("test-revm", "Run REVM wrapper tests");
        revm_test_step.dependOn(&run_revm_test.step);
    }

    test_step.dependOn(&run_bn254_fp_test.step);
    test_step.dependOn(&run_bn254_fr_test.step);
    test_step.dependOn(&run_bn254_fp2_test.step);
    test_step.dependOn(&run_bn254_fp6_test.step);
    test_step.dependOn(&run_bn254_fp12_test.step);
    test_step.dependOn(&run_bn254_g1_test.step);
    test_step.dependOn(&run_bn254_g2_test.step);
    test_step.dependOn(&run_bn254_pairing_test.step);

    const evm_runner_test = b.addTest(.{
        .name = "evm-runner-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/evms/zig/src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    evm_runner_test.root_module.addImport("evm", evm_mod);
    evm_runner_test.root_module.addImport("primitives", primitives_mod);
    const run_evm_runner_test = b.addRunArtifact(evm_runner_test);
    test_step.dependOn(&run_evm_runner_test.step);

    // Add differential testing only if REVM is available
    if (revm_lib != null) {
        const differential_test = b.addTest(.{
            .name = "differential-test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/differential/all_tests.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        differential_test.root_module.addImport("evm", evm_mod);
        differential_test.root_module.addImport("primitives", primitives_mod);
        differential_test.root_module.addImport("revm", revm_mod);
        
        differential_test.linkLibrary(revm_lib.?);
        differential_test.addIncludePath(b.path("src/revm_wrapper"));
        differential_test.linkLibC();
        
        const revm_rust_target_dir = if (optimize == .Debug) "debug" else "release";
        const revm_dylib_path = if (rust_target) |target_triple|
            b.fmt("target/{s}/{s}/librevm_wrapper.dylib", .{ target_triple, revm_rust_target_dir })
        else
            b.fmt("target/{s}/librevm_wrapper.dylib", .{revm_rust_target_dir});
        differential_test.addObjectFile(b.path(revm_dylib_path));
        
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
        
        const run_differential_test = b.addRunArtifact(differential_test);
        test_step.dependOn(&run_differential_test.step);
        
        const differential_test_step = b.step("test-differential", "Run differential tests comparing Guillotine and REVM");
        differential_test_step.dependOn(&run_differential_test.step);
    }

    const comprehensive_compare = b.addExecutable(.{
        .name = "comprehensive-opcode-comparison",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/evm/comprehensive_opcode_comparison.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    comprehensive_compare.root_module.addImport("evm", evm_mod);
    comprehensive_compare.root_module.addImport("primitives", primitives_mod);
    comprehensive_compare.root_module.addImport("Address", primitives_mod);
    comprehensive_compare.root_module.addImport("revm", revm_mod);

    if (revm_lib) |revm_library| {
        comprehensive_compare.linkLibrary(revm_library);
        comprehensive_compare.addIncludePath(b.path("src/revm_wrapper"));
        comprehensive_compare.linkLibC();

        const revm_rust_target_dir = if (optimize == .Debug) "debug" else "release";
        const revm_dylib_path = if (rust_target) |target_triple|
            b.fmt("target/{s}/{s}/librevm_wrapper.dylib", .{ target_triple, revm_rust_target_dir })
        else
            b.fmt("target/{s}/librevm_wrapper.dylib", .{revm_rust_target_dir});
        comprehensive_compare.addObjectFile(b.path(revm_dylib_path));

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

    if (bn254_lib) |bn254_library| {
        comprehensive_compare.linkLibrary(bn254_library);
        comprehensive_compare.addIncludePath(b.path("src/bn254_wrapper"));
    }

    const run_comprehensive_compare = b.addRunArtifact(comprehensive_compare);
    const comprehensive_compare_step = b.step("run-comprehensive-compare", "Run comprehensive opcode comparison");
    comprehensive_compare_step.dependOn(&run_comprehensive_compare.step);

    const erc20_trace_test = b.addTest(.{
        .name = "erc20-trace-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/evm/trace_erc20_constructor.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    erc20_trace_test.root_module.addImport("evm", evm_mod);
    erc20_trace_test.root_module.addImport("primitives", primitives_mod);

    const run_erc20_trace_test = b.addRunArtifact(erc20_trace_test);
    const erc20_trace_test_step = b.step("test-erc20-trace", "Run ERC20 constructor trace test");
    erc20_trace_test_step.dependOn(&run_erc20_trace_test.step);

    for (tests.fuzz_tests) |test_info| {
        const fuzz_test = b.addTest(.{
            .name = test_info.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_info.source_file),
                .target = target,
                .optimize = optimize,
            }),
        });
        fuzz_test.root_module.addImport("evm", evm_mod);

        if (std.mem.indexOf(u8, test_info.name, "arithmetic") != null or
            std.mem.indexOf(u8, test_info.name, "bitwise") != null or
            std.mem.indexOf(u8, test_info.name, "comparison") != null or
            std.mem.indexOf(u8, test_info.name, "control") != null or
            std.mem.indexOf(u8, test_info.name, "crypto") != null or
            std.mem.indexOf(u8, test_info.name, "environment") != null or
            std.mem.indexOf(u8, test_info.name, "storage") != null or
            std.mem.indexOf(u8, test_info.name, "state") != null or
            std.mem.indexOf(u8, test_info.name, "evm-bytecode") != null)
        {
            fuzz_test.root_module.addImport("primitives", primitives_mod);
        }

        const run_fuzz_test = b.addRunArtifact(fuzz_test);
        if (b.args) |args| {
            run_fuzz_test.addArgs(args);
        }

        if (test_info.step_name) |step_name| {
            const individual_step = b.step(
                step_name,
                test_info.step_desc orelse "Run test",
            );
            individual_step.dependOn(&run_fuzz_test.step);
        }
    }

    const docs_step = b.step("docs", "Generate and install documentation");
    const docs_install = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&docs_install.step);

    const python_build_cmd = b.addSystemCommand(&[_][]const u8{ "python3", "build.py" });
    python_build_cmd.setCwd(b.path("src/guillotine-py"));
    python_build_cmd.step.dependOn(b.getInstallStep());

    const python_build_step = b.step("python", "Build Python bindings");
    python_build_step.dependOn(&python_build_cmd.step);

    const python_dev_cmd = b.addSystemCommand(&[_][]const u8{ "python3", "build.py", "--dev" });
    python_dev_cmd.setCwd(b.path("src/guillotine-py"));
    python_dev_cmd.step.dependOn(b.getInstallStep());

    const python_dev_step = b.step("python-dev", "Build and install Python bindings in development mode");
    python_dev_step.dependOn(&python_dev_cmd.step);

    const python_test_cmd = b.addSystemCommand(&[_][]const u8{ "python3", "-m", "pytest", "tests/", "-v" });
    python_test_cmd.setCwd(b.path("src/guillotine-py"));
    python_test_cmd.step.dependOn(&python_build_cmd.step);

    const python_test_step = b.step("python-test", "Run Python binding tests");
    python_test_step.dependOn(&python_test_cmd.step);

    const python_examples_cmd = b.addSystemCommand(&[_][]const u8{ "python3", "examples.py" });
    python_examples_cmd.setCwd(b.path("src/guillotine-py"));
    python_examples_cmd.step.dependOn(&python_build_cmd.step);

    const python_examples_step = b.step("python-examples", "Run Python binding examples");
    python_examples_step.dependOn(&python_examples_cmd.step);

    addSwiftSteps(b);

    addGoSteps(b);

    addTypeScriptSteps(b);
}

fn addSwiftSteps(b: *std.Build) void {
    const swift_build_cmd = b.addSystemCommand(&[_][]const u8{ "swift", "build" });
    swift_build_cmd.setCwd(b.path("src/guillotine-swift"));
    swift_build_cmd.step.dependOn(b.getInstallStep());

    const swift_build_step = b.step("swift", "Build Swift bindings");
    swift_build_step.dependOn(&swift_build_cmd.step);

    const swift_test_cmd = b.addSystemCommand(&[_][]const u8{ "swift", "test" });
    swift_test_cmd.setCwd(b.path("src/guillotine-swift"));
    swift_test_cmd.step.dependOn(&swift_build_cmd.step);

    const swift_test_step = b.step("swift-test", "Run Swift binding tests");
    swift_test_step.dependOn(&swift_test_cmd.step);

    const swift_validate_cmd = b.addSystemCommand(&[_][]const u8{ "swift", "package", "validate" });
    swift_validate_cmd.setCwd(b.path("src/guillotine-swift"));

    const swift_validate_step = b.step("swift-validate", "Validate Swift package");
    swift_validate_step.dependOn(&swift_validate_cmd.step);
}

fn addGoSteps(b: *std.Build) void {
    const go_mod_tidy_cmd = b.addSystemCommand(&[_][]const u8{ "go", "mod", "tidy" });
    go_mod_tidy_cmd.setCwd(b.path("src/guillotine-go"));
    go_mod_tidy_cmd.step.dependOn(b.getInstallStep());

    const go_build_cmd = b.addSystemCommand(&[_][]const u8{ "go", "build", "./..." });
    go_build_cmd.setCwd(b.path("src/guillotine-go"));
    go_build_cmd.step.dependOn(&go_mod_tidy_cmd.step);

    const go_build_step = b.step("go", "Build Go bindings");
    go_build_step.dependOn(&go_build_cmd.step);

    const go_test_cmd = b.addSystemCommand(&[_][]const u8{ "go", "test", "./..." });
    go_test_cmd.setCwd(b.path("src/guillotine-go"));
    go_test_cmd.step.dependOn(&go_build_cmd.step);

    const go_test_step = b.step("go-test", "Run Go binding tests");
    go_test_step.dependOn(&go_test_cmd.step);

    const go_vet_cmd = b.addSystemCommand(&[_][]const u8{ "go", "vet", "./..." });
    go_vet_cmd.setCwd(b.path("src/guillotine-go"));
    go_vet_cmd.step.dependOn(&go_build_cmd.step);

    const go_vet_step = b.step("go-vet", "Run Go code analysis");
    go_vet_step.dependOn(&go_vet_cmd.step);

    const go_fmt_check_cmd = b.addSystemCommand(&[_][]const u8{ "sh", "-c", "test -z \"$(gofmt -l .)\" || (echo 'Code is not formatted. Run: go fmt ./...' && exit 1)" });
    go_fmt_check_cmd.setCwd(b.path("src/guillotine-go"));

    const go_fmt_check_step = b.step("go-fmt-check", "Check Go code formatting");
    go_fmt_check_step.dependOn(&go_fmt_check_cmd.step);

    const go_fmt_cmd = b.addSystemCommand(&[_][]const u8{ "go", "fmt", "./..." });
    go_fmt_cmd.setCwd(b.path("src/guillotine-go"));

    const go_fmt_step = b.step("go-fmt", "Format Go code");
    go_fmt_step.dependOn(&go_fmt_cmd.step);
}

fn addTypeScriptSteps(b: *std.Build) void {
    const ts_install_cmd = b.addSystemCommand(&[_][]const u8{ "npm", "install" });
    ts_install_cmd.setCwd(b.path("src/guillotine-ts"));
    ts_install_cmd.step.dependOn(b.getInstallStep());

    const ts_copy_wasm_cmd = b.addSystemCommand(&[_][]const u8{ "npm", "run", "copy-wasm" });
    ts_copy_wasm_cmd.setCwd(b.path("src/guillotine-ts"));
    ts_copy_wasm_cmd.step.dependOn(&ts_install_cmd.step);

    const ts_build_cmd = b.addSystemCommand(&[_][]const u8{ "npm", "run", "build" });
    ts_build_cmd.setCwd(b.path("src/guillotine-ts"));
    ts_build_cmd.step.dependOn(&ts_copy_wasm_cmd.step);

    const ts_build_step = b.step("ts", "Build TypeScript bindings");
    ts_build_step.dependOn(&ts_build_cmd.step);

    const ts_test_cmd = b.addSystemCommand(&[_][]const u8{ "npm", "test" });
    ts_test_cmd.setCwd(b.path("src/guillotine-ts"));
    ts_test_cmd.step.dependOn(&ts_build_cmd.step);

    const ts_test_step = b.step("ts-test", "Run TypeScript binding tests");
    ts_test_step.dependOn(&ts_test_cmd.step);

    const ts_lint_cmd = b.addSystemCommand(&[_][]const u8{ "npm", "run", "lint" });
    ts_lint_cmd.setCwd(b.path("src/guillotine-ts"));
    ts_lint_cmd.step.dependOn(&ts_install_cmd.step);

    const ts_lint_step = b.step("ts-lint", "Run TypeScript linting");
    ts_lint_step.dependOn(&ts_lint_cmd.step);

    const ts_format_check_cmd = b.addSystemCommand(&[_][]const u8{ "npm", "run", "format:check" });
    ts_format_check_cmd.setCwd(b.path("src/guillotine-ts"));
    ts_format_check_cmd.step.dependOn(&ts_install_cmd.step);

    const ts_format_check_step = b.step("ts-format-check", "Check TypeScript code formatting");
    ts_format_check_step.dependOn(&ts_format_check_cmd.step);

    const ts_format_cmd = b.addSystemCommand(&[_][]const u8{ "npm", "run", "format" });
    ts_format_cmd.setCwd(b.path("src/guillotine-ts"));
    ts_format_cmd.step.dependOn(&ts_install_cmd.step);

    const ts_format_step = b.step("ts-format", "Format TypeScript code");
    ts_format_step.dependOn(&ts_format_cmd.step);

    const ts_typecheck_cmd = b.addSystemCommand(&[_][]const u8{ "npm", "run", "typecheck" });
    ts_typecheck_cmd.setCwd(b.path("src/guillotine-ts"));
    ts_typecheck_cmd.step.dependOn(&ts_install_cmd.step);

    const ts_typecheck_step = b.step("ts-typecheck", "Run TypeScript type checking");
    ts_typecheck_step.dependOn(&ts_typecheck_cmd.step);

    const ts_dev_cmd = b.addSystemCommand(&[_][]const u8{ "npm", "run", "dev" });
    ts_dev_cmd.setCwd(b.path("src/guillotine-ts"));
    ts_dev_cmd.step.dependOn(&ts_install_cmd.step);

    const ts_dev_step = b.step("ts-dev", "Run TypeScript in development/watch mode");
    ts_dev_step.dependOn(&ts_dev_cmd.step);

    const ts_clean_cmd = b.addSystemCommand(&[_][]const u8{ "npm", "run", "clean" });
    ts_clean_cmd.setCwd(b.path("src/guillotine-ts"));

    const ts_clean_step = b.step("ts-clean", "Clean TypeScript build artifacts");
    ts_clean_step.dependOn(&ts_clean_cmd.step);
}
