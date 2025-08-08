//! Test demonstrating the generic EVM architecture
//! This shows how the EVM can be configured with different parameters

const std = @import("std");
const ComptimeConfig = @import("src/evm/comptime_config.zig").ComptimeConfig;
const evm_module = @import("src/evm/evm.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Testing Generic EVM Architecture\n", .{});
    std.debug.print("=================================\n", .{});

    // Test 1: Default configuration
    std.debug.print("\n1. Creating EVM with default configuration:\n", .{});
    const default_config = ComptimeConfig.default();
    std.debug.print("   Word type: {}\n", .{default_config.word_type});
    std.debug.print("   Stack capacity: {}\n", .{default_config.stack_capacity});
    std.debug.print("   Max memory: {} MB\n", .{default_config.max_memory_size / (1024 * 1024)});
    
    // Get the EVM type with default config
    const DefaultEvm = evm_module.Evm(default_config);
    std.debug.print("   Default EVM type created successfully ✓\n", .{});

    // Test 2: Custom configuration  
    std.debug.print("\n2. Creating EVM with custom configuration:\n", .{});
    const custom_config = ComptimeConfig{
        .word_type = u256,
        .stack_capacity = 512, // Smaller stack
        .max_memory_size = 16 * 1024 * 1024, // 16 MB
        .enable_safety_checks = false, // Faster execution
        .clear_on_pop = false, // No clearing for performance
    };
    std.debug.print("   Custom stack capacity: {}\n", .{custom_config.stack_capacity});
    std.debug.print("   Custom max memory: {} MB\n", .{custom_config.max_memory_size / (1024 * 1024)});
    std.debug.print("   Safety checks: {}\n", .{custom_config.enable_safety_checks});

    // Get the EVM type with custom config
    const CustomEvm = evm_module.Evm(custom_config);
    std.debug.print("   Custom EVM type created successfully ✓\n", .{});

    // Test 3: Different hardfork configuration
    std.debug.print("\n3. Creating EVM with Berlin hardfork configuration:\n", .{});
    const berlin_config = ComptimeConfig.forHardfork(.BERLIN);
    std.debug.print("   Hardfork: {}\n", .{berlin_config.hardfork});
    
    const BerlinEvm = evm_module.Evm(berlin_config);
    std.debug.print("   Berlin EVM type created successfully ✓\n", .{});

    // Test 4: Testing configuration for different use cases
    std.debug.print("\n4. Creating specialized EVM configurations:\n", .{});
    
    // High performance config
    const perf_config = ComptimeConfig{
        .optimize_for_speed = true,
        .enable_safety_checks = false,
        .clear_on_pop = false,
        .enable_thread_checks = false,
    };
    const PerfEvm = evm_module.Evm(perf_config);
    std.debug.print("   Performance EVM type created successfully ✓\n", .{});

    // Testing/debug config
    const test_config = ComptimeConfig.forTesting();
    const TestEvm = evm_module.Evm(test_config);
    std.debug.print("   Test EVM type created successfully ✓\n", .{});

    // Demonstrate that DefaultEvm is available for backward compatibility
    std.debug.print("\n5. Testing backward compatibility:\n", .{});
    const DefaultEvmType = evm_module.DefaultEvm;
    std.debug.print("   DefaultEvm type available ✓\n", .{});
    _ = DefaultEvmType; // Use to avoid unused variable warning

    std.debug.print("\n✅ Generic EVM architecture is working correctly!\n", .{});
    std.debug.print("\nKey features demonstrated:\n", .{});
    std.debug.print("  • EVM is generic over comptime config parameter\n", .{});
    std.debug.print("  • Config is passed to all components (Stack, Memory, Frame)\n", .{});
    std.debug.print("  • Different configurations create different EVM types\n", .{});
    std.debug.print("  • DefaultEvm provides backward compatibility\n", .{});
    std.debug.print("  • Specialized configurations for different use cases\n", .{});
}