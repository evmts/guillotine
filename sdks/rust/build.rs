use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=wrapper.h");
    println!("cargo:rerun-if-changed=../../src");
    println!("cargo:rerun-if-changed=../../build.zig");
    
    let out_dir = env::var("OUT_DIR").unwrap();
    let manifest_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
    
    // For docs.rs, we need to handle the special case where we can't build
    if env::var("DOCS_RS").is_ok() {
        println!("cargo:warning=Building on docs.rs - compilation skipped");
        generate_bindings(&out_dir, &manifest_dir);
        return;
    }
    
    // Determine if we're in the Guillotine repository or a published crate
    let project_root = Path::new(&manifest_dir)
        .parent().unwrap()  // sdks/
        .parent().unwrap(); // Guillotine root
    
    let src_dir = project_root.join("src");
    let build_zig = project_root.join("build.zig");
    
    let build_dir = if src_dir.exists() && build_zig.exists() {
        // Local development - build from source in repo
        println!("cargo:warning=Building from local Guillotine source");
        project_root.to_path_buf()
    } else {
        // Published crate - need to clone/download source
        println!("cargo:warning=Downloading Guillotine source for build");
        download_and_prepare_source(&out_dir)
    };
    
    // Build the static library from source
    build_guillotine_library(&build_dir);
    
    // Link the built library - check for both possible names
    let zig_out = build_dir.join("zig-out").join("lib");
    println!("cargo:rustc-link-search=native={}", zig_out.display());
    
    // Check which library was actually built
    if zig_out.join("libguillotine_ffi_static.a").exists() {
        println!("cargo:rustc-link-lib=static=guillotine_ffi_static");
    } else if zig_out.join("libguillotine_ffi.a").exists() {
        println!("cargo:rustc-link-lib=static=guillotine_ffi");
    } else if zig_out.join("libGuillotine.a").exists() {
        println!("cargo:rustc-link-lib=static=Guillotine");
    } else {
        // Try the default name anyway
        println!("cargo:rustc-link-lib=static=guillotine_ffi_static");
    }
    
    // Link system libraries
    if cfg!(target_os = "macos") {
        println!("cargo:rustc-link-lib=c++");
    } else if cfg!(target_os = "linux") {
        println!("cargo:rustc-link-lib=stdc++");
    }
    
    // Generate bindings
    generate_bindings(&out_dir, &manifest_dir);
}

fn download_and_prepare_source(out_dir: &str) -> PathBuf {
    let guillotine_dir = Path::new(out_dir).join("guillotine-src");
    
    // Skip if already downloaded
    if guillotine_dir.join("build.zig").exists() {
        return guillotine_dir;
    }
    
    // Clone the repository (shallow clone for speed)
    let status = Command::new("git")
        .args(&[
            "clone",
            "--depth", "1",
            "--recursive",
            "https://github.com/evmts/guillotine.git",
            guillotine_dir.to_str().unwrap()
        ])
        .status()
        .expect("Failed to clone Guillotine repository. Is git installed?");
    
    if !status.success() {
        panic!("Failed to download Guillotine source code");
    }
    
    // Download KZG trusted setup if it doesn't exist
    let kzg_path = guillotine_dir.join("src/kzg/trusted_setup.txt");
    if !kzg_path.exists() {
        println!("cargo:warning=Downloading KZG trusted setup...");
        std::fs::create_dir_all(kzg_path.parent().unwrap()).ok();
        
        let status = Command::new("curl")
            .args(&[
                "-L",
                "-o",
                kzg_path.to_str().unwrap(),
                "https://github.com/ethereum/c-kzg-4844/raw/main/src/trusted_setup.txt"
            ])
            .status()
            .expect("Failed to download KZG trusted setup. Is curl installed?");
        
        if !status.success() {
            panic!("Failed to download KZG trusted setup");
        }
    }
    
    guillotine_dir
}

fn build_guillotine_library(project_dir: &Path) {
    // Check for Zig compiler
    let zig_version = Command::new("zig")
        .arg("version")
        .output();
    
    if zig_version.is_err() {
        panic!(
            "\n\n\
            ========================================\n\
            ERROR: Zig compiler not found!\n\
            ========================================\n\
            \n\
            This package requires Zig to build the Guillotine EVM.\n\
            \n\
            Please install Zig 0.15.1 or later:\n\
              https://ziglang.org/download/\n\
            \n\
            On macOS:    brew install zig\n\
            On Ubuntu:   snap install zig --classic\n\
            On Windows:  winget install zig.zig\n\
            "
        );
    }
    
    // Map Rust profile to Zig optimization mode
    let profile = env::var("PROFILE").unwrap_or_else(|_| "debug".to_string());
    let opt_level = env::var("OPT_LEVEL").unwrap_or_else(|_| "0".to_string());
    let debug = env::var("DEBUG").unwrap_or_else(|_| "true".to_string());
    
    let zig_optimize = match (profile.as_str(), opt_level.as_str(), debug.as_str()) {
        ("release", "3", _) => "ReleaseFast",     // cargo build --release (default)
        ("release", "s" | "z", _) => "ReleaseSmall", // cargo build --release with opt-level = "s" or "z"
        ("release", _, _) => "ReleaseSafe",       // cargo build --release with opt-level = 1 or 2
        _ => "Debug",                              // cargo build (debug mode)
    };
    
    println!("cargo:warning=Building Guillotine with Zig (optimization: {}) - this may take a few minutes on first build", zig_optimize);
    
    // Collect build arguments based on enabled features
    let optimize_arg = format!("-Doptimize={}", zig_optimize);
    let mut build_args = vec!["build", "static"];
    let mut extra_args = vec![optimize_arg.clone()];
    
    // Check for hardfork features
    if cfg!(feature = "hardfork-frontier") {
        extra_args.push("-Devm-hardfork=FRONTIER".to_string());
    } else if cfg!(feature = "hardfork-homestead") {
        extra_args.push("-Devm-hardfork=HOMESTEAD".to_string());
    } else if cfg!(feature = "hardfork-byzantium") {
        extra_args.push("-Devm-hardfork=BYZANTIUM".to_string());
    } else if cfg!(feature = "hardfork-berlin") {
        extra_args.push("-Devm-hardfork=BERLIN".to_string());
    } else if cfg!(feature = "hardfork-london") {
        extra_args.push("-Devm-hardfork=LONDON".to_string());
    } else if cfg!(feature = "hardfork-shanghai") {
        extra_args.push("-Devm-hardfork=SHANGHAI".to_string());
    } else if cfg!(feature = "hardfork-cancun") {
        extra_args.push("-Devm-hardfork=CANCUN".to_string());
    }
    
    // Check for optimization strategy features
    if cfg!(feature = "optimize-fast") {
        extra_args.push("-Devm-optimize=fast".to_string());
    } else if cfg!(feature = "optimize-small") {
        extra_args.push("-Devm-optimize=small".to_string());
    } else if cfg!(feature = "optimize-safe") {
        extra_args.push("-Devm-optimize=safe".to_string());
    }
    
    // Check for configuration features
    if cfg!(feature = "max-call-depth-256") {
        extra_args.push("-Devm-max-call-depth=256".to_string());
    } else if cfg!(feature = "max-call-depth-512") {
        extra_args.push("-Devm-max-call-depth=512".to_string());
    } else if cfg!(feature = "max-call-depth-2048") {
        extra_args.push("-Devm-max-call-depth=2048".to_string());
    }
    
    if cfg!(feature = "stack-size-256") {
        extra_args.push("-Devm-stack-size=256".to_string());
    } else if cfg!(feature = "stack-size-512") {
        extra_args.push("-Devm-stack-size=512".to_string());
    } else if cfg!(feature = "stack-size-2048") {
        extra_args.push("-Devm-stack-size=2048".to_string());
    }
    
    if cfg!(feature = "disable-precompiles") {
        extra_args.push("-Dno_precompiles=true".to_string());
    }
    
    if cfg!(feature = "disable-fusion") {
        extra_args.push("-Devm-disable-fusion=true".to_string());
    }
    
    if cfg!(feature = "disable-gas-checks") {
        extra_args.push("-Devm-disable-gas=true".to_string());
    }
    
    if cfg!(feature = "disable-balance-checks") {
        extra_args.push("-Devm-disable-balance=true".to_string());
    }
    
    // Input size configuration (not directly supported in build system)
    // These features are documented but don't map to Zig build options yet
    // Users would need to modify EvmConfig directly for now
    if cfg!(feature = "max-input-size-64kb") {
        println!("cargo:warning=max-input-size-64kb feature is documented but requires EvmConfig modification");
    } else if cfg!(feature = "max-input-size-256kb") {
        println!("cargo:warning=max-input-size-256kb feature is documented but requires EvmConfig modification");
    } else if cfg!(feature = "max-input-size-1mb") {
        println!("cargo:warning=max-input-size-1mb feature is documented but requires EvmConfig modification");
    }

    // Bytecode size configuration
    if cfg!(feature = "max-bytecode-size-12kb") {
        extra_args.push("-Devm-max-bytecode=12288".to_string());
    } else if cfg!(feature = "max-bytecode-size-48kb") {
        extra_args.push("-Devm-max-bytecode=49152".to_string());
    } else if cfg!(feature = "max-bytecode-size-100kb") {
        extra_args.push("-Devm-max-bytecode=102400".to_string());
    }

    // Init code size configuration
    if cfg!(feature = "max-initcode-size-24kb") {
        extra_args.push("-Devm-max-initcode=24576".to_string());
    } else if cfg!(feature = "max-initcode-size-96kb") {
        extra_args.push("-Devm-max-initcode=98304".to_string());
    } else if cfg!(feature = "max-initcode-size-200kb") {
        extra_args.push("-Devm-max-initcode=204800".to_string());
    }

    // Memory initial capacity configuration
    if cfg!(feature = "memory-initial-capacity-2kb") {
        extra_args.push("-Devm-memory-init=2048".to_string());
    } else if cfg!(feature = "memory-initial-capacity-8kb") {
        extra_args.push("-Devm-memory-init=8192".to_string());
    } else if cfg!(feature = "memory-initial-capacity-16kb") {
        extra_args.push("-Devm-memory-init=16384".to_string());
    }

    // Memory limit configuration
    if cfg!(feature = "large-memory-limit") {
        extra_args.push("-Devm-memory-limit=67108864".to_string()); // 64MB
    } else if cfg!(feature = "small-memory-limit") {
        extra_args.push("-Devm-memory-limit=1048576".to_string()); // 1MB
    }

    // Arena configuration
    if cfg!(feature = "large-arena") {
        extra_args.push("-Devm-arena-capacity=134217728".to_string()); // 128MB
    } else if cfg!(feature = "small-arena") {
        extra_args.push("-Devm-arena-capacity=16777216".to_string()); // 16MB
    }

    // Arena growth factor (not directly supported in Zig build system)
    if cfg!(feature = "arena-growth-125") {
        println!("cargo:warning=arena-growth-125 feature is documented but requires EvmConfig modification");
    } else if cfg!(feature = "arena-growth-200") {
        println!("cargo:warning=arena-growth-200 feature is documented but requires EvmConfig modification");
    }

    // Block gas limit configuration
    if cfg!(feature = "block-gas-limit-8m") {
        extra_args.push("-Devm-block-gas-limit=8000000".to_string());
    } else if cfg!(feature = "block-gas-limit-15m") {
        extra_args.push("-Devm-block-gas-limit=15000000".to_string());
    } else if cfg!(feature = "block-gas-limit-50m") {
        extra_args.push("-Devm-block-gas-limit=50000000".to_string());
    }

    // SIMD/Vector length configuration (not directly supported in build system)
    if cfg!(feature = "vector-length-1") {
        println!("cargo:warning=vector-length-1 feature is documented but requires EvmConfig modification");
    } else if cfg!(feature = "vector-length-4") {
        println!("cargo:warning=vector-length-4 feature is documented but requires EvmConfig modification");
    } else if cfg!(feature = "vector-length-8") {
        println!("cargo:warning=vector-length-8 feature is documented but requires EvmConfig modification");
    } else if cfg!(feature = "vector-length-16") {
        println!("cargo:warning=vector-length-16 feature is documented but requires EvmConfig modification");
    }

    // Safety configuration (not directly supported in build system)
    if cfg!(feature = "disable-loop-quota") {
        println!("cargo:warning=disable-loop-quota feature is documented but requires EvmConfig modification");
    } else if cfg!(feature = "loop-quota-100k") {
        println!("cargo:warning=loop-quota-100k feature is documented but requires EvmConfig modification");
    } else if cfg!(feature = "loop-quota-10m") {
        println!("cargo:warning=loop-quota-10m feature is documented but requires EvmConfig modification");
    }

    // Feature flags
    if cfg!(feature = "enable-fusion") {
        extra_args.push("-Devm-enable-fusion=true".to_string());
    }

    if cfg!(feature = "enable-precompiles") {
        // Default is enabled, so this is mostly for explicit documentation
    }

    if cfg!(feature = "tracing") {
        extra_args.push("-Denable-tracing=true".to_string());
    }
    
    // Debug: Print which features are enabled
    if !extra_args.is_empty() {
        println!("cargo:warning=Configuring EVM with features: {:?}", extra_args);
    }
    
    // Add extra args references to build_args
    for arg in &extra_args {
        build_args.push(arg.as_str());
    }
    
    // Build the static library with Zig
    // First try 'static' step, fall back to default install if not available
    let mut output = Command::new("zig")
        .current_dir(project_dir)
        .args(&build_args)
        .output()
        .expect("Failed to execute zig build");
    
    // If 'static' step doesn't exist, try default build
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        if stderr.contains("no step named 'static'") {
            println!("cargo:warning=Static build step not found, using default build");
            output = Command::new("zig")
                .current_dir(project_dir)
                .args(&["build", &format!("-Doptimize={}", zig_optimize)])
                .output()
                .expect("Failed to execute zig build");
        }
    }
    
    if !output.status.success() {
        eprintln!("Zig build output:");
        eprintln!("{}", String::from_utf8_lossy(&output.stdout));
        eprintln!("{}", String::from_utf8_lossy(&output.stderr));
        panic!("Failed to build Guillotine library");
    }
    
    // Also build the Rust dependencies (bn254, revm wrappers)
    println!("cargo:warning=Building Rust crypto dependencies");
    
    // Build Rust dependencies with matching profile
    let cargo_args = if profile == "release" {
        vec!["build", "--release"]
    } else {
        vec!["build"]
    };
    
    let cargo_output = Command::new("cargo")
        .current_dir(project_dir)
        .args(&cargo_args)
        .env("CARGO_TARGET_DIR", project_dir.join("target"))
        .output()
        .expect("Failed to execute cargo build");
    
    if !cargo_output.status.success() {
        eprintln!("Cargo build output:");
        eprintln!("{}", String::from_utf8_lossy(&cargo_output.stdout));
        eprintln!("{}", String::from_utf8_lossy(&cargo_output.stderr));
        panic!("Failed to build Rust dependencies");
    }
    
    // Link the Rust crypto libraries from the appropriate profile directory
    let rust_profile_dir = if profile == "release" { "release" } else { "debug" };
    let target_dir = project_dir.join("target").join(rust_profile_dir);
    println!("cargo:rustc-link-search=native={}", target_dir.display());
    println!("cargo:rustc-link-lib=static=bn254_wrapper");
    println!("cargo:rustc-link-lib=static=revm_wrapper");
}

fn generate_bindings(out_dir: &str, manifest_dir: &str) {
    let project_root = Path::new(manifest_dir).parent().unwrap().parent().unwrap();
    let src_path = project_root.join("src");
    
    let mut builder = bindgen::Builder::default()
        .header("wrapper.h")
        .allowlist_function("guillotine_.*")
        .allowlist_type("BlockInfoFFI")
        .allowlist_type("CallParams")
        .allowlist_type("EvmResult")
        .allowlist_type("EvmHandle")
        .allowlist_type("LogEntry")
        .allowlist_type("SelfDestructRecord")
        .allowlist_type("StorageAccessRecord");
    
    // Add include paths if we have access to source
    if src_path.exists() {
        builder = builder
            .clang_arg(format!("-I{}", src_path.display()))
            .clang_arg(format!("-I{}/primitives", src_path.display()))
            .clang_arg(format!("-I{}/evm", src_path.display()));
    }
    
    let bindings = builder
        .generate()
        .expect("Unable to generate bindings");
    
    let out_path = PathBuf::from(out_dir);
    bindings
        .write_to_file(out_path.join("bindings.rs"))
        .expect("Couldn't write bindings!");
}