#!/usr/bin/env python3
"""
Generate Zig test files from execution-specs JSON test files.
This script scans the execution-specs directory and creates a Zig test file
for each JSON test file.
"""

import os
import json
import sys
from pathlib import Path


def sanitize_test_name(name: str) -> str:
    """Convert test name to valid Zig identifier."""
    # Replace invalid characters with underscores
    sanitized = name.replace("-", "_").replace(".", "_").replace(" ", "_")
    # Remove any other special characters
    sanitized = "".join(c if c.isalnum() or c == "_" else "_" for c in sanitized)
    # Ensure it doesn't start with a number
    if sanitized and sanitized[0].isdigit():
        sanitized = "test_" + sanitized
    return sanitized


def generate_test_file(json_path: Path, output_dir: Path, specs_root: Path, repo_root: Path) -> int:
    """Generate a Zig test file for a JSON test file. Returns number of tests generated."""
    # Read and parse JSON to get test names
    try:
        with open(json_path, "r") as f:
            data = json.load(f)
    except (json.JSONDecodeError, IOError) as e:
        print(f"Warning: Could not parse {json_path}: {e}", file=sys.stderr)
        return 0

    if not isinstance(data, dict):
        print(f"Warning: {json_path} does not contain a test object", file=sys.stderr)
        return 0

    # Get relative path from specs root for the JSON file
    rel_path = json_path.relative_to(specs_root)

    # Create output file path
    output_file = output_dir / rel_path.with_suffix(".zig")
    output_file.parent.mkdir(parents=True, exist_ok=True)

    # Calculate relative path from generated file back to root.zig
    # The generated file will be at test/specs/generated/...
    # We need to import root.zig from test/specs/
    depth = len(output_file.relative_to(output_dir).parts)  # includes the file itself
    # Go up to test/specs/generated/, then up once more to test/specs/
    root_import = "../" * depth + "root.zig"

    # Generate Zig test code
    zig_code = ['const std = @import("std");']
    zig_code.append('const testing = std.testing;')
    zig_code.append(f'const root = @import("{root_import}");')
    zig_code.append('const runner = root.runner;')
    zig_code.append("")

    # Track used test names to handle collisions
    used_names = {}
    test_count = 0

    # Generate a test for each test case in the JSON file
    for test_name in data.keys():
        safe_test_name = sanitize_test_name(test_name)

        # Handle duplicate test names by appending a counter
        if safe_test_name in used_names:
            used_names[safe_test_name] += 1
            unique_test_name = f"{safe_test_name}_{used_names[safe_test_name]}"
        else:
            used_names[safe_test_name] = 0
            unique_test_name = safe_test_name

        # Absolute path to JSON file from repository root
        # When tests run, cwd is the repository root
        # Construct path relative to repo_root
        json_abs_path = str((specs_root / rel_path).relative_to(repo_root))

        zig_code.append(f'test "{unique_test_name}" {{')
        zig_code.append("    const allocator = testing.allocator;")
        zig_code.append("")
        zig_code.append("    // Read and parse the JSON test file")
        zig_code.append(f'    const json_path = "{json_abs_path}";')
        zig_code.append("    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);")
        zig_code.append("    defer allocator.free(json_content);")
        zig_code.append("")
        zig_code.append("    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});")
        zig_code.append("    defer parsed.deinit();")
        zig_code.append("")
        zig_code.append("    // Get the specific test case")
        zig_code.append(f'    const test_name = "{test_name}";')
        zig_code.append(f'    const test_case = parsed.value.object.get(test_name) orelse return error.TestNotFound;')
        zig_code.append("")
        zig_code.append("    // Run the test with path and name for trace generation")
        zig_code.append("    try runner.runJsonTestWithPathAndName(allocator, test_case, json_path, test_name);")
        zig_code.append("}")
        zig_code.append("")
        test_count += 1

    # Write the Zig file
    with open(output_file, "w") as f:
        f.write("\n".join(zig_code))

    return test_count


def main():
    import sys

    # Get test type from command line argument
    test_type = sys.argv[1] if len(sys.argv) > 1 else "state"

    if test_type not in ["state", "blockchain"]:
        print(f"Error: Invalid test type '{test_type}'. Must be 'state' or 'blockchain'", file=sys.stderr)
        sys.exit(1)

    # Get the repository root
    script_dir = Path(__file__).parent
    repo_root = script_dir.parent
    specs_base = repo_root / "execution-specs" / "tests" / "eest" / "static" / "state_tests"

    # Select appropriate test directory based on test type
    if test_type == "state":
        specs_root = specs_base / "state_tests"
        output_root = repo_root / "test" / "specs" / "generated_state"
    else:  # blockchain
        specs_root = specs_base / "blockchain_tests"
        output_root = repo_root / "test" / "specs" / "generated_blockchain"

    # Clean output directory
    if output_root.exists():
        import shutil
        shutil.rmtree(output_root)
    output_root.mkdir(parents=True, exist_ok=True)

    # Find all JSON test files (excluding .meta directories)
    json_files = [f for f in specs_root.rglob("*.json") if ".meta" not in f.parts]
    print(f"Found {len(json_files)} {test_type.upper()} test JSON files")
    print(f"Generating {test_type} test files...")

    # Generate test files
    total_tests = 0
    for i, json_file in enumerate(json_files, 1):
        if i % 100 == 0:
            print(f"Progress: {i}/{len(json_files)} files...")
        test_count = generate_test_file(json_file, output_root, specs_root, repo_root)
        total_tests += test_count

    print(f"\nGenerated {total_tests} {test_type} zig tests in {output_root}")


if __name__ == "__main__":
    main()
