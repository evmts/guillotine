#include <stddef.h>
#include <stdio.h>
#include "guillotine.h"

/* Header-only check; this does not load or execute the native EVM. */
int main(void) {
    if (sizeof(((BlockInfoFFI *)0)->coinbase) != 20 ||
        sizeof(((CallParams *)0)->value) != 32 ||
        sizeof(EvmConfiguration) != 1 || sizeof(CFusionType) != 1) {
        fputs("C ABI array or enum width mismatch\n", stderr);
        return 1;
    }
#if UINTPTR_MAX == UINT64_MAX && defined(__LP64__)
    if (sizeof(BlockInfoFFI) != 104 || sizeof(CallParams) != 136 ||
        sizeof(EvmResult) != 144 || sizeof(AccountStateFFI) != 104 ||
        offsetof(CallParams, salt) != 97 ||
        offsetof(EvmResult, trace_json) != 128) {
        fputs("64-bit C ABI layout mismatch\n", stderr);
        return 1;
    }
#endif
    puts("C header types and layout checks passed; native execution not tested.");
    return 0;
}
