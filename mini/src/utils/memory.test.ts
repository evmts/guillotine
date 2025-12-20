import { describe, it, expect } from "bun:test";
import {
  wordCount,
  wordAlignedSize,
  memoryGasCost,
  calculateMemoryExpansionCost,
  expandMemory,
  readMemory,
  writeMemory,
  copyMemory,
} from "./memory";

describe("wordCount", () => {
  it("should calculate word count for exact multiples", () => {
    expect(wordCount(0)).toBe(0);
    expect(wordCount(32)).toBe(1);
    expect(wordCount(64)).toBe(2);
    expect(wordCount(96)).toBe(3);
  });

  it("should round up for partial words", () => {
    expect(wordCount(1)).toBe(1);
    expect(wordCount(31)).toBe(1);
    expect(wordCount(33)).toBe(2);
    expect(wordCount(63)).toBe(2);
    expect(wordCount(65)).toBe(3);
  });

  it("should handle large sizes", () => {
    expect(wordCount(1024)).toBe(32);
    expect(wordCount(1025)).toBe(33);
  });
});

describe("wordAlignedSize", () => {
  it("should return word-aligned sizes", () => {
    expect(wordAlignedSize(0)).toBe(0);
    expect(wordAlignedSize(1)).toBe(32);
    expect(wordAlignedSize(31)).toBe(32);
    expect(wordAlignedSize(32)).toBe(32);
    expect(wordAlignedSize(33)).toBe(64);
    expect(wordAlignedSize(64)).toBe(64);
    expect(wordAlignedSize(65)).toBe(96);
  });

  it("should handle large sizes", () => {
    expect(wordAlignedSize(1000)).toBe(1024); // 32 words
    expect(wordAlignedSize(1024)).toBe(1024); // Exact 32 words
    expect(wordAlignedSize(1025)).toBe(1056); // 33 words
  });
});

describe("memoryGasCost", () => {
  it("should calculate zero cost for zero words", () => {
    expect(memoryGasCost(0)).toBe(0);
  });

  it("should calculate linear + quadratic cost", () => {
    // 1 word: 3*1 + (1*1)/512 = 3 + 0 = 3
    expect(memoryGasCost(1)).toBe(3);

    // 2 words: 3*2 + (2*2)/512 = 6 + 0 = 6
    expect(memoryGasCost(2)).toBe(6);

    // 10 words: 3*10 + (10*10)/512 = 30 + 0 = 30
    expect(memoryGasCost(10)).toBe(30);

    // 100 words: 3*100 + (100*100)/512 = 300 + 19 = 319
    expect(memoryGasCost(100)).toBe(319);

    // 512 words: 3*512 + (512*512)/512 = 1536 + 512 = 2048
    expect(memoryGasCost(512)).toBe(2048);

    // 1000 words: 3*1000 + (1000*1000)/512 = 3000 + 1953 = 4953
    expect(memoryGasCost(1000)).toBe(4953);
  });

  it("should handle large word counts", () => {
    // 10000 words: 3*10000 + (10000*10000)/512 = 30000 + 195312 = 225312
    expect(memoryGasCost(10000)).toBe(225312);
  });
});

describe("calculateMemoryExpansionCost", () => {
  it("should return zero when no expansion needed", () => {
    expect(calculateMemoryExpansionCost(0, 0)).toBe(0);
    expect(calculateMemoryExpansionCost(32, 32)).toBe(0);
    expect(calculateMemoryExpansionCost(64, 32)).toBe(0);
    expect(calculateMemoryExpansionCost(100, 50)).toBe(0);
  });

  it("should calculate expansion from zero", () => {
    // 0 -> 1 byte (1 word): 0 -> 3
    expect(calculateMemoryExpansionCost(0, 1)).toBe(3);

    // 0 -> 32 bytes (1 word): 0 -> 3
    expect(calculateMemoryExpansionCost(0, 32)).toBe(3);

    // 0 -> 33 bytes (2 words): 0 -> 6
    expect(calculateMemoryExpansionCost(0, 33)).toBe(6);

    // 0 -> 64 bytes (2 words): 0 -> 6
    expect(calculateMemoryExpansionCost(0, 64)).toBe(6);
  });

  it("should calculate incremental expansion cost", () => {
    // 32 -> 64 bytes (1 word -> 2 words): 3 -> 6 = 3 gas
    expect(calculateMemoryExpansionCost(32, 64)).toBe(3);

    // 64 -> 96 bytes (2 words -> 3 words): 6 -> 9 = 3 gas
    expect(calculateMemoryExpansionCost(64, 96)).toBe(3);

    // 32 -> 96 bytes (1 word -> 3 words): 3 -> 9 = 6 gas
    expect(calculateMemoryExpansionCost(32, 96)).toBe(6);
  });

  it("should handle large expansions with quadratic growth", () => {
    // 0 -> 100 words: 0 -> 319 = 319 gas
    expect(calculateMemoryExpansionCost(0, 100 * 32)).toBe(319);

    // 100 -> 200 words: 319 -> 678 = 359 gas
    expect(calculateMemoryExpansionCost(100 * 32, 200 * 32)).toBe(359);

    // 0 -> 512 words: 0 -> 2048 = 2048 gas
    expect(calculateMemoryExpansionCost(0, 512 * 32)).toBe(2048);

    // 0 -> 1000 words: 0 -> 4953 = 4953 gas
    expect(calculateMemoryExpansionCost(0, 1000 * 32)).toBe(4953);
  });

  it("should round up partial words consistently", () => {
    // 1 byte requires 1 word (32 bytes)
    expect(calculateMemoryExpansionCost(0, 1)).toBe(3);
    expect(calculateMemoryExpansionCost(0, 31)).toBe(3);

    // 33 bytes requires 2 words (64 bytes)
    expect(calculateMemoryExpansionCost(0, 33)).toBe(6);
    expect(calculateMemoryExpansionCost(0, 63)).toBe(6);
  });

  it("should return max value for excessive memory sizes", () => {
    const MAX_MEMORY = 0x1000000;
    expect(calculateMemoryExpansionCost(0, MAX_MEMORY + 1)).toBe(
      Number.MAX_SAFE_INTEGER
    );
  });
});

describe("expandMemory", () => {
  it("should not expand if already large enough", () => {
    const memory = new Uint8Array(64);
    const result = expandMemory(memory, 32);
    expect(result).toBe(memory); // Same reference
    expect(result.length).toBe(64);
  });

  it("should expand to word-aligned size", () => {
    const memory = new Uint8Array(0);

    // Expand to 1 byte -> 32 bytes (1 word)
    const result1 = expandMemory(memory, 1);
    expect(result1.length).toBe(32);

    // Expand to 33 bytes -> 64 bytes (2 words)
    const result2 = expandMemory(memory, 33);
    expect(result2.length).toBe(64);

    // Expand to 100 bytes -> 128 bytes (4 words)
    const result3 = expandMemory(memory, 100);
    expect(result3.length).toBe(128);
  });

  it("should preserve existing data when expanding", () => {
    const memory = new Uint8Array([1, 2, 3, 4, 5]);
    const result = expandMemory(memory, 64);

    expect(result.length).toBe(64);
    expect(result[0]).toBe(1);
    expect(result[1]).toBe(2);
    expect(result[2]).toBe(3);
    expect(result[3]).toBe(4);
    expect(result[4]).toBe(5);

    // Rest should be zeros
    for (let i = 5; i < 64; i++) {
      expect(result[i]).toBe(0);
    }
  });
});

describe("readMemory", () => {
  it("should read bytes within bounds", () => {
    const memory = new Uint8Array([10, 20, 30, 40, 50]);

    expect(readMemory(memory, 0, 3)).toEqual(new Uint8Array([10, 20, 30]));
    expect(readMemory(memory, 2, 2)).toEqual(new Uint8Array([30, 40]));
    expect(readMemory(memory, 0, 5)).toEqual(
      new Uint8Array([10, 20, 30, 40, 50])
    );
  });

  it("should return zeros for out-of-bounds reads", () => {
    const memory = new Uint8Array([10, 20, 30]);

    // Read beyond memory
    expect(readMemory(memory, 5, 3)).toEqual(new Uint8Array([0, 0, 0]));

    // Partial out-of-bounds
    expect(readMemory(memory, 2, 3)).toEqual(new Uint8Array([30, 0, 0]));
  });

  it("should handle zero-length reads", () => {
    const memory = new Uint8Array([10, 20, 30]);
    expect(readMemory(memory, 0, 0)).toEqual(new Uint8Array(0));
    expect(readMemory(memory, 5, 0)).toEqual(new Uint8Array(0));
  });

  it("should throw on overflow", () => {
    const memory = new Uint8Array([10, 20, 30]);
    expect(() =>
      readMemory(memory, Number.MAX_SAFE_INTEGER, 10)
    ).toThrow("Memory offset overflow");
  });
});

describe("writeMemory", () => {
  it("should write bytes within existing memory", () => {
    const memory = new Uint8Array(64);
    const data = new Uint8Array([10, 20, 30]);

    const result = writeMemory(memory, 0, data);
    expect(result[0]).toBe(10);
    expect(result[1]).toBe(20);
    expect(result[2]).toBe(30);
  });

  it("should expand memory when writing beyond bounds", () => {
    const memory = new Uint8Array(32);
    const data = new Uint8Array([10, 20, 30]);

    // Write at offset 60 (requires expansion to at least 63 bytes -> 64 bytes)
    const result = writeMemory(memory, 60, data);
    expect(result.length).toBe(64); // Expanded to 2 words
    expect(result[60]).toBe(10);
    expect(result[61]).toBe(20);
    expect(result[62]).toBe(30);
  });

  it("should preserve existing data when expanding", () => {
    const memory = new Uint8Array([1, 2, 3, 4, 5]);
    const data = new Uint8Array([10, 20]);

    const result = writeMemory(memory, 50, data);
    expect(result[0]).toBe(1);
    expect(result[1]).toBe(2);
    expect(result[2]).toBe(3);
    expect(result[3]).toBe(4);
    expect(result[4]).toBe(5);
    expect(result[50]).toBe(10);
    expect(result[51]).toBe(20);
  });

  it("should handle zero-length writes", () => {
    const memory = new Uint8Array([1, 2, 3]);
    const result = writeMemory(memory, 0, new Uint8Array(0));
    expect(result).toBe(memory); // Same reference
  });

  it("should throw on overflow", () => {
    const memory = new Uint8Array([10, 20, 30]);
    const data = new Uint8Array([1, 2, 3]);
    expect(() =>
      writeMemory(memory, Number.MAX_SAFE_INTEGER, data)
    ).toThrow("Memory offset overflow");
  });
});

describe("copyMemory", () => {
  it("should copy non-overlapping regions", () => {
    const memory = new Uint8Array([10, 20, 30, 40, 50, 0, 0, 0]);

    // Copy [10, 20, 30] from offset 0 to offset 5
    const result = copyMemory(memory, 5, 0, 3);
    expect(result[5]).toBe(10);
    expect(result[6]).toBe(20);
    expect(result[7]).toBe(30);

    // Original data should be preserved
    expect(result[0]).toBe(10);
    expect(result[1]).toBe(20);
    expect(result[2]).toBe(30);
  });

  it("should handle overlapping regions (forward)", () => {
    const memory = new Uint8Array([10, 20, 30, 40, 50, 0, 0, 0]);

    // Copy [10, 20, 30] from offset 0 to offset 2
    const result = copyMemory(memory, 2, 0, 3);
    expect(result[2]).toBe(10);
    expect(result[3]).toBe(20);
    expect(result[4]).toBe(30);
  });

  it("should handle overlapping regions (backward)", () => {
    const memory = new Uint8Array([10, 20, 30, 40, 50, 0, 0, 0]);

    // Copy [30, 40, 50] from offset 2 to offset 0
    const result = copyMemory(memory, 0, 2, 3);
    expect(result[0]).toBe(30);
    expect(result[1]).toBe(40);
    expect(result[2]).toBe(50);
  });

  it("should expand memory when copying to out-of-bounds destination", () => {
    const memory = new Uint8Array([10, 20, 30]);

    // Copy to offset 50 (requires expansion)
    const result = copyMemory(memory, 50, 0, 3);
    expect(result.length).toBeGreaterThanOrEqual(53);
    expect(result[50]).toBe(10);
    expect(result[51]).toBe(20);
    expect(result[52]).toBe(30);
  });

  it("should read zeros when copying from out-of-bounds source", () => {
    const memory = new Uint8Array([10, 20, 30]);

    // Copy from offset 5 (out of bounds) to offset 0
    const result = copyMemory(memory, 0, 5, 3);
    expect(result[0]).toBe(0);
    expect(result[1]).toBe(0);
    expect(result[2]).toBe(0);
  });

  it("should handle zero-length copies", () => {
    const memory = new Uint8Array([10, 20, 30]);
    const result = copyMemory(memory, 0, 0, 0);
    expect(result).toBe(memory); // Same reference
  });

  it("should handle MCOPY edge cases", () => {
    // MCOPY: memory copy within same buffer
    const memory = new Uint8Array(96);
    memory[0] = 0xaa;
    memory[1] = 0xbb;
    memory[2] = 0xcc;

    // Copy 3 bytes from offset 0 to offset 32
    const result = copyMemory(memory, 32, 0, 3);
    expect(result[32]).toBe(0xaa);
    expect(result[33]).toBe(0xbb);
    expect(result[34]).toBe(0xcc);

    // Original data preserved
    expect(result[0]).toBe(0xaa);
    expect(result[1]).toBe(0xbb);
    expect(result[2]).toBe(0xcc);
  });

  it("should throw on destination overflow", () => {
    const memory = new Uint8Array([10, 20, 30]);
    expect(() =>
      copyMemory(memory, Number.MAX_SAFE_INTEGER, 0, 3)
    ).toThrow("Memory destination overflow");
  });

  it("should throw on source overflow", () => {
    const memory = new Uint8Array([10, 20, 30]);
    expect(() =>
      copyMemory(memory, 0, Number.MAX_SAFE_INTEGER, 3)
    ).toThrow("Memory source overflow");
  });
});

describe("Memory expansion cost examples from EVM spec", () => {
  it("should match expected costs for common patterns", () => {
    // MSTORE at offset 0 (32 bytes)
    expect(calculateMemoryExpansionCost(0, 32)).toBe(3);

    // MSTORE at offset 32 after previous MSTORE at 0
    expect(calculateMemoryExpansionCost(32, 64)).toBe(3);

    // Large expansion from 0 to 1KB (32 words)
    expect(calculateMemoryExpansionCost(0, 1024)).toBe(98);

    // Large expansion from 0 to 10KB (320 words)
    expect(calculateMemoryExpansionCost(0, 10240)).toBe(1160);
  });

  it("should demonstrate quadratic growth", () => {
    const cost0to100 = calculateMemoryExpansionCost(0, 100 * 32);
    const cost100to200 = calculateMemoryExpansionCost(100 * 32, 200 * 32);
    const cost200to300 = calculateMemoryExpansionCost(200 * 32, 300 * 32);

    // Each 100-word expansion should cost more than the previous
    expect(cost100to200).toBeGreaterThan(cost0to100);
    expect(cost200to300).toBeGreaterThan(cost100to200);

    // Verify actual values
    expect(cost0to100).toBe(319); // 3*100 + 100²/512 = 300 + 19
    expect(cost100to200).toBe(359); // (3*200 + 200²/512) - (3*100 + 100²/512) = 678 - 319
    expect(cost200to300).toBe(397); // (3*300 + 300²/512) - (3*200 + 200²/512) = 1075 - 678
  });
});
