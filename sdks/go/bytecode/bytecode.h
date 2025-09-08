#ifndef BYTECODE_H
#define BYTECODE_H

#include <stdint.h>
#include <stddef.h>

// ========================
// Types from bytecode_c.zig
// ========================

// Opaque bytecode handle
typedef struct BytecodeHandle BytecodeHandle;

// Bytecode statistics
typedef struct {
    size_t total_bytes;
    uint32_t instruction_count;
    uint32_t jump_dest_count;
    uint32_t invalid_opcode_count;
    uint32_t push_instruction_count;
    uint32_t jump_instruction_count;
    uint32_t call_instruction_count;
    uint32_t create_instruction_count;
    uint64_t complexity_score;
} CBytecodeStats;

// Basic block information
typedef struct {
    uint32_t start;
    uint32_t end;
} CBasicBlock;

// Fusion types
typedef enum {
    FUSION_CONSTANT_FOLD = 0,
    FUSION_MULTI_PUSH = 1,
    FUSION_MULTI_POP = 2,
    FUSION_ISZERO_JUMPI = 3,
    FUSION_DUP2_MSTORE_PUSH = 4,
} CFusionType;

// Fusion information
typedef struct {
    CFusionType fusion_type;
    uint32_t original_length;
    uint64_t folded_value_low;
    uint64_t folded_value_high;
    uint64_t folded_value_extra_high;
    uint64_t folded_value_top;
    uint8_t count;
} CFusionInfo;

// Jump fusion entry
typedef struct {
    uint32_t source_pc;
    uint32_t target_pc;
} CJumpFusion;

// Advanced fusion entry
typedef struct {
    uint32_t pc;
    CFusionInfo info;
} CAdvancedFusion;

// Bytecode analysis result
typedef struct {
    // Arrays of program counters
    uint32_t* push_pcs;
    uint32_t push_pcs_count;
    
    uint32_t* jumpdests;
    uint32_t jumpdests_count;
    
    // Basic blocks
    CBasicBlock* basic_blocks;
    uint32_t basic_blocks_count;
    
    // Jump fusions
    CJumpFusion* jump_fusions;
    uint32_t jump_fusions_count;
    
    // Advanced fusions
    CAdvancedFusion* advanced_fusions;
    uint32_t advanced_fusions_count;
} CBytecodeAnalysis;

// ========================
// Functions from bytecode_c.zig
// ========================

// Bytecode lifecycle
BytecodeHandle* evm_bytecode_create(const uint8_t* data, size_t data_len);
void evm_bytecode_destroy(BytecodeHandle* handle);

// Bytecode inspection
size_t evm_bytecode_get_length(const BytecodeHandle* handle);
size_t evm_bytecode_get_data(const BytecodeHandle* handle, uint8_t* buffer, size_t buffer_len);
uint8_t evm_bytecode_get_opcode_at(const BytecodeHandle* handle, size_t position);
int evm_bytecode_is_jump_dest(const BytecodeHandle* handle, size_t position);

// Runtime vs full bytes
size_t evm_bytecode_get_full_length(const BytecodeHandle* handle);
size_t evm_bytecode_get_runtime_data(const BytecodeHandle* handle, uint8_t* buffer, size_t buffer_len);

// Metadata accessors
int evm_bytecode_has_metadata(const BytecodeHandle* handle);
size_t evm_bytecode_get_metadata_length(const BytecodeHandle* handle);
size_t evm_bytecode_get_metadata_ipfs(const BytecodeHandle* handle, uint8_t* out, size_t max_len);
int evm_bytecode_get_metadata_solc_version(const BytecodeHandle* handle, uint8_t* out_major, uint8_t* out_minor, uint8_t* out_patch);

// Bytecode validation
uint32_t evm_bytecode_count_invalid_opcodes(const BytecodeHandle* handle);
int evm_bytecode_find_jump_dests(const BytecodeHandle* handle, uint32_t* jump_dests, uint32_t max_dests, uint32_t* count_out);

// Bytecode statistics
int evm_bytecode_get_stats(const BytecodeHandle* handle, CBytecodeStats* stats_out);

// Bytecode analysis
int evm_bytecode_analyze(const BytecodeHandle* handle, CBytecodeAnalysis* analysis_out);
void evm_bytecode_free_analysis(CBytecodeAnalysis* analysis);

// Utilities
const char* evm_bytecode_opcode_name(uint8_t opcode_value);

// FFI initialization and cleanup (from parent package)
void guillotine_init(void);
void guillotine_cleanup(void);
const char* guillotine_get_last_error(void);

extern size_t evm_bytecode_pretty_print(const unsigned char* data, size_t data_len, char* buffer, size_t buffer_len);

#endif // BYTECODE_H
