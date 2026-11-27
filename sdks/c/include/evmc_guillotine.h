/* EVMC ABI v12 factory header for Guillotine (`libguillotine_evmc`).
 *
 * Compatible with EVMC v12 hosts (Erigon, Nethermind, Silkworm, Besu, evmc-vmtester).
 * If <evmc/evmc.h> is already included, this header declares only `evmc_create_guillotine`.
 */
#ifndef GUILLOTINE_EVMC_H
#define GUILLOTINE_EVMC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef EVMC_ABI_VERSION
#define EVMC_ABI_VERSION 12
#define EVMC_CAPABILITY_EVM1 (1u << 0)
#define EVMC_STATIC (1u << 0)

typedef struct evmc_bytes32 { uint8_t bytes[32]; } evmc_bytes32;
typedef evmc_bytes32 evmc_uint256be;
typedef struct evmc_address { uint8_t bytes[20]; } evmc_address;

enum evmc_call_kind {
    EVMC_CALL = 0,
    EVMC_DELEGATECALL = 1,
    EVMC_CALLCODE = 2,
    EVMC_CREATE = 3,
    EVMC_CREATE2 = 4,
    EVMC_EOFCREATE = 5
};

enum evmc_status_code {
    EVMC_SUCCESS = 0,
    EVMC_FAILURE = 1,
    EVMC_REVERT = 2,
    EVMC_OUT_OF_GAS = 3,
    EVMC_INVALID_INSTRUCTION = 4,
    EVMC_UNDEFINED_INSTRUCTION = 5,
    EVMC_STACK_OVERFLOW = 6,
    EVMC_STACK_UNDERFLOW = 7,
    EVMC_BAD_JUMP_DESTINATION = 8,
    EVMC_INVALID_MEMORY_ACCESS = 9,
    EVMC_CALL_DEPTH_EXCEEDED = 10,
    EVMC_STATIC_MODE_VIOLATION = 11,
    EVMC_PRECOMPILE_FAILURE = 12,
    EVMC_CONTRACT_VALIDATION_FAILURE = 13,
    EVMC_ARGUMENT_OUT_OF_RANGE = 14,
    EVMC_WASM_UNREACHABLE_INSTRUCTION = 15,
    EVMC_WASM_TRAP = 16,
    EVMC_INSUFFICIENT_BALANCE = 17,
    EVMC_INTERNAL_ERROR = -1,
    EVMC_REJECTED = -2,
    EVMC_OUT_OF_MEMORY = -3
};

enum evmc_revision {
    EVMC_FRONTIER = 0,
    EVMC_HOMESTEAD = 1,
    EVMC_TANGERINE_WHISTLE = 2,
    EVMC_SPURIOUS_DRAGON = 3,
    EVMC_BYZANTIUM = 4,
    EVMC_CONSTANTINOPLE = 5,
    EVMC_PETERSBURG = 6,
    EVMC_ISTANBUL = 7,
    EVMC_BERLIN = 8,
    EVMC_LONDON = 9,
    EVMC_PARIS = 10,
    EVMC_SHANGHAI = 11,
    EVMC_CANCUN = 12,
    EVMC_PRAGUE = 13,
    EVMC_OSAKA = 14
};

enum evmc_set_option_result {
    EVMC_SET_OPTION_SUCCESS = 0,
    EVMC_SET_OPTION_INVALID_NAME = 1,
    EVMC_SET_OPTION_INVALID_VALUE = 2
};

struct evmc_vm;
struct evmc_host_interface;
struct evmc_host_context;
struct evmc_message;
struct evmc_result;

typedef void (*evmc_release_result_fn)(const struct evmc_result *result);

struct evmc_message {
    enum evmc_call_kind kind;
    uint32_t flags;
    int32_t depth;
    int64_t gas;
    evmc_address recipient;
    evmc_address sender;
    const uint8_t *input_data;
    size_t input_size;
    evmc_uint256be value;
    evmc_bytes32 create2_salt;
    evmc_address code_address;
    const uint8_t *code;
    size_t code_size;
};

struct evmc_result {
    enum evmc_status_code status_code;
    int64_t gas_left;
    int64_t gas_refund;
    const uint8_t *output_data;
    size_t output_size;
    evmc_release_result_fn release;
    evmc_address create_address;
    uint8_t padding[4];
};

struct evmc_vm {
    const int abi_version;
    const char *name;
    const char *version;
    void (*destroy)(struct evmc_vm *vm);
    struct evmc_result (*execute)(
        struct evmc_vm *vm,
        const struct evmc_host_interface *host,
        struct evmc_host_context *context,
        enum evmc_revision rev,
        const struct evmc_message *msg,
        const uint8_t *code,
        size_t code_size);
    uint32_t (*get_capabilities)(struct evmc_vm *vm);
    enum evmc_set_option_result (*set_option)(
        struct evmc_vm *vm,
        const char *name,
        const char *value);
};
#endif

struct evmc_vm *evmc_create_guillotine(void);

#ifdef __cplusplus
}
#endif
#endif
