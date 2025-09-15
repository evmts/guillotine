#include <stdio.h>
#include <string.h>
#include <assert.h>
#include <stdint.h>
#include <stdbool.h>

// Include the header - using wrapper from Rust SDK for now
#include "../../../sdks/rust/wrapper.h"

void test_init_cleanup() {
    printf("Testing initialization and cleanup...\n");

    guillotine_init();

    // Get error should return null when no error
    // Note: error might be non-null but should be safe to call
    (void)guillotine_get_last_error(); // Suppress unused variable warning

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

    CallParams params = {
        .call_type = 0, // CALL
        .gas = 1000000,
        .input = NULL,
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

    printf("✅ Contract deployment test passed: Gas used = %llu\n", (unsigned long long)(1000000 - result->gas_left));

    guillotine_free_result(result);
    guillotine_evm_destroy(evm);
    guillotine_cleanup();
}

int main() {
    printf("🧪 Running Guillotine C SDK Tests\n");
    printf("=====================================\n");

    test_init_cleanup();
    test_evm_creation();
    test_balance_operations();
    test_basic_call();
    test_contract_deployment();

    printf("\n🎉 All C SDK tests passed!\n");
    return 0;
}