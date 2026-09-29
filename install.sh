#!/usr/bin/env bash
# Copy the eleven Team Agent Skills packages into a skills directory and verify them.
# Works for any harness: pass the directory your agent loads skills from.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install.sh --target DIR [--only PKG[,PKG...]] [--dry-run] [--no-verify] [--force]

  --target DIR   Directory to install the packages into (created if missing).
                 Examples: ~/.claude/skills   <repo>/.claude/skills   any directory.
  --only LIST    Install only the named packages (comma-separated).
  --dry-run      Show what would be copied; change nothing.
  --no-verify    Skip running verify.sh after copying.
  --force        Replace a same-named directory this installer did not write.

Each package is synced as TARGET/<package>/ — files removed upstream are removed
from the installed copy too. Nothing outside those eleven directories is touched;
a skill's private configuration and state live elsewhere and are never affected.
A TARGET/<package>/ without tests/validate.sh was not written by this installer
(a personal skill that shares a package's name, say), so it is left alone and
the run stops, unless --force is given.
EOF
  exit "${1:-0}"
}

ALL_PACKAGES=(clean-memory create-clarity implement manual-qa orchestrate pr-fix pr-review ship tickets watch-and-fix watch-and-review)

TARGET="" ONLY="" DRY_RUN=0 NO_VERIFY=0 FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="${2:?--target needs a directory}"; shift 2 ;;
    --only) ONLY="${2:?--only needs a package list}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-verify) NO_VERIFY=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "install.sh: unknown argument: $1" >&2; usage 1 ;;
  esac
done

[[ -n "$TARGET" ]] || { echo "install.sh: --target is required" >&2; usage 1; }
command -v rsync >/dev/null 2>&1 || { echo "install.sh: rsync is required" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$REPO_DIR/skills"
[[ -d "$SRC" ]] || { echo "install.sh: $SRC not found — run from a clone of the repository" >&2; exit 1; }

PACKAGES=("${ALL_PACKAGES[@]}")
if [[ -n "$ONLY" ]]; then
  IFS=',' read -r -a PACKAGES <<<"$ONLY"
  for p in "${PACKAGES[@]}"; do
    [[ -d "$SRC/$p" ]] || { echo "install.sh: unknown package: $p" >&2; exit 1; }
  done
fi

mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"
if [[ "$TARGET" == "$SRC" ]]; then
  echo "install.sh: target is the repository's own skills/ directory — refusing" >&2
  exit 1
fi

# Every package this installer writes carries tests/validate.sh. A same-named
# directory without it is someone else's skill: mirroring over it would
# replace its files and delete the rest, so stop and name it instead.
FOREIGN=()
for p in "${PACKAGES[@]}"; do
  if [[ -e "$TARGET/$p" && ! -f "$TARGET/$p/tests/validate.sh" ]]; then
    FOREIGN+=("$TARGET/$p")
  fi
done
if [[ ${#FOREIGN[@]} -gt 0 && $FORCE -eq 0 ]]; then
  echo "install.sh: these directories were not installed from this repository and would be replaced:" >&2
  printf '  %s\n' "${FOREIGN[@]}" >&2
  echo "Move them aside, leave those packages out with --only, or pass --force only if they may be discarded." >&2
  exit 1
fi

RSYNC_FLAGS=(-a --delete)
[[ $DRY_RUN -eq 1 ]] && RSYNC_FLAGS+=(--dry-run --itemize-changes)

echo "Installing ${#PACKAGES[@]} package(s) into $TARGET"
for p in "${PACKAGES[@]}"; do
  echo "  - $p"
  rsync "${RSYNC_FLAGS[@]}" "$SRC/$p/" "$TARGET/$p/"
done

if [[ $DRY_RUN -eq 1 ]]; then
  echo "Dry run — nothing was changed."
  exit 0
fi

if [[ $NO_VERIFY -eq 0 && -x "$REPO_DIR/verify.sh" ]]; then
  echo
  echo "Verifying installed packages..."
  INSTALLED=()
  for p in "${PACKAGES[@]}"; do INSTALLED+=("$TARGET/$p"); done
  "$REPO_DIR/verify.sh" "${INSTALLED[@]}"
else
  [[ $NO_VERIFY -eq 1 ]] || echo "verify.sh not found or not executable — skipped verification" >&2
fi

echo
echo "Done. If your harness indexes skills at startup, restart or reload it."
