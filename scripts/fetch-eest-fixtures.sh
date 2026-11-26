#!/usr/bin/env bash
# Fetch the official pre-filled Ethereum Execution Spec Tests (EEST) state-test
# fixtures (Frontier through Osaka and later) for specs/eest_runner.zig.
#
# Source: release assets of github.com/ethereum/execution-specs (tag "tests@vX.Y.Z",
# asset "fixtures.tar.gz"). Only the `fixtures/state_tests` and `fixtures/.meta`
# trees are extracted.
#
# The fetch is idempotent: a stamp file records the release tag and the SHA-256
# of the tarball. A second run with the same release does no network download.
#
# Usage:
#   scripts/fetch-eest-fixtures.sh [--force] [--print-dir]
#
# Environment:
#   EEST_CACHE_DIR      Destination (default: <repo>/.cache/eest-fixtures)
#   EEST_RELEASE_TAG    Release tag (default: the pinned tests@v21.0.3)
#   EEST_REPO           GitHub repository (default: ethereum/execution-specs)
#   EEST_ASSET          Asset name (default: fixtures.tar.gz)
#   EEST_SHA256         Expected SHA-256 (default: the pinned digest when the
#                       tag is the pinned tag, else the digest GitHub publishes)
#   EEST_KEEP_TARBALL   Set to 1 to keep the downloaded tarball (default: delete)
#   GITHUB_TOKEN        Optional token for the GitHub API when `gh` is absent
#
# Output layout:
#   $EEST_CACHE_DIR/
#     .gitignore                 ignores the whole cache
#     current -> <tag dir>       symlink to the active release
#     <tag dir>/STAMP            tag, asset, sha256
#     <tag dir>/fixtures/state_tests/**/*.json
set -euo pipefail

FORCE=0
PRINT_DIR=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --print-dir) PRINT_DIR=1 ;;
    -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "fetch-eest-fixtures: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="${EEST_CACHE_DIR:-$REPO_ROOT/.cache/eest-fixtures}"
REPO="${EEST_REPO:-ethereum/execution-specs}"
ASSET="${EEST_ASSET:-fixtures.tar.gz}"
# The pinned release. The state-tests baseline (66,652 cases, Frontier through
# Osaka) and CI's expected case count refer to exactly this tarball; bump the
# tag, digest and EEST_EXPECTED_CASES in .github/workflows/ci.yml together.
PINNED_TAG="tests@v21.0.3"
PINNED_SHA256="46bd48fb71a23da084218fe856fe442ab0c8d00c85c1c1aead0d2a965804fd24"
TAG="${EEST_RELEASE_TAG:-$PINNED_TAG}"
KEEP="${EEST_KEEP_TARBALL:-0}"

log() { echo "fetch-eest-fixtures: $*" >&2; }
die() { log "error: $*"; exit 1; }

for tool in curl tar python3; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Print the GitHub API response for a path under repos/$REPO.
api() {
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh api "repos/$REPO/$1"
    return
  fi
  local headers=(-H "Accept: application/vnd.github+json")
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi
  curl -fsSL "${headers[@]}" "https://api.github.com/repos/$REPO/$1"
}

# Reads a release JSON document on stdin; prints "<tag>\t<url>\t<sha256 or empty>".
release_fields() {
  python3 -I -c '
import json, sys
asset_name = sys.argv[1]
release = json.load(sys.stdin)
for asset in release.get("assets", []):
    if asset.get("name") == asset_name:
        digest = asset.get("digest") or ""
        if digest.startswith("sha256:"):
            digest = digest[len("sha256:"):]
        else:
            digest = ""
        print("\t".join([release["tag_name"], asset["browser_download_url"], digest]))
        sys.exit(0)
sys.exit("release %s has no asset named %s" % (release.get("tag_name"), asset_name))
' "$ASSET"
}

ENCODED_TAG="$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$TAG")"
FIELDS="$(api "releases/tags/$ENCODED_TAG" | release_fields)" || die "cannot read release $TAG of $REPO"

IFS=$'\t' read -r TAG URL API_SHA <<<"$FIELDS"
DEFAULT_SHA="$API_SHA"
if [ "$TAG" = "$PINNED_TAG" ] && [ "$ASSET" = "fixtures.tar.gz" ] && [ "$REPO" = "ethereum/execution-specs" ]; then
  DEFAULT_SHA="$PINNED_SHA256"
  if [ -n "$API_SHA" ] && [ "$API_SHA" != "$PINNED_SHA256" ]; then
    die "GitHub reports sha256 $API_SHA for $TAG/$ASSET, but the pinned digest is $PINNED_SHA256"
  fi
fi
EXPECTED_SHA="${EEST_SHA256:-$DEFAULT_SHA}"
[ -n "$EXPECTED_SHA" ] || die "release $TAG publishes no SHA-256 digest for $ASSET; set EEST_SHA256"

TAG_DIR_NAME="$(printf '%s' "$TAG" | tr -c 'A-Za-z0-9._-' '_')"
TAG_DIR="$CACHE_DIR/$TAG_DIR_NAME"
STAMP="$TAG_DIR/STAMP"
STATE_DIR="$TAG_DIR/fixtures/state_tests"
WANT_STAMP="tag=$TAG
asset=$ASSET
sha256=$EXPECTED_SHA"

mkdir -p "$CACHE_DIR"
[ -f "$CACHE_DIR/.gitignore" ] || printf '*\n' >"$CACHE_DIR/.gitignore"

link_current() {
  ln -sfn "$TAG_DIR_NAME" "$CACHE_DIR/current"
}

if [ "$FORCE" = 0 ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT_STAMP" ] && [ -d "$STATE_DIR" ]; then
  link_current
  log "up to date: $TAG (sha256 $EXPECTED_SHA)"
  log "fixtures: $STATE_DIR"
  [ "$PRINT_DIR" = 1 ] && echo "$STATE_DIR"
  exit 0
fi

mkdir -p "$TAG_DIR"
TARBALL="$TAG_DIR/$ASSET"

if [ -f "$TARBALL" ] && [ "$(sha256_of "$TARBALL")" = "$EXPECTED_SHA" ]; then
  log "reusing verified tarball $TARBALL"
else
  log "downloading $URL"
  # Resume a partial download; the checksum below rejects a corrupt result.
  curl -fL --retry 5 --retry-delay 2 -C - -o "$TARBALL.part" "$URL"
  ACTUAL_SHA="$(sha256_of "$TARBALL.part")"
  if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
    rm -f "$TARBALL.part"
    die "checksum mismatch for $ASSET: expected $EXPECTED_SHA, got $ACTUAL_SHA"
  fi
  mv "$TARBALL.part" "$TARBALL"
  log "verified sha256 $EXPECTED_SHA"
fi

# Extract into a fresh directory, then swap it in, so an interrupted run never
# leaves a half-extracted tree behind a valid stamp.
STAGE="$TAG_DIR/.extract.$$"
rm -rf "$STAGE"
mkdir -p "$STAGE"
trap 'rm -rf "$STAGE"' EXIT

MEMBERS=()
while IFS= read -r member; do
  MEMBERS+=("$member")
done < <(tar -tzf "$TARBALL" | awk -F/ '
  { top = ($1 == "." ? 2 : 1) }
  $(top) == "fixtures" && ($(top + 1) == "state_tests" || $(top + 1) == ".meta") && $(top + 2) == "" && !seen[$0]++ { print }
  ')
# The awk filter selects directory entries only; fall back to path prefixes
# when the archive has no explicit directory members.
if [ "${#MEMBERS[@]}" -eq 0 ]; then
  MEMBERS=("fixtures/state_tests" "fixtures/.meta")
fi
log "extracting ${MEMBERS[*]}"
tar -xzf "$TARBALL" -C "$STAGE" "${MEMBERS[@]}"

EXTRACTED="$(find "$STAGE" -type d -name state_tests -path '*fixtures/state_tests' | head -n 1)"
[ -n "$EXTRACTED" ] || die "archive $ASSET contains no fixtures/state_tests directory"
COUNT="$(find "$EXTRACTED" -type f -name '*.json' | wc -l | tr -d ' ')"
[ "$COUNT" -gt 0 ] || die "archive $ASSET contains no state test JSON files"

rm -rf "$TAG_DIR/fixtures"
mv "$(dirname "$EXTRACTED")" "$TAG_DIR/fixtures"
rm -rf "$STAGE"
trap - EXIT

printf '%s\n' "$WANT_STAMP" >"$STAMP"
[ "$KEEP" = 1 ] || rm -f "$TARBALL"
link_current

log "fetched $TAG: $COUNT state test JSON files"
log "fixtures: $STATE_DIR"
[ "$PRINT_DIR" = 1 ] && echo "$STATE_DIR"
exit 0
