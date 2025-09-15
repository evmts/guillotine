# C SDK Makefile
CC = gcc
CFLAGS = -Wall -Wextra -std=c99 -I../rust
LDFLAGS = -L/Users/williamcory/guillotine/zig-out/lib -lguillotine_ffi_static -L/Users/williamcory/guillotine/target/release -lc_kzg -lblst
TESTDIR = tests
BUILDDIR = build

# Platform-specific adjustments
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Linux)
    LDFLAGS += -lpthread -lm -ldl
endif
ifeq ($(UNAME_S),Darwin)
    LDFLAGS += -framework Foundation
endif

.PHONY: all test clean build-core

all: test

# Build the Guillotine core first
build-core:
	@echo "Building Guillotine core library..."
	cd /Users/williamcory/guillotine && zig build

# Create build directory
$(BUILDDIR):
	mkdir -p $(BUILDDIR)

# Build and run tests
test: build-core $(BUILDDIR)
	@echo "Compiling C SDK tests..."
	$(CC) $(CFLAGS) $(TESTDIR)/basic_test.c -o $(BUILDDIR)/basic_test $(LDFLAGS)
	@echo "Running C SDK tests..."
	./$(BUILDDIR)/basic_test

# Individual test targets
basic: build-core $(BUILDDIR)
	$(CC) $(CFLAGS) $(TESTDIR)/basic_test.c -o $(BUILDDIR)/basic_test $(LDFLAGS)
	./$(BUILDDIR)/basic_test

simple: build-core $(BUILDDIR)
	$(CC) $(CFLAGS) $(TESTDIR)/simple_test.c -o $(BUILDDIR)/simple_test
	./$(BUILDDIR)/simple_test

# Clean build artifacts
clean:
	rm -rf $(BUILDDIR)

# Help
help:
	@echo "Available targets:"
	@echo "  test      - Build core, compile tests, and run all tests"
	@echo "  basic     - Run basic test only"
	@echo "  clean     - Clean build artifacts"
	@echo "  help      - Show this help message"