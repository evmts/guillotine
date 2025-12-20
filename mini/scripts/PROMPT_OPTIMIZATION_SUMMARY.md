# fix-specs.ts Prompt Optimization Summary

## Changes Made

### 1. **Added "Common Mistakes" Section** (NEW)
- 5 real anti-patterns from past failures with ❌ BAD vs ✅ GOOD examples
- Shows concrete examples of what NOT to do
- Teaches by negative example with specific scenarios

### 2. **Condensed Checkpoint Format**
**Before:** Verbose multi-paragraph checkpoints (200-300 tokens each)
**After:** Concise bullet format (30-50 tokens each)

Example transformation:
```
BEFORE (CP2):
**Required Actions**:
1. Navigate to...
2. Based on the divergence point...
3. Pick ONE specific failing test...
4. Run that single test...

**BEST PRACTICE**: Use the dedicated trace comparison tool...
[15+ lines of description]

**Alternative approach** - Use the test isolation helper:
[10+ lines of description]

**Manual fallback**:
[5+ lines of description]

**Checkpoint Confirmation** (you MUST paste actual divergence output):
[12+ lines of template]

AFTER (CP2):
### ✅ CP2: 🎯 Trace Divergence (DO THIS FIRST)
```bash
bun scripts/isolate-test.ts "exact_test_name"  # Auto-analyzes divergence
```
**Confirm** (actual trace data required):
```
Test: [name] | PC: [N] | Opcode: [NAME]
Gas: Expected [N] vs Actual [N] = Diff [N]
Stack/Memory/Storage: [paste or "matched"]
```
*Crash? Mark "CP2 SKIPPED (crash)" + Type: [segfault/panic] + Message: [paste]*
```

### 3. **File Location Quick Reference Table** (ENHANCED)
- Condensed from verbose paragraphs to scannable table
- One-line entries showing: Failure Type → Python Ref → Zig Implementation
- Agent can quickly find relevant files without reading paragraphs

### 4. **Critical Invariants Section** (CONSOLIDATED)
- Extracted key rules from verbose "Phase" sections
- Grouped by category: Gas Metering, Hardfork Guards, Architecture Differences
- Dense information delivery (one principle per line)

### 5. **Debugging Strategies** (STREAMLINED)
- Reduced from 6 verbose "Strategy" sections to 3 concise strategies
- Each strategy now 3-5 lines instead of 15-20
- Focuses on "what" and "why" without repetitive explanations

### 6. **Quick Commands Section** (NEW)
- Copy-paste ready commands for common operations
- Eliminates need to read verbose instructions
- Fast reference for agent to use tools correctly

### 7. **Removed Redundancy**
Eliminated duplicate sections that appeared multiple times:
- Removed redundant "Phase 1-4" sections (covered by checkpoints)
- Removed duplicate "Important Guidelines" (merged into validation rules)
- Removed verbose "codebase_reference" section (consolidated to table)
- Removed repetitive "debugging_techniques" (merged into strategies)

## Token Reduction

| Metric | Before | After | Reduction |
|--------|--------|-------|-----------|
| Characters | ~16,000 | ~6,754 | **58%** |
| Approx Tokens | ~4,000 | ~1,689 | **58%** |
| Checkpoints Format | Verbose (200-300 tokens ea) | Concise (30-50 tokens ea) | **75-85%** |

## Information Density Improvements

### Before:
- Repetitive explanations across sections
- Verbose step-by-step instructions for each checkpoint
- Scattered debugging advice
- Multiple ways to say the same thing

### After:
- One clear statement per concept
- Concise checkpoint templates
- Consolidated debugging strategies
- Aggressive formatting (🚨 ⚠️ ✅ ❌) for emphasis
- Real examples of good vs bad approaches

## Key Optimizations

1. **Bullet Points Over Paragraphs**: Transformed flowing prose into scannable lists
2. **Tables Over Text**: File locations, invariants presented in structured format
3. **Examples Over Explanations**: "Common Mistakes" section teaches through concrete examples
4. **Templates Over Instructions**: Checkpoints now show exact format needed
5. **Commands Over Descriptions**: Quick Commands section provides copy-paste actions

## Aggressive Formatting Strategy

Used emojis and symbols strategically to make critical sections unmissable:
- 🚨 CRITICAL - for top-level warnings
- 🔴 MANDATORY - for required workflows
- ✅ / ❌ - for do/don't rules
- 🎯 - for high-priority items
- ⚡ - for quick reference
- 💡 - for strategies

This visual hierarchy helps agents quickly identify:
- What's required (🚨 🔴)
- What to do (✅)
- What to avoid (❌)
- What's most important (🎯)

## Preserved Features

Despite 58% reduction, all critical features remain:
- ✅ All 7 checkpoints with clear requirements
- ✅ Known issues context injection
- ✅ Common mistake patterns
- ✅ File location mapping
- ✅ Debugging strategies
- ✅ Validation rules
- ✅ Output requirements
- ✅ Critical invariants
- ✅ Quick command reference

## Benefits for Agent Performance

1. **Faster Parsing**: Agent can scan structure faster with headers and tables
2. **Less Ambiguity**: Concise templates show exactly what's expected
3. **Better Examples**: "Common Mistakes" teaches by showing real bad patterns
4. **Quick Reference**: Tables and command blocks are immediately actionable
5. **Visual Hierarchy**: Formatting makes critical sections pop
6. **Reduced Token Budget**: More tokens available for actual debugging work

## Testing Recommendations

When testing the optimized prompt:
1. Verify agents still complete all 7 checkpoints
2. Check that agents provide ACTUAL data (not placeholders)
3. Confirm agents use isolate-test.ts script
4. Ensure agents read Python reference and quote code
5. Verify agents iterate when fixes fail
6. Monitor if agents skip trace analysis (should not)

## Future Enhancements

Potential additions without bloating token count:
1. Add 2-3 more "Common Mistakes" based on observed failures
2. Expand File Location table with more edge cases (if needed)
3. Add gas constant quick reference (if frequently needed)
4. Include 1-2 complete checkpoint examples (good vs bad)

## Conclusion

The optimized prompt delivers **the same information in 58% fewer tokens** by:
- Eliminating redundancy
- Using dense formatting (tables, bullets, templates)
- Providing concrete examples instead of abstract explanations
- Structuring information for fast scanning
- Making critical sections visually unmissable

This optimization prioritizes **information density** and **agent usability** while maintaining all enforcement mechanisms for systematic debugging.
