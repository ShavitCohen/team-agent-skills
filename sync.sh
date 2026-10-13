#!/usr/bin/env bash
# sync.sh — generate the shared-component copies inside each skill package.
#
# Usage: sync.sh [--root DIR]
#
# Reads shared/manifest.tsv (one line per shared file: PATH<TAB>PKG PKG ...)
# and copies shared/PATH byte-for-byte to DIR/PKG/PATH for every listed
# package directory present under DIR (default: this repository's skills/).
# The copies are generated, not committed; install.sh runs this script.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$REPO_DIR/skills"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:?--root needs a directory}"; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "sync.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

MANIFEST="$REPO_DIR/shared/manifest.tsv"
[[ -f "$MANIFEST" ]] || { echo "sync.sh: $MANIFEST not found" >&2; exit 1; }
[[ -d "$ROOT" ]] || { echo "sync.sh: $ROOT is not a directory" >&2; exit 1; }

written=0
while IFS=$'\t' read -r path pkgs; do
  path=${path%$'\r'}; pkgs=${pkgs%$'\r'}
  [[ -z "$path" || "$path" == \#* ]] && continue
  case $path in
    /*|..|../*|*/..|*/../*)
      echo "sync.sh: unsafe path in manifest (absolute or ..): $path" >&2; exit 1 ;;
  esac
  src="$REPO_DIR/shared/$path"
  [[ -f "$src" ]] || { echo "sync.sh: master missing: shared/$path" >&2; exit 1; }
  [[ -n "$pkgs" ]] || { echo "sync.sh: no packages listed for $path" >&2; exit 1; }
  for p in $pkgs; do
    if [[ ! -d "$ROOT/$p" ]]; then
      echo "sync.sh: warning: package $p not found under $ROOT; skipped $path" >&2
      continue
    fi
    mkdir -p "$ROOT/$p/$(dirname "$path")"
    cp -p -- "$src" "$ROOT/$p/$path"
    written=$((written + 1))
  done
done < "$MANIFEST"
echo "sync.sh: wrote $written shared-component copies under $ROOT"
