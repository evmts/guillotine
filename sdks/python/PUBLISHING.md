# Publishing test-guillotine-publish to PyPI

This guide explains how to publish the `test-guillotine-publish` Python package to PyPI.

## Prerequisites

1. **PyPI Account**: Register at [pypi.org](https://pypi.org) and [test.pypi.org](https://test.pypi.org)
2. **API Tokens**: Generate tokens from your PyPI account settings
3. **Build Tools**: Install required Python packages:
   ```bash
   pip install build twine bump2version wheel setuptools cffi
   ```
4. **Zig Compiler**: Ensure Zig 0.15.1 is installed

## Package Structure

```
sdks/python/
├── guillotine_evm/      # Main package code
│   ├── __init__.py       # Package initialization
│   ├── py.typed          # Type hints marker
│   └── *.py              # Module files
├── tests/                # Test files
├── pyproject.toml        # Package configuration
├── setup.py              # Backwards compatibility
├── MANIFEST.in           # Source distribution files
├── .bumpversion.cfg      # Version management config
├── release.py            # Release helper script
└── publish-to-pypi.yml   # GitHub Action workflow
```

## Local Development Publishing

### Quick Release (Using Helper Script)

```bash
# Test release (to TestPyPI)
python release.py patch --test

# Production release
python release.py minor
```

### Manual Release Process

1. **Build the Zig library**:
   ```bash
   cd ../..  # Go to project root
   zig build python
   cd sdks/python
   ```

2. **Bump version** (optional):
   ```bash
   # Patch version (0.1.0 -> 0.1.1)
   bump2version patch

   # Minor version (0.1.0 -> 0.2.0)
   bump2version minor

   # Major version (0.1.0 -> 1.0.0)
   bump2version major
   ```

3. **Build distributions**:
   ```bash
   # Clean previous builds
   rm -rf dist/ build/ *.egg-info

   # Build source and wheel distributions
   python -m build --sdist --wheel
   ```

4. **Check distributions**:
   ```bash
   twine check dist/*
   ```

5. **Upload to TestPyPI** (recommended first):
   ```bash
   twine upload --repository testpypi dist/*

   # Test installation
   pip install --index-url https://test.pypi.org/simple/ test-guillotine-publish
   ```

6. **Upload to PyPI**:
   ```bash
   twine upload dist/*
   ```

## GitHub Actions Publishing

The included workflow (`publish-to-pypi.yml`) automates the entire process.

**IMPORTANT**: Move `publish-to-pypi.yml` to `.github/workflows/publish-python.yml` in your repository root to enable the GitHub Action.

### Setup GitHub Secrets

1. Go to Repository Settings → Secrets → Actions
2. Add these secrets:
   - `TEST_PYPI_API_TOKEN`: Your TestPyPI token
   - `PYPI_API_TOKEN`: Your PyPI token

### Trigger the Workflow

1. Go to Actions tab → "Publish Python Package to PyPI"
2. Click "Run workflow"
3. Select options:
   - **Release type**: `test` or `production`
   - **Version bump**: `patch`, `minor`, or `major` (optional)

### What the Workflow Does

1. **Builds** the Zig library
2. **Bumps** version (if specified)
3. **Creates** source and wheel distributions
4. **Publishes** to TestPyPI or PyPI
5. **Creates** GitHub release (for production)
6. **Builds** platform-specific wheels (production only)

## Authentication

### Configure PyPI Credentials

Create `~/.pypirc`:

```ini
[distutils]
index-servers =
    pypi
    testpypi

[pypi]
username = __token__
password = pypi-AgEIcHl...your-token-here

[testpypi]
username = __token__
password = pypi-AgEIcHl...your-test-token-here
```

### Using Environment Variables

```bash
export TWINE_USERNAME=__token__
export TWINE_PASSWORD=pypi-AgEIcHl...your-token-here
twine upload dist/*
```

## Platform-Specific Wheels

For maximum compatibility, build wheels for multiple platforms:

### Using cibuildwheel

```bash
pip install cibuildwheel

# Build for current platform
cibuildwheel --output-dir dist

# Build for specific Python versions
CIBW_BUILD="cp39-* cp310-* cp311-*" cibuildwheel --output-dir dist
```

### Manual Cross-Platform Building

```bash
# Linux wheels
docker run -v $(pwd):/io python:3.11 bash -c "cd /io && pip install build && python -m build"

# macOS wheels (on macOS)
python -m build --wheel

# Windows wheels (on Windows)
python -m build --wheel
```

## Version Management

Version is tracked in multiple places:
- `pyproject.toml`: Main version source
- `guillotine_evm/__init__.py`: Runtime version
- Git tags: `python-v0.1.0` format

The `.bumpversion.cfg` keeps these synchronized.

## Testing the Published Package

### From TestPyPI

```bash
pip install --index-url https://test.pypi.org/simple/ --extra-index-url https://pypi.org/simple test-guillotine-publish
```

### From PyPI

```bash
pip install test-guillotine-publish

# Verify installation
python -c "import guillotine_evm; print(guillotine_evm.__version__)"
```

## Troubleshooting

### Common Issues

1. **Missing compiled library**: Ensure `zig build python` was run
2. **Version conflict**: Package name already exists with that version
3. **Authentication failed**: Check API token and `.pypirc` configuration
4. **Missing dependencies**: Install all build requirements
5. **Platform compatibility**: Use cibuildwheel for cross-platform wheels

### Checking Package Contents

```bash
# List files in source distribution
tar -tzf dist/*.tar.gz

# Inspect wheel contents
unzip -l dist/*.whl

# Extract and examine
cd /tmp
pip download --no-deps test-guillotine-publish
unzip test_guillotine_publish-*.whl
```

## Best Practices

1. **Always test on TestPyPI first**
2. **Use semantic versioning** (MAJOR.MINOR.PATCH)
3. **Include comprehensive metadata** in pyproject.toml
4. **Build platform-specific wheels** for better performance
5. **Tag releases in Git** for traceability
6. **Document breaking changes** in release notes
7. **Test installation** in clean virtual environment

## Package URLs

Once published:
- **PyPI**: https://pypi.org/project/test-guillotine-publish/
- **TestPyPI**: https://test.pypi.org/project/test-guillotine-publish/
- **Documentation**: Link to your docs
- **Repository**: https://github.com/evmts/guillotine