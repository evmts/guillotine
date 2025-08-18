# Dead Code Inventory

This document tracks dead code that was removed from the `src/evm/` directory after refactoring to the new interpreter, frame, and call implementations.

## Special Note
The directory `src/evm/opcode_metadata/` is marked as dead code but will be used soon - DO NOT DELETE.

## Dead Code Still Present

### src/evm/opcode_metadata/
**Status**: Dead but will be used soon - DO NOT DELETE
- `inline_hot_ops.zig`
- `jump_table.zig` 
- `opcode_metadata.zig`
- `operation_config.zig`
- `soa_opcode_metadata.zig`

## Dead Code Removed

### src/evm/ (Old interpreter/block execution system)
**Status**: DELETED - replaced by interpret2/call2 system
- ~~`instruction.zig`~~ - Old instruction representation system
- ~~`instruction_generation.zig`~~ - Block-based code generation
- ~~`block_analysis.zig`~~ - Block analysis for old interpreter
- ~~`block_metrics.zig`~~ - Performance metrics for block execution
- ~~`code_bitmap.zig`~~ - Bitmap for code analysis
- ~~`dynamic_gas_mapping.zig`~~ - Dynamic gas calculation mapping
- ~~`pattern_optimization.zig`~~ - Pattern-based optimizations
- ~~`jump_resolution.zig`~~ - Jump resolution for blocks
- ~~`jumpdest_array.zig`~~ - Jump destination tracking
- ~~`size_buckets.zig`~~ - Size-based instruction bucketing
- ~~`execution_func.zig`~~ - Old execution function type
- ~~`analysis.zig`~~ - Compatibility wrapper
- ~~`analysis_cache.zig`~~ - Analysis caching system
- ~~`test_memory_sizes.zig`~~ - Test file for old system
- ~~`instruction_tag_test.zig`~~ - Test file for instruction tags
- ~~`message_fast.zig`~~ - Old message type
- ~~`newevm_test.zig`~~ - Test file
- ~~`evm_new_tests.zig`~~ - Test file

### src/evm/state/
**Status**: DELETED
- ~~`journaling_database.zig`~~ - Old journaling system

### src/evm/memory/
**Status**: DELETED
- ~~`context.zig`~~ - Memory context

### src/evm/stack/
**Status**: DELETED
- ~~`validation_patterns.zig`~~ - Stack validation patterns

## Summary

All dead code has been successfully removed except for the `opcode_metadata/` directory which is being kept for future use.

Note: Build errors related to these deletions have been resolved by:
1. Removing imports from deleted files
2. Updating the interpret() method to use call2 
3. Defining ExecutionFunc inline in operation.zig
4. Removing dead exports from root.zig