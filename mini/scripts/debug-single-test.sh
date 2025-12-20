#!/bin/bash
# Debug a single failing test by running just one test case

# Run the specs and capture the first failure
zig build specs 2>&1 | head -200 > /tmp/first_failure.log

echo "First failure captured to /tmp/first_failure.log"
cat /tmp/first_failure.log
