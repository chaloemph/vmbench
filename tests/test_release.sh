#!/usr/bin/env bash
# Tests for scripts/build-release.sh: the tarball is reproducible, has the right contents and VERSION, and get.sh can
# install it from a local fake release. Builds from the committed HEAD (uncommitted changes are not in a release).
# No network, no sudo. Usage: bash tests/test_release.sh
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT=$PWD
pass=0 fail=0
check() { # name, ok (0 = pass), details...
  local name=$1 ok=$2; shift 2
  if [ "$ok" = 0 ]; then pass=$((pass + 1)); printf 'ok   %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; [ $# -gt 0 ] && printf '       %s\n' "$@"; fi
}
if ! git rev-parse --verify --quiet 'HEAD^{commit}' >/dev/null 2>&1; then
  echo "skip: not a git checkout, nothing to build a release from"; exit 0
fi
TMP=$(mktemp -d)
SRV=""
trap '[ -n "$SRV" ] && kill $SRV 2>/dev/null; rm -rf "$TMP"' EXIT
TAG=v0.0.0-citest
SH=$(command -v dash || command -v sh)

check "VERSION file exists and says 0.0.0-dev" "$([ "$(cat VERSION)" = 0.0.0-dev ] && echo 0 || echo 1)"

out=$(bash scripts/build-release.sh "$TAG" --out "$TMP/a" 2>&1); rc=$?
[ "$rc" = 0 ] && check "build-release.sh succeeds" 0 || check "build-release.sh succeeds" 1 "$out"
sleep 1.2   # a different wall clock second must not change the bytes
bash scripts/build-release.sh "$TAG" --out "$TMP/b" >/dev/null 2>&1
cmp -s "$TMP/a/vmbench-$TAG.tar.gz" "$TMP/b/vmbench-$TAG.tar.gz" && check "building twice gives identical bytes" 0 || check "building twice gives identical bytes" 1
[ "$(cat "$TMP/a/SHA256SUMS")" = "$(cat "$TMP/b/SHA256SUMS")" ] && check "building twice gives the same SHA256SUMS ($(cut -c1-12 "$TMP/a/SHA256SUMS"))" 0 || check "building twice gives the same SHA256SUMS" 1
(cd "$TMP/a" && sha256sum -c --status SHA256SUMS) && check "SHA256SUMS verifies the tarball (sha256sum -c)" 0 || check "SHA256SUMS verifies the tarball" 1
bash scripts/build-release.sh v0.0.0-other --out "$TMP/c" >/dev/null 2>&1
cmp -s "$TMP/a/vmbench-$TAG.tar.gz" "$TMP/c/vmbench-v0.0.0-other.tar.gz" && check "a different tag gives a different tarball" 1 || check "a different tag gives a different tarball" 0

list=$(tar -tzf "$TMP/a/vmbench-$TAG.tar.gz")
[ "$(printf '%s\n' "$list" | cut -d/ -f1 | sort -u)" = "vmbench-$TAG" ] && check "one top folder vmbench-<tag>/" 0 || check "one top folder vmbench-<tag>/" 1
for f in vmbench get.sh VERSION lib/common.sh stages/cpu.sh report.py README.md LICENSE; do
  printf '%s\n' "$list" | grep -qx "vmbench-$TAG/$f" && check "tarball contains $f" 0 || check "tarball contains $f" 1
done
printf '%s\n' "$list" | grep -Eq "^vmbench-$TAG/(tests|\.github)(/|$)" && check "tarball leaves out tests/ and .github/" 1 || check "tarball leaves out tests/ and .github/" 0
printf '%s\n' "$list" | grep -Eq '^/|\.\.' && check "tarball has no absolute or .. paths" 1 || check "tarball has no absolute or .. paths" 0
tar -tvzf "$TMP/a/vmbench-$TAG.tar.gz" | cut -c1 | grep -q '[lh]' && check "tarball has no links" 1 || check "tarball has no links" 0
tar -tvzf "$TMP/a/vmbench-$TAG.tar.gz" | awk '{print $2}' | grep -vqx '0/0' && check "all files are owned by 0/0" 1 || check "all files are owned by 0/0" 0
mkdir "$TMP/x" && tar -xzf "$TMP/a/vmbench-$TAG.tar.gz" -C "$TMP/x"
[ "$(cat "$TMP/x/vmbench-$TAG/VERSION")" = "$TAG" ] && check "VERSION in the tarball is the tag" 0 || check "VERSION in the tarball is the tag" 1
[ "$(bash "$TMP/x/vmbench-$TAG/vmbench" version)" = "vmbench $TAG" ] && check "vmbench version in the extracted tarball prints the tag" 0 || check "vmbench version in the extracted tarball prints the tag" 1 "$(bash "$TMP/x/vmbench-$TAG/vmbench" version 2>&1)"
[ -x "$TMP/x/vmbench-$TAG/vmbench" ] && [ -x "$TMP/x/vmbench-$TAG/get.sh" ] && check "vmbench and get.sh stay executable" 0 || check "vmbench and get.sh stay executable" 1
v=$(bash "$ROOT/vmbench" version)
[ "$v" != "vmbench 0.0.0-dev" ] && [ "$v" != "vmbench unknown" ] && check "a git checkout still reports git describe ($v)" 0 || check "a git checkout still reports git describe" 1 "$v"
bash scripts/build-release.sh 'bad tag' --out "$TMP/d" >/dev/null 2>&1; [ $? = 2 ] && check "a bad tag is refused" 0 || check "a bad tag is refused" 1

# install the freshly built tarball with get.sh from a local fake release
mkdir -p "$TMP/web/$TAG"; cp "$TMP/a/vmbench-$TAG.tar.gz" "$TMP/a/SHA256SUMS" "$TMP/web/$TAG/"
python3 -I tests/fakeserver.py "$TMP/web" "$TMP/port" & SRV=$!
for _ in $(seq 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
H=$TMP/home; mkdir -p "$H"
out=$(HOME=$H VMBENCH_BASE_URL=http://127.0.0.1:$(cat "$TMP/port") "$SH" "$ROOT/get.sh" --version "$TAG" 2>&1); rc=$?
[ "$rc" = 0 ] && check "get.sh installs the built tarball" 0 || check "get.sh installs the built tarball" 1 "$out"
got=$(HOME=$H "$H/.local/bin/vmbench" version 2>&1)
[ "$got" = "vmbench $TAG" ] && check "installed vmbench version prints the tag" 0 || check "installed vmbench version prints the tag" 1 "$got"
got=$(HOME=$H "$H/.local/bin/vmbench" help 2>&1 | head -1)
[[ $got == *vmbench* ]] && check "installed vmbench runs help" 0 || check "installed vmbench runs help" 1 "$got"
HOME=$H "$SH" "$ROOT/get.sh" --uninstall >/dev/null 2>&1
[ ! -e "$H/.local/share/vmbench" ] && [ ! -L "$H/.local/bin/vmbench" ] && check "uninstall cleans it up" 0 || check "uninstall cleans it up" 1

echo
echo "release tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
