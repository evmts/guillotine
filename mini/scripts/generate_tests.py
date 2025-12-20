#!/usr/bin/env python3
"""
Generate Zig test files from Ethereum execution test JSON fixtures.

This script scans multiple test sources and creates a Zig test file for each JSON test file:
1. execution-specs/tests/eest/static/state_tests/ - Python execution specs tests
2. ethereum-tests/GeneralStateTests/ - Official Ethereum test suite

Each JSON file containing test cases becomes ONE Zig file with ONE test function per test case.
"""

import os
import json
import sys
from pathlib import Path
from typing import Dict, List, Tuple


def sanitize_test_name(name: str) -> str:
    """Convert test name to valid Zig identifier."""
    # Replace invalid characters with underscores
    sanitized = name.replace("-", "_").replace(".", "_").replace(" ", "_")
    sanitized = sanitized.replace("::", "_").replace("(", "_").replace(")", "_")
    sanitized = sanitized.replace("[", "_").replace("]", "_").replace(",", "_")
    # Remove any other special characters
    sanitized = "".join(c if c.isalnum() or c == "_" else "_" for c in sanitized)
    # Remove consecutive underscores
    while "__" in sanitized:
        sanitized = sanitized.replace("__", "_")
    # Ensure it doesn't start with a number
    if sanitized and sanitized[0].isdigit():
        sanitized = "test_" + sanitized
    return sanitized


def generate_test_file(
    json_path: Path,
    output_dir: Path,
    json_rel_path: str,
    source_name: str
) -> int:
    """
    Generate a Zig test file for a JSON test file.

    Returns the number of test cases generated.
    """
    # Read and parse JSON to get test names
    try:
        with open(json_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (json.JSONDecodeError, IOError) as e:
        print(f"Warning: Could not parse {json_path}: {e}", file=sys.stderr)
        return 0

    if not isinstance(data, dict):
        print(f"Warning: {json_path} does not contain a test object", file=sys.stderr)
        return 0

    # Create output file path - preserve directory structure
    # For execution-specs: stRandom/randomStatetest0Filler.json -> stRandom/randomStatetest0Filler.zig
    # For ethereum-tests: stSelfBalance/selfBalance.json -> ethereum_tests/stSelfBalance/selfBalance.zig
    if source_name == "ethereum_tests":
        output_file = output_dir / "ethereum_tests" / json_rel_path.replace(".json", ".zig")
    else:
        output_file = output_dir / json_rel_path.replace(".json", ".zig")

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

    test_count = 0
    used_names: Dict[str, int] = {}  # Track used test names to handle collisions

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

        zig_code.append(f'test "{unique_test_name}" {{')
        zig_code.append("    const allocator = testing.allocator;")
        zig_code.append("")
        zig_code.append("    // Read and parse the JSON test file")
        zig_code.append(f'    const json_path = "{json_rel_path}";')
        zig_code.append("    const json_content = try std.fs.cwd().readFileAlloc(allocator, json_path, 100 * 1024 * 1024);")
        zig_code.append("    defer allocator.free(json_content);")
        zig_code.append("")
        zig_code.append("    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});")
        zig_code.append("    defer parsed.deinit();")
        zig_code.append("")
        zig_code.append("    // Get the specific test case")
        zig_code.append(f'    const test_case = parsed.value.object.get("{test_name}") orelse return error.TestNotFound;')
        zig_code.append("")
        zig_code.append("    // Run the test with path for trace generation")
        zig_code.append("    try runner.runJsonTestWithPath(allocator, test_case, json_path);")
        zig_code.append("}")
        zig_code.append("")
        test_count += 1

    # Write the Zig file
    with open(output_file, "w", encoding="utf-8") as f:
        f.write("\n".join(zig_code))

    return test_count


def scan_test_directory(
    base_path: Path,
    source_name: str,
    repo_root: Path
) -> List[Tuple[Path, str]]:
    """
    Scan a test directory and return list of (json_file_path, relative_path_from_repo_root).
    """
    if not base_path.exists():
        print(f"Warning: Test directory not found: {base_path}", file=sys.stderr)
        return []

    json_files = []
    for json_file in base_path.rglob("*.json"):
        # Get path relative to repo root for the JSON file
        if source_name == "execution_specs":
            # For execution-specs, path from repo root is execution-specs/tests/eest/...
            rel_path = str(json_file.relative_to(repo_root))
        else:
            # For ethereum-tests, path from repo root is ethereum-tests/GeneralStateTests/...
            rel_path = str(json_file.relative_to(repo_root))

        json_files.append((json_file, rel_path))

    return json_files


def main():
    # Get the repository root
    script_dir = Path(__file__).parent
    repo_root = script_dir.parent

    # Define test sources
    test_sources = [
        {
            "name": "execution_specs",
            "path": repo_root / "execution-specs" / "tests" / "eest" / "static" / "state_tests",
            "description": "Python execution-specs tests"
        },
        {
            "name": "ethereum_tests",
            "path": repo_root / "ethereum-tests" / "GeneralStateTests",
            "description": "Official Ethereum test suite"
        }
    ]

    output_root = repo_root / "test" / "specs" / "generated"

    # Clean output directory
    if output_root.exists():
        import shutil
        shutil.rmtree(output_root)
    output_root.mkdir(parents=True, exist_ok=True)

    print("=" * 80)
    print("ETHEREUM TEST GENERATOR")
    print("=" * 80)
    print()

    total_files = 0
    total_tests = 0
    stats_by_source: Dict[str, Tuple[int, int]] = {}

    # Process each test source
    for source in test_sources:
        source_name = source["name"]
        source_path = source["path"]
        description = source["description"]

        print(f"Scanning {description}...")
        print(f"  Path: {source_path}")

        # Find all JSON test files
        json_files = scan_test_directory(source_path, source_name, repo_root)

        if not json_files:
            print(f"  No test files found!\n")
            continue

        print(f"  Found {len(json_files)} JSON test files")
        print(f"  Generating test files...")

        source_file_count = 0
        source_test_count = 0

        # Generate test files
        for i, (json_file, rel_path) in enumerate(json_files, 1):
            if i % 100 == 0:
                print(f"  Progress: {i}/{len(json_files)} files...")

            test_count = generate_test_file(json_file, output_root, rel_path, source_name)
            if test_count > 0:
                source_file_count += 1
                source_test_count += test_count

        print(f"  ✓ Generated {source_file_count} test files with {source_test_count} test cases")
        print()

        stats_by_source[source_name] = (source_file_count, source_test_count)
        total_files += source_file_count
        total_tests += source_test_count

    # Print summary
    print("=" * 80)
    print("GENERATION COMPLETE")
    print("=" * 80)
    print()
    print(f"Output directory: {output_root}")
    print()
    print("Test Sources:")
    for source in test_sources:
        source_name = source["name"]
        description = source["description"]
        if source_name in stats_by_source:
            files, tests = stats_by_source[source_name]
            print(f"  {description}:")
            print(f"    Files: {files}")
            print(f"    Tests: {tests}")
    print()
    print(f"Total: {total_files} test files with {total_tests} test cases")
    print()
    print("Next steps:")
    print("  1. Run: zig build test-specs")
    print("  2. Review test results")
    print()


if __name__ == "__main__":
    main()
