/// Concrete EVM implementations for each hardfork.
/// These are used by the C FFI interface to provide runtime-selectable EVM instances.

const std = @import("std");
const EvmImpl = @import("evm.zig").EvmImpl;
const ComptimeConfig = @import("comptime_config.zig").ComptimeConfig;
const Hardfork = @import("hardforks/hardfork.zig").Hardfork;

/// Concrete EVM type for Frontier hardfork
pub const FrontierEvm = EvmImpl(ComptimeConfig.forHardfork(.FRONTIER));

/// Concrete EVM type for Homestead hardfork
pub const HomesteadEvm = EvmImpl(ComptimeConfig.forHardfork(.HOMESTEAD));

/// Concrete EVM type for DAO hardfork
pub const DaoEvm = EvmImpl(ComptimeConfig.forHardfork(.DAO));

/// Concrete EVM type for Tangerine Whistle hardfork
pub const TangerineWhistleEvm = EvmImpl(ComptimeConfig.forHardfork(.TANGERINE_WHISTLE));

/// Concrete EVM type for Spurious Dragon hardfork
pub const SpuriousDragonEvm = EvmImpl(ComptimeConfig.forHardfork(.SPURIOUS_DRAGON));

/// Concrete EVM type for Byzantium hardfork
pub const ByzantiumEvm = EvmImpl(ComptimeConfig.forHardfork(.BYZANTIUM));

/// Concrete EVM type for Constantinople hardfork
pub const ConstantinopleEvm = EvmImpl(ComptimeConfig.forHardfork(.CONSTANTINOPLE));

/// Concrete EVM type for Petersburg hardfork
pub const PetersburgEvm = EvmImpl(ComptimeConfig.forHardfork(.PETERSBURG));

/// Concrete EVM type for Istanbul hardfork
pub const IstanbulEvm = EvmImpl(ComptimeConfig.forHardfork(.ISTANBUL));

/// Concrete EVM type for Muir Glacier hardfork
pub const MuirGlacierEvm = EvmImpl(ComptimeConfig.forHardfork(.MUIR_GLACIER));

/// Concrete EVM type for Berlin hardfork
pub const BerlinEvm = EvmImpl(ComptimeConfig.forHardfork(.BERLIN));

/// Concrete EVM type for London hardfork
pub const LondonEvm = EvmImpl(ComptimeConfig.forHardfork(.LONDON));

/// Concrete EVM type for Arrow Glacier hardfork
pub const ArrowGlacierEvm = EvmImpl(ComptimeConfig.forHardfork(.ARROW_GLACIER));

/// Concrete EVM type for Gray Glacier hardfork
pub const GrayGlacierEvm = EvmImpl(ComptimeConfig.forHardfork(.GRAY_GLACIER));

/// Concrete EVM type for Merge hardfork
pub const MergeEvm = EvmImpl(ComptimeConfig.forHardfork(.MERGE));

/// Concrete EVM type for Shanghai hardfork
pub const ShanghaiEvm = EvmImpl(ComptimeConfig.forHardfork(.SHANGHAI));

/// Concrete EVM type for Cancun hardfork (latest)
pub const CancunEvm = EvmImpl(ComptimeConfig.forHardfork(.CANCUN));

/// Union type to hold any concrete EVM instance at runtime
pub const AnyEvm = union(Hardfork) {
    FRONTIER: *FrontierEvm,
    HOMESTEAD: *HomesteadEvm,
    DAO: *DaoEvm,
    TANGERINE_WHISTLE: *TangerineWhistleEvm,
    SPURIOUS_DRAGON: *SpuriousDragonEvm,
    BYZANTIUM: *ByzantiumEvm,
    CONSTANTINOPLE: *ConstantinopleEvm,
    PETERSBURG: *PetersburgEvm,
    ISTANBUL: *IstanbulEvm,
    MUIR_GLACIER: *MuirGlacierEvm,
    BERLIN: *BerlinEvm,
    LONDON: *LondonEvm,
    ARROW_GLACIER: *ArrowGlacierEvm,
    GRAY_GLACIER: *GrayGlacierEvm,
    MERGE: *MergeEvm,
    SHANGHAI: *ShanghaiEvm,
    CANCUN: *CancunEvm,

    /// Initialize an EVM for the specified hardfork
    pub fn init(allocator: std.mem.Allocator, hardfork: Hardfork, db_interface: anytype, host: anytype, journal: anytype) !AnyEvm {
        return switch (hardfork) {
            .FRONTIER => {
                const vm = try allocator.create(FrontierEvm);
                vm.* = try FrontierEvm.init(allocator, db_interface, host, journal);
                return AnyEvm{ .FRONTIER = vm };
            },
            .HOMESTEAD => {
                const vm = try allocator.create(HomesteadEvm);
                vm.* = try HomesteadEvm.init(allocator, db_interface, host, journal);
                return AnyEvm{ .HOMESTEAD = vm };
            },
            .DAO => {
                const vm = try allocator.create(DaoEvm);
                vm.* = try DaoEvm.init(allocator, db_interface, host, journal);
                return AnyEvm{ .DAO = vm };
            },
            .TANGERINE_WHISTLE => {
                const vm = try allocator.create(TangerineWhistleEvm);
                vm.* = try TangerineWhistleEvm.init(allocator, db_interface, host, journal);
                return AnyEvm{ .TANGERINE_WHISTLE = vm };
            },
            .SPURIOUS_DRAGON => {
                const vm = try allocator.create(SpuriousDragonEvm);
                vm.* = try SpuriousDragonEvm.init(allocator, db_interface, host, journal);
                return AnyEvm{ .SPURIOUS_DRAGON = vm };
            },
            .BYZANTIUM => {
                const vm = try allocator.create(ByzantiumEvm);
                vm.* = try ByzantiumEvm.init(allocator, db_interface, host, journal);
                return AnyEvm{ .BYZANTIUM = vm };
            },
            .CONSTANTINOPLE => {
                const vm = try allocator.create(ConstantinopleEvm);
                vm.* = try ConstantinopleEvm.init(allocator, db_interface, host, journal);
                return AnyEvm{ .CONSTANTINOPLE = vm };
            },
            .PETERSBURG => {
                const vm = try allocator.create(PetersburgEvm);
                vm.* = try PetersburgEvm.init(allocator, db_interface, host, journal);
                return AnyEvm{ .PETERSBURG = vm };
            },
            .ISTANBUL => {
                const vm = try allocator.create(IstanbulEvm);
                vm.* = try IstanbulEvm.init(allocator, db_interface, host, journal);
                return AnyEvm{ .ISTANBUL = vm };
            },
            .MUIR_GLACIER => {
                const vm = try allocator.create(MuirGlacierEvm);
                vm.* = try MuirGlacierEvm.init(allocator, db_interface, host, journal);
                return AnyEvm{ .MUIR_GLACIER = vm };
            },
            .BERLIN => {
                const vm = try allocator.create(BerlinEvm);
                vm.* = try BerlinEvm.init(allocator, db_interface, host, journal);
                return AnyEvm{ .BERLIN = vm };
            },
            .LONDON => {
                const vm = try allocator.create(LondonEvm);
                vm.* = try LondonEvm.init(allocator, db_interface, host, journal);
                return AnyEvm{ .LONDON = vm };
            },
            .ARROW_GLACIER => {
                const vm = try allocator.create(ArrowGlacierEvm);
                vm.* = try ArrowGlacierEvm.init(allocator, db_interface, host, journal);
                return AnyEvm{ .ARROW_GLACIER = vm };
            },
            .GRAY_GLACIER => {
                const vm = try allocator.create(GrayGlacierEvm);
                vm.* = try GrayGlacierEvm.init(allocator, db_interface, host, journal);
                return AnyEvm{ .GRAY_GLACIER = vm };
            },
            .MERGE => {
                const vm = try allocator.create(MergeEvm);
                vm.* = try MergeEvm.init(allocator, db_interface, host, journal);
                return AnyEvm{ .MERGE = vm };
            },
            .SHANGHAI => {
                const vm = try allocator.create(ShanghaiEvm);
                vm.* = try ShanghaiEvm.init(allocator, db_interface, host, journal);
                return AnyEvm{ .SHANGHAI = vm };
            },
            .CANCUN => {
                const vm = try allocator.create(CancunEvm);
                vm.* = try CancunEvm.init(allocator, db_interface, host, journal);
                return AnyEvm{ .CANCUN = vm };
            },
        };
    }

    /// Deinitialize the EVM and free memory
    pub fn deinit(self: *AnyEvm, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |vm| {
                vm.deinit();
                allocator.destroy(vm);
            },
        }
    }

    /// Execute bytecode (dispatches to the appropriate concrete EVM)
    pub fn run(self: *AnyEvm, code: []const u8, context: anytype) !anytype {
        return switch (self.*) {
            inline else => |vm| vm.run(code, context),
        };
    }
};

/// Get the default EVM type based on build mode
pub fn getDefaultEvm() type {
    const mode = @import("builtin").mode;
    return switch (mode) {
        .Debug => CancunEvm,          // Latest for development
        .ReleaseSafe => CancunEvm,    // Latest stable
        .ReleaseFast => CancunEvm,    // Latest for performance
        .ReleaseSmall => BerlinEvm,   // Older, simpler for size optimization
    };
}