/* Safety and isolation tests for the Guillotine C ABI (src/evm_c_api.zig).
 *
 * Covers: NULL and foreign handle rejection, invalid configuration bytes,
 * double destroy, cleanup with live handles, fresh state per handle, repeated
 * calls and invalid bytecode without memory growth, ORIGIN parity between
 * guillotine_call and guillotine_simulate, test-mode and tracing handles
 * through the shared entry points, and chain id range handling.
 *
 * Run from the repository root: make -f sdks/c/Makefile safety
 */
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
#include <mach/mach.h>
#endif

#include "guillotine.h"

static int failures = 0;

#define CHECK(cond)                                                              \
    do {                                                                         \
        if (!(cond)) {                                                           \
            fprintf(stderr, "FAIL %s:%d: %s (last error: %s)\n", __FILE__,      \
                    __LINE__, #cond, guillotine_get_last_error());               \
            failures++;                                                          \
        }                                                                        \
    } while (0)

static int error_contains(const char *needle) {
    const char *err = guillotine_get_last_error();
    return err != NULL && strstr(err, needle) != NULL;
}

/* Resident set size in bytes. */
static size_t rss_bytes(void) {
#if defined(__linux__)
    FILE *f = fopen("/proc/self/statm", "r");
    if (f == NULL) {
        perror("fopen /proc/self/statm");
        exit(2);
    }
    unsigned long size = 0, resident = 0;
    if (fscanf(f, "%lu %lu", &size, &resident) != 2) {
        fputs("cannot parse /proc/self/statm\n", stderr);
        exit(2);
    }
    fclose(f);
    return (size_t)resident * 4096u;
#elif defined(__APPLE__)
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
        fputs("task_info failed\n", stderr);
        exit(2);
    }
    return (size_t)info.resident_size;
#else
#error "rss_bytes: unsupported platform"
#endif
}

static BlockInfoFFI block(uint64_t chain_id) {
    BlockInfoFFI info;
    memset(&info, 0, sizeof info);
    info.number = 20000000;
    info.timestamp = 1700000000;
    info.gas_limit = 30000000;
    info.base_fee = 0;
    info.chain_id = chain_id;
    return info;
}

static CallParams call_to(const uint8_t caller[20], const uint8_t to[20], uint8_t call_type) {
    CallParams p;
    memset(&p, 0, sizeof p);
    memcpy(p.caller, caller, 20);
    memcpy(p.to, to, 20);
    p.gas = 1000000;
    p.call_type = call_type;
    return p;
}

static const uint8_t CALLER_A[20] = {[19] = 0xa1};
static const uint8_t CALLER_B[20] = {[19] = 0xb2};
static const uint8_t TARGET[20] = {[19] = 0xc3};

/* ORIGIN PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN */
static const uint8_t ORIGIN_CODE[] = {0x32, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3};
/* CHAINID PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN */
static const uint8_t CHAINID_CODE[] = {0x46, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3};
/* LOG1(offset 0, size 0x400, topic 0xaa); RETURN(0, 0x10000) */
static const uint8_t BIG_CODE[] = {0x60, 0xaa, 0x61, 0x04, 0x00, 0x60, 0x00, 0xa1,
                                   0x62, 0x01, 0x00, 0x00, 0x60, 0x00, 0xf3};

static uint64_t word_tail_u64(const uint8_t *word) {
    uint64_t v = 0;
    for (int i = 24; i < 32; i++) v = (v << 8) | word[i];
    return v;
}

static void test_null_and_foreign_handles(void) {
    BlockInfoFFI info = block(1);
    CallParams params = call_to(CALLER_A, TARGET, GUILLOTINE_CALL);
    uint8_t word[32] = {0};
    uint8_t *code = NULL;
    size_t len = 0;

    CHECK(guillotine_evm_create(NULL) == NULL);
    CHECK(error_contains("block_info is NULL"));
    CHECK(guillotine_evm_create_with_config(NULL, GUILLOTINE_TEST_MODE) == NULL);

    CHECK(!guillotine_set_balance(NULL, TARGET, word));
    CHECK(error_contains("handle is NULL"));
    CHECK(!guillotine_set_nonce(NULL, TARGET, 1));
    CHECK(!guillotine_set_code(NULL, TARGET, ORIGIN_CODE, sizeof ORIGIN_CODE));
    CHECK(!guillotine_set_storage(NULL, TARGET, word, word));
    CHECK(!guillotine_get_balance(NULL, TARGET, word));
    CHECK(!guillotine_get_storage(NULL, TARGET, word, word));
    CHECK(!guillotine_get_code(NULL, TARGET, &code, &len));
    CHECK(guillotine_call(NULL, &params) == NULL);
    CHECK(guillotine_call_tracing(NULL, &params) == NULL);
    CHECK(guillotine_simulate(NULL, &params) == NULL);
    CHECK(guillotine_dump_state(NULL) == NULL);
    CHECK(guillotine_dump_state_test(NULL) == NULL);
    guillotine_evm_destroy(NULL);
    guillotine_evm_destroy_tracing(NULL);
    guillotine_free_result(NULL);
    guillotine_free_state_dump(NULL);
    guillotine_free_code(NULL, 0);
    guillotine_free_output(NULL, 0);

    EvmHandle *evm = guillotine_evm_create(&info);
    CHECK(evm != NULL);
    CHECK(!guillotine_set_balance(evm, NULL, word));
    CHECK(error_contains("address is NULL"));
    CHECK(!guillotine_set_balance(evm, TARGET, NULL));
    CHECK(!guillotine_get_balance(evm, TARGET, NULL));
    CHECK(!guillotine_set_storage(evm, TARGET, NULL, word));
    CHECK(!guillotine_get_storage(evm, TARGET, word, NULL));
    CHECK(!guillotine_get_code(evm, TARGET, NULL, &len));
    CHECK(!guillotine_get_code(evm, TARGET, &code, NULL));
    CHECK(!guillotine_set_code(evm, TARGET, NULL, 4));
    CHECK(error_contains("code is NULL"));
    CHECK(guillotine_set_code(evm, TARGET, NULL, 0));
    CHECK(guillotine_call(evm, NULL) == NULL);
    CHECK(error_contains("params is NULL"));
    CallParams bad_input = params;
    bad_input.input = NULL;
    bad_input.input_len = 8;
    CHECK(guillotine_call(evm, &bad_input) == NULL);
    CHECK(error_contains("params.input is NULL"));
    CallParams bad_type = params;
    bad_type.call_type = 6;
    CHECK(guillotine_call(evm, &bad_type) == NULL);
    CHECK(error_contains("Invalid call type"));

    /* A pointer that never came from guillotine_evm_create is rejected, not dereferenced. */
    uint64_t not_a_handle[8] = {0};
    EvmHandle *forged = (EvmHandle *)(void *)not_a_handle;
    CHECK(!guillotine_set_balance(forged, TARGET, word));
    CHECK(error_contains("Invalid or destroyed"));
    CHECK(guillotine_call(forged, &params) == NULL);
    guillotine_evm_destroy(forged);
    CHECK(error_contains("invalid or already destroyed"));

    /* Use after destroy and double destroy are reported, not executed. */
    guillotine_evm_destroy(evm);
    CHECK(!guillotine_get_balance(evm, TARGET, word));
    CHECK(error_contains("Invalid or destroyed"));
    guillotine_evm_destroy(evm);
    CHECK(error_contains("invalid or already destroyed"));
    guillotine_evm_destroy_tracing(evm);
    puts("ok: NULL, foreign, and destroyed handles are rejected");
}

static void test_invalid_config(void) {
    BlockInfoFFI info = block(1);
    const uint8_t bad[] = {3, 4, 0x7f, 0xff};
    for (size_t i = 0; i < sizeof bad; i++) {
        CHECK(guillotine_evm_create_with_config(&info, bad[i]) == NULL);
        CHECK(error_contains("Invalid EVM configuration"));
    }
    for (uint8_t config = 0; config <= 2; config++) {
        EvmHandle *evm = guillotine_evm_create_with_config(&info, config);
        CHECK(evm != NULL);
        guillotine_evm_destroy(evm);
    }
    puts("ok: configuration bytes outside 0..2 are rejected");
}

static void test_fresh_state_per_handle(void) {
    BlockInfoFFI info = block(1);
    uint8_t balance[32] = {0};
    balance[31] = 0x77;
    uint8_t key[32] = {0};
    key[31] = 1;
    uint8_t value[32] = {0};
    value[31] = 0x42;

    for (int round = 0; round < 4; round++) {
        EvmHandle *evm = guillotine_evm_create_with_config(&info, (uint8_t)(round % 3));
        CHECK(evm != NULL);
        uint8_t out[32];
        memset(out, 0xff, sizeof out);
        CHECK(guillotine_get_balance(evm, TARGET, out));
        CHECK(word_tail_u64(out) == 0);
        memset(out, 0xff, sizeof out);
        CHECK(guillotine_get_storage(evm, TARGET, key, out));
        CHECK(word_tail_u64(out) == 0);
        StateDumpFFI *dump = guillotine_dump_state(evm);
        CHECK(dump != NULL);
        if (dump != NULL) CHECK(dump->accounts_count == 0);
        guillotine_free_state_dump(dump);

        CHECK(guillotine_set_balance(evm, TARGET, balance));
        CHECK(guillotine_set_storage(evm, TARGET, key, value));
        CHECK(guillotine_set_code(evm, TARGET, ORIGIN_CODE, sizeof ORIGIN_CODE));
        CHECK(guillotine_set_nonce(evm, TARGET, 9));
        dump = guillotine_dump_state(evm);
        CHECK(dump != NULL);
        if (dump != NULL) {
            CHECK(dump->accounts_count == 1);
            if (dump->accounts_count == 1) {
                CHECK(memcmp(dump->accounts[0].address, TARGET, 20) == 0);
                CHECK(dump->accounts[0].nonce == 9);
                CHECK(dump->accounts[0].code_len == sizeof ORIGIN_CODE);
                CHECK(dump->accounts[0].balance[31] == 0x77);
            }
        }
        guillotine_free_state_dump(dump);
        guillotine_evm_destroy(evm);
    }
    puts("ok: every handle starts from empty state");
}

static void test_origin_parity(void) {
    BlockInfoFFI info = block(1);
    for (uint8_t config = 0; config <= 2; config++) {
        EvmHandle *evm = guillotine_evm_create_with_config(&info, config);
        CHECK(evm != NULL);
        if (evm == NULL) continue;
        CHECK(guillotine_set_code(evm, TARGET, ORIGIN_CODE, sizeof ORIGIN_CODE));

        /* Simulate first: the handle has never seen a caller. */
        CallParams sim_b = call_to(CALLER_B, TARGET, GUILLOTINE_CALL);
        EvmResult *r = guillotine_simulate(evm, &sim_b);
        CHECK(r != NULL && r->success && r->output_len == 32);
        if (r != NULL && r->output_len == 32) CHECK(memcmp(r->output + 12, CALLER_B, 20) == 0);
        guillotine_free_result(r);

        CallParams call_a = call_to(CALLER_A, TARGET, GUILLOTINE_CALL);
        r = guillotine_call(evm, &call_a);
        CHECK(r != NULL && r->success && r->output_len == 32);
        if (r != NULL && r->output_len == 32) CHECK(memcmp(r->output + 12, CALLER_A, 20) == 0);
        guillotine_free_result(r);

        /* Simulate after a call must not reuse the previous call's origin. */
        r = guillotine_simulate(evm, &sim_b);
        CHECK(r != NULL && r->success && r->output_len == 32);
        if (r != NULL && r->output_len == 32) CHECK(memcmp(r->output + 12, CALLER_B, 20) == 0);
        guillotine_free_result(r);

        CallParams create = call_to(CALLER_B, TARGET, GUILLOTINE_CREATE);
        CHECK(guillotine_simulate(evm, &create) == NULL);
        CHECK(error_contains("Simulate only supports CALL"));
        guillotine_evm_destroy(evm);
    }
    puts("ok: guillotine_simulate and guillotine_call report the same ORIGIN");
}

static void test_test_mode_and_tracing_handles(void) {
    BlockInfoFFI info = block(1);
    uint8_t balance[32] = {0};
    balance[30] = 0x01;

    EvmHandle *test = guillotine_evm_create_with_config(&info, GUILLOTINE_TEST_MODE);
    CHECK(test != NULL);
    if (test != NULL) {
        CHECK(guillotine_set_balance(test, CALLER_A, balance));
        uint8_t out[32] = {0};
        CHECK(guillotine_get_balance(test, CALLER_A, out));
        CHECK(out[30] == 0x01);
        CHECK(guillotine_set_code(test, TARGET, BIG_CODE, sizeof BIG_CODE));
        uint8_t *code = NULL;
        size_t len = 0;
        CHECK(guillotine_get_code(test, TARGET, &code, &len));
        CHECK(len == sizeof BIG_CODE && code != NULL && memcmp(code, BIG_CODE, len) == 0);
        guillotine_free_code(code, len);
        CallParams p = call_to(CALLER_A, TARGET, GUILLOTINE_CALL);
        EvmResult *r = guillotine_call(test, &p);
        CHECK(r != NULL && r->success);
        if (r != NULL) {
            CHECK(r->output_len == 0x10000);
            CHECK(r->logs_len == 1);
            if (r->logs_len == 1) {
                CHECK(r->logs[0].topics_len == 1 && r->logs[0].topics[0][31] == 0xaa);
                CHECK(r->logs[0].data_len == 0x400);
                CHECK(memcmp(r->logs[0].address, TARGET, 20) == 0);
            }
            CHECK(r->trace_json_len == 0);
            CHECK(r->error_message != NULL);
        }
        guillotine_free_result(r);
        guillotine_evm_destroy(test);
    }

    EvmHandle *tracing = guillotine_evm_create_tracing(&info);
    CHECK(tracing != NULL);
    if (tracing != NULL) {
        CHECK(guillotine_set_code(tracing, TARGET, ORIGIN_CODE, sizeof ORIGIN_CODE));
        CallParams p = call_to(CALLER_A, TARGET, GUILLOTINE_CALL);
        EvmResult *r = guillotine_call(tracing, &p);
        CHECK(r != NULL && r->success);
        if (r != NULL) {
            CHECK(r->trace_json_len > 0);
            CHECK(r->trace_json_len > 14 && memcmp(r->trace_json, "{\"structLogs\":", 14) == 0);
        }
        guillotine_free_result(r);
        guillotine_evm_destroy_tracing(tracing);
    }
    puts("ok: test-mode and tracing handles run through the shared entry points");
}

static void run_big_calls(EvmHandle *evm, int n) {
    CallParams p = call_to(CALLER_A, TARGET, GUILLOTINE_CALL);
    for (int i = 0; i < n; i++) {
        EvmResult *r = guillotine_call(evm, &p);
        if (r == NULL || !r->success || r->output_len != 0x10000 || r->logs_len != 1) {
            fprintf(stderr, "FAIL call %d: %s\n", i, guillotine_get_last_error());
            failures++;
            guillotine_free_result(r);
            return;
        }
        guillotine_free_result(r);
    }
}

static void test_repeated_calls_do_not_grow_memory(void) {
    BlockInfoFFI info = block(1);
    for (uint8_t config = 0; config <= 2; config++) {
        EvmHandle *evm = guillotine_evm_create_with_config(&info, config);
        CHECK(evm != NULL);
        if (evm == NULL) continue;
        CHECK(guillotine_set_code(evm, TARGET, BIG_CODE, sizeof BIG_CODE));
        run_big_calls(evm, 50); /* warm allocator caches */
        size_t before = rss_bytes();
        run_big_calls(evm, 500);
        size_t after = rss_bytes();
        /* Each call returns 64 KiB of output and a 1 KiB log; leaking either would
         * grow RSS by more than 32 MiB over 500 calls. */
        size_t growth = after > before ? after - before : 0;
        if (growth >= 8u * 1024u * 1024u) {
            fprintf(stderr, "FAIL config %u: RSS grew %zu bytes over 500 calls\n", config, growth);
            failures++;
        }
        guillotine_evm_destroy(evm);
    }

    /* Creating and destroying handles must not accumulate state or memory. */
    size_t before = rss_bytes();
    for (int i = 0; i < 300; i++) {
        EvmHandle *evm = guillotine_evm_create_with_config(&info, (uint8_t)(i % 3));
        if (evm == NULL) {
            fprintf(stderr, "FAIL create %d: %s\n", i, guillotine_get_last_error());
            failures++;
            break;
        }
        guillotine_evm_destroy(evm);
    }
    size_t after = rss_bytes();
    size_t growth = after > before ? after - before : 0;
    if (growth >= 64u * 1024u * 1024u) {
        fprintf(stderr, "FAIL: RSS grew %zu bytes over 300 create/destroy cycles\n", growth);
        failures++;
    }
    puts("ok: 500 calls per configuration and 300 handle cycles without memory growth");
}

static void test_invalid_bytecode_does_not_leak(void) {
    size_t n = 70000; /* longer than any PC the analyzer can index */
    uint8_t *code = malloc(n);
    if (code == NULL) {
        perror("malloc");
        exit(2);
    }
    memset(code, 0x5b, n);
    CHECK(evm_bytecode_create(code, n) == NULL);
    CHECK(error_contains("Invalid bytecode"));
    CHECK(evm_bytecode_create(NULL, 4) == NULL);
    size_t before = rss_bytes();
    for (int i = 0; i < 400; i++) {
        if (evm_bytecode_create(code, n) != NULL) {
            fputs("FAIL: oversized bytecode accepted\n", stderr);
            failures++;
            break;
        }
    }
    size_t after = rss_bytes();
    free(code);
    size_t growth = after > before ? after - before : 0;
    /* A leak of the 70 KB copy per failure would be 28 MB. */
    if (growth >= 8u * 1024u * 1024u) {
        fprintf(stderr, "FAIL: RSS grew %zu bytes over 400 rejected bytecode inputs\n", growth);
        failures++;
    }

    BytecodeHandle *ok = evm_bytecode_create(ORIGIN_CODE, sizeof ORIGIN_CODE);
    CHECK(ok != NULL);
    CHECK(evm_bytecode_get_length(ok) == sizeof ORIGIN_CODE);
    CHECK(evm_bytecode_analyze(ok, NULL) == EVM_BYTECODE_ERROR_NULL_POINTER);
    evm_bytecode_destroy(ok);
    evm_bytecode_free_analysis(NULL);
    CHECK(evm_bytecode_pretty_print(NULL, 4, NULL, 0) == 0);
    uint8_t text[64];
    CHECK(evm_dispatch_pretty_print(NULL, 4, text, sizeof text) > 0);
    CHECK(strstr((const char *)text, "Error") != NULL);
    puts("ok: rejected bytecode frees its copy");
}

static void test_cleanup_invalidates_handles(void) {
    BlockInfoFFI info = block(1);
    EvmHandle *a = guillotine_evm_create(&info);
    EvmHandle *b = guillotine_evm_create_test(&info);
    CHECK(a != NULL && b != NULL);
    guillotine_cleanup();
    uint8_t word[32];
    CHECK(!guillotine_get_balance(a, TARGET, word));
    CHECK(!guillotine_get_balance(b, TARGET, word));
    CHECK(guillotine_evm_create(&info) == NULL);
    CHECK(error_contains("not initialized"));
    guillotine_evm_destroy(a); /* already freed by cleanup: reported, not freed twice */
    guillotine_init();
    EvmHandle *c = guillotine_evm_create(&info);
    CHECK(c != NULL);
    guillotine_evm_destroy(c);
    puts("ok: cleanup frees live handles and rejects them afterwards");
}

static void check_chain_id(uint64_t chain_id) {
    BlockInfoFFI info = block(chain_id);
    EvmHandle *evm = guillotine_evm_create(&info);
    if (evm == NULL) {
        /* The EVM's CHAINID width is narrower than this id: creation must fail
         * loudly, never truncate. */
        CHECK(error_contains("exceeds the supported maximum"));
        printf("ok: chain id %llu rejected by this EVM build (%s)\n",
               (unsigned long long)chain_id, guillotine_get_last_error());
        return;
    }
    CHECK(guillotine_set_code(evm, TARGET, CHAINID_CODE, sizeof CHAINID_CODE));
    CallParams p = call_to(CALLER_A, TARGET, GUILLOTINE_CALL);
    EvmResult *r = guillotine_call(evm, &p);
    CHECK(r != NULL && r->success && r->output_len == 32);
    if (r != NULL && r->output_len == 32) CHECK(word_tail_u64(r->output) == chain_id);
    guillotine_free_result(r);
    guillotine_evm_destroy(evm);
    printf("ok: CHAINID returns %llu\n", (unsigned long long)chain_id);
}

static void test_chain_ids(void) {
    check_chain_id(1);
    check_chain_id(8453);     /* Base Mainnet */
    check_chain_id(84532);    /* Base Sepolia */
    check_chain_id(11155111); /* Sepolia */
    /* Ids within u16 must always work. */
    BlockInfoFFI base = block(8453);
    EvmHandle *evm = guillotine_evm_create(&base);
    CHECK(evm != NULL);
    guillotine_evm_destroy(evm);
}

int main(void) {
    guillotine_init();
    test_null_and_foreign_handles();
    test_invalid_config();
    test_fresh_state_per_handle();
    test_origin_parity();
    test_test_mode_and_tracing_handles();
    test_repeated_calls_do_not_grow_memory();
    test_invalid_bytecode_does_not_leak();
    test_chain_ids();
    test_cleanup_invalidates_handles();
    guillotine_cleanup();
    if (failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    puts("All C ABI safety tests passed");
    return 0;
}
