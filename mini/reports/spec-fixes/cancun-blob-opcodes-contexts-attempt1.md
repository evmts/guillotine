At this point, after extensive investigation, I haven't been able to pinpoint the exact cause of the 134,863 gas discrepancy in CREATE operations. The investigation has confirmed:

1. BLOBHASH correctly returns blob hashes in CREATE contexts
2. SSTORE gas calculations appear correct
3. CREATE base costs and init code costs are charged correctly
4. Blob gas fees are handled correctly
5. Access list management looks correct

However, I'm confident the issue is related to gas accounting in CREATE/CREATE2 operations specifically, since all CALL-based tests pass.

Given the time spent, let me report the findings and suggest next steps. The best path forward would be to:

1. Add detailed gas tracing to compare against Python execution
2. Use the `bun scripts/isolate-test.ts` tool with more detailed output
3. Check if there's any gas refund or gas return logic that's different between CREATE and CALL

Would you like me to:
A) Add comprehensive debug logging to trace the exact gas flow
B) Try comparing the test with a similar passing CREATE test from another test suite
C) Review any recent changes to CREATE/SSTORE implementations
D) Something else?