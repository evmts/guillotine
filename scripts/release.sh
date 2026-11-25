#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

usage() {
  cat <<'EOF'
Usage: ./scripts/release.sh <version> [--dry-run]

Prepare a Guillotine release:
  1. Validates semver (X.Y.Z or X.Y.Z-alpha.N, without a leading 'v').
  2. Verifies CHANGELOG.md contains a section for <version>.
  3. Syncs .version in build.zig.zon and "version" in sdks/typescript/package.json
     (skipped with preview in --dry-run mode).
  4. Runs local preflight checks:
       - zig build
       - zig build shared -Doptimize=ReleaseFast
       - sdks/typescript: bun install, build:native, build, typecheck, test, lint:package
  5. Prints exact jj and gh commands to tag and trigger .github/workflows/release.yml.

Options:
  --dry-run    Validate and run preflight checks without modifying version files.
  -h, --help   Show this help message.
EOF
}

VERSION=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Error: unknown option '$1'" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$VERSION" ]]; then
        echo "Error: unexpected extra argument '$1'" >&2
        usage >&2
        exit 1
      fi
      VERSION="$1"
      shift
      ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "Error: <version> is required." >&2
  usage >&2
  exit 1
fi

if [[ "$VERSION" == v* ]]; then
  echo "Error: omit the leading 'v' in <version> (got '$VERSION', expected '${VERSION#v}')." >&2
  exit 1
fi

SEMVER_REGEX='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
if [[ ! "$VERSION" =~ $SEMVER_REGEX ]]; then
  echo "Error: '$VERSION' is not valid semver (expected X.Y.Z or X.Y.Z-alpha.N)." >&2
  exit 1
fi

echo "==> Release preflight for Guillotine v${VERSION} (dry_run=${DRY_RUN})"

# 1. Verify toolchain availability
for cmd in zig bun python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required tool '$cmd' not found in PATH." >&2
    exit 1
  fi
done

ZIG_VERSION="$(zig version)"
if [[ ! "$ZIG_VERSION" =~ ^0\.15\. ]]; then
  echo "Error: Zig 0.15.x is required (CI uses 0.15.2; found '$ZIG_VERSION')." >&2
  echo "Hint: switch toolchains (e.g. PATH=\"\$HOME/.zvm/0.15.2:\$PATH\" or zvm use 0.15.2)." >&2
  exit 1
fi
echo "    zig: $ZIG_VERSION"
echo "    bun: $(bun --version)"

# 2. Verify CHANGELOG.md contains an entry for <version>
if [[ ! -f CHANGELOG.md ]]; then
  echo "Error: CHANGELOG.md not found at repository root." >&2
  exit 1
fi

if ! python3 - "$VERSION" CHANGELOG.md <<'PY'
import re
import sys
from pathlib import Path

version, path = sys.argv[1], Path(sys.argv[2])
text = path.read_text(encoding="utf-8")
pattern = re.compile(
    rf"^##\s+(?:\[{re.escape(version)}\]|{re.escape(version)})(?:\s+-\s+.*)?\s*$",
    re.MULTILINE,
)
sys.exit(0 if pattern.search(text) else 1)
PY
then
  echo "Error: CHANGELOG.md does not contain a '## [${VERSION}]' entry." >&2
  echo "Add a release section for ${VERSION} in CHANGELOG.md before cutting the release." >&2
  exit 1
fi
echo "==> Verified CHANGELOG.md entry for ${VERSION}"

# 3. Sync build.zig.zon and sdks/typescript/package.json
python3 - "$VERSION" "$DRY_RUN" build.zig.zon sdks/typescript/package.json <<'PY'
import json
import re
import sys
from pathlib import Path

version = sys.argv[1]
dry_run = sys.argv[2] == "1"
zon_path = Path(sys.argv[3])
pkg_path = Path(sys.argv[4])

zon_text = zon_path.read_text(encoding="utf-8")
zon_match = re.search(r'(\.version\s*=\s*")([^"]*)(")', zon_text)
if not zon_match:
    print(f"Error: could not find .version in {zon_path}", file=sys.stderr)
    sys.exit(1)
old_zon_ver = zon_match.group(2)
new_zon_text = re.sub(
    r'(\.version\s*=\s*")([^"]*)(")',
    rf'\g<1>{version}\g<3>',
    zon_text,
    count=1,
)

pkg_text = pkg_path.read_text(encoding="utf-8")
pkg_data = json.loads(pkg_text)
old_pkg_ver = pkg_data.get("version")
pkg_match = re.search(r'("version"\s*:\s*")([^"]*)(")', pkg_text)
if not pkg_match:
    print(f"Error: could not find \"version\" in {pkg_path}", file=sys.stderr)
    sys.exit(1)
new_pkg_text = re.sub(
    r'("version"\s*:\s*")([^"]*)(")',
    rf'\g<1>{version}\g<3>',
    pkg_text,
    count=1,
)

if dry_run:
    print(f"==> [dry-run] build.zig.zon: .version \"{old_zon_ver}\" -> \"{version}\" (not written)")
    print(f"==> [dry-run] sdks/typescript/package.json: \"version\" \"{old_pkg_ver}\" -> \"{version}\" (not written)")
else:
    zon_path.write_text(new_zon_text, encoding="utf-8")
    pkg_path.write_text(new_pkg_text, encoding="utf-8")
    print(f"==> Updated build.zig.zon: .version \"{old_zon_ver}\" -> \"{version}\"")
    print(f"==> Updated sdks/typescript/package.json: \"version\" \"{old_pkg_ver}\" -> \"{version}\"")
PY

# 4. Run local preflight checks from repository root
echo "==> Running zig build"
zig build

echo "==> Running zig build shared -Doptimize=ReleaseFast"
zig build shared -Doptimize=ReleaseFast

echo "==> Running sdks/typescript preflight checks"
(
  cd "$REPO_ROOT/sdks/typescript"
  if [[ -f bun.lock ]]; then
    bun install --frozen-lockfile || bun install
  else
    bun install
  fi
  bun run build:native
  bun run build
  bun run typecheck
  bun test
  bun run lint:package
)

TAG="v${VERSION}"
echo ""
echo "======================================================================"
echo "Preflight passed for Guillotine ${TAG}"
echo "======================================================================"
echo ""
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run complete (no files were modified). To apply version bumps:"
  echo "  ./scripts/release.sh ${VERSION}"
  echo ""
fi
echo "Next steps to publish ${TAG} using jj and gh:"
echo ""
echo "  1. Review the version bump and CHANGELOG diff:"
echo "     jj diff"
echo ""
echo "  2. Commit and push the release commit to main:"
echo "     jj commit -m \"chore(release): prepare ${TAG}\""
echo "     jj bookmark set main -r @-"
echo "     jj git push --bookmark main"
echo ""
echo "  3. (Optional) Dry-run the GitHub Actions release workflow first:"
echo "     gh workflow run release.yml --ref main -f version=${VERSION} -f dry_run=true"
echo "     gh run watch"
echo ""
echo "  4. Create the release tag locally in jj and push the GitHub ref to trigger release.yml:"
echo "     jj tag set ${TAG} -r main"
echo "     gh api repos/evmts/guillotine/git/refs \\"
echo "       -f ref=refs/tags/${TAG} \\"
echo "       -f sha=\"\$(jj --no-pager log -r main --no-graph -T commit_id)\""
echo ""
echo "  5. Watch the release workflow:"
echo "     gh run list --workflow=release.yml --limit 5"
echo "     gh run watch"
echo ""
echo "  (Alternatively, trigger without creating the tag manually:"
echo "     gh workflow run release.yml --ref main -f version=${VERSION} -f dry_run=false)"
