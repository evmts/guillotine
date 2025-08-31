/// Jump table functionality for dispatch operations
/// Creates jump table types for a given Frame type and Dispatch type
pub fn JumpTable(comptime FrameType: type, comptime DispatchType: type) type {
    const Self = DispatchType;

    // Performance note: JumpTable is a compact array of structs rather than a sparse bitmap. A sparse bitmap would provide O(1) lookups
    // But at the cost of cpu cache utilization. For the scale of how many jump destinations contracts have it is more performant to
    // Create a compact data structure where all to most of the items fit in a single cache line and can be quickly binary searched
    return struct {
        /// Jump table entry for dynamic jumps
        pub const JumpTableEntry = struct {
            pc: FrameType.PcType,
            dispatch: Self,
        };

        entries: []const JumpTableEntry,

        /// Find the dispatch for a given PC using binary search
        pub fn findJumpTarget(self: @This(), target_pc: FrameType.PcType) ?Self {
            // TODO: We can make this more efficient by starting our search at the relative location the jump destination is
            // E.g. If jump destination is 20% of the way through the bytecode length we should start jumpdest searching 20% of the way through the targets
            // because the targets are evenly distributed.
            // THis optimization did have measurable impact in a previous version of the evm
            var left: usize = 0;
            var right: usize = self.entries.len;

            while (left < right) {
                const mid = left + (right - left) / 2;
                const entry = self.entries[mid];

                if (entry.pc == target_pc) return entry.dispatch;
                if (entry.pc < target_pc) {
                    left = mid + 1;
                } else {
                    right = mid;
                }
            }
            return null;
        }
    };
}