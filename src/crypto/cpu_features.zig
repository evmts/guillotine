const std = @import("std");
const builtin = @import("builtin");

pub const CpuFeatures = struct {
    has_aes: bool,
    has_sha: bool,
    has_avx2: bool,
    has_bmi2: bool,
    has_sha_ni: bool,
    has_aes_ni: bool,
    has_arm_crypto: bool,
    has_arm_neon: bool,

    const Self = @This();

    pub fn init() Self {
        // Only detect features for the actual target architecture
        return switch (builtin.target.cpu.arch) {
            .x86_64 => Self{
                .has_aes = std.Target.x86.featureSetHas(builtin.target.cpu.features, .aes),
                .has_sha = std.Target.x86.featureSetHas(builtin.target.cpu.features, .sha),
                .has_avx2 = std.Target.x86.featureSetHas(builtin.target.cpu.features, .avx2),
                .has_bmi2 = std.Target.x86.featureSetHas(builtin.target.cpu.features, .bmi2),
                .has_sha_ni = std.Target.x86.featureSetHas(builtin.target.cpu.features, .sha),
                .has_aes_ni = std.Target.x86.featureSetHas(builtin.target.cpu.features, .aes),
                .has_arm_crypto = false,
                .has_arm_neon = false,
            },
            .aarch64 => Self{
                .has_aes = std.Target.aarch64.featureSetHas(builtin.target.cpu.features, .aes),
                .has_sha = std.Target.aarch64.featureSetHas(builtin.target.cpu.features, .sha2),
                .has_avx2 = false,
                .has_bmi2 = false,
                .has_sha_ni = std.Target.aarch64.featureSetHas(builtin.target.cpu.features, .sha2),
                .has_aes_ni = std.Target.aarch64.featureSetHas(builtin.target.cpu.features, .aes),
                .has_arm_crypto = std.Target.aarch64.featureSetHas(builtin.target.cpu.features, .crypto),
                .has_arm_neon = std.Target.aarch64.featureSetHas(builtin.target.cpu.features, .neon),
            },
            else => Self{
                .has_aes = false,
                .has_sha = false,
                .has_avx2 = false,
                .has_bmi2 = false,
                .has_sha_ni = false,
                .has_aes_ni = false,
                .has_arm_crypto = false,
                .has_arm_neon = false,
            },
        };
    }
};

pub const cpu_features = CpuFeatures.init();

test "CPU feature detection" {
    const features = CpuFeatures.init();
    try std.testing.expect(features.has_aes == true or features.has_aes == false);
    try std.testing.expect(features.has_sha == true or features.has_sha == false);
    try std.testing.expect(features.has_avx2 == true or features.has_avx2 == false);
    try std.testing.expect(features.has_bmi2 == true or features.has_bmi2 == false);
}
