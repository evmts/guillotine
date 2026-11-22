/* Native ABI of src/evm_c_api.zig. Keep field order and natural C alignment.
 * Arrays and u256 words are inline; words are big-endian. See the SDK guide
 * for ownership, threading, and mainnet/tracing handle restrictions.
 * This header does not describe src/root_c.zig or the WASM ABI.
 */
#ifndef GUILLOTINE_H
#define GUILLOTINE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct EvmHandle EvmHandle;
typedef struct BytecodeHandle BytecodeHandle;
/* Zig enum(u8): these are bytes, not C int-sized enums. */
typedef uint8_t EvmConfiguration;
#define GUILLOTINE_MAINNET 0
#define GUILLOTINE_MAINNET_WITH_TRACER 1
#define GUILLOTINE_TEST_MODE 2
#define GUILLOTINE_CALL 0
#define GUILLOTINE_CALLCODE 1
#define GUILLOTINE_DELEGATECALL 2
#define GUILLOTINE_STATICCALL 3
#define GUILLOTINE_CREATE 4
#define GUILLOTINE_CREATE2 5

typedef struct LogEntry {
    uint8_t address[20];
    const uint8_t (*topics)[32];
    size_t topics_len;
    const uint8_t *data;
    size_t data_len;
} LogEntry;
typedef struct SelfDestructRecord {
    uint8_t contract[20];
    uint8_t beneficiary[20];
} SelfDestructRecord;
typedef struct StorageAccessRecord {
    uint8_t address[20];
    uint8_t slot[32];
} StorageAccessRecord;
typedef struct EvmResult {
    bool success;
    uint64_t gas_left;
    const uint8_t *output;
    size_t output_len;
    const char *error_message;
    const LogEntry *logs;
    size_t logs_len;
    const SelfDestructRecord *selfdestructs;
    size_t selfdestructs_len;
    const uint8_t (*accessed_addresses)[20];
    size_t accessed_addresses_len;
    const StorageAccessRecord *accessed_storage;
    size_t accessed_storage_len;
    uint8_t created_address[20];
    bool has_created_address;
    const uint8_t *trace_json;
    size_t trace_json_len;
} EvmResult;
typedef struct CallParams {
    uint8_t caller[20];
    uint8_t to[20];
    uint8_t value[32];
    const uint8_t *input;
    size_t input_len;
    uint64_t gas;
    uint8_t call_type;
    uint8_t salt[32];
} CallParams;
typedef struct BlockInfoFFI {
    uint64_t number;
    uint64_t timestamp;
    uint64_t gas_limit;
    uint8_t coinbase[20];
    uint64_t base_fee;
    uint64_t chain_id;
    uint64_t difficulty;
    uint8_t prev_randao[32];
} BlockInfoFFI;
typedef struct AccountStateFFI {
    uint8_t address[20];
    uint8_t balance[32];
    uint64_t nonce;
    const uint8_t *code;
    size_t code_len;
    const uint8_t (*storage_keys)[32];
    const uint8_t (*storage_values)[32];
    size_t storage_count;
} AccountStateFFI;
typedef struct StateDumpFFI {
    const AccountStateFFI *accounts;
    size_t accounts_count;
} StateDumpFFI;

typedef struct CBasicBlock { uint32_t start; uint32_t end; } CBasicBlock;
typedef uint8_t CFusionType;
#define GUILLOTINE_FUSION_CONSTANT_FOLD 0
#define GUILLOTINE_FUSION_MULTI_PUSH 1
#define GUILLOTINE_FUSION_MULTI_POP 2
#define GUILLOTINE_FUSION_ISZERO_JUMPI 3
#define GUILLOTINE_FUSION_DUP2_MSTORE_PUSH 4
typedef struct CFusionInfo {
    CFusionType fusion_type;
    uint32_t original_length;
    uint64_t folded_value_low;
    uint64_t folded_value_high;
    uint64_t folded_value_extra_high;
    uint64_t folded_value_top;
    uint8_t count;
} CFusionInfo;
typedef struct CJumpFusion { uint32_t source_pc; uint32_t target_pc; } CJumpFusion;
typedef struct CAdvancedFusion { uint32_t pc; CFusionInfo info; } CAdvancedFusion;
typedef struct CBytecodeAnalysis {
    uint32_t *push_pcs;
    uint32_t push_pcs_count;
    uint32_t *jumpdests;
    uint32_t jumpdests_count;
    CBasicBlock *basic_blocks;
    uint32_t basic_blocks_count;
    CJumpFusion *jump_fusions;
    uint32_t jump_fusions_count;
    CAdvancedFusion *advanced_fusions;
    uint32_t advanced_fusions_count;
} CBytecodeAnalysis;
typedef struct COpcodeInfo {
    uint16_t gas_cost;
    uint8_t stack_inputs;
    uint8_t stack_outputs;
} COpcodeInfo;
#define EVM_BYTECODE_SUCCESS 0
#define EVM_BYTECODE_ERROR_NULL_POINTER -1
#define EVM_BYTECODE_ERROR_INVALID_BYTECODE -2
#define EVM_BYTECODE_ERROR_OUT_OF_MEMORY -3
#define EVM_BYTECODE_ERROR_BYTECODE_TOO_LARGE -4
#define EVM_BYTECODE_ERROR_INVALID_OPCODE -5
#define EVM_BYTECODE_ERROR_OUT_OF_BOUNDS -6

void guillotine_init(void);
void guillotine_cleanup(void);
EvmHandle * guillotine_evm_create_with_config(const BlockInfoFFI * block_info_ptr, EvmConfiguration config);
EvmHandle * guillotine_evm_create(const BlockInfoFFI * block_info_ptr);
EvmHandle * guillotine_evm_create_mainnet(const BlockInfoFFI * block_info_ptr);
EvmHandle * guillotine_evm_create_tracing(const BlockInfoFFI * block_info_ptr);
EvmHandle * guillotine_evm_create_test(const BlockInfoFFI * block_info_ptr);
void guillotine_evm_destroy(EvmHandle * handle);
void guillotine_evm_destroy_tracing(EvmHandle * handle);
bool guillotine_set_balance(EvmHandle * handle, const uint8_t address[20], const uint8_t balance[32]);
bool guillotine_set_balance_tracing(EvmHandle * handle, const uint8_t address[20], const uint8_t balance[32]);
bool guillotine_set_nonce(EvmHandle * handle, const uint8_t address[20], uint64_t nonce);
bool guillotine_set_nonce_tracing(EvmHandle * handle, const uint8_t address[20], uint64_t nonce);
bool guillotine_set_code(EvmHandle * handle, const uint8_t address[20], const uint8_t * code, size_t code_len);
bool guillotine_set_code_tracing(EvmHandle * handle, const uint8_t address[20], const uint8_t * code, size_t code_len);
EvmResult * guillotine_call(EvmHandle * handle, const CallParams * params);
EvmResult * guillotine_call_tracing(EvmHandle * handle, const CallParams * params);
bool guillotine_get_balance(EvmHandle * handle, const uint8_t address[20], uint8_t balance_out[32]);
bool guillotine_get_code(EvmHandle * handle, const uint8_t address[20], uint8_t ** code_out, size_t * len_out);
void guillotine_free_code(uint8_t * code, size_t len);
bool guillotine_set_storage(EvmHandle * handle, const uint8_t address[20], const uint8_t key[32], const uint8_t value[32]);
bool guillotine_get_storage(EvmHandle * handle, const uint8_t address[20], const uint8_t key[32], uint8_t value_out[32]);
void guillotine_free_output(uint8_t * output, size_t len);
void guillotine_free_result(EvmResult * result);
const char * guillotine_get_last_error(void);
BytecodeHandle * evm_bytecode_create(const uint8_t * data, size_t data_len);
void evm_bytecode_destroy(BytecodeHandle * handle);
size_t evm_bytecode_get_length(const BytecodeHandle * handle);
size_t evm_bytecode_get_runtime_data(const BytecodeHandle * handle, uint8_t * buffer, size_t buffer_len);
uint8_t evm_bytecode_get_opcode_at(const BytecodeHandle * handle, size_t position);
int evm_bytecode_analyze(const BytecodeHandle * handle, CBytecodeAnalysis * analysis_out);
void evm_bytecode_free_analysis(CBytecodeAnalysis * analysis);
const char * evm_bytecode_opcode_name(uint8_t opcode_value);
COpcodeInfo evm_bytecode_opcode_info(uint8_t opcode_value);
int evm_bytecode_is_valid_opcode(uint8_t opcode_value);
const char * evm_bytecode_error_string(int error_code);
size_t evm_bytecode_pretty_print(const uint8_t * data, size_t data_len, uint8_t * buffer, size_t buffer_len);
size_t evm_dispatch_pretty_print(const uint8_t * data, size_t data_len, uint8_t * buffer, size_t buffer_len);
EvmResult * guillotine_simulate(EvmHandle * handle, const CallParams * params);
StateDumpFFI * guillotine_dump_state(EvmHandle * handle);
void guillotine_free_state_dump(StateDumpFFI * dump);
StateDumpFFI * guillotine_dump_state_test(EvmHandle * handle);

#ifdef __cplusplus
}
#endif
#endif
