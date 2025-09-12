#!/bin/bash

# Script to build Zig compiler from source and then build the project
# This ensures we have the ghccc calling convention support

set -e  # Exit on error

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
ZIG_SOURCE_DIR="$PROJECT_ROOT/lib/zig"
ZIG_BUILD_DIR="$ZIG_SOURCE_DIR/build"

echo "==================================="
echo "Zig Compiler and Project Build Script"
echo "==================================="
echo ""

# Check if Zig source exists
if [ ! -d "$ZIG_SOURCE_DIR" ]; then
    echo "Error: Zig source not found at $ZIG_SOURCE_DIR"
    echo "Please ensure the Zig submodule is initialized:"
    echo "  git submodule update --init --recursive"
    exit 1
fi

# Check for required tools
echo "Checking for required tools..."
if ! command -v cmake &> /dev/null; then
    echo "Error: cmake is not installed. Please install cmake first."
    exit 1
fi

if ! command -v make &> /dev/null && ! command -v ninja &> /dev/null; then
    echo "Error: Neither make nor ninja is installed. Please install one of them."
    exit 1
fi

# Detect build system
BUILD_SYSTEM="make"
if command -v ninja &> /dev/null; then
    BUILD_SYSTEM="ninja"
    echo "Using Ninja build system (faster)"
else
    echo "Using Make build system"
fi

# Build Zig compiler
echo ""
echo "==================================="
echo "Building Zig Compiler with ghccc support"
echo "==================================="
echo ""

cd "$ZIG_SOURCE_DIR"

# Create build directory if it doesn't exist
if [ ! -d "$ZIG_BUILD_DIR" ]; then
    echo "Creating build directory..."
    mkdir -p "$ZIG_BUILD_DIR"
fi

cd "$ZIG_BUILD_DIR"

# Set LLVM and LLD paths for macOS
LLVM_PREFIX=""
LLD_PREFIX=""
if [[ "$OSTYPE" == "darwin"* ]]; then
    if [ -d "/opt/homebrew/opt/llvm@20" ]; then
        LLVM_PREFIX="/opt/homebrew/opt/llvm@20"
    elif [ -d "/usr/local/opt/llvm@20" ]; then
        LLVM_PREFIX="/usr/local/opt/llvm@20"
    elif [ -d "/opt/homebrew/opt/llvm" ]; then
        LLVM_PREFIX="/opt/homebrew/opt/llvm"
    elif [ -d "/usr/local/opt/llvm" ]; then
        LLVM_PREFIX="/usr/local/opt/llvm"
    fi
    
    if [ -d "/opt/homebrew/opt/lld@20" ]; then
        LLD_PREFIX="/opt/homebrew/opt/lld@20"
    elif [ -d "/usr/local/opt/lld@20" ]; then
        LLD_PREFIX="/usr/local/opt/lld@20"
    elif [ -d "/opt/homebrew/opt/lld" ]; then
        LLD_PREFIX="/opt/homebrew/opt/lld"
    elif [ -d "/usr/local/opt/lld" ]; then
        LLD_PREFIX="/usr/local/opt/lld"
    fi
    
    if [ -n "$LLVM_PREFIX" ]; then
        echo "Found LLVM at: $LLVM_PREFIX"
    fi
    if [ -n "$LLD_PREFIX" ]; then
        echo "Found LLD at: $LLD_PREFIX"
    fi
fi

# Configure if not already configured
if [ ! -f "CMakeCache.txt" ]; then
    echo "Configuring Zig build..."
    CMAKE_ARGS="-DCMAKE_BUILD_TYPE=Release -DZIG_NO_LIB=OFF"
    
    # Export paths for cmake to find
    if [ -n "$LLVM_PREFIX" ]; then
        export PATH="$LLVM_PREFIX/bin:$PATH"
    fi
    if [ -n "$LLD_PREFIX" ]; then
        export PATH="$LLD_PREFIX/bin:$PATH"
        export LIBRARY_PATH="$LLD_PREFIX/lib:$LIBRARY_PATH"
        export LD_LIBRARY_PATH="$LLD_PREFIX/lib:$LD_LIBRARY_PATH"
    fi
    
    if [ "$BUILD_SYSTEM" = "ninja" ]; then
        cmake .. -G Ninja $CMAKE_ARGS
    else
        cmake .. $CMAKE_ARGS
    fi
else
    echo "Build already configured, skipping cmake..."
fi

# Build Zig
echo "Building Zig compiler..."
if [ "$BUILD_SYSTEM" = "ninja" ]; then
    ninja -j$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
else
    make -j$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
fi

# Check if build succeeded
if [ ! -f "stage3/bin/zig" ]; then
    echo "Error: Zig build failed. The zig executable was not created."
    exit 1
fi

echo ""
echo "Zig compiler built successfully!"
echo "Zig executable: $ZIG_BUILD_DIR/stage3/bin/zig"

# Build the project
echo ""
echo "==================================="
echo "Building Guillotine Project"
echo "==================================="
echo ""

cd "$PROJECT_ROOT"

# Use the newly built Zig compiler
ZIG_EXECUTABLE="$ZIG_BUILD_DIR/stage3/bin/zig"

echo "Using Zig compiler: $ZIG_EXECUTABLE"
echo "Zig version:"
"$ZIG_EXECUTABLE" version

# Build in release-fast mode for maximum performance
echo ""
echo "Building project in release-fast mode..."
"$ZIG_EXECUTABLE" build -Doptimize=ReleaseFast

echo ""
echo "==================================="
echo "Build Complete!"
echo "==================================="
echo ""
echo "Zig compiler: $ZIG_BUILD_DIR/stage3/bin/zig"
echo "Project built in release-fast mode"
echo ""
echo "You can now run benchmarks with:"
echo "  $ZIG_EXECUTABLE build benchmark"
echo ""
echo "Or run tests with:"
echo "  $ZIG_EXECUTABLE build test-opcodes"