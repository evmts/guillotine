// TODO PLAN: Systematic Commented Code Cleanup for Issue #648
//
// This file documents the broader cleanup plan for the remaining commented code
// violations across the EVM. This minimal PR addresses only the immediate deprecated
// methods - the full cleanup requires more extensive review.
//
// IMMEDIATE ACTIONS COMPLETED IN THIS PR:
// 1. ✅ Remove 3 deprecated methods from bytecode.zig (lines 714-805)
// 2. ✅ Add TODO marker for std.debug.print violation in evm.zig:1090
// 3. ✅ Add compile-time test to prevent deprecated method regression
//
// REMAINING WORK (for follow-up PRs):
//
// CATEGORY A: Debug Statement Violations (HIGH PRIORITY)
// - handlers_stack.zig:90-98 - Commented log.debug statements (UNCOMMENT)
// - dispatch.zig:268 - Commented JUMPI debug log (UNCOMMENT) 
// - evm.zig:441,443,583,585 - Multiple commented log.debug (REVIEW & UNCOMMENT)
// - differential_tracer.zig:108,248,254 - std.debug.print calls (KEEP - debugging tool)
//
// CATEGORY B: TODO/FIXME Conversion (MEDIUM PRIORITY)
// - Convert ~16 TODO comments to GitHub issues
// - Replace multi-line TODO blocks with issue references
// - Examples: "TODO: Re-enable gas comparison" -> "See issue #XXX"
//
// CATEGORY C: Dead Code Comments (LOW PRIORITY)
// - Review ~95 remaining files for commented implementation blocks
// - Delete alternative implementations (use Git history)
// - Keep explanatory comments that explain WHY not WHAT
//
// IMPLEMENTATION STRATEGY:
// 1. File-by-file review using red-green-refactor TDD approach
// 2. Performance-critical files first (dispatch, frame, handlers)
// 3. Comprehensive test coverage verification after each change
// 4. Git commits with single responsibility per file/category
//
// SUCCESS CRITERIA:
// - Zero std.debug.print in production code (except tracer)
// - All useful log.debug statements uncommented with proper levels
// - All TODOs converted to tracked GitHub issues
// - No commented implementation blocks (only explanatory comments)
// - Full test suite passing after all changes
//
// RISK MITIGATION:
// - Small, focused commits with rollback capability
// - Existing test coverage validates functionality preservation
// - Performance benchmarks catch any regression
// - Pre-commit hooks prevent future violations