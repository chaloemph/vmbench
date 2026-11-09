#!/usr/bin/env bash
# scripts/build-release.sh - build the release tarball and SHA256SUMS. The release workflow calls this; you can run it
# locally and get the same bytes.
#
#   bash scripts/build-release.sh v0.1.0                 # from HEAD, into ./dist
#   bash scripts/build-release.sh v0.1.0 --ref v0.1.0 --out /tmp/rel
#
# Output: <out>/vmbench-<tag>.tar.gz and <out>/SHA256SUMS. The tarball has one top folder vmbench-<tag>/ and is the
# committed files of REF (git archive; .gitattributes leaves out tests/ and .github/) plus a VERSION file holding the tag.
# Reproducible: files are sorted, owner is root, every timestamp is the commit time of REF, gzip stores no name or time.
# Building twice from the same commit gives the same sha256.
set -euo pipefail

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }

TAG="" REF=HEAD OUT=dist
while [ $# -gt 0 ]; do
  case $1 in
    --ref) REF=${2:?--ref needs a value}; shift 2 ;;
    --out) OUT=${2:?--out needs a value}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "build-release: unknown option $1" >&2; exit 2 ;;
    *) [ -z "$TAG" ] || { echo "build-release: one tag only" >&2; exit 2; }; TAG=$1; shift ;;
  esac
done
[ -n "$TAG" ] || { usage >&2; exit 2; }
[[ $TAG =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "build-release: bad tag '$TAG'" >&2; exit 2; }

cd "$(dirname "${BASH_SOURCE[0]}")/.."
git rev-parse --git-dir >/dev/null 2>&1 || { echo "build-release: not a git checkout" >&2; exit 1; }
git rev-parse --verify --quiet "$REF^{commit}" >/dev/null || { echo "build-release: unknown ref $REF" >&2; exit 1; }
stamp=$(git log -1 --format=%ct "$REF^{commit}")
name=vmbench-$TAG

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tree" "$OUT"

git archive --format=tar --prefix="$name/" "$REF^{commit}" | tar -xf - -C "$work/tree" --no-same-owner
printf '%s\n' "$TAG" > "$work/tree/$name/VERSION"
chmod 644 "$work/tree/$name/VERSION"

tarball=$work/$name.tar.gz
(
  cd "$work/tree"
  tar --sort=name --mtime="@$stamp" --owner=0 --group=0 --numeric-owner --format=gnu -cf - "$name" | gzip -n -9 > "$tarball"
)
out_abs=$(cd "$OUT" && pwd)
mv "$tarball" "$out_abs/$name.tar.gz"
(cd "$out_abs" && sha256sum "$name.tar.gz" > SHA256SUMS)
echo "built $out_abs/$name.tar.gz"
cat "$out_abs/SHA256SUMS"
