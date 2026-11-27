#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "guillotine.h"

static BlockInfoFFI make_block(uint64_t number, uint64_t base_fee) {
    BlockInfoFFI b;
    memset(&b, 0, sizeof b);
    b.number = number;
    b.timestamp = 1700000000;
    b.gas_limit = 30000000;
    b.coinbase[19] = 0xCB;
    b.base_fee = base_fee;
    b.chain_id = 1;
    return b;
}

static void u256_from_u64(uint8_t out[32], uint64_t v) {
    memset(out, 0, 32);
    for (int i = 0; i < 8; i++) {
        out[31 - i] = (uint8_t)(v >> (i * 8));
    }
}

static uint64_t u256_tail_u64(const uint8_t word[32]) {
    uint64_t v = 0;
    for (int i = 24; i < 32; i++) {
        v = (v << 8) | word[i];
    }
    return v;
}

static void test_set_block_info(void) {
    BlockInfoFFI b = make_block(42, 10);
    EvmHandle *evm = guillotine_evm_create(&b);
    assert(evm != NULL);

    uint8_t target[20] = {0};
    target[18] = 0x10;
    target[19] = 0x10;
    /* NUMBER; PUSH1 0; MSTORE; PUSH1 32; PUSH1 0; RETURN */
    const uint8_t code[] = {0x43, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xF3};
    assert(guillotine_set_code(evm, target, code, sizeof code));

    CallParams p;
    memset(&p, 0, sizeof p);
    p.caller[19] = 0xA0;
    p.to[18] = 0x10;
    p.to[19] = 0x10;
    p.gas = 100000;
    p.call_type = GUILLOTINE_CALL;

    EvmResult *r1 = guillotine_call(evm, &p);
    assert(r1 != NULL && r1->success && r1->output_len == 32);
    assert(u256_tail_u64(r1->output) == 42);
    guillotine_free_result(r1);

    b.number = 999999;
    assert(guillotine_set_block_info(evm, &b));

    EvmResult *r2 = guillotine_call(evm, &p);
    assert(r2 != NULL && r2->success && r2->output_len == 32);
    assert(u256_tail_u64(r2->output) == 999999);
    guillotine_free_result(r2);

    guillotine_evm_destroy(evm);
    puts("ok: guillotine_set_block_info updates block context in place");
}

static void test_hardfork_selection(void) {
    BlockInfoFFI b = make_block(1, 0);
    /* Invalid fork returns NULL */
    assert(guillotine_evm_create_with_fork(&b, 99) == NULL);

    /* EIP-1153 TSTORE/TLOAD: invalid on Shanghai, valid on Cancun */
    const uint8_t tstore_code[] = {
        0x60, 0x77, 0x60, 0x00, 0x5D, /* PUSH1 0x77; PUSH1 0; TSTORE */
        0x60, 0x00, 0x5C,             /* PUSH1 0; TLOAD */
        0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xF3
    };
    uint8_t target[20] = {0};
    target[19] = 0x20;

    EvmHandle *shanghai = guillotine_evm_create_with_fork(&b, GUILLOTINE_FORK_SHANGHAI);
    assert(shanghai != NULL);
    assert(guillotine_set_code(shanghai, target, tstore_code, sizeof tstore_code));
    CallParams p;
    memset(&p, 0, sizeof p);
    p.caller[19] = 0x01;
    p.to[19] = 0x20;
    p.gas = 100000;
    EvmResult *rs = guillotine_call(shanghai, &p);
    assert(rs != NULL && !rs->success);
    guillotine_free_result(rs);
    guillotine_evm_destroy(shanghai);

    EvmHandle *cancun = guillotine_evm_create_with_fork(&b, GUILLOTINE_FORK_CANCUN);
    assert(cancun != NULL);
    assert(guillotine_set_code(cancun, target, tstore_code, sizeof tstore_code));
    EvmResult *rc = guillotine_call(cancun, &p);
    assert(rc != NULL && rc->success && rc->output_len == 32);
    assert(u256_tail_u64(rc->output) == 0x77);
    guillotine_free_result(rc);
    guillotine_evm_destroy(cancun);

    /* EIP-7939 CLZ: valid on Osaka */
    const uint8_t clz_code[] = {
        0x60, 0x01, 0x1E, /* PUSH1 1; CLZ => 255 */
        0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xF3
    };
    EvmHandle *osaka = guillotine_evm_create_with_fork(&b, GUILLOTINE_FORK_OSAKA);
    assert(osaka != NULL);
    assert(guillotine_set_code(osaka, target, clz_code, sizeof clz_code));
    EvmResult *ro = guillotine_call(osaka, &p);
    assert(ro != NULL && ro->success && ro->output_len == 32);
    assert(u256_tail_u64(ro->output) == 255);
    guillotine_free_result(ro);
    guillotine_evm_destroy(osaka);

    puts("ok: guillotine_evm_create_with_fork enforces Shanghai/Cancun/Osaka semantics");
}

static void test_call_tracer(void) {
    BlockInfoFFI b = make_block(1, 0);
    EvmHandle *evm = guillotine_evm_create_call_tracer(&b);
    assert(evm != NULL);

    uint8_t parent[20] = {0}, child[20] = {0};
    parent[19] = 0xC1;
    child[19] = 0xC2;

    const uint8_t child_code[] = {0x60, 0x2A, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xF3};
    const uint8_t parent_code[] = {
        0x60, 0x20, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00,
        0x60, 0xC2, 0x61, 0xC3, 0x50, 0xFA, 0x50,
        0x60, 0x20, 0x60, 0x00, 0xF3
    };
    assert(guillotine_set_code(evm, child, child_code, sizeof child_code));
    assert(guillotine_set_code(evm, parent, parent_code, sizeof parent_code));

    CallParams p;
    memset(&p, 0, sizeof p);
    p.caller[19] = 0xA1;
    p.to[19] = 0xC1;
    p.gas = 200000;

    EvmResult *r = guillotine_call(evm, &p);
    assert(r != NULL && r->success);
    assert(r->trace_json_len > 0 && r->trace_json_len < 4096);
    char trace_buf[4096];
    memcpy(trace_buf, r->trace_json, r->trace_json_len);
    trace_buf[r->trace_json_len] = '\0';
    assert(strstr(trace_buf, "\"type\":\"STATICCALL\"") != NULL);
    assert(strstr(trace_buf, "\"type\":\"CALL\"") != NULL);
    guillotine_free_result(r);
    guillotine_evm_destroy(evm);

    puts("ok: guillotine_evm_create_call_tracer emits structured nested call JSON");
}

typedef struct MockHost {
    int account_calls;
    int storage_calls;
    int code_calls;
} MockHost;

/* Reads slot 0, adds 1, stores back to slot 0, returns new value. */
static const uint8_t HOST_INC_CODE[] = {
    0x60, 0x00, 0x54, /* PUSH1 0; SLOAD */
    0x60, 0x01, 0x01, /* PUSH1 1; ADD */
    0x80, 0x60, 0x00, 0x55, /* DUP1; PUSH1 0; SSTORE */
    0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xF3
};

static bool mock_get_account(void *ctx, const uint8_t address[20], GuillotineHostAccount *out) {
    MockHost *h = (MockHost *)ctx;
    h->account_calls++;
    if (address[19] == 0x55) {
        u256_from_u64(out->balance, 5000);
        out->nonce = 3;
        out->exists = true;
    } else {
        out->exists = false;
    }
    return true;
}

static bool mock_get_storage(void *ctx, const uint8_t address[20], const uint8_t key[32], uint8_t value_out[32]) {
    MockHost *h = (MockHost *)ctx;
    h->storage_calls++;
    if (address[19] == 0x55 && u256_tail_u64(key) == 0) {
        u256_from_u64(value_out, 41);
    } else {
        memset(value_out, 0, 32);
    }
    return true;
}

static size_t mock_get_code(void *ctx, const uint8_t address[20], uint8_t *buf, size_t buf_len) {
    MockHost *h = (MockHost *)ctx;
    h->code_calls++;
    if (address[19] != 0x55) return 0;
    if (buf == NULL || buf_len == 0) return sizeof HOST_INC_CODE;
    size_t n = buf_len < sizeof HOST_INC_CODE ? buf_len : sizeof HOST_INC_CODE;
    memcpy(buf, HOST_INC_CODE, n);
    return n;
}

static void test_host_vtable(void) {
    BlockInfoFFI b = make_block(10, 0);
    MockHost host = {0, 0, 0};
    GuillotineHostVTable vt = {
        .get_account = mock_get_account,
        .get_storage = mock_get_storage,
        .get_code = mock_get_code,
    };

    EvmHandle *evm = guillotine_evm_create_with_host(&b, &vt, &host);
    assert(evm != NULL);

    uint8_t target[20] = {0};
    target[19] = 0x55;
    uint64_t nonce = 0;
    assert(guillotine_get_nonce(evm, target, &nonce));
    assert(nonce == 3);

    CallParams p;
    memset(&p, 0, sizeof p);
    p.caller[19] = 0x01;
    p.to[19] = 0x55;
    p.gas = 100000;

    EvmResult *r = guillotine_call(evm, &p);
    assert(r != NULL && r->success && r->output_len == 32);
    assert(u256_tail_u64(r->output) == 42);
    guillotine_free_result(r);

    uint8_t slot0[32] = {0}, val[32] = {0};
    assert(guillotine_get_storage(evm, target, slot0, val));
    assert(u256_tail_u64(val) == 42);
    assert(host.storage_calls == 1);

    guillotine_evm_destroy(evm);
    puts("ok: guillotine_evm_create_with_host lazily loads and caches external state");
}

static void test_execute_tx(void) {
    BlockInfoFFI b = make_block(100, 10);
    EvmHandle *evm = guillotine_evm_create(&b);
    assert(evm != NULL);

    uint8_t sender[20] = {0}, target[20] = {0}, bal[32] = {0};
    sender[19] = 0xA1;
    target[19] = 0xB1;
    u256_from_u64(bal, 1000000000ULL);
    assert(guillotine_set_balance(evm, sender, bal));

    /* PUSH1 7; PUSH1 5; ADD; PUSH1 0; MSTORE; PUSH1 32; PUSH1 0; RETURN => 12 */
    const uint8_t code[] = {0x60, 0x07, 0x60, 0x05, 0x01, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xF3};
    assert(guillotine_set_code(evm, target, code, sizeof code));

    TxParamsFFI tx;
    memset(&tx, 0, sizeof tx);
    tx.tx_type = 2;
    tx.from[19] = 0xA1;
    tx.to[19] = 0xB1;
    tx.has_to = true;
    tx.nonce = 0;
    tx.has_nonce = true;
    tx.gas_limit = 100000;
    u256_from_u64(tx.max_fee_per_gas, 20);
    tx.has_max_fee = true;
    u256_from_u64(tx.max_priority_fee_per_gas, 5);

    EvmResult *r = guillotine_execute_tx(evm, &tx);
    assert(r != NULL && r->success && r->output_len == 32);
    assert(u256_tail_u64(r->output) == 12);
    uint64_t gas_used = tx.gas_limit - r->gas_left;
    assert(gas_used > 21000);
    guillotine_free_result(r);

    uint64_t next_nonce = 0;
    assert(guillotine_get_nonce(evm, sender, &next_nonce));
    assert(next_nonce == 1);

    uint8_t cb_bal[32] = {0};
    assert(guillotine_get_balance(evm, b.coinbase, cb_bal));
    assert(u256_tail_u64(cb_bal) == gas_used * 5);

    /* EIP-7825 Osaka gas limit cap rejection */
    tx.gas_limit = 20000000;
    tx.nonce = 1;
    assert(guillotine_execute_tx(evm, &tx) == NULL);

    guillotine_evm_destroy(evm);
    puts("ok: guillotine_execute_tx enforces EIP-1559 fees, nonce, coinbase tip, and EIP-7825");
}

int main(void) {
    guillotine_init();
    test_set_block_info();
    test_hardfork_selection();
    test_call_tracer();
    test_host_vtable();
    test_execute_tx();
    guillotine_cleanup();
    puts("ALL C ABI V2 TESTS PASSED");
    return 0;
}
