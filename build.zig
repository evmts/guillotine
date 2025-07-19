const std = @import("std");

// Asset generation step for devtool
const GenerateAssetsStep = struct {
    step: std.Build.Step,
    dist_path: []const u8,
    out_path: []const u8,

    fn init(b: *std.Build, dist_path: []const u8, out_path: []const u8) *GenerateAssetsStep {
        const self = b.allocator.create(GenerateAssetsStep) catch @panic("OOM");
        self.* = GenerateAssetsStep{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "generate assets",
                .owner = b,
                .makeFn = make,
            }),
            .dist_path = b.dupe(dist_path),
            .out_path = b.dupe(out_path),
        };
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;
        const self: *GenerateAssetsStep = @fieldParentPtr("step", step);
        const b = step.owner;
        const allocator = b.allocator;

        var file = try std.fs.cwd().createFile(self.out_path, .{});
        defer file.close();

        var writer = file.writer();

        try writer.writeAll("// This file is auto-generated. Do not edit manually.\n");
        try writer.writeAll("const std = @import(\"std\");\n\n");
        try writer.writeAll("const Self = @This();\n\n");
        try writer.writeAll("path: []const u8,\n");
        try writer.writeAll("content: []const u8,\n");
        try writer.writeAll("mime_type: []const u8,\n");
        try writer.writeAll("response: [:0]const u8,\n\n");

        try writer.writeAll("pub fn init(\n");
        try writer.writeAll("    comptime path: []const u8,\n");
        try writer.writeAll("    comptime content: []const u8,\n");
        try writer.writeAll("    comptime mime_type: []const u8,\n");
        try writer.writeAll(") Self {\n");
        try writer.writeAll("    var buf: [20]u8 = undefined;\n");
        try writer.writeAll("    const n = std.fmt.bufPrint(&buf, \"{d}\", .{content.len}) catch unreachable;\n");
        try writer.writeAll("    const content_length = buf[0..n.len];\n");
        try writer.writeAll("    const response = \"HTTP/1.1 200 OK\\n\" ++\n");
        try writer.writeAll("        \"Content-Type: \" ++ mime_type ++ \"\\n\" ++\n");
        try writer.writeAll("        \"Content-Length: \" ++ content_length ++ \"\\n\" ++\n");
        try writer.writeAll("        \"\\n\" ++\n");
        try writer.writeAll("        content;\n");
        try writer.writeAll("    return Self{\n");
        try writer.writeAll("        .path = path,\n");
        try writer.writeAll("        .content = content,\n");
        try writer.writeAll("        .mime_type = mime_type,\n");
        try writer.writeAll("        .response = response,\n");
        try writer.writeAll("    };\n");
        try writer.writeAll("}\n\n");

        try writer.writeAll("pub const not_found_asset = Self.init(\n");
        try writer.writeAll("    \"/notfound.html\",\n");
        try writer.writeAll("    \"<div>Page not found</div>\",\n");
        try writer.writeAll("    \"text/html\",\n");
        try writer.writeAll(");\n\n");

        try writer.writeAll("pub const assets = [_]Self{\n");

        var dir = try std.fs.cwd().openDir(self.dist_path, .{ .iterate = true });
        defer dir.close();

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;

            const mime_type = get_mime_type(entry.basename);
            const path = try std.fmt.allocPrint(allocator, "/{s}", .{entry.path});
            defer allocator.free(path);

            try writer.print("    Self.init(\n", .{});
            try writer.print("        \"{s}\",\n", .{path});
            try writer.print("        @embedFile(\"dist/{s}\"),\n", .{entry.path});
            try writer.print("        \"{s}\",\n", .{mime_type});
            try writer.print("    ),\n", .{});
        }

        try writer.writeAll("};\n\n");

        try writer.writeAll("pub fn get_asset(path: []const u8) Self {\n");
        try writer.writeAll("    for (assets) |asset| {\n");
        try writer.writeAll("        if (std.mem.eql(u8, asset.path, path)) {\n");
        try writer.writeAll("            return asset;\n");
        try writer.writeAll("        }\n");
        try writer.writeAll("    }\n");
        try writer.writeAll("    return not_found_asset;\n");
        try writer.writeAll("}\n");
    }

    fn get_mime_type(filename: []const u8) []const u8 {
        if (std.mem.endsWith(u8, filename, ".html")) return "text/html";
        if (std.mem.endsWith(u8, filename, ".js")) return "application/javascript";
        if (std.mem.endsWith(u8, filename, ".css")) return "text/css";
        if (std.mem.endsWith(u8, filename, ".svg")) return "image/svg+xml";
        if (std.mem.endsWith(u8, filename, ".png")) return "image/png";
        if (std.mem.endsWith(u8, filename, ".jpg") or std.mem.endsWith(u8, filename, ".jpeg")) return "image/jpeg";
        if (std.mem.endsWith(u8, filename, ".gif")) return "image/gif";
        if (std.mem.endsWith(u8, filename, ".ico")) return "image/x-icon";
        if (std.mem.endsWith(u8, filename, ".woff")) return "font/woff";
        if (std.mem.endsWith(u8, filename, ".woff2")) return "font/woff2";
        if (std.mem.endsWith(u8, filename, ".ttf")) return "font/ttf";
        if (std.mem.endsWith(u8, filename, ".otf")) return "font/otf";
        if (std.mem.endsWith(u8, filename, ".json")) return "application/json";
        if (std.mem.endsWith(u8, filename, ".xml")) return "application/xml";
        if (std.mem.endsWith(u8, filename, ".pdf")) return "application/pdf";
        if (std.mem.endsWith(u8, filename, ".txt")) return "text/plain";
        return "application/octet-stream";
    }
};

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
    
    // Custom build option to optimize for size
    const optimize_size = b.option(bool, "optimize_size", "Optimize for binary size by using runtime calculations instead of lookup tables") orelse false;

    // Create build options module
    const build_options = b.addOptions();
    build_options.addOption(bool, "no_precompiles", no_precompiles);
    build_options.addOption(bool, "optimize_size", optimize_size);

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addIncludePath(b.path("src/bn254_wrapper"));

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
    const rust_profile = if (optimize == .Debug) "dev" else "release";
    const rust_target_dir = if (optimize == .Debug) "debug" else "release";

    const rust_build = b.addSystemCommand(&[_][]const u8{ "cargo", "build", "--profile", rust_profile, "--manifest-path", "src/bn254_wrapper/Cargo.toml", "--verbose" });

    // Fix for macOS linking issues (only on macOS)
    if (target.result.os.tag == .macos) {
        rust_build.setEnvironmentVariable("RUSTFLAGS", "-L/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/lib");
    }

    // Create static library artifact for the Rust BN254 wrapper
    const bn254_lib = b.addStaticLibrary(.{
        .name = "bn254_wrapper",
        .target = target,
        .optimize = optimize,
    });

    // Link the compiled Rust library
    const rust_lib_path = b.fmt("target/{s}/libbn254_wrapper.a", .{rust_target_dir});
    bn254_lib.addObjectFile(b.path(rust_lib_path));
    bn254_lib.linkLibC();

    // Link additional system libraries that Rust might need
    if (target.result.os.tag == .linux) {
        bn254_lib.linkSystemLibrary("dl");
        bn254_lib.linkSystemLibrary("pthread");
        bn254_lib.linkSystemLibrary("m");
        bn254_lib.linkSystemLibrary("rt");
    } else if (target.result.os.tag == .macos) {
        bn254_lib.linkFramework("Security");
        bn254_lib.linkFramework("CoreFoundation");
    }

    // Add include path for C header
    bn254_lib.addIncludePath(b.path("src/bn254_wrapper"));

    // Make the rust build a dependency
    bn254_lib.step.dependOn(&rust_build.step);

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
    evm_mod.addImport("build_options", build_options.createModule());

    // Link BN254 Rust library to EVM module (native targets only)
    evm_mod.linkLibrary(bn254_lib);
    evm_mod.addIncludePath(b.path("src/bn254_wrapper"));

    // Link c-kzg library to EVM module
    evm_mod.linkLibrary(c_kzg_lib);

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

    // Create bench module - always use ReleaseFast for benchmarks
    const bench_optimize = if (optimize == .Debug) .ReleaseFast else optimize;
    
    // Create a separate BN254 library for benchmarks that always uses release mode
    const bench_rust_profile = "release";
    const bench_rust_target_dir = "release";
    
    const bench_rust_build = b.addSystemCommand(&[_][]const u8{ "cargo", "build", "--profile", bench_rust_profile, "--manifest-path", "src/bn254_wrapper/Cargo.toml", "--verbose" });
    
    // Fix for macOS linking issues (only on macOS)
    if (target.result.os.tag == .macos) {
        bench_rust_build.setEnvironmentVariable("RUSTFLAGS", "-L/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/lib");
    }
    
    // Create static library artifact for the Rust BN254 wrapper (bench version)
    const bench_bn254_lib = b.addStaticLibrary(.{
        .name = "bn254_wrapper_bench",
        .target = target,
        .optimize = bench_optimize,
    });
    
    // Link the compiled Rust library
    const bench_rust_lib_path = b.fmt("target/{s}/libbn254_wrapper.a", .{bench_rust_target_dir});
    bench_bn254_lib.addObjectFile(b.path(bench_rust_lib_path));
    bench_bn254_lib.linkLibC();
    
    // Link additional system libraries that Rust might need
    if (target.result.os.tag == .linux) {
        bench_bn254_lib.linkSystemLibrary("dl");
        bench_bn254_lib.linkSystemLibrary("pthread");
        bench_bn254_lib.linkSystemLibrary("m");
        bench_bn254_lib.linkSystemLibrary("rt");
    } else if (target.result.os.tag == .macos) {
        bench_bn254_lib.linkFramework("Security");
        bench_bn254_lib.linkFramework("CoreFoundation");
    }
    
    // Add include path for C header
    bench_bn254_lib.addIncludePath(b.path("src/bn254_wrapper"));
    
    // Make the rust build a dependency
    bench_bn254_lib.step.dependOn(&bench_rust_build.step);
    
    // Create a separate EVM module for benchmarks with release-mode Rust dependencies
    const bench_evm_mod = b.createModule(.{
        .root_source_file = b.path("src/evm/root.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    bench_evm_mod.addImport("primitives", primitives_mod);
    bench_evm_mod.addImport("crypto", crypto_mod);
    bench_evm_mod.addImport("build_options", build_options.createModule());
    
    // Link BN254 Rust library to bench EVM module (native targets only)
    bench_evm_mod.linkLibrary(bench_bn254_lib);
    bench_evm_mod.addIncludePath(b.path("src/bn254_wrapper"));
    
    // Link c-kzg library to bench EVM module
    bench_evm_mod.linkLibrary(c_kzg_lib);
    
    const zbench_dep = b.dependency("zbench", .{
        .target = target,
        .optimize = bench_optimize,
    });
    
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/root.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    bench_mod.addImport("primitives", primitives_mod);
    bench_mod.addImport("evm", bench_evm_mod);  // Use the bench-specific EVM module
    bench_mod.addImport("zbench", zbench_dep.module("zbench"));

    // Add modules to lib_mod so tests can access them
    lib_mod.addImport("primitives", primitives_mod);
    lib_mod.addImport("crypto", crypto_mod);
    lib_mod.addImport("evm", evm_mod);
    lib_mod.addImport("provider", provider_mod);
    lib_mod.addImport("compilers", compilers_mod);
    lib_mod.addImport("trie", trie_mod);
    lib_mod.addImport("bench", bench_mod);

    const exe_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    exe_mod.addImport("Guillotine_lib", lib_mod);
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "Guillotine",
        .root_module = lib_mod,
    });

    // Link BN254 Rust library to the library artifact
    lib.linkLibrary(bn254_lib);
    lib.addIncludePath(b.path("src/bn254_wrapper"));

    // Note: c-kzg is now available as a module import, no need to link to main library

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

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

    // WASM library build optimized for size
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding, // Use freestanding for minimal size
    });

    // Use the same optimization mode as specified by the user
    const wasm_optimize = optimize;

    // Create WASM-specific modules with minimal dependencies
    // Create WASM-specific primitives module without c-kzg
    const wasm_primitives_mod = b.createModule(.{
        .root_source_file = b.path("src/primitives/root.zig"),
        .target = wasm_target,
        .optimize = wasm_optimize,
    });
    // Note: WASM build excludes c-kzg-4844 (not available for WASM)

    // Create WASM-specific crypto module
    const wasm_crypto_mod = b.createModule(.{
        .root_source_file = b.path("src/crypto/root.zig"),
        .target = wasm_target,
        .optimize = wasm_optimize,
    });
    wasm_crypto_mod.addImport("primitives", wasm_primitives_mod);

    // Create WASM-specific EVM module without Rust dependencies
    const wasm_evm_mod = b.createModule(.{
        .root_source_file = b.path("src/evm/root.zig"),
        .target = wasm_target,
        .optimize = wasm_optimize,
    });
    wasm_evm_mod.addImport("primitives", wasm_primitives_mod);
    wasm_evm_mod.addImport("crypto", wasm_crypto_mod);
    wasm_evm_mod.addImport("build_options", build_options.createModule());
    // Note: WASM build uses pure Zig implementations for BN254 operations

    const wasm_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root_c.zig"),
        .target = wasm_target,
        .optimize = wasm_optimize,
        .single_threaded = true,
    });
    wasm_lib_mod.addImport("primitives", wasm_primitives_mod);
    wasm_lib_mod.addImport("evm", wasm_evm_mod); // Use WASM-specific EVM module

    const wasm_lib = b.addExecutable(.{
        .name = "guillotine",
        .root_module = wasm_lib_mod,
    });

    wasm_lib.entry = .disabled;
    wasm_lib.rdynamic = true;

    const wasm_install = b.addInstallArtifact(wasm_lib, .{ .dest_sub_path = "guillotine.wasm" });

    // Add step to report WASM bundle size
    const wasm_size_step = b.addSystemCommand(&[_][]const u8{ "sh", "-c", "echo '\\n=== WASM Bundle Size Report ===' && " ++
        "ls -lh zig-out/bin/guillotine.wasm | awk '{print \"WASM Bundle Size: \" $5}' && " ++
        "echo '=== End Report ===\\n'" });
    wasm_size_step.step.dependOn(&wasm_install.step);

    const wasm_step = b.step("wasm", "Build WASM library and show bundle size");
    wasm_step.dependOn(&wasm_size_step.step);

    // Debug WASM build for analysis
    const wasm_debug_mod = b.createModule(.{
        .root_source_file = b.path("src/root_c.zig"),
        .target = wasm_target,
        .optimize = .Debug, // Debug mode for symbols
        .single_threaded = true,
    });
    wasm_debug_mod.addImport("primitives", wasm_primitives_mod);
    wasm_debug_mod.addImport("evm", wasm_evm_mod);

    const wasm_debug = b.addExecutable(.{
        .name = "guillotine-debug",
        .root_module = wasm_debug_mod,
    });

    wasm_debug.entry = .disabled;
    wasm_debug.rdynamic = true;

    const wasm_debug_install = b.addInstallArtifact(wasm_debug, .{ .dest_sub_path = "../bin/guillotine-debug.wasm" });

    const wasm_debug_step = b.step("wasm-debug", "Build debug WASM for analysis");
    wasm_debug_step.dependOn(&wasm_debug_install.step);

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

    // Benchmark executable
    const bench_exe = b.addExecutable(.{
        .name = "guillotine-bench",
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    bench_exe.root_module.addImport("bench", bench_mod);
    bench_exe.root_module.addImport("zbench", zbench_dep.module("zbench"));
    bench_exe.root_module.addImport("evm", bench_evm_mod);  // Use the bench-specific EVM module
    bench_exe.root_module.addImport("primitives", primitives_mod);
    
    b.installArtifact(bench_exe);
    
    const run_bench_cmd = b.addRunArtifact(bench_exe);
    run_bench_cmd.step.dependOn(b.getInstallStep());
    
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench_cmd.step);

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
    const generate_assets = GenerateAssetsStep.init(b, "src/devtool/dist", "src/devtool/assets.zig");
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

    // Link webui library
    devtool_exe.linkLibrary(webui.artifact("webui"));

    // Link external libraries if needed for WebUI
    devtool_exe.linkLibC();
    if (target.result.os.tag == .macos) {
        devtool_exe.linkFramework("WebKit");
    }

    // Make devtool build depend on asset generation
    devtool_exe.step.dependOn(&generate_assets.step);

    b.installArtifact(devtool_exe);

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

    // Add Precompile SHA256 tests
    const sha256_test = b.addTest(.{
        .name = "sha256-test",
        .root_source_file = b.path("test/evm/precompiles/sha256_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sha256_test.root_module.stack_check = false;
    sha256_test.root_module.addImport("primitives", primitives_mod);
    sha256_test.root_module.addImport("evm", evm_mod);

    const run_sha256_test = b.addRunArtifact(sha256_test);
    const sha256_test_step = b.step("test-sha256", "Run SHA256 precompile tests");
    sha256_test_step.dependOn(&run_sha256_test.step);

    // Add RIPEMD160 precompile tests
    const ripemd160_test = b.addTest(.{
        .name = "ripemd160-test",
        .root_source_file = b.path("test/evm/precompiles/ripemd160_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    ripemd160_test.root_module.stack_check = false;
    ripemd160_test.root_module.addImport("primitives", primitives_mod);
    ripemd160_test.root_module.addImport("evm", evm_mod);

    const run_ripemd160_test = b.addRunArtifact(ripemd160_test);
    const ripemd160_test_step = b.step("test-ripemd160", "Run RIPEMD160 precompile tests");
    ripemd160_test_step.dependOn(&run_ripemd160_test.step);

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

    // Add BN254 Rust wrapper tests
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
    bn254_rust_test.linkLibrary(bn254_lib);
    bn254_rust_test.addIncludePath(b.path("src/bn254_wrapper"));

    const run_bn254_rust_test = b.addRunArtifact(bn254_rust_test);
    const bn254_rust_test_step = b.step("test-bn254-rust", "Run BN254 Rust wrapper precompile tests");
    bn254_rust_test_step.dependOn(&run_bn254_rust_test.step);

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
    test_step.dependOn(&run_stack_validation_test.step);
    test_step.dependOn(&run_jump_table_test.step);
    test_step.dependOn(&run_opcodes_test.step);
    test_step.dependOn(&run_vm_opcode_test.step);
    test_step.dependOn(&run_integration_test.step);
    test_step.dependOn(&run_gas_test.step);
    test_step.dependOn(&run_static_protection_test.step);
    test_step.dependOn(&run_sha256_test.step);
    test_step.dependOn(&run_ripemd160_test.step);
    test_step.dependOn(&run_blake2f_test.step);
    test_step.dependOn(&run_bn254_rust_test.step);
    test_step.dependOn(&run_e2e_simple_test.step);
    test_step.dependOn(&run_e2e_error_test.step);
    test_step.dependOn(&run_e2e_data_test.step);
    test_step.dependOn(&run_e2e_inheritance_test.step);
    test_step.dependOn(&run_constructor_bug_test.step);
    test_step.dependOn(&run_solidity_constructor_test.step);
    test_step.dependOn(&run_contract_call_test.step);
    // Hardfork tests removed completely
    test_step.dependOn(&run_delegatecall_test.step);
    // TODO: Re-enable when Rust integration is fixed
    // test_step.dependOn(&run_compiler_test.step);
    // test_step.dependOn(&run_snail_tracer_test.step);

    // Add Fuzz Testing
    const fuzz_stack_test = b.addTest(.{
        .name = "fuzz-stack-test",
        .root_source_file = b.path("test/fuzz/stack_fuzz_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_stack_test.root_module.addImport("evm", evm_mod);

    const run_fuzz_stack_test = b.addRunArtifact(fuzz_stack_test);
    const fuzz_stack_test_step = b.step("fuzz-stack", "Run stack fuzz tests");
    fuzz_stack_test_step.dependOn(&run_fuzz_stack_test.step);

    const fuzz_memory_test = b.addTest(.{
        .name = "fuzz-memory-test",
        .root_source_file = b.path("test/fuzz/memory_fuzz_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_memory_test.root_module.addImport("evm", evm_mod);

    const run_fuzz_memory_test = b.addRunArtifact(fuzz_memory_test);
    const fuzz_memory_test_step = b.step("fuzz-memory", "Run memory fuzz tests");
    fuzz_memory_test_step.dependOn(&run_fuzz_memory_test.step);

    const fuzz_arithmetic_test = b.addTest(.{
        .name = "fuzz-arithmetic-test",
        .root_source_file = b.path("test/fuzz/arithmetic_fuzz_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_arithmetic_test.root_module.addImport("evm", evm_mod);
    fuzz_arithmetic_test.root_module.addImport("primitives", primitives_mod);

    const run_fuzz_arithmetic_test = b.addRunArtifact(fuzz_arithmetic_test);
    const fuzz_arithmetic_test_step = b.step("fuzz-arithmetic", "Run arithmetic fuzz tests");
    fuzz_arithmetic_test_step.dependOn(&run_fuzz_arithmetic_test.step);

    const fuzz_bitwise_test = b.addTest(.{
        .name = "fuzz-bitwise-test",
        .root_source_file = b.path("test/fuzz/bitwise_fuzz_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_bitwise_test.root_module.addImport("evm", evm_mod);
    fuzz_bitwise_test.root_module.addImport("primitives", primitives_mod);

    const run_fuzz_bitwise_test = b.addRunArtifact(fuzz_bitwise_test);
    const fuzz_bitwise_test_step = b.step("fuzz-bitwise", "Run bitwise fuzz tests");
    fuzz_bitwise_test_step.dependOn(&run_fuzz_bitwise_test.step);

    const fuzz_comparison_test = b.addTest(.{
        .name = "fuzz-comparison-test",
        .root_source_file = b.path("test/fuzz/comparison_fuzz_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_comparison_test.root_module.addImport("evm", evm_mod);
    fuzz_comparison_test.root_module.addImport("primitives", primitives_mod);

    const run_fuzz_comparison_test = b.addRunArtifact(fuzz_comparison_test);
    const fuzz_comparison_test_step = b.step("fuzz-comparison", "Run comparison fuzz tests");
    fuzz_comparison_test_step.dependOn(&run_fuzz_comparison_test.step);

    const fuzz_control_test = b.addTest(.{
        .name = "fuzz-control-test",
        .root_source_file = b.path("test/fuzz/control_fuzz_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_control_test.root_module.addImport("evm", evm_mod);
    fuzz_control_test.root_module.addImport("primitives", primitives_mod);

    const run_fuzz_control_test = b.addRunArtifact(fuzz_control_test);
    const fuzz_control_test_step = b.step("fuzz-control", "Run control fuzz tests");
    fuzz_control_test_step.dependOn(&run_fuzz_control_test.step);

    const fuzz_crypto_test = b.addTest(.{
        .name = "fuzz-crypto-test",
        .root_source_file = b.path("test/fuzz/crypto_fuzz_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_crypto_test.root_module.addImport("evm", evm_mod);
    fuzz_crypto_test.root_module.addImport("primitives", primitives_mod);

    const run_fuzz_crypto_test = b.addRunArtifact(fuzz_crypto_test);
    const fuzz_crypto_test_step = b.step("fuzz-crypto", "Run crypto fuzz tests");
    fuzz_crypto_test_step.dependOn(&run_fuzz_crypto_test.step);

    const fuzz_environment_test = b.addTest(.{
        .name = "fuzz-environment-test",
        .root_source_file = b.path("test/fuzz/environment_fuzz_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_environment_test.root_module.addImport("evm", evm_mod);
    fuzz_environment_test.root_module.addImport("primitives", primitives_mod);

    const run_fuzz_environment_test = b.addRunArtifact(fuzz_environment_test);
    const fuzz_environment_test_step = b.step("fuzz-environment", "Run environment fuzz tests");
    fuzz_environment_test_step.dependOn(&run_fuzz_environment_test.step);

    const fuzz_storage_test = b.addTest(.{
        .name = "fuzz-storage-test",
        .root_source_file = b.path("test/fuzz/storage_fuzz_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_storage_test.root_module.addImport("evm", evm_mod);
    fuzz_storage_test.root_module.addImport("primitives", primitives_mod);

    const run_fuzz_storage_test = b.addRunArtifact(fuzz_storage_test);
    const fuzz_storage_test_step = b.step("fuzz-storage", "Run storage fuzz tests");
    fuzz_storage_test_step.dependOn(&run_fuzz_storage_test.step);

    // Add State Fuzz Testing
    const fuzz_state_test = b.addTest(.{
        .name = "fuzz-state-test",
        .root_source_file = b.path("test/fuzz/state_fuzz_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_state_test.root_module.addImport("evm", evm_mod);
    fuzz_state_test.root_module.addImport("primitives", primitives_mod);
    const run_fuzz_state_test = b.addRunArtifact(fuzz_state_test);
    const fuzz_state_test_step = b.step("fuzz-state", "Run state fuzz tests");
    fuzz_state_test_step.dependOn(&run_fuzz_state_test.step);

    // Combined fuzz test step
    const fuzz_test_step = b.step("fuzz", "Run all fuzz tests");
    fuzz_test_step.dependOn(&run_fuzz_stack_test.step);
    fuzz_test_step.dependOn(&run_fuzz_memory_test.step);
    fuzz_test_step.dependOn(&run_fuzz_arithmetic_test.step);
    fuzz_test_step.dependOn(&run_fuzz_bitwise_test.step);
    fuzz_test_step.dependOn(&run_fuzz_comparison_test.step);
    fuzz_test_step.dependOn(&run_fuzz_control_test.step);
    fuzz_test_step.dependOn(&run_fuzz_crypto_test.step);
    fuzz_test_step.dependOn(&run_fuzz_environment_test.step);
    fuzz_test_step.dependOn(&run_fuzz_storage_test.step);
    fuzz_test_step.dependOn(&run_fuzz_state_test.step);

    // Documentation generation step
    const docs_step = b.step("docs", "Generate and install documentation");
    const docs_install = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&docs_install.step);
}
