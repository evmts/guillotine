import { expect } from 'bun:test';

/**
 * Type-safe assertion helpers for tests
 * 
 * ## The Problem
 * 
 * TypeScript's strict null checking creates verbose test code when accessing arrays and optional properties:
 * 
 * ```typescript
 * // ❌ Verbose and repetitive
 * const log = result.logs[0];
 * if (!log) throw new Error('Log not found');
 * expect(log.address).toBe(addr);
 * 
 * // ❌ Type casting - loses type safety
 * const topic = (result.logs[0] as LogEntry).topics[0] as U256;
 * 
 * // ❌ Non-null assertions - discouraged by linters
 * const data = result.logs[0]!.data;
 * ```
 * 
 * ## The Solution: Type-Safe Assertion Functions
 * 
 * Use assertion functions that TypeScript understands:
 * 
 * ```typescript
 * import { first, getElement, assertDefined } from './test-assertions.js';
 * 
 * // ✅ Clean, type-safe, and informative
 * const log = first(result.logs, 'log');
 * expect(log.address).toBe(addr);
 * 
 * const topic = getElement(log.topics, 0, 'topic');
 * expect(topic.toBigInt()).toBe(42n);
 * ```
 * 
 * ## Available Helpers
 * 
 * ### Basic Assertions
 * ```typescript
 * // Assert value is defined and narrow type
 * assertDefined(value, 'Value must exist');
 * 
 * // Assert array element exists
 * assertExists(array[0], 'First element required');
 * ```
 * 
 * ### Array Access
 * ```typescript
 * // Get first/last with assertion
 * const firstLog = first(logs, 'log');
 * const lastTopic = last(topics, 'topic');
 * 
 * // Get by index with assertion
 * const thirdItem = getElement(items, 2, 'item');
 * 
 * // Assert array length
 * assertLength(results, 5, 'results');
 * ```
 * 
 * ### Property Access
 * ```typescript
 * // Get required property
 * const balance = getRequired(account, 'balance', 'account balance');
 * ```
 * 
 * ### Chaining (Advanced)
 * ```typescript
 * // Chain assertions for nested access
 * const value = assert(result)
 *   .get('logs')
 *   .at(0)
 *   .get('topics')
 *   .at(1)
 *   .val();
 * ```
 * 
 * ## Benefits
 * 
 * 1. **Type Safety**: TypeScript knows the value is defined after assertion
 * 2. **Better Errors**: Meaningful error messages with context
 * 3. **Clean Code**: Less boilerplate, more readable tests
 * 4. **Lint Friendly**: No non-null assertions or type casts
 * 5. **Consistent**: Same pattern everywhere
 * 
 * ## Usage Example
 * 
 * ```typescript
 * describe('Evm Logs', () => {
 *   it('should emit log with topics', async () => {
 *     const result = await evm.call(params);
 *     
 *     // Instead of:
 *     // if (!result.logs[0]) throw new Error('No logs');
 *     // if (!result.logs[0].topics[0]) throw new Error('No topic');
 *     // expect(result.logs[0].topics[0].toBigInt()).toBe(42n);
 *     
 *     // Use:
 *     const log = first(result.logs, 'log');
 *     const topic = first(log.topics, 'topic');
 *     expect(topic.toBigInt()).toBe(42n);
 *   });
 * });
 * ```
 */

/**
 * Assert that a value is defined and narrow its type
 */
export function assertDefined<T>(
  value: T | null | undefined,
  message?: string
): asserts value is T {
  expect(value).toBeDefined();
  if (value === null || value === undefined) {
    throw new Error(message ?? 'Expected value to be defined');
  }
}

/**
 * Assert that an array element exists and narrow its type
 */
export function assertExists<T>(
  value: T | undefined,
  message?: string
): asserts value is T {
  expect(value).toBeDefined();
  if (value === undefined) {
    throw new Error(message ?? 'Expected value to exist');
  }
}

/**
 * Get an array element with assertion
 */
export function getElement<T>(
  array: readonly T[],
  index: number,
  name?: string
): T {
  const element = array[index];
  assertExists(element, `${name ?? 'Element'} at index ${index} not found`);
  return element;
}

/**
 * Get a required property with assertion
 */
export function getRequired<T, K extends keyof T>(
  obj: T,
  key: K,
  name?: string
): NonNullable<T[K]> {
  const value = obj[key];
  assertDefined(value, `${name ?? String(key)} is required but was ${value}`);
  return value as NonNullable<T[K]>;
}

/**
 * Assert array has expected length and return typed array
 */
export function assertLength<T>(
  array: readonly T[],
  expectedLength: number,
  name?: string
): void {
  expect(array).toHaveLength(expectedLength);
  if (array.length !== expectedLength) {
    throw new Error(
      `${name ?? 'Array'} expected length ${expectedLength} but got ${array.length}`
    );
  }
}

/**
 * Get first element with assertion
 */
export function first<T>(array: readonly T[], name?: string): T {
  return getElement(array, 0, `First ${name ?? 'element'}`);
}

/**
 * Get last element with assertion
 */
export function last<T>(array: readonly T[], name?: string): T {
  return getElement(array, array.length - 1, `Last ${name ?? 'element'}`);
}

/**
 * Chain assertions for nested access
 */
export class AssertChain<T> {
  constructor(private value: T, private path: string = 'value') {}

  get<K extends keyof T>(key: K): AssertChain<NonNullable<T[K]>> {
    const nextValue = this.value[key];
    assertDefined(nextValue, `${this.path}.${String(key)} is not defined`);
    return new AssertChain(nextValue as NonNullable<T[K]>, `${this.path}.${String(key)}`);
  }

  at<U = T extends readonly (infer E)[] ? E : never>(index: number): AssertChain<U> {
    if (!Array.isArray(this.value)) {
      throw new Error(`${this.path} is not an array`);
    }
    const element = (this.value as readonly U[])[index];
    assertExists(element, `${this.path}[${index}] not found`);
    return new AssertChain(element, `${this.path}[${index}]`);
  }

  val(): T {
    return this.value;
  }
}

/**
 * Start an assertion chain
 */
export function assert<T>(value: T, name?: string): AssertChain<T> {
  return new AssertChain(value, name ?? 'value');
}