const std = @import("std");
const modules = @import("modules.zig");

pub fn setupTests(b: *std.Build, mods: modules.Modules, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const test_step = b.step("test", "Run unit tests");

    // Library unit tests
    const lib_unit_tests = b.addTest(.{
        .root_module = mods.lib,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    test_step.dependOn(&run_lib_unit_tests.step);

    // Executable unit tests
    const exe_unit_tests = b.addTest(.{
        .root_module = mods.exe,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    test_step.dependOn(&run_exe_unit_tests.step);

    // Memory tests
    const memory_test = b.addTest(.{
        .name = "memory-test",
        .root_source_file = b.path("test/evm/memory_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    memory_test.root_module.addImport("evm", mods.evm);
    memory_test.root_module.addImport("primitives", mods.primitives);
    const run_memory_test = b.addRunArtifact(memory_test);
    const memory_test_step = b.step("test-memory", "Run Memory tests");
    memory_test_step.dependOn(&run_memory_test.step);
    test_step.dependOn(&run_memory_test.step);

    // Memory Leak tests
    const memory_leak_test = b.addTest(.{
        .name = "memory-leak-test",
        .root_source_file = b.path("test/evm/memory_leak_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    memory_leak_test.root_module.addImport("evm", mods.evm);
    memory_leak_test.root_module.addImport("primitives", mods.primitives);
    const run_memory_leak_test = b.addRunArtifact(memory_leak_test);
    const memory_leak_test_step = b.step("test-memory-leak", "Run Memory leak prevention tests");
    memory_leak_test_step.dependOn(&run_memory_leak_test.step);

    // Stack tests
    const stack_test = b.addTest(.{
        .name = "stack-test",
        .root_source_file = b.path("test/evm/stack_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    stack_test.root_module.addImport("evm", mods.evm);
    const run_stack_test = b.addRunArtifact(stack_test);
    const stack_test_step = b.step("test-stack", "Run Stack tests");
    stack_test_step.dependOn(&run_stack_test.step);
    test_step.dependOn(&run_stack_test.step);

    // New EVM tests
    const newevm_test = b.addTest(.{
        .name = "newevm-test",
        .root_source_file = b.path("src/evm/newevm_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    newevm_test.root_module.addImport("evm", mods.evm);
    newevm_test.root_module.addImport("primitives", mods.primitives);
    const run_newevm_test = b.addRunArtifact(newevm_test);
    const newevm_test_step = b.step("test-newevm", "Run new EVM tests");
    newevm_test_step.dependOn(&run_newevm_test.step);
    test_step.dependOn(&run_newevm_test.step);

    // Arithmetic opcode tests
    const newevm_arithmetic_test = b.addTest(.{
        .name = "newevm-arithmetic-test",
        .root_source_file = b.path("test/evm/opcodes/arithmetic_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    newevm_arithmetic_test.root_module.addImport("evm", mods.evm);
    newevm_arithmetic_test.root_module.addImport("primitives", mods.primitives);
    const run_newevm_arithmetic_test = b.addRunArtifact(newevm_arithmetic_test);
    newevm_test_step.dependOn(&run_newevm_arithmetic_test.step);

    // Bitwise opcode tests
    const newevm_bitwise_test = b.addTest(.{
        .name = "newevm-bitwise-test",
        .root_source_file = b.path("test/evm/opcodes/bitwise_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    newevm_bitwise_test.root_module.addImport("evm", mods.evm);
    newevm_bitwise_test.root_module.addImport("primitives", mods.primitives);
    const run_newevm_bitwise_test = b.addRunArtifact(newevm_bitwise_test);
    newevm_test_step.dependOn(&run_newevm_bitwise_test.step);

    // Comparison opcode tests
    const newevm_comparison_test = b.addTest(.{
        .name = "newevm-comparison-test",
        .root_source_file = b.path("test/evm/opcodes/comparison_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    newevm_comparison_test.root_module.addImport("evm", mods.evm);
    newevm_comparison_test.root_module.addImport("primitives", mods.primitives);
    const run_newevm_comparison_test = b.addRunArtifact(newevm_comparison_test);
    newevm_test_step.dependOn(&run_newevm_comparison_test.step);

    // Block opcode tests
    const newevm_block_test = b.addTest(.{
        .name = "newevm-block-test",
        .root_source_file = b.path("test/evm/opcodes/block_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    newevm_block_test.root_module.addImport("evm", mods.evm);
    newevm_block_test.root_module.addImport("primitives", mods.primitives);
    const run_newevm_block_test = b.addRunArtifact(newevm_block_test);
    newevm_test_step.dependOn(&run_newevm_block_test.step);

    // Control opcode tests
    const newevm_control_test = b.addTest(.{
        .name = "newevm-control-test",
        .root_source_file = b.path("test/evm/opcodes/control_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    newevm_control_test.root_module.addImport("evm", mods.evm);
    newevm_control_test.root_module.addImport("primitives", mods.primitives);
    const run_newevm_control_test = b.addRunArtifact(newevm_control_test);
    newevm_test_step.dependOn(&run_newevm_control_test.step);

    // Environment opcode tests
    const newevm_environment_test = b.addTest(.{
        .name = "newevm-environment-test",
        .root_source_file = b.path("test/evm/opcodes/environment_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    newevm_environment_test.root_module.addImport("evm", mods.evm);
    newevm_environment_test.root_module.addImport("primitives", mods.primitives);
    const run_newevm_environment_test = b.addRunArtifact(newevm_environment_test);
    newevm_test_step.dependOn(&run_newevm_environment_test.step);

    // Memory opcode tests
    const newevm_memory_test = b.addTest(.{
        .name = "newevm-memory-test",
        .root_source_file = b.path("test/evm/opcodes/memory_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    newevm_memory_test.root_module.addImport("evm", mods.evm);
    newevm_memory_test.root_module.addImport("primitives", mods.primitives);
    const run_newevm_memory_test = b.addRunArtifact(newevm_memory_test);
    newevm_test_step.dependOn(&run_newevm_memory_test.step);

    // Stack opcode tests
    const newevm_stack_test = b.addTest(.{
        .name = "newevm-stack-test",
        .root_source_file = b.path("test/evm/opcodes/stack_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    newevm_stack_test.root_module.addImport("evm", mods.evm);
    newevm_stack_test.root_module.addImport("primitives", mods.primitives);
    const run_newevm_stack_test = b.addRunArtifact(newevm_stack_test);
    newevm_test_step.dependOn(&run_newevm_stack_test.step);

    // Storage opcode tests
    const newevm_storage_test = b.addTest(.{
        .name = "newevm-storage-test",
        .root_source_file = b.path("test/evm/opcodes/storage_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    newevm_storage_test.root_module.addImport("evm", mods.evm);
    newevm_storage_test.root_module.addImport("primitives", mods.primitives);
    const run_newevm_storage_test = b.addRunArtifact(newevm_storage_test);
    newevm_test_step.dependOn(&run_newevm_storage_test.step);

    // System opcode tests
    const newevm_system_test = b.addTest(.{
        .name = "newevm-system-test",
        .root_source_file = b.path("test/evm/opcodes/system_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    newevm_system_test.root_module.addImport("evm", mods.evm);
    newevm_system_test.root_module.addImport("primitives", mods.primitives);
    const run_newevm_system_test = b.addRunArtifact(newevm_system_test);
    newevm_test_step.dependOn(&run_newevm_system_test.step);

    // Crypto opcode tests
    const newevm_crypto_test = b.addTest(.{
        .name = "newevm-crypto-test",
        .root_source_file = b.path("test/evm/opcodes/crypto_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    newevm_crypto_test.root_module.addImport("evm", mods.evm);
    newevm_crypto_test.root_module.addImport("primitives", mods.primitives);
    const run_newevm_crypto_test = b.addRunArtifact(newevm_crypto_test);
    newevm_test_step.dependOn(&run_newevm_crypto_test.step);

    // Stack validation tests
    const stack_validation_test = b.addTest(.{
        .name = "stack-validation-test",
        .root_source_file = b.path("test/evm/stack_validation_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    stack_validation_test.root_module.addImport("evm", mods.evm);
    stack_validation_test.root_module.addImport("primitives", mods.primitives);
    const run_stack_validation_test = b.addRunArtifact(stack_validation_test);
    const stack_validation_test_step = b.step("test-stack-validation", "Run Stack validation tests");
    stack_validation_test_step.dependOn(&run_stack_validation_test.step);
    test_step.dependOn(&run_stack_validation_test.step);

    // Jump table tests
    const jump_table_test = b.addTest(.{
        .name = "jump-table-test",
        .root_source_file = b.path("test/evm/jump_table_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    jump_table_test.root_module.addImport("evm", mods.evm);
    jump_table_test.root_module.addImport("primitives", mods.primitives);
    const run_jump_table_test = b.addRunArtifact(jump_table_test);
    const jump_table_test_step = b.step("test-jump-table", "Run Jump table tests");
    jump_table_test_step.dependOn(&run_jump_table_test.step);
    test_step.dependOn(&run_jump_table_test.step);


    // VM opcode tests
    const vm_opcode_test = b.addTest(.{
        .name = "vm-opcode-test",
        .root_source_file = b.path("test/evm/vm_opcode_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    vm_opcode_test.root_module.addImport("evm", mods.evm);
    vm_opcode_test.root_module.addImport("primitives", mods.primitives);
    const run_vm_opcode_test = b.addRunArtifact(vm_opcode_test);
    const vm_opcode_test_step = b.step("test-vm-opcode", "Run VM opcode tests");
    vm_opcode_test_step.dependOn(&run_vm_opcode_test.step);
    test_step.dependOn(&run_vm_opcode_test.step);

    // Inline ops test
    const inline_ops_test = b.addTest(.{
        .name = "inline-ops-test",
        .root_source_file = b.path("test/evm/inline_ops_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    inline_ops_test.root_module.stack_check = false;
    inline_ops_test.root_module.addImport("evm", mods.evm);
    inline_ops_test.root_module.addImport("primitives", mods.primitives);
    const run_inline_ops_test = b.addRunArtifact(inline_ops_test);
    const inline_ops_test_step = b.step("test-inline-ops", "Run inline ops tests");
    inline_ops_test_step.dependOn(&run_inline_ops_test.step);
    test_step.dependOn(&run_inline_ops_test.step);

    // Contract call test
    const contract_call_test = b.addTest(.{
        .name = "contract-call-test",
        .root_source_file = b.path("test/evm/contract_call_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    contract_call_test.root_module.addImport("evm", mods.evm);
    contract_call_test.root_module.addImport("primitives", mods.primitives);
    const run_contract_call_test = b.addRunArtifact(contract_call_test);
    const contract_call_test_step = b.step("test-contract-call", "Run contract call tests");
    contract_call_test_step.dependOn(&run_contract_call_test.step);
    test_step.dependOn(&run_contract_call_test.step);


}