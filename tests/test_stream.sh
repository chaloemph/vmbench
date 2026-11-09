#!/usr/bin/env bash
# Tests for the pinned STREAM source (lib/stream.sh) and its use by the mem stage. They use a tiny synthetic stream.c,
# never the real file, and no network (downloads come from file:// URLs).
# Usage: bash tests/test_stream.sh
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT=$PWD
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
check() { # name, ok (0 = pass), details...
  local name=$1 ok=$2; shift 2
  if [ "$ok" = 0 ]; then pass=$((pass + 1)); printf 'ok   %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; [ $# -gt 0 ] && printf '       %s\n' "$@"; fi
}

# a stand-in for stream.c: it only prints the two lines the mem stage reads
SYN=$TMP/synthetic-stream.c
cat > "$SYN" <<'C'
#include <stdio.h>
int main(void) { printf("Copy:  1000.5  0.1  0.1  0.1\nTriad: 2000.5  0.1  0.1  0.1\n"); return 0; }
C
OTHER=$TMP/other.c
printf '/* not the pinned file */\nint main(void){return 0;}\n' > "$OTHER"
SYN_SUM=$(sha256sum "$SYN" | awk '{print $1}')
export HOME=$TMP/home; mkdir -p "$HOME"
unset STREAM_C STREAM_URL STREAM_SKIP_CHECK STREAM_CACHE_DIR

# --- the pin itself
pin_commit=$(sed -n 's/^STREAM_COMMIT=//p' lib/stream.sh)
pin_sum=$(sed -n 's/^STREAM_SHA256=//p' lib/stream.sh)
if [[ $pin_commit =~ ^[0-9a-f]{40}$ ]] && [[ $pin_sum =~ ^[0-9a-f]{64}$ ]]; then check "the pin is a 40 hex commit and a 64 hex sha256" 0
else check "the pin is a 40 hex commit and a 64 hex sha256" 1 "$pin_commit $pin_sum"; fi
url=$(bash -c '. lib/stream.sh; echo "$STREAM_PINNED_URL"')
[ "$url" = "https://raw.githubusercontent.com/jeffhammond/STREAM/$pin_commit/stream.c" ] && check "the default URL is the pinned commit, not a branch" 0 || check "the default URL is the pinned commit, not a branch" 1 "$url"
if grep -q "$pin_commit" README.md docs/tests.md && grep -q "$pin_sum" README.md docs/tests.md; then check "README.md and docs/tests.md name the pinned commit and sha256" 0
else check "README.md and docs/tests.md name the pinned commit and sha256" 1; fi
git ls-files 2>/dev/null | grep -qx 'stream.c' && check "the real stream.c is not committed" 1 || check "the real stream.c is not committed" 0

# --- local file (STREAM_C), standalone script: real exit codes
out=$(STREAM_C=$SYN bash lib/stream.sh "$TMP/d1.c" 2>&1); rc=$?
if [ "$rc" = 1 ] && [[ $out == *"does not match the pinned sha256"* ]] && [[ $out == *"$SYN_SUM"* ]] && [ ! -e "$TMP/d1.c" ]; then check "STREAM_C with the wrong hash: exit 1, message, nothing left behind" 0
else check "STREAM_C with the wrong hash: exit 1, message, nothing left behind" 1 "rc=$rc $out"; fi
out=$(STREAM_C=$SYN STREAM_SKIP_CHECK=1 bash lib/stream.sh "$TMP/d2.c" 2>&1); rc=$?
if [ "$rc" = 0 ] && [[ $out == *"WARNING"*"NOT verified"* ]] && [[ $out == *UNVERIFIED* ]] && cmp -s "$SYN" "$TMP/d2.c"; then check "STREAM_SKIP_CHECK=1 accepts the file and warns loudly" 0
else check "STREAM_SKIP_CHECK=1 accepts the file and warns loudly" 1 "rc=$rc $out"; fi
out=$(STREAM_C="$TMP/missing.c" bash lib/stream.sh "$TMP/d3.c" 2>&1); rc=$?
[ "$rc" = 1 ] && [[ $out == *"not a readable"* ]] && check "STREAM_C pointing at nothing: exit 1 and a message" 0 || check "STREAM_C pointing at nothing: exit 1 and a message" 1 "rc=$rc $out"

# --- with the right hash (the pin is overridden in a subshell, since the real file is not in the tests)
out=$(STREAM_C=$SYN bash -c ". lib/stream.sh; STREAM_SHA256=$SYN_SUM; stream_fetch '$TMP/d4.c' && echo \"\$STREAM_SOURCE_NOTE\"" 2>&1); rc=$?
if [ "$rc" = 0 ] && [[ $out == *"sha256 verified"* ]] && cmp -s "$SYN" "$TMP/d4.c"; then check "STREAM_C with the right hash is accepted and copied" 0
else check "STREAM_C with the right hash is accepted and copied" 1 "rc=$rc $out"; fi

# --- download (file:// URL) and cache
mkdir -p "$TMP/cache"
out=$(STREAM_CACHE_DIR=$TMP/cache STREAM_URL="file://$OTHER" bash lib/stream.sh "$TMP/d5.c" 2>&1); rc=$?
if [ "$rc" = 1 ] && [[ $out == *"does not match"* ]] && [ ! -e "$TMP/cache/stream.c" ] && [ ! -e "$TMP/d5.c" ]; then check "a download with the wrong hash fails and is not cached" 0
else check "a download with the wrong hash fails and is not cached" 1 "rc=$rc $out"; fi
out=$(STREAM_CACHE_DIR=$TMP/cache STREAM_URL="file://$SYN" bash -c ". lib/stream.sh; STREAM_SHA256=$SYN_SUM; stream_fetch '$TMP/d6.c' && echo \"\$STREAM_SOURCE_NOTE\"" 2>&1); rc=$?
if [ "$rc" = 0 ] && cmp -s "$SYN" "$TMP/d6.c" && cmp -s "$SYN" "$TMP/cache/stream.c"; then check "a download with the right hash works and is cached" 0
else check "a download with the right hash works and is cached" 1 "rc=$rc $out"; fi
# the cache is checked too: a copy that is not the pinned file is ignored and fetched again
cp "$OTHER" "$TMP/cache/stream.c"
out=$(STREAM_CACHE_DIR=$TMP/cache STREAM_URL="file://$SYN" bash -c ". lib/stream.sh; STREAM_SHA256=$SYN_SUM; stream_fetch '$TMP/d7.c'" 2>&1); rc=$?
if [ "$rc" = 0 ] && [[ $out == *"downloading it again"* ]] && cmp -s "$SYN" "$TMP/d7.c" && cmp -s "$SYN" "$TMP/cache/stream.c"; then check "a bad cached stream.c is replaced, not trusted" 0
else check "a bad cached stream.c is replaced, not trusted" 1 "rc=$rc $out"; fi
cp "$OTHER" "$TMP/cache/stream.c"
out=$(STREAM_CACHE_DIR=$TMP/cache STREAM_URL="file://$OTHER" bash lib/stream.sh "$TMP/d8.c" 2>&1); rc=$?
[ "$rc" = 1 ] && check "bad cache and bad download: exit 1" 0 || check "bad cache and bad download: exit 1" 1 "rc=$rc $out"

# --- the mem stage, with stubs for what vmbench provides and the synthetic file as the "download" (needs gcc)
stage() { # stage ENV...  runs stage_mem_run in a subshell and prints what it recorded
  (
    env "$@" bash -c '
      VMBENCH_HOME=$1; OUT=$2; STATUS=$OUT/status.tsv; QUICK=1; NPROC=1; MEM_AVAIL_KB=1000000; MEM_ROUNDS=2
      . "$VMBENCH_HOME/lib/common.sh"; . "$VMBENCH_HOME/lib/stream.sh"; . "$VMBENCH_HOME/stages/mem.sh"
      rec() { echo "REC $1 $2"; }
      [ -n "${SYN_SUM:-}" ] && STREAM_SHA256=$SYN_SUM
      stage_mem_run >/dev/null 2>&1
      cat "$STATUS"; cat "$OUT/info.txt" 2>/dev/null
      ls "$OUT"
    ' _ "$ROOT" "$OUT"
  )
}
if command -v gcc >/dev/null 2>&1; then
  export OUT=$TMP/out1; mkdir -p "$OUT"
  res=$(stage STREAM_C="$SYN" SYN_SUM="$SYN_SUM" HOME="$HOME")
  if grep -q '^mem	stream r1	OK' <<<"$res" && grep -q '^mem	stream r2	OK' <<<"$res" && grep -q '^stream: local file (STREAM_C), sha256 verified' <<<"$res" && ! grep -qx 'stream.c' <<<"$res"; then check "mem stage: verified file is compiled once and run in every round, source recorded in info.txt" 0
  else check "mem stage: verified file is compiled once and run in every round, source recorded in info.txt" 1 "$res"; fi
  export OUT=$TMP/out2; mkdir -p "$OUT"
  res=$(stage STREAM_C="$OTHER" HOME="$HOME")
  if grep -q '^mem	stream.c	FAIL' <<<"$res" && ! grep -q '^REC' <<<"$res" && ! grep -qx 'stream-build.log' <<<"$res"; then check "mem stage: a wrong hash is a FAIL and nothing is compiled" 0
  else check "mem stage: a wrong hash is a FAIL and nothing is compiled" 1 "$res"; fi
  export OUT=$TMP/out3; mkdir -p "$OUT"
  res=$(stage STREAM_C="$SYN" STREAM_SKIP_CHECK=1 HOME="$HOME")
  if grep -q '^mem	stream r1	OK' <<<"$res" && grep -q 'UNVERIFIED' <<<"$res"; then check "mem stage: STREAM_SKIP_CHECK=1 runs and records UNVERIFIED" 0
  else check "mem stage: STREAM_SKIP_CHECK=1 runs and records UNVERIFIED" 1 "$res"; fi
else
  echo "skip mem stage tests (no gcc)"
fi

# --- pre-flight
out=$(STREAM_C="$TMP/missing.c" HOME=$TMP/home bash vmbench run --only mem 2>&1); rc=$?
if [ "$rc" = 2 ] && [[ $out == *"STREAM_C=$TMP/missing.c is not a readable file"* ]]; then check "pre-flight reports a STREAM_C that does not exist" 0
else check "pre-flight reports a STREAM_C that does not exist" 1 "rc=$rc ${out:0:300}"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
