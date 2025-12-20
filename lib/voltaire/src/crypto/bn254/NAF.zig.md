# Review: bn254/NAF.zig

## 1. Overview
Implements Non-Adjacent Form (NAF) representation for scalars. NAF minimizes number of additions in scalar multiplication by using digits {-1, 0, 1} instead of {0, 1}. Reduces Hamming weight by ~50% on average.

## 2. Code Quality

### Strengths
- Clean, simple implementation
- Well-tested with reconstruction verification
- Efficient algorithm
- Good test coverage with various input sizes

### Issues
- **Limited documentation**: Algorithm not explained (why NAF helps)
- **Fixed size**: Always returns [128]i2, no variable length
- **No Hamming weight test**: Should verify NAF reduces weight

## 3. Completeness

**Complete** for its purpose - simple NAF conversion.

### Missing (Low Priority)
- **Width-w NAF**: Only width-2 NAF implemented
- **Hamming weight query**: No function to compute weight
- **Variable length NAF**: Always 128 bits

## 4. Test Coverage

**Good** - Tests verify correctness by reconstructing original value. Test cases cover:
- Zero
- Small values
- Large values
- 128-bit values

### Missing
- **Hamming weight tests**: Should verify NAF reduces weight compared to binary
- **Property tests**: Average Hamming weight should be ~n/3 for n-bit numbers

## 5. Security Issues

**None** - NAF is a public representation, no secrets involved.

## 6. Issues Found

### Bugs
- None identified - appears correct

### Code Smells
- Minimal documentation of algorithm benefits
- Test could be more comprehensive

## 7. Recommendations

### HIGH PRIORITY
1. **Add algorithm documentation**:
   ```zig
   /// Non-Adjacent Form (NAF) representation
   ///
   /// NAF uses digits {-1, 0, 1} ensuring no adjacent non-zero digits.
   /// This reduces Hamming weight by ~50% compared to binary representation,
   /// minimizing additions in scalar multiplication:
   ///   Binary: avg weight = n/2
   ///   NAF:    avg weight = n/3
   ///
   /// Algorithm: At each position, if bit is 1 and next bit is 1,
   /// use -1 and carry to eliminate adjacency.
   ```

2. **Add Hamming weight test**:
   ```zig
   test "naf reduces hamming weight" {
       const values = [_]u128{ /* test cases */ };
       for (values) |n| {
           const naf_repr = naf(n);

           // Count non-zero digits in NAF
           var naf_weight: usize = 0;
           for (naf_repr) |d| if (d != 0) naf_weight += 1;

           // Count ones in binary
           var binary_weight: usize = @popCount(n);

           // NAF weight should be less (or equal for small numbers)
           try std.testing.expect(naf_weight <= binary_weight);
       }
   }
   ```

3. **Add property test** verifying average weight:
   ```zig
   test "naf average hamming weight is approximately n/3" {
       var total_naf_weight: f64 = 0;
       var total_binary_weight: f64 = 0;
       const n_trials = 1000;

       var prng = std.rand.DefaultPrng.init(0);
       for (0..n_trials) |_| {
           const val = prng.random().int(u128);
           const naf_repr = naf(val);

           var naf_weight: usize = 0;
           for (naf_repr) |d| if (d != 0) naf_weight += 1;

           total_naf_weight += @floatFromInt(naf_weight);
           total_binary_weight += @floatFromInt(@popCount(val));
       }

       const avg_naf = total_naf_weight / n_trials;
       const avg_binary = total_binary_weight / n_trials;

       // NAF should reduce weight by ~33%
       try std.testing.expect(avg_naf < avg_binary * 0.7);
   }
   ```

### MEDIUM PRIORITY
4. **Add width-w NAF** for more aggressive optimization:
   ```zig
   /// Width-w NAF uses digits in range [-(2^(w-1)), 2^(w-1)]
   /// Reduces additions further but requires precomputation
   pub fn nafW(comptime w: u8, n: u128) [128]i8
   ```

5. **Add variable-length NAF**:
   ```zig
   pub fn nafDynamic(allocator: Allocator, n: u128) ![]i2
   ```

**Overall**: Simple, correct implementation. Would benefit from better documentation explaining why NAF is useful and verification that it actually reduces Hamming weight.
