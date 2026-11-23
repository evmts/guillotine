# Invoke from the repository root: make -f sdks/c/Makefile test
CC = cc
CFLAGS ?= -Wall -Wextra -std=c99
CPPFLAGS += -Isdks/c/include
LDFLAGS += -Lzig-out/lib -Wl,-rpath,$(abspath zig-out/lib)
LDLIBS += -lguillotine_ffi
TESTDIR = sdks/c/tests
BUILDDIR = sdks/c/build

.PHONY: all test basic simple clean build-core help
all: test

build-core:
	zig build shared

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

$(BUILDDIR)/basic_test: $(TESTDIR)/basic_test.c sdks/c/include/guillotine.h build-core | $(BUILDDIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) $< -o $@ $(LDFLAGS) $(LDLIBS)

$(BUILDDIR)/simple_test: $(TESTDIR)/simple_test.c sdks/c/include/guillotine.h | $(BUILDDIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) $< -o $@

basic: $(BUILDDIR)/basic_test
	./$(BUILDDIR)/basic_test

simple: $(BUILDDIR)/simple_test
	./$(BUILDDIR)/simple_test

test: simple basic

clean:
	rm -rf $(BUILDDIR)

help:
	@echo "From the repository root: make -f sdks/c/Makefile [test|basic|simple|clean]"
