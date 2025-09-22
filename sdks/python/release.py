#!/usr/bin/env python3
"""
Release helper script for test-guillotine-publish package.

Usage:
    python release.py [patch|minor|major] [--test]

Examples:
    python release.py patch --test  # Release patch version to TestPyPI
    python release.py minor          # Release minor version to PyPI
"""

import argparse
import subprocess
import sys
import os
from pathlib import Path

def run_command(cmd, cwd=None):
    """Run a shell command and return the result."""
    print(f"Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Error: {result.stderr}")
        sys.exit(1)
    return result.stdout.strip()

def main():
    parser = argparse.ArgumentParser(description="Release helper for test-guillotine-publish")
    parser.add_argument("bump_type", choices=["patch", "minor", "major"],
                        help="Type of version bump")
    parser.add_argument("--test", action="store_true",
                        help="Upload to TestPyPI instead of PyPI")
    parser.add_argument("--skip-build", action="store_true",
                        help="Skip building the Zig library")
    parser.add_argument("--skip-tests", action="store_true",
                        help="Skip running tests")

    args = parser.parse_args()

    # Change to the script's directory
    script_dir = Path(__file__).parent
    os.chdir(script_dir)

    # Step 1: Build the Zig library
    if not args.skip_build:
        print("\n=== Building Zig library ===")
        run_command(["zig", "build", "python"], cwd=script_dir.parent.parent)

    # Step 2: Run tests
    if not args.skip_tests and (script_dir / "tests").exists():
        print("\n=== Running tests ===")
        run_command(["python", "-m", "pytest", "tests/"])

    # Step 3: Bump version
    print(f"\n=== Bumping {args.bump_type} version ===")
    run_command(["bump2version", args.bump_type])

    # Step 4: Clean previous builds
    print("\n=== Cleaning previous builds ===")
    for dir_name in ["dist", "build", "*.egg-info"]:
        run_command(["rm", "-rf", dir_name])

    # Step 5: Build distributions
    print("\n=== Building distributions ===")
    run_command(["python", "-m", "build", "--sdist", "--wheel"])

    # Step 6: Check distributions
    print("\n=== Checking distributions ===")
    run_command(["twine", "check", "dist/*"])

    # Step 7: Upload to PyPI or TestPyPI
    if args.test:
        print("\n=== Uploading to TestPyPI ===")
        run_command(["twine", "upload", "--repository", "testpypi", "dist/*"])
        print("\n✅ Package uploaded to TestPyPI!")
        print("Install with: pip install --index-url https://test.pypi.org/simple/ test-guillotine-publish")
    else:
        print("\n=== Uploading to PyPI ===")
        response = input("Are you sure you want to upload to production PyPI? (yes/no): ")
        if response.lower() == "yes":
            run_command(["twine", "upload", "dist/*"])
            print("\n✅ Package uploaded to PyPI!")
            print("Install with: pip install test-guillotine-publish")
        else:
            print("Upload cancelled.")

    print("\n=== Release complete! ===")

if __name__ == "__main__":
    main()