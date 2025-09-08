#!/bin/bash

# Simple script to run CLI and capture all debug logs
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="debug_${TIMESTAMP}.log"

echo "Building Guillotine CLI..."
go build -o guillotine-cli .

echo "Starting Guillotine CLI..."
echo "All debug output will be captured to: ${LOG_FILE}"
echo ""

# Run the CLI with stderr redirected to log file
# This preserves the normal CLI experience while capturing debug logs
./guillotine-cli 2>"${LOG_FILE}"

echo ""
echo "CLI exited."
echo "Debug log saved to: ${LOG_FILE}"