#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <string.h>
#include <assert.h>
#include <stdint.h>
#include <stdbool.h>

#include "guillotine.h"

void test_init_cleanup() {
    printf("Testing initialization and cleanup...\n");

    guillotine_init();

    // Get error should return null when no error
    // Note: error might be non-null but should be safe to call
    const char *initial_error = guillotine_get_last_error();
    assert(initial_error != NULL);
    assert(strnlen(initial_error, 257) < 257);

    guillotine_cleanup();
    printf("✅ Init/cleanup test passed\n");
}

void test_evm_creation() {
    printf("Testing EVM creation and destruction...\n");

    guillotine_init();

    BlockInfoFFI block_info = {
        .number = 1000000,
        .timestamp = 1640995200,
        .gas_limit = 30000000,
        .chain_id = 1,
        .base_fee = 20000000000,
        .difficulty = 0,
    };

    // Zero initialize addresses
    memset(block_info.coinbase, 0, 20);
    memset(block_info.prev_randao, 0, 32);

    EvmHandle* evm = guillotine_evm_create(&block_info);
    assert(evm != NULL);

    guillotine_evm_destroy(evm);
    guillotine_cleanup();
    printf("✅ EVM creation test passed\n");
}

void test_balance_operations() {
    printf("Testing balance set/get operations...\n");

    guillotine_init();

    BlockInfoFFI block_info = {
        .number = 1000000,
        .timestamp = 1640995200,
        .gas_limit = 30000000,
        .chain_id = 1,
        .base_fee = 20000000000,
        .difficulty = 0,
    };

    memset(block_info.coinbase, 0, 20);
    memset(block_info.prev_randao, 0, 32);

    EvmHandle* evm = guillotine_evm_create(&block_info);
    assert(evm != NULL);

    uint8_t address[20] = {0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a,
                           0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14};

    // Set balance to 1000 ETH (in wei)
    uint8_t balance[32] = {0};
    balance[28] = 0x36; // 1000 ETH in wei (roughly)
    balance[29] = 0x35;
    balance[30] = 0xc9;
    balance[31] = 0xad;

    bool success = guillotine_set_balance(evm, address, balance);
    assert(success);

    // Get balance back
    uint8_t retrieved_balance[32] = {0};
    success = guillotine_get_balance(evm, address, retrieved_balance);
    assert(success);

    // Verify balance matches
    assert(memcmp(balance, retrieved_balance, 32) == 0);

    guillotine_evm_destroy(evm);
    guillotine_cleanup();
    printf("✅ Balance operations test passed\n");
}

void test_basic_call() {
    printf("Testing basic contract call...\n");

    guillotine_init();

    BlockInfoFFI block_info = {
        .number = 1000000,
        .timestamp = 1640995200,
        .gas_limit = 30000000,
        .chain_id = 1,
        .base_fee = 20000000000,
        .difficulty = 0,
    };

    memset(block_info.coinbase, 0, 20);
    memset(block_info.prev_randao, 0, 32);

    EvmHandle* evm = guillotine_evm_create(&block_info);
    assert(evm != NULL);

    // Simple bytecode that pushes values and adds them
    uint8_t bytecode[] = {
        0x60, 0x05,  // PUSH1 5
        0x60, 0x0A,  // PUSH1 10
        0x01,        // ADD (result: 15)
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE (store result to memory)
        0x60, 0x20,  // PUSH1 32 (return size)
        0x60, 0x00,  // PUSH1 0 (return offset)
        0xF3         // RETURN
    };

    uint8_t contract_addr[20] = {0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11,
                                 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11};

    bool set_success = guillotine_set_code(evm, contract_addr, bytecode, sizeof(bytecode));
    assert(set_success);

    const uint8_t empty = 0;
    CallParams params = {
        .call_type = 0, // CALL
        .gas = 1000000,
        .input = &empty,
        .input_len = 0
    };
    memcpy(params.caller, contract_addr, 20);
    memcpy(params.to, contract_addr, 20);
    memset(params.value, 0, 32);
    memset(params.salt, 0, 32);

    EvmResult* result = guillotine_call(evm, &params);
    assert(result != NULL);
    assert(result->success);

    // Should have 32-byte return value with result 15
    assert(result->output_len == 32);
    assert(result->output[31] == 15); // Value at least significant byte

    printf("✅ Basic call test passed: Gas used = %llu\n", (unsigned long long)(1000000 - result->gas_left));

    guillotine_free_result(result);
    guillotine_evm_destroy(evm);
    guillotine_cleanup();
}

void test_contract_deployment() {
    printf("Testing contract deployment via CREATE...\n");

    guillotine_init();

    BlockInfoFFI block_info = {
        .number = 1000000,
        .timestamp = 1640995200,
        .gas_limit = 30000000,
        .chain_id = 1,
        .base_fee = 20000000000,
        .difficulty = 0,
    };

    memset(block_info.coinbase, 0, 20);
    memset(block_info.prev_randao, 0, 32);

    EvmHandle* evm = guillotine_evm_create(&block_info);
    assert(evm != NULL);

    uint8_t caller_addr[20] = {0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a,
                               0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14};

    // Set some balance for the deployer
    uint8_t balance[32] = {0};
    balance[31] = 0xFF; // Some balance
    bool success = guillotine_set_balance(evm, caller_addr, balance);
    assert(success);

    // Simple deployment: returns 0x42
    uint8_t deployment_code[] = {
        0x60, 0x42,  // PUSH1 0x42
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x01,  // PUSH1 1 (code size)
        0x60, 0x1f,  // PUSH1 31 (code offset in memory)
        0xF3         // RETURN (deploy the code)
    };

    CallParams params = {
        .call_type = 4, // CREATE
        .gas = 1000000,
        .input = deployment_code,
        .input_len = sizeof(deployment_code)
    };
    memcpy(params.caller, caller_addr, 20);
    memset(params.to, 0, 20);  // CREATE uses zero address
    memset(params.value, 0, 32);
    memset(params.salt, 0, 32);

    EvmResult* result = guillotine_call(evm, &params);
    assert(result != NULL);
    assert(result->success);

    assert(result->has_created_address);
    uint8_t *code = NULL;
    size_t code_len = 0;
    assert(guillotine_get_code(evm, result->created_address, &code, &code_len));
    assert(code_len == 1 && code[0] == 0x42);
    guillotine_free_code(code, code_len);

    printf("✅ Contract deployment test passed: Gas used = %llu\n", (unsigned long long)(1000000 - result->gas_left));

    guillotine_free_result(result);
    guillotine_evm_destroy(evm);
    guillotine_cleanup();
}

static BlockInfoFFI default_block(void) {
    BlockInfoFFI block_info = {
        .number = 1000000,
        .timestamp = 1640995200,
        .gas_limit = 30000000,
        .chain_id = 1,
        .base_fee = 0,
        .difficulty = 0,
    };
    memset(block_info.coinbase, 0, 20);
    memset(block_info.prev_randao, 0, 32);
    return block_info;
}

static CallParams call_to(const uint8_t to[20]) {
    CallParams params;
    memset(&params, 0, sizeof(params));
    params.caller[19] = 0x01;
    memcpy(params.to, to, 20);
    params.gas = 1000000;
    params.call_type = GUILLOTINE_CALL;
    static const uint8_t sentinel = 0;
    params.input = &sentinel;
    params.input_len = 0;
    return params;
}

void test_trace_json() {
    printf("Testing trace JSON ownership...\n");
    guillotine_init();
    BlockInfoFFI block_info = default_block();
    uint8_t contract[20] = {0};
    contract[19] = 0x42;
    uint8_t code[] = {0x60, 0x02, 0x60, 0x03, 0x01, 0x00}; /* PUSH1 2 PUSH1 3 ADD STOP */

    EvmHandle *evm = guillotine_evm_create(&block_info);
    assert(evm != NULL);
    assert(guillotine_set_code(evm, contract, code, sizeof(code)));
    CallParams params = call_to(contract);
    EvmResult *result = guillotine_call(evm, &params);
    assert(result != NULL && result->success);
    assert(result->trace_json_len == 0); /* mainnet handles do not trace */
    guillotine_free_result(result);
    guillotine_evm_destroy(evm);

    EvmHandle *tracing = guillotine_evm_create_tracing(&block_info);
    assert(tracing != NULL);
    assert(guillotine_set_code_tracing(tracing, contract, code, sizeof(code)));
    result = guillotine_call_tracing(tracing, &params);
    assert(result != NULL && result->success);
    const char *prefix = "{\"structLogs\":[{\"pc\":0,\"op\":\"PUSH1\"";
    assert(result->trace_json_len > strlen(prefix));
    assert(memcmp(result->trace_json, prefix, strlen(prefix)) == 0);
    assert(memcmp(result->trace_json + result->trace_json_len - 2, "]}", 2) == 0);
    guillotine_free_result(result);
    guillotine_evm_destroy_tracing(tracing);

    guillotine_cleanup();
    printf("✅ Trace JSON test passed\n");
}

void test_revert_result() {
    printf("Testing revert output and error message...\n");
    guillotine_init();
    BlockInfoFFI block_info = default_block();
    uint8_t contract[20] = {0};
    contract[19] = 0x43;
    /* MSTORE 0xdead at 0, REVERT(30, 2) */
    uint8_t code[] = {0x61, 0xde, 0xad, 0x60, 0x00, 0x52, 0x60, 0x02, 0x60, 0x1e, 0xfd};

    EvmHandle *evm = guillotine_evm_create(&block_info);
    assert(evm != NULL);
    assert(guillotine_set_code(evm, contract, code, sizeof(code)));
    CallParams params = call_to(contract);
    EvmResult *result = guillotine_call(evm, &params);
    assert(result != NULL);
    assert(!result->success);
    assert(result->output_len == 2 && result->output[0] == 0xde && result->output[1] == 0xad);
    assert(result->gas_left > 0 && result->gas_left < params.gas);
    assert(result->error_message != NULL);
    assert(strnlen(result->error_message, 257) < 257);
    guillotine_free_result(result);
    guillotine_evm_destroy(evm);
    guillotine_cleanup();
    printf("✅ Revert result test passed\n");
}

int main() {
    printf("🧪 Running Guillotine C SDK Tests\n");
    printf("=====================================\n");

    test_init_cleanup();
    test_evm_creation();
    test_balance_operations();
    test_basic_call();
    test_contract_deployment();
    test_trace_json();
    test_revert_result();

    printf("\n🎉 All C SDK tests passed!\n");
    return 0;
}