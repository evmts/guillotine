#!/usr/bin/env python3
"""
Fetch Ethereum execution spec test fixtures.
Python equivalent of fetch-test-fixtures.sh for better cross-platform compatibility.
"""

import os
import sys
import subprocess
import tempfile
import shutil
import tarfile
import urllib.request
from pathlib import Path


def run_git_command(args):
    """Run a git command and return the output."""
    result = subprocess.run(['git'] + args, capture_output=True, text=True, check=True)
    return result.stdout.strip()


def download_file(url, dest_path):
    """Download a file from URL to destination path with progress indication."""
    print(f"Downloading from {url}...")
    try:
        with urllib.request.urlopen(url) as response:
            total_size = int(response.headers.get('Content-Length', 0))
            downloaded = 0
            block_size = 8192

            with open(dest_path, 'wb') as f:
                while True:
                    chunk = response.read(block_size)
                    if not chunk:
                        break
                    f.write(chunk)
                    downloaded += len(chunk)
                    if total_size > 0:
                        percent = (downloaded / total_size) * 100
                        print(f"  Progress: {percent:.1f}%", end='\r')

            if total_size > 0:
                print()  # New line after progress
            return True
    except Exception as e:
        print(f"Error downloading file: {e}", file=sys.stderr)
        return False


def main():
    # Configuration
    FIXTURES_TYPE = "fixtures_stable"  # Can be fixtures_stable, fixtures_develop, or fixtures_benchmark
    FIXTURES_BASE_DIR = "test/execution-spec-tests/fixtures"
    FIXTURES_DIR = os.path.join(FIXTURES_BASE_DIR, FIXTURES_TYPE)
    VERSION_FILE = ".test-fixtures-version"

    # Check if version file exists
    if not os.path.exists(VERSION_FILE):
        print(f"Error: Version file '{VERSION_FILE}' not found", file=sys.stderr)
        sys.exit(1)

    # Read required version
    with open(VERSION_FILE, 'r') as f:
        REQUIRED_VERSION = f.read().strip()

    if not REQUIRED_VERSION:
        print("Error: Version file is empty", file=sys.stderr)
        sys.exit(1)

    CURRENT_VERSION_FILE = os.path.join(FIXTURES_DIR, ".version")

    # Check if we already have the right version
    if os.path.exists(CURRENT_VERSION_FILE):
        with open(CURRENT_VERSION_FILE, 'r') as f:
            current_version = f.read().strip()
            if current_version == REQUIRED_VERSION:
                print(f"✅ Test fixtures ({FIXTURES_TYPE}) {REQUIRED_VERSION} already installed")
                return 0

    print(f"📥 Fetching Ethereum test fixtures ({FIXTURES_TYPE}) {REQUIRED_VERSION}...")

    # Get repository root
    try:
        repo_root = run_git_command(['rev-parse', '--show-toplevel'])
    except subprocess.CalledProcessError:
        print("Error: Not in a git repository", file=sys.stderr)
        sys.exit(1)

    fixtures_dir_abs = os.path.join(repo_root, FIXTURES_DIR)
    fixtures_base_abs = os.path.join(repo_root, FIXTURES_BASE_DIR)

    # Clean old fixtures
    if os.path.exists(fixtures_dir_abs):
        print(f"Removing old fixtures at {fixtures_dir_abs}...")
        shutil.rmtree(fixtures_dir_abs)

    # Create base directory if it doesn't exist
    os.makedirs(fixtures_base_abs, exist_ok=True)

    # Create temporary directory for extraction
    with tempfile.TemporaryDirectory() as temp_dir:
        # Download from GitHub releases
        url = f"https://github.com/ethereum/execution-spec-tests/releases/download/{REQUIRED_VERSION}/{FIXTURES_TYPE}.tar.gz"
        tar_path = os.path.join(temp_dir, "fixtures.tar.gz")

        print(f"Downloading {FIXTURES_TYPE}.tar.gz...")
        if not download_file(url, tar_path):
            print(f"Error: Failed to download fixtures from {url}", file=sys.stderr)
            sys.exit(1)

        # Extract tar file
        print("Extracting fixtures...")
        try:
            with tarfile.open(tar_path, 'r:gz') as tar:
                tar.extractall(path=temp_dir)
        except Exception as e:
            print(f"Error extracting tar file: {e}", file=sys.stderr)
            sys.exit(1)

        # Find the extracted fixtures directory
        extracted_dir = os.path.join(temp_dir, "fixtures")
        if not os.path.exists(extracted_dir):
            # Sometimes the archive might have a different structure
            # List what was extracted
            extracted_items = os.listdir(temp_dir)
            extracted_items = [item for item in extracted_items if item != "fixtures.tar.gz"]
            if len(extracted_items) == 1 and os.path.isdir(os.path.join(temp_dir, extracted_items[0])):
                extracted_dir = os.path.join(temp_dir, extracted_items[0])
            else:
                print("Error: Unexpected archive structure", file=sys.stderr)
                print(f"Extracted items: {extracted_items}", file=sys.stderr)
                sys.exit(1)

        # Move the extracted directory to the correct location
        print(f"Moving fixtures to {fixtures_dir_abs}...")
        shutil.move(extracted_dir, fixtures_dir_abs)

    # Write version file
    version_file_path = os.path.join(fixtures_dir_abs, ".version")
    with open(version_file_path, 'w') as f:
        f.write(REQUIRED_VERSION)

    print(f"✅ Test fixtures ({FIXTURES_TYPE}) {REQUIRED_VERSION} installed")
    return 0


if __name__ == "__main__":
    sys.exit(main())