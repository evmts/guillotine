---
allowed-tools: Bash(zig build:*), Bash(zig build test:*), Bash(zig build test-opcodes:*), Bash(zig build test-snailtracer:*), Bash(zig build test-synthetic:*), Bash(zig build test-fusions:*), Read, Edit, MultiEdit, Bash(echo:*), Bash(grep:*), Bash(find:*)
argument-hint: <test-command> <file-path> [--function <name>]
description: Systematically isolate the exact line causing a crash through methodical code bisection
model: claude-sonnet-4-20250514
---

# Crash Bisection Debugging Command

Systematically isolate the exact line of code causing a crash through methodical bisection (commenting/uncommenting code). This process will ALWAYS succeed if followed precisely.

## CRITICAL: Unwavering Methodology

**YOU MUST BE ABSOLUTELY STUBBORN AND METHODICAL. DO NOT DEVIATE.**

- ❌ DO NOT try to add debug logging (crashes swallow output)
- ❌ DO NOT try to fix the issue until the exact line is found
- ❌ DO NOT skip steps or make assumptions
- ❌ DO NOT re-enable all code if something doesn't work
- ❌ DO NOT report back until the EXACT line is identified
- ✅ DO follow the bisection process EXACTLY as described
- ✅ DO continue methodically even if it seems tedious
- ✅ DO test after EVERY single change

## Required Information from User

Ask the user to provide:
1. **Test command**: The exact command that reproduces the crash (e.g., `zig build test-opcodes -Dtest-filter='ADD opcode'`)
2. **File path**: The file suspected to contain the crash (or use $ARGUMENTS if provided)
3. **Function name** (optional): Specific function to start with if known
4. **Crash symptoms**: What happens (segfault, panic, hang, etc.)

## Phase 1: Initial Verification

1. Run the test command to confirm the crash reproduces
2. Note the exact error message or crash behavior
3. You do not need to create a backup of the file, we already use version control for that

## Phase 2: Function-Level Bisection

1. **Identify all functions** in the suspect file
2. **Replace function bodies with stubs** one by one, testing after each:
   ```zig
   pub fn someFunction(args: Type) ReturnType {
       // [entire function body commented out]
       // Return stub value to keep compilation working:
       return undefined; // or appropriate default/zero value
   }
   ```
   For error unions: `return error.NotImplemented;`
   For optionals: `return null;`
   For void: just return
   For noreturn: `unreachable;` or `@panic("stub");`

3. When the crash disappears after stubbing a function, YOU FOUND THE CULPRIT FUNCTION
4. **Restore all other functions** to their original state
5. **Keep only the culprit function for investigation**

## Phase 3: Block-Level Bisection Within Function

For the identified function:

1. **Comment out the ENTIRE function body** (keeping signature)
2. **Test** - crash should be gone
3. **Binary search through blocks**:
   - Uncomment first half of the function
   - Test
   - If crashes: culprit is in first half
   - If doesn't crash: culprit is in second half
   - Repeat with the identified half until you have a single block

## Phase 4: Line-by-Line Bisection

**THIS IS THE MOST CRITICAL PHASE - BE ABSOLUTELY METHODICAL**

1. **Comment out the entire identified block**
2. **Uncomment ONE LINE AT A TIME**, testing after EACH line:
   ```zig
   // Start with everything commented
   // const x = something();  // Line 1 - commented
   // const y = x + 1;        // Line 2 - commented
   // doSomething(y);         // Line 3 - commented

   // Step 1: Uncomment line 1 only
   const x = something();     // Line 1 - uncommented
   // const y = x + 1;        // Line 2 - still commented
   // doSomething(y);         // Line 3 - still commented
   // TEST NOW

   // Step 2: If no crash, uncomment line 2
   const x = something();     // Line 1 - uncommented
   const y = x + 1;          // Line 2 - uncommented
   // doSomething(y);         // Line 3 - still commented
   // TEST NOW

   // Step 3: If no crash, uncomment line 3
   const x = something();     // Line 1 - uncommented
   const y = x + 1;          // Line 2 - uncommented
   doSomething(y);           // Line 3 - uncommented
   // TEST NOW - CRASH! Line 3 is the culprit
   ```

3. **When crash returns**: The LAST uncommented line is the culprit

## Phase 5: Recursive Descent (If Culprit is Function Call)

If the culprit line is a function call:

1. **Note the exact function being called**
2. **Navigate to that function's definition**
3. **REPEAT PHASE 4** for that function
4. **Continue recursively** until you find a non-function-call culprit

Example:
```zig
// Culprit line identified:
result = processData(input);  // This line crashes

// Now bisect processData function:
pub fn processData(data: []u8) !Result {
    // Apply Phase 4 here line by line
}
```

## Phase 6: Special Cases

### For Loops
```zig
// Comment out entire loop first
// for (items) |item| {
//     processItem(item);
// }

// Then uncomment loop structure only
for (items) |item| {
    // processItem(item);  // Keep body commented
}
// TEST

// Then uncomment body lines one by one
```

### Switch Statements

Method 1: Replace case bodies with stubs
```zig
// Start with all cases having empty/stub bodies
switch (value) {
    .case1 => {}, // Empty body
    .case2 => {}, // Empty body
    .case3 => {}, // Empty body
}

// Then restore each case body one at a time
switch (value) {
    .case1 => { actual_code_1 }, // Restored
    .case2 => {}, // Still empty
    .case3 => {}, // Still empty
}
// TEST after each restoration
```

Method 2: Convert to if-else chain for precise testing
```zig
// Temporarily replace switch with if-else to test cases individually
if (value == .case1) {
    // actual_code_1  // Uncomment to test
} else if (value == .case2) {
    // actual_code_2  // Uncomment to test
} else if (value == .case3) {
    // actual_code_3  // Uncomment to test
}
```

### Defer Statements
```zig
// Test with and without defer
// defer cleanup();  // Comment/uncomment to test
```

## Phase 7: Final Verification

1. **Verify the exact culprit line** by:
   - Commenting ONLY that line → no crash
   - Uncommenting ONLY that line → crash returns
2. **Document the finding**:
   ```
   CRASH ISOLATED TO:
   File: <filepath>
   Line: <line_number>
   Code: <exact_line_of_code>
   Function: <containing_function>
   ```

## ENFORCEMENT RULES

**YOU MUST:**
- Test after EVERY SINGLE uncomment operation
- Never skip a line because it "looks safe"
- Never assume a line is innocent
- Continue even if it takes 100+ iterations
- Be more stubborn than any crash
- Report progress every 10 iterations to show you're working

**IF YOU FEEL TEMPTED TO:**
- Add debug prints → DON'T, continue bisection
- Try to understand why → DON'T, find the line first
- Skip "obvious" safe lines → DON'T, test everything
- Give up → DON'T, the process WILL work

## Success Criteria

You have succeeded when you can say with 100% certainty:
"Line X in file Y, containing code Z, when commented out, prevents the crash, and when uncommented, causes the crash."

## Example Progress Output

```
Iteration 1: Commenting function handleOpcode() - Testing... CRASH GONE
Iteration 2: Found culprit function, now bisecting handleOpcode()
Iteration 3: Uncommenting lines 1-10 - Testing... NO CRASH
Iteration 4: Uncommenting lines 11-20 - Testing... CRASH
Iteration 5: Commenting lines 11-20, uncommenting 11-15 - Testing... NO CRASH
Iteration 6: Uncommenting lines 16-20 - Testing... CRASH
...
Iteration 47: Uncommenting line 127 - Testing... NO CRASH
Iteration 48: Uncommenting line 128 - Testing... CRASH
FOUND: Line 128 causes crash
```

Remember: This process is mechanical and WILL succeed. Do not think, just bisect.