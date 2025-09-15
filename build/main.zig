const std = @import("std");

// Build configuration and options
pub const Config = @import("config.zig");

// Module definitions
pub const Modules = @import("modules.zig");

// Executables
pub const GuillotineExe = @import("executables/guillotine.zig");
pub const DevtoolExe = @import("executables/devtool.zig");
pub const EvmRunnerExe = @import("executables/evm_runner.zig");
pub const BenchmarksExe = @import("executables/benchmarks.zig");

// Libraries
pub const BlstLib = @import("libraries/blst.zig");
pub const CKzgLib = @import("libraries/c_kzg.zig");
pub const Bn254Lib = @import("libraries/bn254.zig");
// RevmLib removed - using MinimalEvm for differential testing
pub const FoundryLib = @import("libraries/foundry.zig");

// Language bindings
pub const WasmBindings = @import("bindings/wasm.zig");
pub const PythonBindings = @import("bindings/python.zig");
pub const SwiftBindings = @import("bindings/swift.zig");
pub const GoBindings = @import("bindings/go.zig");
pub const TypeScriptBindings = @import("bindings/typescript.zig");

// Build steps (existing)
pub const RustBuild = @import("steps/rust_build.zig");
pub const AssetGenerator = @import("steps/asset_generator.zig");
pub const Tests = @import("steps/tests_integration.zig");
