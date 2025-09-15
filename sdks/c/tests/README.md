# Guillotine C SDK Tests

This directory contains tests for the Guillotine C SDK.

## Test Files

- `simple_test.c` - Basic compilation and header inclusion tests
- `basic_test.c` - Full integration tests (requires crypto library linking)

## Running Tests

### Simple Compilation Test
```bash
make simple
```

This test verifies:
- Header files compile correctly
- Basic types are available
- FFI binding structure is valid

### Full Integration Test (Advanced)
```bash
make basic
```

This test requires proper linking with crypto libraries and verifies:
- EVM initialization and cleanup
- Balance operations
- Contract deployment
- Basic contract execution

## Notes

The simple test is sufficient to verify that the C SDK structure is correct and can be used for FFI bindings. The full integration test requires additional setup for crypto dependencies (BLS, KZG libraries).

For production use, the C SDK primarily serves as a header file for other language bindings rather than direct C usage, though direct C usage is fully supported with proper linking.