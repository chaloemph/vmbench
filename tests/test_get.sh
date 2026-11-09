#!/usr/bin/env bash
# Tests for get.sh (the installer) against a fake release on 127.0.0.1: install, checksum mismatch, bad tar paths,
# --dry-run, --uninstall, "latest" lookup, root refusal, truncated script. No real network, no sudo, temp HOME.
# Usage: bash tests/test_get.sh
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT=$PWD
GET=$ROOT/get.sh
TMP=$(mktemp -d)
SH=$(command -v dash || command -v sh)   # the strictest POSIX shell we have
pass=0 fail=0
check() { # name, ok (0 = pass), details...
  local name=$1 ok=$2; shift 2
  if [ "$ok" = 0 ]; then pass=$((pass + 1)); printf 'ok   %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; [ $# -gt 0 ] && printf '       %s\n' "$@"; fi
}

# --- fake release: web/<tag>/vmbench-<tag>.tar.gz + SHA256SUMS
WEB=$TMP/web
mkdir -p "$WEB"
mkrelease() { # tag [bad: sums|dotdot|abs|link|notvmbench]
  local tag=$1 mode=${2:-} d=$WEB/$1 src=$TMP/src-$1-${2:-ok}
  mkdir -p "$d" "$src/vmbench-$tag/lib"
  printf '#!/usr/bin/env bash\necho "vmbench %s"\n' "$tag" > "$src/vmbench-$tag/vmbench"
  chmod +x "$src/vmbench-$tag/vmbench"
  echo "# fake" > "$src/vmbench-$tag/lib/common.sh"
  echo "$tag" > "$src/vmbench-$tag/VERSION"
  case $mode in
    dotdot) echo evil > "$TMP/evil-src"; tar -czf "$d/vmbench-$tag.tar.gz" -C "$src" --transform="s,^vmbench-$tag/VERSION,vmbench-$tag/../../escaped," "vmbench-$tag" ;;
    abs)    tar -czf "$d/vmbench-$tag.tar.gz" -C "$src" --absolute-names --transform="s,^vmbench-$tag/VERSION,$TMP/abs-escaped," "vmbench-$tag" ;;
    link)   ln -s /etc/passwd "$src/vmbench-$tag/passwd-link"; tar -czf "$d/vmbench-$tag.tar.gz" -C "$src" "vmbench-$tag" ;;
    notvmbench) rm -rf "$src/vmbench-$tag/lib"; tar -czf "$d/vmbench-$tag.tar.gz" -C "$src" "vmbench-$tag" ;;
    *)      tar -czf "$d/vmbench-$tag.tar.gz" -C "$src" "vmbench-$tag" ;;
  esac
  (cd "$d" && sha256sum "vmbench-$tag.tar.gz" > SHA256SUMS)
  [ "$mode" = sums ] && echo "0000000000000000000000000000000000000000000000000000000000000000  vmbench-$tag.tar.gz" > "$d/SHA256SUMS"
  return 0
}
mkrelease v1.0.0
mkrelease v1.0.1
mkrelease v2.0.0 sums
mkrelease v3.0.0 dotdot
mkrelease v4.0.0 abs
mkrelease v5.0.0 link
mkrelease v6.0.0 notvmbench

python3 -I "$ROOT/tests/fakeserver.py" "$WEB" "$TMP/port" &
SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
PORT=$(cat "$TMP/port" 2>/dev/null)
[ -n "$PORT" ] || { echo "FAIL fake server did not start"; exit 1; }
BASE=http://127.0.0.1:$PORT

# run_get <home> <args...>: RC and OUT; env points the script at the fake server
run_get() {
  local home=$1; shift
  mkdir -p "$home"
  OUT=$(HOME=$home PATH="$home/.local/bin:$PATH" VMBENCH_BASE_URL=$BASE VMBENCH_LATEST_URL=$BASE/latest \
    VMBENCH_HOME="" VMBENCH_BIN_DIR="" VMBENCH_VERSION="" TMPDIR=$TMP timeout 30 "$SH" "$GET" "$@" 2>&1); RC=$?
}
snapshot() { (cd "$1" 2>/dev/null && find . | LC_ALL=C sort) | tr '\n' ' '; }

# --- install
H=$TMP/h1
run_get "$H" --version v1.0.0
[ "$RC" = 0 ] && check "install v1.0.0 exits 0" 0 || check "install v1.0.0 exits 0" 1 "rc=$RC" "$OUT"
[ -x "$H/.local/share/vmbench/v1.0.0/vmbench" ] && check "files are in the prefix, in a folder per version" 0 || check "files are in the prefix, in a folder per version" 1 "$(snapshot "$H")"
[ "$(readlink "$H/.local/share/vmbench/current")" = "$H/.local/share/vmbench/v1.0.0" ] && check "current points at the version" 0 || check "current points at the version" 1
[ "$(readlink "$H/.local/bin/vmbench")" = "$H/.local/share/vmbench/current/vmbench" ] && check "the bin symlink links through current" 0 || check "the bin symlink links through current" 1
got=$(HOME=$H "$H/.local/bin/vmbench") ; [ "$got" = "vmbench v1.0.0" ] && check "the installed command runs" 0 || check "the installed command runs" 1 "$got"
[[ $OUT == *"sha256 ok"* ]] && check "install reports the verified checksum" 0 || check "install reports the verified checksum" 1 "$OUT"
[[ $OUT != *"not in your PATH"* ]] && check "no PATH warning when ~/.local/bin is in PATH" 0 || check "no PATH warning when ~/.local/bin is in PATH" 1
[[ $OUT == *"sudo apt-get install"* ]] && check "prints the apt-get line instead of running it" 0 || check "prints the apt-get line instead of running it" 1
[ -z "$(find "$TMP" -maxdepth 1 -name 'vmbench-get.*')" ] && check "temporary folder is cleaned up" 0 || check "temporary folder is cleaned up" 1

# PATH warning: run with a PATH lacking ~/.local/bin
H=$TMP/h1b; mkdir -p "$H"
OUT=$(HOME=$H VMBENCH_BASE_URL=$BASE "$SH" "$GET" --version v1.0.0 2>&1); RC=$?
[[ $OUT == *"not in your PATH"* ]] && check "PATH warning appears when ~/.local/bin is missing from PATH" 0 || check "PATH warning appears when ~/.local/bin is missing from PATH" 1 "$OUT"

# second version, then switch of current; reinstall replaces
H=$TMP/h1
run_get "$H" --version v1.0.1
[ "$(readlink "$H/.local/share/vmbench/current")" = "$H/.local/share/vmbench/v1.0.1" ] && [ -d "$H/.local/share/vmbench/v1.0.0" ] && check "a second version keeps the first and moves current" 0 || check "a second version keeps the first and moves current" 1 "$OUT"
run_get "$H" --version v1.0.1
[ "$RC" = 0 ] && check "reinstalling the same version works" 0 || check "reinstalling the same version works" 1 "$OUT"

# VMBENCH_VERSION env, --prefix, --bin-dir, --dir
H=$TMP/h2
OUT=$(HOME=$H VMBENCH_BASE_URL=$BASE VMBENCH_VERSION=v1.0.0 VMBENCH_HOME=$TMP/pfx VMBENCH_BIN_DIR=$TMP/bin "$SH" "$GET" 2>&1); RC=$?
[ "$RC" = 0 ] && [ -x "$TMP/pfx/v1.0.0/vmbench" ] && [ -L "$TMP/bin/vmbench" ] && [ ! -e "$H/.local" ] && check "VMBENCH_VERSION, VMBENCH_HOME and VMBENCH_BIN_DIR are honoured" 0 || check "VMBENCH_VERSION, VMBENCH_HOME and VMBENCH_BIN_DIR are honoured" 1 "$OUT"
run_get "$TMP/h3" --version v1.0.0 --dir "$TMP/exact" --bin-dir "$TMP/bin2"
[ "$RC" = 0 ] && [ -x "$TMP/exact/vmbench" ] && [ "$(readlink "$TMP/bin2/vmbench")" = "$TMP/exact/vmbench" ] && [ ! -e "$TMP/exact/current" ] && check "--dir installs exactly there" 0 || check "--dir installs exactly there" 1 "$OUT"

# latest
run_get "$TMP/h4"
[ "$RC" = 1 ] && [[ $OUT == *"v9.9.9"* ]] && check "latest resolves the tag from the releases/latest redirect" 0 || check "latest resolves the tag from the releases/latest redirect (v9.9.9 has no files here, so it fails at download)" 1 "rc=$RC" "$OUT"
mkrelease v9.9.9
run_get "$TMP/h4"
[ "$RC" = 0 ] && [ -x "$TMP/h4/.local/share/vmbench/v9.9.9/vmbench" ] && check "latest installs the resolved release" 0 || check "latest installs the resolved release" 1 "rc=$RC" "$OUT"
H=$TMP/h5; mkdir -p "$H"
OUT=$(HOME=$H VMBENCH_BASE_URL=$BASE VMBENCH_LATEST_URL=$BASE/latest-none "$SH" "$GET" 2>&1); RC=$?
if [ "$RC" = 1 ] && [[ $OUT == *"no release yet"* ]] && [[ $OUT == *"VMBENCH_VERSION=main"* ]] && [[ $OUT == *"Nothing was installed"* ]] && [ ! -e "$H/.local" ]; then
  check "no release: exit 1, says how to pin or use main, installs nothing" 0
else check "no release: exit 1, says how to pin or use main, installs nothing" 1 "rc=$RC" "$OUT"; fi

# --- refusals
for case_ in "v2.0.0:CHECKSUM MISMATCH:checksum mismatch" "v3.0.0:'..' path:tarball with ../ path" "v4.0.0:absolute path:tarball with an absolute path" "v5.0.0:link:tarball with a symlink" "v6.0.0:not a vmbench release:tarball that is not vmbench"; do
  IFS=: read -r tag msg name <<< "$case_"
  H=$TMP/bad-$tag
  run_get "$H" --version "$tag"
  left=$(snapshot "$H")
  if [ "$RC" = 1 ] && [[ $OUT == *"$msg"* ]] && [ ! -e "$H/.local/share/vmbench/$tag" ] && [ ! -e "$H/.local/bin/vmbench" ]; then check "$name is refused, nothing installed" 0
  else check "$name is refused, nothing installed" 1 "rc=$RC want '$msg'" "$OUT" "left: $left"; fi
done
[ ! -e "$TMP/escaped" ] && [ ! -e "$TMP/h/escaped" ] && [ ! -e "$TMP/abs-escaped" ] && check "nothing was written outside the install folder" 0 || check "nothing was written outside the install folder" 1
run_get "$TMP/bad-v2.0.0" --version v2.0.0
[[ $OUT == *"nothing was extracted"* ]] && check "checksum mismatch says nothing was extracted" 0 || check "checksum mismatch says nothing was extracted" 1 "$OUT"
run_get "$TMP/bad-v7" --version v7.7.7
[ "$RC" = 1 ] && [[ $OUT == *"download failed"* ]] && check "a version that does not exist fails at download" 0 || check "a version that does not exist fails at download" 1 "rc=$RC" "$OUT"
run_get "$TMP/bad-v8" --version 'v1/../x'
[ "$RC" = 2 ] && check "a version with a slash is a usage error" 0 || check "a version with a slash is a usage error" 1 "rc=$RC" "$OUT"
run_get "$TMP/bad-v9" --bogus
[ "$RC" = 2 ] && [[ $OUT == *"unknown option"* ]] && check "unknown option exits 2" 0 || check "unknown option exits 2" 1 "rc=$RC" "$OUT"
run_get "$TMP/bad-v10" --prefix relative/dir --version v1.0.0
[ "$RC" = 2 ] && check "relative --prefix is refused" 0 || check "relative --prefix is refused" 1 "rc=$RC" "$OUT"

# --- dry run
H=$TMP/dry; mkdir -p "$H"
before=$(snapshot "$H")
run_get "$H" --dry-run --version v1.0.0
after=$(snapshot "$H")
[ "$RC" = 0 ] && [ "$before" = "$after" ] && [[ $OUT == *"[dry-run] download:"*"v1.0.0"* ]] && [[ $OUT == *"[dry-run] install into:"* ]] && check "--dry-run prints the actions and changes nothing" 0 || check "--dry-run prints the actions and changes nothing" 1 "$OUT" "$after"
run_get "$TMP/h1" --dry-run --uninstall
[ -d "$TMP/h1/.local/share/vmbench" ] && [[ $OUT == *"[dry-run] rm -rf"* ]] && check "--dry-run --uninstall removes nothing" 0 || check "--dry-run --uninstall removes nothing" 1 "$OUT"

# --- uninstall
H=$TMP/h1
run_get "$H" --uninstall --version v1.0.0
[ "$RC" = 0 ] && [ ! -e "$H/.local/share/vmbench/v1.0.0" ] && [ -d "$H/.local/share/vmbench/v1.0.1" ] && [ -L "$H/.local/bin/vmbench" ] && check "--uninstall --version removes only that version" 0 || check "--uninstall --version removes only that version" 1 "$OUT"
run_get "$H" --uninstall
[ "$RC" = 0 ] && [ ! -e "$H/.local/share/vmbench" ] && [ ! -L "$H/.local/bin/vmbench" ] && check "--uninstall removes the install and the symlink" 0 || check "--uninstall removes the install and the symlink" 1 "$OUT" "$(snapshot "$H")"
run_get "$H" --uninstall
[ "$RC" = 0 ] && [[ $OUT == *"nothing to remove"* ]] && check "--uninstall twice is fine" 0 || check "--uninstall twice is fine" 1 "$OUT"
# the symlink is only removed when it is ours; a folder without the marker is never deleted
H=$TMP/h6; mkdir -p "$H/.local/bin" "$H/.local/share/vmbench"; echo keep > "$H/.local/share/vmbench/precious"
ln -s /bin/true "$H/.local/bin/vmbench"
run_get "$H" --uninstall
[ "$RC" = 1 ] && [ -f "$H/.local/share/vmbench/precious" ] && check "--uninstall refuses a folder get.sh did not create" 0 || check "--uninstall refuses a folder get.sh did not create" 1 "rc=$RC" "$OUT"
run_get "$H" --uninstall --prefix "$H/other"
[ -L "$H/.local/bin/vmbench" ] && check "--uninstall leaves a foreign symlink alone" 0 || check "--uninstall leaves a foreign symlink alone" 1 "$OUT"
run_get "$TMP/h7" --uninstall --dir "$TMP"
[ "$RC" = 1 ] && [ -d "$TMP/web" ] && check "--uninstall --dir refuses a folder that is not vmbench" 0 || check "--uninstall --dir refuses a folder that is not vmbench" 1 "rc=$RC" "$OUT"
run_get "$TMP/h3" --uninstall --dir "$TMP/exact" --bin-dir "$TMP/bin2"
[ "$RC" = 0 ] && [ ! -e "$TMP/exact" ] && [ ! -L "$TMP/bin2/vmbench" ] && check "--uninstall --dir removes that folder and its link" 0 || check "--uninstall --dir removes that folder and its link" 1 "$OUT"

# --- root refusal: a fake `id` that says 0
mkdir -p "$TMP/fakebin"; printf '#!/bin/sh\n[ "$1" = -u ] && echo 0 || echo uid=0\n' > "$TMP/fakebin/id"; chmod +x "$TMP/fakebin/id"
H=$TMP/root; mkdir -p "$H"
OUT=$(HOME=$H PATH="$TMP/fakebin:$PATH" VMBENCH_BASE_URL=$BASE "$SH" "$GET" --version v1.0.0 2>&1); RC=$?
[ "$RC" = 1 ] && [[ $OUT == *"refusing to run as root"* ]] && [ ! -e "$H/.local" ] && check "root is refused" 0 || check "root is refused" 1 "rc=$RC" "$OUT"
OUT=$(HOME=$H PATH="$TMP/fakebin:$PATH" VMBENCH_BASE_URL=$BASE "$SH" "$GET" --version v1.0.0 --allow-root 2>&1); RC=$?
[ "$RC" = 0 ] && [ -x "$H/.local/share/vmbench/v1.0.0/vmbench" ] && check "--allow-root lets root install (into its own HOME)" 0 || check "--allow-root lets root install (into its own HOME)" 1 "rc=$RC" "$OUT"

# --- missing tools are all reported at once: a PATH with only what the script itself needs to print
mkdir -p "$TMP/emptybin"
for t in sed printf cat id; do p=$(command -v $t) && ln -sf "$p" "$TMP/emptybin/$t"; done
H=$TMP/notools; mkdir -p "$H"
OUT=$(HOME=$H PATH="$TMP/emptybin" "$SH" "$GET" --version v1.0.0 2>&1); RC=$?
[ "$RC" = 1 ] && [[ $OUT == *"curl(or wget)"* ]] && [[ $OUT == *"tar"* ]] && [[ $OUT == *"sha256sum(or shasum)"* ]] && check "all missing tools are reported together" 0 || check "all missing tools are reported together" 1 "rc=$RC" "$OUT"

# --- help
OUT=$(HOME=$TMP/h8 "$SH" "$GET" --help 2>&1); RC=$?
[ "$RC" = 0 ] && [[ $OUT == *"--dry-run"* ]] && [[ $OUT == *"--uninstall"* ]] && check "--help prints the options" 0 || check "--help prints the options" 1 "$OUT"

# --- a cut-short download never runs anything: every line prefix, and the byte-halves, piped to sh
total=$(wc -l < "$GET")
bad=0 n=0
for k in $(seq 1 $((total - 1))); do
  H=$TMP/trunc; rm -rf "$H"; mkdir -p "$H"
  head -n "$k" "$GET" | HOME=$H VMBENCH_BASE_URL=$BASE VMBENCH_VERSION=v1.0.0 "$SH" >/dev/null 2>&1
  n=$((n + 1))
  [ -z "$(find "$H" -mindepth 1 | head -1)" ] || { bad=$((bad + 1)); echo "       installed after cutting at line $k"; }
done
[ "$bad" = 0 ] && check "no cut of get.sh at any line ($n cuts) installs anything" 0 || check "no cut of get.sh at any line installs anything" 1 "$bad cuts installed something"
size=$(wc -c < "$GET"); bad=0
for div in 2 3 5 7; do
  H=$TMP/trunc; rm -rf "$H"; mkdir -p "$H"
  head -c $((size / div)) "$GET" | HOME=$H VMBENCH_BASE_URL=$BASE VMBENCH_VERSION=v1.0.0 "$SH" >/dev/null 2>&1
  [ -z "$(find "$H" -mindepth 1 | head -1)" ] || bad=1
done
[ "$bad" = 0 ] && check "a script cut at 1/2, 1/3, 1/5, 1/7 of its bytes installs nothing" 0 || check "a script cut at fractions of its bytes installs nothing" 1
[ "$(tail -n 1 "$GET")" = 'main "$@"' ] && check "main is called on the last line" 0 || check "main is called on the last line" 1 "$(tail -n 1 "$GET")"
[ "$(grep -c '^main "\$@"$' "$GET")" = 1 ] && check "main is called exactly once" 0 || check "main is called exactly once" 1

# --- syntax under dash and shellcheck when present
"$SH" -n "$GET" && check "$(basename "$SH") -n get.sh" 0 || check "$(basename "$SH") -n get.sh" 1
if command -v shellcheck >/dev/null; then
  shellcheck -s sh "$GET" && check "shellcheck -s sh get.sh" 0 || check "shellcheck -s sh get.sh" 1
fi

echo
echo "get.sh tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
