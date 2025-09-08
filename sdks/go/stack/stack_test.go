package stack

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/evmts/guillotine/bindings/go/primitives"
)

// Test the stack creation and destruction
func TestStack_New(t *testing.T) {
	t.Run("ValidCreation", func(t *testing.T) {
		// Should create a new stack successfully
		stack, err := New()
		require.NoError(t, err)
		require.NotNil(t, stack)
		defer stack.Close()

		// Should start empty
		assert.True(t, stack.IsEmpty())
		assert.Equal(t, uint32(0), stack.Size())
		assert.False(t, stack.IsFull())
		assert.Equal(t, uint32(1024), stack.Capacity()) // EVM standard
	})
}

func TestStack_BasicOperations(t *testing.T) {
	stack, err := New()
	require.NoError(t, err)
	defer stack.Close()

	t.Run("PushU64", func(t *testing.T) {
		// Should push 64-bit values
		err := stack.PushU64(42)
		require.NoError(t, err)
		assert.Equal(t, uint32(1), stack.Size())
		assert.False(t, stack.IsEmpty())

		err = stack.PushU64(100)
		require.NoError(t, err)
		assert.Equal(t, uint32(2), stack.Size())
	})

	t.Run("PopU64", func(t *testing.T) {
		// Should pop in LIFO order
		value, err := stack.PopU64()
		require.NoError(t, err)
		assert.Equal(t, uint64(100), value)
		assert.Equal(t, uint32(1), stack.Size())

		value, err = stack.PopU64()
		require.NoError(t, err)
		assert.Equal(t, uint64(42), value)
		assert.Equal(t, uint32(0), stack.Size())
		assert.True(t, stack.IsEmpty())
	})

	t.Run("PopEmptyStack", func(t *testing.T) {
		// Should error on underflow
		_, err := stack.PopU64()
		assert.Error(t, err)
		assert.Contains(t, err.Error(), "underflow")
	})
}

func TestStack_U256Operations(t *testing.T) {
	stack, err := New()
	require.NoError(t, err)
	defer stack.Close()

	t.Run("PushU256", func(t *testing.T) {
		// Test with various U256 values
		values := []string{
			"0x0",
			"0x42",
			"0x1234567890abcdef",
			"0x1fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
		}

		for _, valueHex := range values {
			value, err := primitives.U256FromHex(valueHex)
			require.NoError(t, err)

			err = stack.PushU256(value)
			require.NoError(t, err)
		}

		assert.Equal(t, uint32(len(values)), stack.Size())
	})

	t.Run("PopU256", func(t *testing.T) {
		// Should pop in reverse order
		expectedValues := []string{
			"0x1fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
			"0x1234567890abcdef", 
			"0x42",
			"0x0",
		}

		for _, expectedHex := range expectedValues {
			expected, err := primitives.U256FromHex(expectedHex)
			require.NoError(t, err)

			actual, err := stack.PopU256()
			require.NoError(t, err)
			assert.True(t, actual.Equal(expected), 
				"Expected %s, got %s", expected.Hex(), actual.Hex())
		}

		assert.True(t, stack.IsEmpty())
	})
}

func TestStack_PeekOperations(t *testing.T) {
	stack, err := New()
	require.NoError(t, err)
	defer stack.Close()

	// Set up test data
	values := []uint64{10, 20, 30, 40, 50}
	for _, v := range values {
		err := stack.PushU64(v)
		require.NoError(t, err)
	}

	t.Run("PeekTop", func(t *testing.T) {
		// Should peek at top without removing
		value, err := stack.PeekU64()
		require.NoError(t, err)
		assert.Equal(t, uint64(50), value) // Last pushed
		assert.Equal(t, uint32(5), stack.Size()) // Size unchanged
	})

	t.Run("PeekAt", func(t *testing.T) {
		// Should peek at specific depths
		testCases := []struct {
			depth    uint32
			expected uint64
		}{
			{0, 50}, // Top
			{1, 40}, // Second from top
			{2, 30}, // Third from top  
			{3, 20}, // Fourth from top
			{4, 10}, // Bottom
		}

		for _, tc := range testCases {
			value, err := stack.PeekAt(tc.depth)
			require.NoError(t, err, "Failed to peek at depth %d", tc.depth)
			assert.Equal(t, tc.expected, value, 
				"Wrong value at depth %d", tc.depth)
		}

		// Size should remain unchanged
		assert.Equal(t, uint32(5), stack.Size())
	})

	t.Run("PeekOutOfBounds", func(t *testing.T) {
		// Should error when peeking beyond stack size
		_, err := stack.PeekAt(10)
		assert.Error(t, err)
		assert.Contains(t, err.Error(), "underflow")
	})
}

func TestStack_EVMOperations(t *testing.T) {
	stack, err := New()
	require.NoError(t, err)
	defer stack.Close()

	// Set up test data: [10, 20, 30, 40, 50] (50 on top)
	for _, v := range []uint64{10, 20, 30, 40, 50} {
		err := stack.PushU64(v)
		require.NoError(t, err)
	}

	t.Run("Dup", func(t *testing.T) {
		// DUP1 - duplicate top element
		err := stack.Dup(1)
		require.NoError(t, err)
		assert.Equal(t, uint32(6), stack.Size())

		// Top two should be same
		val1, err := stack.PopU64()
		require.NoError(t, err)
		val2, err := stack.PopU64()
		require.NoError(t, err)
		assert.Equal(t, uint64(50), val1)
		assert.Equal(t, uint64(50), val2)
	})

	t.Run("Swap", func(t *testing.T) {
		// Current stack: [10, 20, 30, 40] (40 on top)
		// SWAP1 - swap top two elements
		err := stack.Swap(1)
		require.NoError(t, err)
		assert.Equal(t, uint32(4), stack.Size()) // Size unchanged

		// Should have swapped 40 and 30
		val1, err := stack.PopU64()
		require.NoError(t, err)
		val2, err := stack.PopU64()  
		require.NoError(t, err)
		assert.Equal(t, uint64(30), val1) // Was second, now top
		assert.Equal(t, uint64(40), val2) // Was top, now second
	})
}

func TestStack_OverflowHandling(t *testing.T) {
	stack, err := New()
	require.NoError(t, err)
	defer stack.Close()

	t.Run("StackOverflow", func(t *testing.T) {
		// Fill stack to capacity (1024 items)
		capacity := stack.Capacity()
		for i := uint32(0); i < capacity; i++ {
			err := stack.PushU64(uint64(i))
			require.NoError(t, err)
		}

		assert.True(t, stack.IsFull())
		assert.Equal(t, capacity, stack.Size())

		// One more push should fail
		err := stack.PushU64(9999)
		assert.Error(t, err)
		assert.Contains(t, err.Error(), "overflow")
		
		// Size should be unchanged
		assert.Equal(t, capacity, stack.Size())
	})
}

func TestStack_ResourceManagement(t *testing.T) {
	t.Run("Close", func(t *testing.T) {
		stack, err := New()
		require.NoError(t, err)

		// Add some data
		err = stack.PushU64(42)
		require.NoError(t, err)

		// Should close successfully
		err = stack.Close()
		assert.NoError(t, err)

		// Operations after close should fail
		err = stack.PushU64(100)
		assert.Error(t, err)
		assert.Contains(t, err.Error(), "closed")
	})

	t.Run("DoubleClose", func(t *testing.T) {
		stack, err := New()
		require.NoError(t, err)

		err1 := stack.Close()
		err2 := stack.Close()
		
		assert.NoError(t, err1)
		assert.NoError(t, err2) // Should not error on double close
	})
}

func TestStack_Reset(t *testing.T) {
	stack, err := New()
	require.NoError(t, err)
	defer stack.Close()

	// Add some data
	for i := 0; i < 10; i++ {
		err := stack.PushU64(uint64(i))
		require.NoError(t, err)
	}
	assert.Equal(t, uint32(10), stack.Size())

	// Reset should clear the stack
	err = stack.Reset()
	require.NoError(t, err)

	assert.True(t, stack.IsEmpty())
	assert.Equal(t, uint32(0), stack.Size())
	assert.False(t, stack.IsFull())
}

func TestStack_Contents(t *testing.T) {
	stack, err := New()
	require.NoError(t, err)
	defer stack.Close()

	// Add test data
	testValues := []uint64{10, 20, 30, 40, 50}
	for _, v := range testValues {
		err := stack.PushU64(v)
		require.NoError(t, err)
	}

	t.Run("GetContents", func(t *testing.T) {
		contents, err := stack.GetContents()
		require.NoError(t, err)
		
		// Should get all items (top first)
		assert.Len(t, contents, len(testValues))
		
		// Verify order (top to bottom)
		expectedOrder := []uint64{50, 40, 30, 20, 10}
		for i, expected := range expectedOrder {
			assert.True(t, contents[i].Equal(primitives.NewU256(expected)),
				"Position %d: expected %d, got %s", i, expected, contents[i].Hex())
		}
	})
}

func TestStack_ConcurrentAccess(t *testing.T) {
	stack, err := New()
	require.NoError(t, err)
	defer stack.Close()

	t.Run("ConcurrentReads", func(t *testing.T) {
		// Add some data
		for i := 0; i < 100; i++ {
			err := stack.PushU64(uint64(i))
			require.NoError(t, err)
		}

		// Concurrent reads should be safe
		done := make(chan bool, 2)

		go func() {
			for i := 0; i < 50; i++ {
				size := stack.Size()
				assert.GreaterOrEqual(t, size, uint32(50)) // Should have at least 50
			}
			done <- true
		}()

		go func() {
			for i := 0; i < 50; i++ {
				isEmpty := stack.IsEmpty()
				assert.False(t, isEmpty) // Should not be empty
			}
			done <- true
		}()

		<-done
		<-done
	})
}

// Benchmark tests
func BenchmarkStack_PushU64(b *testing.B) {
	stack, err := New()
	if err != nil {
		b.Fatal(err)
	}
	defer stack.Close()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if err := stack.PushU64(uint64(i)); err != nil {
			b.Fatal(err)
		}
		
		// Reset when approaching capacity
		if i%1000 == 999 {
			stack.Reset()
		}
	}
}

func BenchmarkStack_PopU64(b *testing.B) {
	stack, err := New()
	if err != nil {
		b.Fatal(err)
	}
	defer stack.Close()

	// Pre-populate stack
	for i := 0; i < 1000; i++ {
		if err := stack.PushU64(uint64(i)); err != nil {
			b.Fatal(err)
		}
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		// Replenish when empty
		if stack.IsEmpty() {
			for j := 0; j < 1000; j++ {
				stack.PushU64(uint64(j))
			}
		}
		
		if _, err := stack.PopU64(); err != nil {
			b.Fatal(err)
		}
	}
}