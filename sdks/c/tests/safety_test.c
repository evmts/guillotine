/* Safety and isolation tests for the Guillotine C ABI (src/evm_c_api.zig).
 *
 * Covers: NULL and foreign handle rejection, invalid configuration bytes,
 * double destroy, cleanup with live handles, fresh state per handle, repeated
 * calls and invalid bytecode without memory growth, ORIGIN parity between
 * guillotine_call and guillotine_simulate, test-mode and tracing handles
 * through the shared entry points, chain id range handling, traces that
 * report real state (preset storage, per-instruction gas across JUMPDEST
 * blocks, nested calls), deep recursion and handle creation on small thread
 * stacks, test-mode calls with little gas, handle tokens that are never
 * reused, hostile inputs to the dispatch pretty printer, zeroed analysis
 * output, stored code for delegated accounts, and the KZG precompile.
 *
 * Run from the repository root: make -f sdks/c/Makefile safety
 */
#define _POSIX_C_SOURCE 200809L
#include <pthread.h>
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
    /* TransactionContext.chain_id is u64: every u64 chain id must be accepted. */
    CHECK(evm != NULL);
    if (evm == NULL) return;
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
    check_chain_id(UINT64_MAX);
    /* Ids within u16 must always work. */
    BlockInfoFFI base = block(8453);
    EvmHandle *evm = guillotine_evm_create(&base);
    CHECK(evm != NULL);
    guillotine_evm_destroy(evm);
}

/* ---- Round 2 regressions: tracing accuracy, small thread stacks, handle tokens ---- */

typedef struct TraceStep {
    unsigned pc;
    char op[16];
    unsigned long long gas;
    unsigned long long gas_cost;
    unsigned depth;
    const char *stack; /* points at the step's `[` in the trace JSON */
} TraceStep;

/* Parse the structLogs entry that starts at or after `*cursor` and advance past it.
 * Returns 0 at the end of the trace. `json` must be NUL-terminated. */
static int next_step(const char **cursor, TraceStep *step) {
    const char *at = strstr(*cursor, "{\"pc\":");
    if (at == NULL) return 0;
    if (sscanf(at, "{\"pc\":%u,\"op\":\"%15[^\"]\",\"gas\":%llu,\"gasCost\":%llu,\"depth\":%u", &step->pc,
               step->op, &step->gas, &step->gas_cost, &step->depth) != 5) {
        fprintf(stderr, "FAIL: malformed trace step: %.80s\n", at);
        failures++;
        return 0;
    }
    step->stack = strstr(at, "\"stack\":");
    if (step->stack == NULL) {
        fputs("FAIL: trace step without a stack\n", stderr);
        failures++;
        return 0;
    }
    step->stack += strlen("\"stack\":");
    *cursor = step->stack;
    return 1;
}

static int stack_is(const TraceStep *step, const char *expected) {
    return strncmp(step->stack, expected, strlen(expected)) == 0;
}

/* NUL-terminated copy of a result's trace, or NULL (and a recorded failure) when absent. */
static char *trace_copy(const EvmResult *r) {
    if (r == NULL || r->trace_json_len == 0) {
        fputs("FAIL: result carries no trace\n", stderr);
        failures++;
        return NULL;
    }
    char *json = malloc(r->trace_json_len + 1);
    if (json == NULL) {
        perror("malloc");
        exit(2);
    }
    memcpy(json, r->trace_json, r->trace_json_len);
    json[r->trace_json_len] = 0;
    return json;
}

/* PUSH1 1 SLOAD PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN */
static const uint8_t SLOAD_CODE[] = {0x60, 0x01, 0x54, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3};

/* A traced SLOAD must read the handle's real storage, and tracing must not abort. */
static void test_trace_reads_preset_storage(void) {
    BlockInfoFFI info = block(1);
    EvmHandle *evm = guillotine_evm_create_tracing(&info);
    CHECK(evm != NULL);
    if (evm == NULL) return;
    uint8_t key[32] = {[31] = 0x01};
    uint8_t value[32] = {[31] = 0x2a};
    CHECK(guillotine_set_code(evm, TARGET, SLOAD_CODE, sizeof SLOAD_CODE));
    CHECK(guillotine_set_storage(evm, TARGET, key, value));
    CallParams p = call_to(CALLER_A, TARGET, GUILLOTINE_CALL);
    EvmResult *r = guillotine_call(evm, &p);
    CHECK(r != NULL && r->success);
    if (r != NULL) {
        CHECK(r->output_len == 32 && r->output[31] == 0x2a);
        char *json = trace_copy(r);
        if (json != NULL) {
            static const struct { unsigned pc; const char *op; unsigned long long cost; const char *stack; } want[] = {
                {0, "PUSH1", 3, "[]"},
                {2, "SLOAD", 2100, "[\"0x1\"]"},
                {3, "PUSH1", 3, "[\"0x2a\"]"},
                {5, "MSTORE", 6, "[\"0x0\",\"0x2a\"]"},
                {6, "PUSH1", 3, "[]"},
                {8, "PUSH1", 3, "[\"0x20\"]"},
                {10, "RETURN", 0, "[\"0x0\",\"0x20\"]"},
            };
            const char *cursor = json;
            TraceStep step;
            unsigned long long gas = 0;
            for (size_t i = 0; i < sizeof want / sizeof want[0]; i++) {
                if (!next_step(&cursor, &step)) {
                    fprintf(stderr, "FAIL: trace ends before step %zu\n", i);
                    failures++;
                    break;
                }
                CHECK(step.pc == want[i].pc);
                CHECK(strcmp(step.op, want[i].op) == 0);
                CHECK(step.gas_cost == want[i].cost);
                CHECK(step.depth == 1);
                CHECK(stack_is(&step, want[i].stack));
                if (i > 0) CHECK(step.gas == gas);
                gas = step.gas - step.gas_cost;
            }
            CHECK(!next_step(&cursor, &step));
            free(json);
        }
    }
    guillotine_free_result(r);
    guillotine_evm_destroy(evm);

    /* Test mode validates its tracer. It must read the same storage and never abort. */
    evm = guillotine_evm_create_test(&info);
    CHECK(evm != NULL);
    if (evm != NULL) {
        CHECK(guillotine_set_code(evm, TARGET, SLOAD_CODE, sizeof SLOAD_CODE));
        CHECK(guillotine_set_storage(evm, TARGET, key, value));
        r = guillotine_call(evm, &p);
        CHECK(r != NULL && r->success);
        if (r != NULL) CHECK(r->output_len == 32 && r->output[31] == 0x2a);
        guillotine_free_result(r);
        guillotine_evm_destroy(evm);
    }
    puts("ok: a traced SLOAD reads preset storage and every step is exact");
}

/* PUSH1 3; JUMPDEST(2) GAS POP PUSH1 1 SWAP1 SUB DUP1 PUSH1 2 JUMPI; STOP */
static const uint8_t GAS_LOOP_CODE[] = {0x60, 0x03, 0x5b, 0x5a, 0x50, 0x60, 0x01, 0x90,
                                        0x03, 0x80, 0x60, 0x02, 0x57, 0x00};

/* JUMPDEST charges a whole basic block in the EVM. The trace must still report
 * per-instruction gas: every step's gas is the previous step's gas minus its cost,
 * and the value GAS pushes equals the gas the trace reports after GAS. */
static void test_trace_jumpdest_gas_loop(void) {
    BlockInfoFFI info = block(1);
    EvmHandle *plain = guillotine_evm_create(&info);
    EvmHandle *evm = guillotine_evm_create_tracing(&info);
    CHECK(plain != NULL && evm != NULL);
    if (plain == NULL || evm == NULL) {
        guillotine_evm_destroy(plain);
        guillotine_evm_destroy(evm);
        return;
    }
    CHECK(guillotine_set_code(plain, TARGET, GAS_LOOP_CODE, sizeof GAS_LOOP_CODE));
    CHECK(guillotine_set_code(evm, TARGET, GAS_LOOP_CODE, sizeof GAS_LOOP_CODE));
    CallParams p = call_to(CALLER_A, TARGET, GUILLOTINE_CALL);
    EvmResult *expected = guillotine_call(plain, &p);
    EvmResult *r = guillotine_call(evm, &p);
    CHECK(expected != NULL && expected->success);
    CHECK(r != NULL && r->success);
    if (r != NULL && expected != NULL) {
        CHECK(r->gas_left == expected->gas_left);
        char *json = trace_copy(r);
        if (json != NULL) {
            const char *cursor = json;
            TraceStep step;
            unsigned long long gas = 0, gas_pushed = 0;
            unsigned steps = 0, jumpdests = 0, gas_ops = 0;
            int after_gas = 0;
            while (next_step(&cursor, &step)) {
                if (steps > 0) CHECK(step.gas == gas);
                CHECK(step.depth == 1);
                if (after_gas) {
                    /* POP: the stack top is the value GAS pushed. */
                    char top[40];
                    snprintf(top, sizeof top, "[\"0x%llx\",", gas_pushed);
                    CHECK(strcmp(step.op, "POP") == 0 && stack_is(&step, top));
                    after_gas = 0;
                }
                if (strcmp(step.op, "JUMPDEST") == 0) {
                    CHECK(step.pc == 2 && step.gas_cost == 1);
                    jumpdests++;
                }
                if (strcmp(step.op, "GAS") == 0) {
                    CHECK(step.pc == 3 && step.gas_cost == 2);
                    gas_pushed = step.gas - step.gas_cost;
                    after_gas = 1;
                    gas_ops++;
                }
                if (strcmp(step.op, "JUMPI") == 0) CHECK(step.pc == 12 && step.gas_cost == 10);
                gas = step.gas - step.gas_cost;
                steps++;
            }
            /* PUSH1, three 9-instruction loop bodies, STOP. */
            CHECK(steps == 29);
            CHECK(jumpdests == 3 && gas_ops == 3);
            CHECK(strcmp(step.op, "STOP") == 0 && step.pc == 13);
            free(json);
        }
    }
    guillotine_free_result(expected);
    guillotine_free_result(r);
    guillotine_evm_destroy(plain);
    guillotine_evm_destroy(evm);
    puts("ok: a traced JUMPDEST + GAS loop reports exact per-instruction gas");
}

/* PUSH1 0 x5, ADDRESS, GAS, CALL, STOP: the contract calls itself until gas or depth runs out. */
static const uint8_t RECURSIVE_CODE[] = {0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00,
                                         0x60, 0x00, 0x30, 0x5a, 0xf1, 0x00};

static void *recursive_calls_thread(void *arg) {
    (void)arg;
    BlockInfoFFI info = block(1);
    static const EvmConfiguration configs[] = {GUILLOTINE_MAINNET, GUILLOTINE_MAINNET_WITH_TRACER, GUILLOTINE_TEST_MODE};
    for (size_t i = 0; i < sizeof configs / sizeof configs[0]; i++) {
        EvmHandle *evm = guillotine_evm_create_with_config(&info, configs[i]);
        CHECK(evm != NULL);
        if (evm == NULL) continue;
        CHECK(guillotine_set_code(evm, TARGET, RECURSIVE_CODE, sizeof RECURSIVE_CODE));
        CallParams p = call_to(CALLER_A, TARGET, GUILLOTINE_CALL);
        p.gas = 16000000; /* below the EIP-7825 transaction gas cap */
        EvmResult *r = guillotine_call(evm, &p);
        CHECK(r != NULL && r->success);
        if (r != NULL && configs[i] == GUILLOTINE_MAINNET_WITH_TRACER) {
            char *json = trace_copy(r);
            if (json != NULL) {
                /* Nested frames are traced from the real EVM, each at its own depth. */
                const char *cursor = json;
                TraceStep step;
                unsigned max_depth = 0, calls = 0;
                while (next_step(&cursor, &step)) {
                    if (step.depth > max_depth) max_depth = step.depth;
                    if (strcmp(step.op, "CALL") == 0) {
                        CHECK(step.pc == 12);
                        calls++;
                    }
                }
                CHECK(max_depth > 100);
                CHECK(calls >= max_depth - 1);
                free(json);
            }
        }
        guillotine_free_result(r);
        guillotine_evm_destroy(evm);
    }
    return NULL;
}

/* Run `fn` on a thread whose stack is `stack_bytes` and wait for it. */
static void run_on_stack(size_t stack_bytes, void *(*fn)(void *)) {
    pthread_attr_t attr;
    pthread_t thread;
    if (pthread_attr_init(&attr) != 0 || pthread_attr_setstacksize(&attr, stack_bytes) != 0) {
        fprintf(stderr, "FAIL: cannot request a %zu byte thread stack\n", stack_bytes);
        failures++;
        return;
    }
    int rc = pthread_create(&thread, &attr, fn, NULL);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        fprintf(stderr, "FAIL: pthread_create with a %zu byte stack: %s\n", stack_bytes, strerror(rc));
        failures++;
        return;
    }
    if (pthread_join(thread, NULL) != 0) {
        fputs("FAIL: pthread_join\n", stderr);
        failures++;
    }
}

static void test_recursive_calls_on_2mib_thread(void) {
    run_on_stack(2u * 1024u * 1024u, recursive_calls_thread);
    puts("ok: deep recursion on a 2 MiB thread ends cleanly for every configuration");
}

static void *create_handles_thread(void *arg) {
    (void)arg;
    BlockInfoFFI info = block(1);
    static const EvmConfiguration configs[] = {GUILLOTINE_MAINNET, GUILLOTINE_MAINNET_WITH_TRACER, GUILLOTINE_TEST_MODE};
    for (size_t i = 0; i < sizeof configs / sizeof configs[0]; i++) {
        EvmHandle *evm = guillotine_evm_create_with_config(&info, configs[i]);
        CHECK(evm != NULL);
        if (evm == NULL) continue;
        CHECK(guillotine_set_code(evm, TARGET, ORIGIN_CODE, sizeof ORIGIN_CODE));
        CallParams p = call_to(CALLER_A, TARGET, GUILLOTINE_CALL);
        EvmResult *r = guillotine_call(evm, &p);
        CHECK(r != NULL && r->success);
        guillotine_free_result(r);
        guillotine_evm_destroy(evm);
    }
    return NULL;
}

static void *last_error_thread(void *arg) {
    (void)arg;
    CHECK(guillotine_evm_create(NULL) == NULL);
    CHECK(error_contains("block_info is NULL"));
    return NULL;
}

static void test_small_thread_stacks(void) {
    /* Creating and using a handle must fit in 512 KiB. */
    run_on_stack(512u * 1024u, create_handles_thread);
    /* Linking the library must not make every thread reserve more TLS than 256 KiB. */
    run_on_stack(256u * 1024u, last_error_thread);
    puts("ok: handles are created on a 512 KiB thread and the library runs on a 256 KiB thread");
}

/* STOP */
static const uint8_t STOP_CODE[] = {0x00};

static void test_test_mode_low_gas(void) {
    BlockInfoFFI info = block(1);
    static const uint64_t gas_limits[] = {100, 21000};
    for (size_t i = 0; i < sizeof gas_limits / sizeof gas_limits[0]; i++) {
        EvmHandle *evm = guillotine_evm_create_test(&info);
        CHECK(evm != NULL);
        if (evm == NULL) continue;
        CHECK(guillotine_set_code(evm, TARGET, GAS_LOOP_CODE, sizeof GAS_LOOP_CODE));
        CallParams p = call_to(CALLER_A, TARGET, GUILLOTINE_CALL);
        p.gas = gas_limits[i];
        EvmResult *r = guillotine_call(evm, &p);
        CHECK(r != NULL);
        if (r != NULL) {
            /* 100 is below the 21000 intrinsic cost and 21000 leaves no gas for the
             * first block: both fail, neither crashes. */
            CHECK(!r->success);
            CHECK(r->gas_left == 0);
            CHECK(r->error_message != NULL);
            CHECK(r->trace_json_len == 0);
        }
        guillotine_free_result(r);
        r = guillotine_simulate(evm, &p);
        CHECK(r != NULL);
        if (r != NULL) CHECK(!r->success);
        guillotine_free_result(r);
        /* STOP needs no execution gas: 21000 succeeds, 100 is still rejected. */
        CHECK(guillotine_set_code(evm, TARGET, STOP_CODE, sizeof STOP_CODE));
        r = guillotine_call(evm, &p);
        CHECK(r != NULL);
        if (r != NULL) {
            CHECK(r->success == (gas_limits[i] >= 21000));
            CHECK(r->gas_left == 0);
        }
        guillotine_free_result(r);
        guillotine_evm_destroy(evm);
    }
    puts("ok: test-mode calls with gas 100 and 21000 return a result");
}

/* A destroyed handle must never alias a newer one, even when the allocator hands the
 * new EVM the memory the old one used. Each create/destroy pair below frees and
 * reallocates blocks of identical sizes, so the allocator reuses them. */
static void test_handle_tokens_are_never_reused(void) {
    BlockInfoFFI info = block(1);
    EvmHandle *first = guillotine_evm_create(&info);
    CHECK(first != NULL);
    guillotine_evm_destroy(first);
    uintptr_t previous = (uintptr_t)first;
    for (int i = 0; i < 2000; i++) {
        EvmHandle *next = guillotine_evm_create_with_config(&info, (EvmConfiguration)(i % 3));
        if (next == NULL) {
            CHECK(next != NULL);
            break;
        }
        if ((uintptr_t)next <= previous) {
            fprintf(stderr, "FAIL: handle %p issued after %p\n", (void *)next, (void *)previous);
            failures++;
        }
        /* The stale handle stays dead while its successor is alive. */
        CHECK(!guillotine_set_nonce(first, TARGET, 1));
        CHECK(error_contains("Invalid or destroyed"));
        CHECK(guillotine_simulate(first, NULL) == NULL);
        CHECK(guillotine_set_nonce(next, TARGET, 1));
        previous = (uintptr_t)next;
        guillotine_evm_destroy(next);
        CHECK(!guillotine_set_nonce(next, TARGET, 1));
    }
    /* Tokens stay unique across cleanup and re-initialization. */
    guillotine_cleanup();
    guillotine_init();
    EvmHandle *after = guillotine_evm_create(&info);
    CHECK(after != NULL && (uintptr_t)after > previous);
    CHECK(!guillotine_set_nonce(first, TARGET, 1));
    guillotine_evm_destroy(after);
    puts("ok: handle tokens are monotonic and never reused");
}

/* Inputs that used to abort evm_dispatch_pretty_print: an undefined opcode, and
 * pushed jump targets that do not fit in 32 bits. */
static void test_dispatch_pretty_print_hostile_inputs(void) {
    static const uint8_t undefined_opcode[] = {0x0c, 0x00};
    uint8_t wide_jumpi[2 + 33 + 2] = {0x60, 0x01, 0x7f};
    memset(wide_jumpi + 3, 0xff, 32);
    wide_jumpi[35] = 0x57;
    wide_jumpi[36] = 0x00;
    static const uint8_t wide_jump[] = {0x64, 0x01, 0x00, 0x00, 0x00, 0x00, 0x56};
    /* PUSH1 4 JUMP INVALID JUMPDEST STOP: a valid static jump. */
    static const uint8_t static_jump[] = {0x60, 0x04, 0x56, 0xfe, 0x5b, 0x00};
    const struct { const uint8_t *code; size_t len; } inputs[] = {
        {undefined_opcode, sizeof undefined_opcode},
        {wide_jumpi, sizeof wide_jumpi},
        {wide_jump, sizeof wide_jump},
        {static_jump, sizeof static_jump},
    };
    size_t capacity = 256u * 1024u;
    char *text = malloc(capacity);
    if (text == NULL) {
        perror("malloc");
        exit(2);
    }
    for (size_t i = 0; i < sizeof inputs / sizeof inputs[0]; i++) {
        size_t needed = evm_dispatch_pretty_print(inputs[i].code, inputs[i].len, NULL, 0);
        CHECK(needed > 1 && needed <= capacity);
        size_t written = evm_dispatch_pretty_print(inputs[i].code, inputs[i].len, (uint8_t *)text, capacity);
        CHECK(written == needed);
        CHECK(written > 0 && text[written - 1] == 0);
        CHECK(strncmp(text, "Error", 5) != 0);
        CHECK(evm_bytecode_pretty_print(inputs[i].code, inputs[i].len, (uint8_t *)text, capacity) > 0);
    }
    size_t before = rss_bytes();
    for (int round = 0; round < 3000; round++) {
        for (size_t i = 0; i < sizeof inputs / sizeof inputs[0]; i++) {
            if (evm_dispatch_pretty_print(inputs[i].code, inputs[i].len, (uint8_t *)text, capacity) == 0) {
                fputs("FAIL: evm_dispatch_pretty_print returned 0\n", stderr);
                failures++;
                round = 3000;
                break;
            }
        }
    }
    size_t after = rss_bytes();
    free(text);
    size_t growth = after > before ? after - before : 0;
    if (growth >= 8u * 1024u * 1024u) {
        fprintf(stderr, "FAIL: RSS grew %zu bytes over 12000 dispatch pretty prints\n", growth);
        failures++;
    }
    puts("ok: evm_dispatch_pretty_print survives undefined opcodes and wide jump targets without leaking");
}

static void test_analysis_output_is_zeroed_on_failure(void) {
    CBytecodeAnalysis analysis;
    memset(&analysis, 0xa5, sizeof analysis);
    CHECK(evm_bytecode_analyze(NULL, &analysis) == EVM_BYTECODE_ERROR_NULL_POINTER);
    CHECK(analysis.push_pcs == NULL && analysis.push_pcs_count == 0);
    CHECK(analysis.jumpdests == NULL && analysis.jumpdests_count == 0);
    CHECK(analysis.basic_blocks == NULL && analysis.basic_blocks_count == 0);
    CHECK(analysis.jump_fusions == NULL && analysis.jump_fusions_count == 0);
    CHECK(analysis.advanced_fusions == NULL && analysis.advanced_fusions_count == 0);
    /* Freeing the zeroed output is safe. */
    evm_bytecode_free_analysis(&analysis);

    /* ISZERO PUSH1 5 JUMPI STOP JUMPDEST STOP */
    static const uint8_t code[] = {0x15, 0x60, 0x05, 0x57, 0x00, 0x5b, 0x00};
    BytecodeHandle *handle = evm_bytecode_create(code, sizeof code);
    CHECK(handle != NULL);
    if (handle != NULL) {
        CHECK(evm_bytecode_analyze(handle, &analysis) == EVM_BYTECODE_SUCCESS);
        CHECK(analysis.jumpdests_count == 1 && analysis.jumpdests[0] == 5);
        for (uint32_t i = 0; i < analysis.advanced_fusions_count; i++) {
            CFusionType kind = analysis.advanced_fusions[i].info.fusion_type;
            CHECK(kind == GUILLOTINE_FUSION_CONSTANT_FOLD || kind == GUILLOTINE_FUSION_ISZERO_JUMPI);
        }
        evm_bytecode_free_analysis(&analysis);
        CHECK(analysis.jumpdests == NULL && analysis.jumpdests_count == 0);
        evm_bytecode_destroy(handle);
    }
    puts("ok: evm_bytecode_analyze zeroes its output before any failure");
}

/* EIP-7702 delegation designator: guillotine_get_code returns the code stored under the
 * account itself, not the delegate's code. */
static void test_get_code_returns_stored_code(void) {
    BlockInfoFFI info = block(1);
    EvmHandle *evm = guillotine_evm_create(&info);
    CHECK(evm != NULL);
    if (evm == NULL) return;
    uint8_t designator[23] = {0xef, 0x01, 0x00};
    memcpy(designator + 3, TARGET, 20);
    CHECK(guillotine_set_code(evm, TARGET, ORIGIN_CODE, sizeof ORIGIN_CODE));
    CHECK(guillotine_set_code(evm, CALLER_B, designator, sizeof designator));
    uint8_t *code = NULL;
    size_t len = 0;
    CHECK(guillotine_get_code(evm, CALLER_B, &code, &len));
    CHECK(len == sizeof designator && code != NULL && memcmp(code, designator, len) == 0);
    guillotine_free_code(code, len);
    CHECK(guillotine_get_code(evm, CALLER_A, &code, &len));
    CHECK(len == 0);
    guillotine_free_code(code, len);
    guillotine_evm_destroy(evm);
    puts("ok: guillotine_get_code returns the account's stored code");
}

/* KZG point evaluation (0x0A) for the point at infinity: commitment and proof are the
 * compressed infinity point, z = y = 0, and the versioned hash is 0x01 followed by
 * sha256(commitment)[1..]. Success returns FIELD_ELEMENTS_PER_BLOB and BLS_MODULUS. */
static void test_kzg_point_evaluation_precompile(void) {
    static const uint8_t versioned_hash[32] = {
        0x01, 0x06, 0x57, 0xf3, 0x75, 0x54, 0xc7, 0x81, 0x40, 0x2a, 0x22, 0x91, 0x7d, 0xee, 0x2f, 0x75,
        0xde, 0xf7, 0xab, 0x96, 0x6d, 0x7b, 0x77, 0x09, 0x05, 0x39, 0x8e, 0xba, 0x3c, 0x44, 0x40, 0x14};
    static const uint8_t expected[64] = {
        [30] = 0x10, [31] = 0x00,
        [32] = 0x73, 0xed, 0xa7, 0x53, 0x29, 0x9d, 0x7d, 0x48, 0x33, 0x39, 0xd8, 0x08, 0x09, 0xa1, 0xd8, 0x05,
        0x53, 0xbd, 0xa4, 0x02, 0xff, 0xfe, 0x5b, 0xfe, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01};
    static const uint8_t kzg[20] = {[19] = 0x0a};
    uint8_t input[192] = {0};
    memcpy(input, versioned_hash, 32);
    input[96] = 0xc0;  /* commitment */
    input[144] = 0xc0; /* proof */

    BlockInfoFFI info = block(1);
    static const EvmConfiguration configs[] = {GUILLOTINE_MAINNET, GUILLOTINE_MAINNET_WITH_TRACER};
    for (size_t i = 0; i < sizeof configs / sizeof configs[0]; i++) {
        EvmHandle *evm = guillotine_evm_create_with_config(&info, configs[i]);
        CHECK(evm != NULL);
        if (evm == NULL) continue;
        CallParams p = call_to(CALLER_A, kzg, GUILLOTINE_CALL);
        p.input = input;
        p.input_len = sizeof input;
        EvmResult *r = guillotine_call(evm, &p);
        CHECK(r != NULL && r->success);
        if (r != NULL) {
            CHECK(r->output_len == 64);
            if (r->output_len == 64) CHECK(memcmp(r->output, expected, 64) == 0);
        }
        guillotine_free_result(r);

        /* A wrong versioned hash is rejected. */
        input[1] ^= 0xff;
        r = guillotine_call(evm, &p);
        CHECK(r != NULL && !r->success);
        guillotine_free_result(r);
        input[1] ^= 0xff;
        guillotine_evm_destroy(evm);
    }
    puts("ok: the KZG point evaluation precompile verifies a proof through the C ABI");
}

int main(void) {
    guillotine_init();
    /* First, so that the first handle of the process is created on the small stack. */
    test_small_thread_stacks();
    test_null_and_foreign_handles();
    test_invalid_config();
    test_fresh_state_per_handle();
    test_origin_parity();
    test_test_mode_and_tracing_handles();
    test_repeated_calls_do_not_grow_memory();
    test_invalid_bytecode_does_not_leak();
    test_chain_ids();
    test_trace_reads_preset_storage();
    test_trace_jumpdest_gas_loop();
    test_recursive_calls_on_2mib_thread();
    test_test_mode_low_gas();
    test_dispatch_pretty_print_hostile_inputs();
    test_analysis_output_is_zeroed_on_failure();
    test_get_code_returns_stored_code();
    test_kzg_point_evaluation_precompile();
    test_handle_tokens_are_never_reused();
    test_cleanup_invalidates_handles();
    guillotine_cleanup();
    if (failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    puts("All C ABI safety tests passed");
    return 0;
}
