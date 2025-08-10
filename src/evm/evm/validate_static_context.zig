const EvmModule = @import("../evm.zig");
const EvmConfig = @import("../config.zig").EvmConfig;

pub const ValidateStaticContextError = error{WriteProtection};

/// Validate that state modifications are allowed in the current context.
/// Returns WriteProtection error if called within a static (read-only) context.
pub fn validate_static_context(comptime config: EvmConfig) type {
    return struct {
        pub fn validateStaticContextImpl(self: *const EvmModule.Evm(config)) ValidateStaticContextError!void {
    if (self.read_only) return error.WriteProtection;
        }
    };
}
