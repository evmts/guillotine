/* Native ABI of src/evm_c_api.zig (libguillotine_ffi). Keep field order and
 * natural C alignment. Arrays and u256 words are inline; words are big-endian.
 *
 * Lifecycle: call guillotine_init() once, create handles, destroy each handle,
 * then optionally guillotine_cleanup(), which destroys any handles still alive.
 *
 * Handles: each guillotine_evm_create* call allocates a fresh EVM and state
 * database; no state is shared or reused between handles. An EvmHandle * is
 * an opaque token, not an address: the Nth handle the process creates has the
 * value N and a value is never issued twice, so a destroyed handle can never
 * alias a newer one. Never dereference it. Every function looks the token up
 * in the library's live-handle registry, so NULL, foreign, destroyed, or
 * cleaned-up handles return NULL/false with an error. Destroying NULL is a
 * no-op; destroying a handle twice is reported and ignored. Any handle works
 * with every function: the *_tracing and *_test variants are aliases kept for
 * existing callers.
 *
 * Tracing: a tracing handle (GUILLOTINE_MAINNET_WITH_TRACER) fills trace_json
 * with {"structLogs":[...],"truncated":false,"truncationReason":"none"}: one
 * entry per executed bytecode instruction at every call depth, read from the
 * executing EVM. "stack" lists the stack before the instruction, top first;
 * "gas" and "gasCost" are per instruction. Capture is bounded (by default
 * 1,000,000 steps and 256 MiB of retained trace data; see
 * guillotine_set_trace_limits). When a bound is reached or memory for a step
 * cannot be allocated, capture stops, "truncated" is true and
 * "truncationReason" is "max_steps", "max_bytes" or "out_of_memory": the
 * listed steps are then a valid prefix of the execution. Truncation never
 * changes success, gas_left, output, logs or state.
 *
 * Stack: handle creation runs on a library thread with its own stack, and
 * deep call chains move to a large-stack worker, so callers may run on small
 * thread stacks. The library installs no alternate signal stack.
 *
 * Errors: functions return NULL or false and record a message readable with
 * guillotine_get_last_error(). That buffer is thread-local and is overwritten
 * by the next failing call on the same thread. EvmResult.error_message is an
 * owned copy that lives until guillotine_free_result.
 *
 * Memory: every buffer the library returns comes from the C allocator and is
 * released with the matching guillotine_free_* or evm_bytecode_* function,
 * from any thread. Zero-length arrays use non-NULL placeholder pointers; never
 * free them yourself.
 *
 * Threads: every function may be called from any thread. Calls on different
 * handles run in parallel; calls on one handle run one at a time. A handle
 * destroyed (or cleaned up) while another thread is inside a call on it stays
 * alive until that call returns, and is invalid for every later call.
 *
 * Pointer arguments: a NULL pointer with a non-zero length (input, code, data)
 * is rejected. A NULL pointer with length 0 is accepted as empty.
 *
 * ABI stability: BlockInfoFFI, CallParams, TxParamsFFI and EvmResult are
 * frozen. Their sizes and field offsets never change, so a host built against
 * an older header keeps working. Fields they have no room for (blob base fee,
 * ancestor block hashes, blob hashes, blob fee cap, access list, authorization
 * list, trace limits) are set on the handle with the "C ABI v3" setters at the
 * end of this header. The library copies every buffer passed to a setter, so
 * the caller may free it as soon as the setter returns. A setter that fails
 * leaves the previous value in place.
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
#define GUILLOTINE_CALL_TRACER 3
#define GUILLOTINE_FORK_SHANGHAI 15
#define GUILLOTINE_FORK_CANCUN 16
#define GUILLOTINE_FORK_PRAGUE 17
#define GUILLOTINE_FORK_OSAKA 18
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

/* C ABI v2 structures (external host state + full transaction execution). */
typedef struct GuillotineHostAccount {
    uint8_t balance[32];
    uint64_t nonce;
    bool exists;
} GuillotineHostAccount;

typedef struct GuillotineHostVTable {
    bool (*get_account)(void *ctx, const uint8_t address[20], GuillotineHostAccount *out);
    bool (*get_storage)(void *ctx, const uint8_t address[20], const uint8_t key[32], uint8_t value_out[32]);
    size_t (*get_code)(void *ctx, const uint8_t address[20], uint8_t *buf, size_t buf_len);
} GuillotineHostVTable;

typedef struct TxParamsFFI {
    uint8_t tx_type;
    uint8_t from[20];
    uint8_t to[20];
    bool has_to;
    uint64_t nonce;
    bool has_nonce;
    uint64_t gas_limit;
    uint8_t value[32];
    uint8_t gas_price[32];
    uint8_t max_fee_per_gas[32];
    bool has_max_fee;
    uint8_t max_priority_fee_per_gas[32];
    const uint8_t *input;
    size_t input_len;
    bool disable_balance_check;
} TxParamsFFI;

/* C ABI v3 structures (additive block and transaction fields). */
typedef struct AccessListEntryFFI {
    uint8_t address[20];
    /* storage_keys_len big-endian 32-byte keys; may be NULL when the length is 0. */
    const uint8_t (*storage_keys)[32];
    size_t storage_keys_len;
} AccessListEntryFFI;
typedef struct AuthorizationFFI {
    uint64_t chain_id;
    uint8_t address[20];
    uint64_t nonce;
    uint8_t y_parity; /* 0 or 1; any other value makes the tuple invalid */
    uint8_t r[32];
    uint8_t s[32];
} AuthorizationFFI;
/* guillotine_set_trace_limits value that removes a bound. */
#define GUILLOTINE_TRACE_UNLIMITED UINT64_MAX
/* Most ancestor hashes BLOCKHASH can reach. */
#define GUILLOTINE_MAX_BLOCK_HASHES 256

typedef struct CBasicBlock { uint32_t start; uint32_t end; } CBasicBlock;
typedef uint8_t CFusionType;
/* Mirrors CFusionType in src/bytecode/bytecode_c.zig: the analyzer reports these two. */
#define GUILLOTINE_FUSION_CONSTANT_FOLD 0
#define GUILLOTINE_FUSION_ISZERO_JUMPI 3
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
/* config is GUILLOTINE_MAINNET, GUILLOTINE_MAINNET_WITH_TRACER,
 * GUILLOTINE_TEST_MODE, or GUILLOTINE_CALL_TRACER; any other byte returns NULL. chain_id is u64 end to
 * end: every value is accepted and CHAINID returns it unchanged. */
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
/* Execute a call and commit its state. The caller is the transaction origin.
 * Free the result with guillotine_free_result. */
EvmResult * guillotine_call(EvmHandle * handle, const CallParams * params);
EvmResult * guillotine_call_tracing(EvmHandle * handle, const CallParams * params);
bool guillotine_get_balance(EvmHandle * handle, const uint8_t address[20], uint8_t balance_out[32]);
/* On success *code_out holds a copy; free it with guillotine_free_code when
 * *len_out > 0. Missing accounts have empty code. */
bool guillotine_get_code(EvmHandle * handle, const uint8_t address[20], uint8_t ** code_out, size_t * len_out);
void guillotine_free_code(uint8_t * code, size_t len);
bool guillotine_set_storage(EvmHandle * handle, const uint8_t address[20], const uint8_t key[32], const uint8_t value[32]);
bool guillotine_get_storage(EvmHandle * handle, const uint8_t address[20], const uint8_t key[32], uint8_t value_out[32]);
void guillotine_free_output(uint8_t * output, size_t len);
void guillotine_free_result(EvmResult * result);
const char * guillotine_get_last_error(void);
/* Returns NULL for invalid bytecode (reason in guillotine_get_last_error). */
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
/* Execute a CALL (call_type 0 only) without committing database changes.
 * ORIGIN is params->caller, exactly as in guillotine_call. */
EvmResult * guillotine_simulate(EvmHandle * handle, const CallParams * params);
/* Every account touched through this handle that is not empty. */
StateDumpFFI * guillotine_dump_state(EvmHandle * handle);
void guillotine_free_state_dump(StateDumpFFI * dump);
StateDumpFFI * guillotine_dump_state_test(EvmHandle * handle);

/* C ABI v2 additions (backwards-compatible). */
EvmHandle * guillotine_evm_create_call_tracer(const BlockInfoFFI * block_info_ptr);
EvmHandle * guillotine_evm_create_with_fork(const BlockInfoFFI * block_info_ptr, uint8_t hardfork_id);
EvmHandle * guillotine_evm_create_with_host(const BlockInfoFFI * block_info_ptr, const GuillotineHostVTable * vtable, void * user_ctx);
/* Replace the block context. Also resets the v3 block extensions: the blob
 * base fee becomes 0 and the ancestor block hashes are cleared. Set them again
 * for the new block. Transaction extensions (blob hashes, blob fee cap, access
 * list, authorization list) and trace limits are kept. */
bool guillotine_set_block_info(EvmHandle * handle, const BlockInfoFFI * block_info_ptr);
bool guillotine_get_nonce(EvmHandle * handle, const uint8_t address[20], uint64_t * nonce_out);
/* Execute a full transaction and commit it. The transaction's origin, gas
 * price and fee fields apply to this call only: later guillotine_call and
 * guillotine_simulate calls run with the handle's own context again. The v3
 * transaction extensions ride on the transaction types that carry them: the
 * access list on tx_type >= 1, blob hashes and the blob fee cap on tx_type 3,
 * the authorization list on tx_type 4. */
EvmResult * guillotine_execute_tx(EvmHandle * handle, const TxParamsFFI * params);

/* C ABI v3 additions (backwards-compatible). Every setter returns false with
 * an error for a NULL, unknown or destroyed handle. */

/* Block: blob base fee (EIP-4844; the BLOBBASEFEE opcode of EIP-7516) as a
 * big-endian u256. A new handle has 0. Lasts until guillotine_set_block_info. */
bool guillotine_set_blob_base_fee(EvmHandle * handle, const uint8_t blob_base_fee[32]);
/* Block: replace the ancestor hashes BLOCKHASH reads. hashes[i] is the hash of
 * block (number - 1 - i), newest first; count is at most
 * GUILLOTINE_MAX_BLOCK_HASHES. Ancestors without an entry read as zero, as do
 * the current block, later blocks and blocks more than 256 back. count 0
 * clears the list. Lasts until guillotine_set_block_info. */
bool guillotine_set_block_hashes(EvmHandle * handle, const uint8_t (*hashes)[32], size_t count);
/* Block: set the hash of one ancestor and keep the others. block_number must be
 * one of the 256 blocks before the handle's current block number; any other
 * number is rejected because BLOCKHASH could never return it. */
bool guillotine_set_block_hash(EvmHandle * handle, uint64_t block_number, const uint8_t hash[32]);
/* Transaction: blob versioned hashes read by BLOBHASH (EIP-4844); an index at
 * or past count reads as zero. They apply to every later guillotine_call and
 * guillotine_simulate, and to guillotine_execute_tx with tx_type 3, where each
 * blob also costs 131072 blob gas at the block's blob base fee. count 0 clears
 * them. */
bool guillotine_set_blob_hashes(EvmHandle * handle, const uint8_t (*hashes)[32], size_t count);
/* Transaction: EIP-4844 fee cap per unit of blob gas, big-endian u256, for
 * guillotine_execute_tx with tx_type 3. A cap below the block's blob base fee
 * rejects the transaction (NULL result, "MaxFeePerBlobGasBelowBlobBaseFee"),
 * and the sender must afford every blob at the cap. NULL removes the cap and
 * both checks, which is the state of a new handle. */
bool guillotine_set_max_fee_per_blob_gas(EvmHandle * handle, const uint8_t max_fee_per_blob_gas[32]);
/* Transaction: EIP-2930 access list. Every address and storage key starts the
 * transaction warm and adds intrinsic gas (2400 per address, 1900 per key).
 * Applies to guillotine_call and guillotine_simulate, and to
 * guillotine_execute_tx with tx_type >= 1. count 0 clears the list. */
bool guillotine_set_access_list(EvmHandle * handle, const AccessListEntryFFI * entries, size_t count);
/* Transaction: EIP-7702 authorization list. Tuples are applied before
 * execution; an invalid tuple (wrong chain id or nonce, bad signature) is
 * skipped as the EIP specifies and is not an error. Each tuple adds 25000
 * intrinsic gas. While the list is not empty, guillotine_call and
 * guillotine_simulate run as set-code transactions: they fail on a handle
 * older than Prague and for CREATE and CREATE2. guillotine_execute_tx uses the
 * list with tx_type 4. count 0 clears the list. */
bool guillotine_set_authorization_list(EvmHandle * handle, const AuthorizationFFI * authorizations, size_t count);
/* Forget the addresses and storage slots touched by calls on this handle so
 * far: the next result's accessed_addresses and accessed_storage, and
 * guillotine_dump_state, start again from the accounts configured through
 * guillotine_set_balance, _nonce, _code and _storage, which stay in the dump.
 * No balance, nonce, code or storage value changes. */
bool guillotine_reset_touched(EvmHandle * handle);
/* Bound the structLogs capture of a tracing handle: at most max_steps entries
 * and max_bytes bytes of retained trace data (each entry and the stack copy it
 * holds) per call. Reaching a bound sets
 * "truncated":true in trace_json and leaves the execution result untouched.
 * GUILLOTINE_TRACE_UNLIMITED removes a bound; 0 captures nothing. Returns
 * false on a handle that is not a tracing handle. */
bool guillotine_set_trace_limits(EvmHandle * handle, uint64_t max_steps, uint64_t max_bytes);

#ifdef __cplusplus
}
#endif
#endif
