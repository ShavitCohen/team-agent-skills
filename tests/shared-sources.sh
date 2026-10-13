#!/usr/bin/env bash
# tests/shared-sources.sh — checks that shared components are defined once
# under shared/ and generated into exactly the packages the manifest lists.
# Usage: tests/shared-sources.sh   (run from anywhere; needs git, rsync)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO/shared/manifest.tsv"
ALL_PACKAGES=(clean-memory create-clarity implement manual-qa orchestrate pr-fix pr-review ship tickets watch-and-fix watch-and-review)
work=$(mktemp -d "${TMPDIR:-/tmp}/shared-test.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

pass=0 failn=0
ok()  { pass=$((pass + 1)); printf 'ok    %s\n' "$1"; }
bad() { failn=$((failn + 1)); printf 'FAIL  %s\n' "$1"; }
res() { if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2"; fi; }  # res RC NAME

# Manifest lines: PATH<TAB>PKG PKG ... ; '#' comments and blank lines ignored.
entries() { grep -vE '^[[:space:]]*(#|$)' "$MANIFEST"; }

# A clean copy of the tracked tree, so tests never touch the working copy.
fresh_copy() { # fresh_copy DIR — what a raw git copy holds (ignored files left out)
  mkdir -p "$1"
  rsync -a --exclude .git --filter=':- .gitignore' "$REPO/" "$1/"
}

# --- AC: manifest exists and every master is present -------------------------
if [ -f "$MANIFEST" ] && [ -n "$(entries 2>/dev/null)" ]; then
  ok "central manifest shared/manifest.tsv exists and is non-empty"
else
  bad "central manifest shared/manifest.tsv exists and is non-empty"
  printf '\n%s passed, %s failed\n' "$pass" "$failn"; exit 1
fi
missing=0
while IFS=$'\t' read -r path pkgs; do
  [ -f "$REPO/shared/$path" ] || { missing=1; printf '      missing master shared/%s\n' "$path"; }
  for p in $pkgs; do
    [ -d "$REPO/skills/$p" ] || { missing=1; printf '      unknown package %s for %s\n' "$p" "$path"; }
  done
done < <(entries)
res "$missing" "every manifest master exists and names known packages"

# --- AC: generated copies are not committed and are gitignored ---------------
tracked=0 unignored=0
while IFS=$'\t' read -r path pkgs; do
  for p in $pkgs; do
    if git -C "$REPO" ls-files --error-unmatch "skills/$p/$path" >/dev/null 2>&1; then
      tracked=1; printf '      still tracked: skills/%s/%s\n' "$p" "$path"
    fi
    if ! git -C "$REPO" check-ignore -q --no-index "skills/$p/$path"; then
      unignored=1; printf '      not ignored: skills/%s/%s\n' "$p" "$path"
    fi
  done
done < <(entries)
res "$tracked" "no generated copy is tracked by git"
res "$unignored" "every generated copy path is gitignored"

# --- AC: sync writes identical content to exactly the listed packages -------
t1="$work/t1"; fresh_copy "$t1"
if [ -x "$t1/sync.sh" ] && "$t1/sync.sh" >"$work/sync.log" 2>&1; then
  ok "sync.sh runs successfully on a fresh copy"
else
  bad "sync.sh runs successfully on a fresh copy"; sed 's/^/      /' "$work/sync.log"
fi
wrong=0
while IFS=$'\t' read -r path pkgs; do
  for p in "${ALL_PACKAGES[@]}"; do
    listed=0; case " $pkgs " in *" $p "*) listed=1 ;; esac
    f="$t1/skills/$p/$path"
    if [ "$listed" -eq 1 ]; then
      cmp -s "$f" "$t1/shared/$path" || { wrong=1; printf '      %s/%s not identical to master\n' "$p" "$path"; }
    elif [ -e "$f" ]; then
      wrong=1; printf '      %s/%s written but not listed\n' "$p" "$path"
    fi
  done
done < <(entries)
res "$wrong" "sync writes identical content to exactly the listed packages"

# --- AC: verify is clean after sync; hand-edited copy fails naming file+pkg --
if "$t1/verify.sh" "$t1"/skills/* >"$work/v1.log" 2>&1; then
  ok "verify.sh passes on all packages after sync"
else
  bad "verify.sh passes on all packages after sync"; grep '^FAIL' "$work/v1.log" | head -20 | sed 's/^/      /'
fi
read -r epath epkgs < <(entries | head -1)
epkg=${epkgs%% *}
printf '\nhand edit\n' >> "$t1/skills/$epkg/$epath"
before=$(cd "$t1" && find . -type f -not -path './.git/*' -exec cksum {} + | sort)  # POSIX cksum: portable
if "$t1/verify.sh" "$t1"/skills/* >"$work/v2.log" 2>&1; then
  bad "verify.sh fails on a hand-edited copy"
else
  if grep -E "^FAIL  \[$epkg\] shared-drift: .*$epath" "$work/v2.log" >/dev/null; then
    ok "verify.sh fails on a hand-edited copy, naming file and package"
  else
    bad "verify.sh fails on a hand-edited copy, naming file and package"; grep '^FAIL' "$work/v2.log" | head -5 | sed 's/^/      /'
  fi
fi
after=$(cd "$t1" && find . -type f -not -path './.git/*' -exec cksum {} + | sort)  # POSIX cksum: portable
if [ "$before" = "$after" ]; then ok "verify.sh is read-only"; else bad "verify.sh is read-only"; fi

# --- AC: install from a raw copy yields self-contained packages --------------
t2="$work/t2"; fresh_copy "$t2"; tgt="$work/target"
if "$t2/install.sh" --target "$tgt" >"$work/inst.log" 2>&1; then
  ok "install.sh from a raw copy succeeds (runs sync, verify passes)"
else
  bad "install.sh from a raw copy succeeds (runs sync, verify passes)"; tail -15 "$work/inst.log" | sed 's/^/      /'
fi
selfc=0
while IFS=$'\t' read -r path pkgs; do
  for p in $pkgs; do
    cmp -s "$tgt/$p/$path" "$t2/shared/$path" || { selfc=1; printf '      installed %s lacks %s\n' "$p" "$path"; }
  done
done < <(entries)
res "$selfc" "every installed package carries its shared files"
# Standalone: an installed package verifies with no repo next to it.
iso="$work/iso"; mkdir -p "$iso"; cp -R "$tgt"/. "$iso/"
if (cd "$work" && "$t2/verify.sh" "$iso"/* >"$work/v3.log" 2>&1); then
  ok "installed packages verify after being moved away from the target"
else
  bad "installed packages verify after being moved away from the target"; grep '^FAIL' "$work/v3.log" | head -5 | sed 's/^/      /'
fi

# --- sync warns on a missing package; sync and verify reject unsafe paths ---
t3="$work/t3"; fresh_copy "$t3"; part="$work/partial"; mkdir -p "$part/ship"
"$t3/sync.sh" --root "$part" >/dev/null 2>"$work/warn.log"
if grep -q 'warning: package clean-memory not found' "$work/warn.log"; then
  ok "sync.sh warns on stderr, naming a missing package"
else
  bad "sync.sh warns on stderr, naming a missing package"
fi
cp "$t3/shared/manifest.tsv" "$work/manifest.orig"
for unsafe in '../escape.md' '/abs.md' 'references/../../x.md'; do
  printf '%s\tship\r\n' "$unsafe" >> "$t3/shared/manifest.tsv"
  s_rc=0; "$t3/sync.sh" --root "$part" >/dev/null 2>&1 || s_rc=$?
  v_rc=0; "$t3/verify.sh" "$part/ship" >/dev/null 2>&1 || v_rc=$?
  if [ "$s_rc" -ne 0 ] && [ "$v_rc" -eq 2 ]; then
    ok "sync.sh and verify.sh reject manifest path $unsafe"
  else
    bad "sync.sh and verify.sh reject manifest path $unsafe (sync $s_rc, verify $v_rc)"
  fi
  cp "$work/manifest.orig" "$t3/shared/manifest.tsv"
done
printf 'schemas/cases-v1.json\tship\r\n' >> "$t3/shared/manifest.tsv"
"$t3/sync.sh" --root "$part" >/dev/null 2>&1
if cmp -s "$part/ship/schemas/cases-v1.json" "$t3/shared/schemas/cases-v1.json"; then
  ok "CRLF manifest lines are parsed (CR stripped)"
else
  bad "CRLF manifest lines are parsed (CR stripped)"
fi

# --- AC: verify.sh no longer hardcodes the shared lists ----------------------
if grep -nE '^(SHARED_SCRIPTS|SHARED_SCHEMAS)=' "$REPO/verify.sh" >/dev/null; then
  bad "verify.sh reads shared lists from the manifest (no hardcoded SHARED_*)"
else
  ok "verify.sh reads shared lists from the manifest (no hardcoded SHARED_*)"
fi
leak=0
while IFS=$'\t' read -r path _; do
  grep -qF " $path " <(sed -n "/^manifest_for()/,/^}/p" "$REPO/verify.sh" | tr "'" ' ') && { leak=1; printf '      verify.sh manifest_for still lists %s\n' "$path"; }
done < <(entries)
res "$leak" "verify.sh per-package lists name no shared file"

# --- AC: guide of five lines or fewer, mentions the installer ---------------
guide=$(awk '/^## Shared components/{f=1;next} /^## /{f=0} f && NF' "$REPO/README.md")
gl=$(printf '%s' "$guide" | grep -c . || true)
if [ "$gl" -ge 1 ] && [ "$gl" -le 5 ] && printf '%s' "$guide" | grep -q 'install.sh' && printf '%s' "$guide" | grep -q 'sync.sh'; then
  ok "README shared-components guide is 1-5 lines and names the installer and sync"
else
  bad "README shared-components guide is 1-5 lines and names the installer and sync (found $gl lines)"
fi

printf '\n%s passed, %s failed\n' "$pass" "$failn"
[ "$failn" -eq 0 ]
