#!/usr/bin/env bash
# setup-cpubench.sh - download cpubench from https://github.com/chaloemph/cpubench and verify it.
#
#   bash setup-cpubench.sh                      # newest GitHub release (default), into ~/cpubench-<tag>
#   VERSION=v0.1.0 bash setup-cpubench.sh       # pin a specific release tag
#   (the default install also points ~/cpubench-current at that folder, so commands can `cd ~/cpubench-current`)
#   DIR=/opt/cpubench bash setup-cpubench.sh    # another install folder
#
# What it does (nothing outside $DIR is touched, no sudo needed):
#   1. picks cpubench-linux-amd64 or cpubench-linux-arm64 from `uname -m`
#   2. downloads that binary and SHA256SUMS from the GitHub release, and checks the sha256
#   3. downloads tools/web-loopback.sh from the same tag (so script and binary match)
#   4. prints `cpubench version`, which must report the tag
#
# Use the SAME version on every machine you compare; `cpubench compare` warns (tool-mismatch) otherwise.
# `latest` can move between runs on different days, so pin VERSION=<tag> when you need identical binaries.
set -euo pipefail

REPO=${REPO:-chaloemph/cpubench}
VERSION=${VERSION:-latest}

if [ "$VERSION" = latest ]; then
  # resolve the newest release tag via the /releases/latest redirect (no API token or rate limit)
  command -v curl >/dev/null || { echo "missing tool: curl" >&2; exit 1; }
  url=$(curl -fsSIL --retry 3 --connect-timeout 15 -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")
  VERSION=${url##*/}
  case "$url" in
    */releases/tag/*) ;;
    *) echo "could not resolve the latest release of $REPO (got: $url)" >&2; exit 1 ;;
  esac
  echo "latest release of $REPO is $VERSION"
fi

CUSTOM_DIR=${DIR:+1}
DIR=${DIR:-$HOME/cpubench-$VERSION}

case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac
BIN=cpubench-linux-$ARCH
REL=https://github.com/$REPO/releases/download/$VERSION
RAW=https://raw.githubusercontent.com/$REPO/$VERSION

for t in curl sha256sum; do
  command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }
done

mkdir -p "$DIR"
cd "$DIR"

get() { # url dest
  curl -fsSL --retry 3 --connect-timeout 15 -o "$2.part" "$1" && mv "$2.part" "$2"
}

get "$REL/SHA256SUMS" SHA256SUMS
grep -F " $BIN" SHA256SUMS > "$BIN.sha256" || { echo "$BIN is not listed in SHA256SUMS of $VERSION" >&2; exit 1; }

if [ -x "$BIN" ] && sha256sum -c --status "$BIN.sha256" 2>/dev/null; then
  echo "[skip] $BIN already downloaded and verified"
else
  get "$REL/$BIN" "$BIN"
  sha256sum -c "$BIN.sha256"
  chmod +x "$BIN"
fi
ln -sf "$BIN" cpubench   # so commands can just say ./cpubench

get "$RAW/tools/web-loopback.sh" web-loopback.sh
chmod +x web-loopback.sh

echo "installed in: $DIR"
if [ -z "${CUSTOM_DIR:-}" ]; then
  link=$HOME/cpubench-current
  if [ -L "$link" ] || [ ! -e "$link" ]; then
    ln -sfn "$DIR" "$link" && echo "$link -> $DIR"
  else
    echo "note: $link exists and is not a symlink, left untouched" >&2
  fi
fi
got=$(./cpubench version | head -1)
echo "$got"
case "$got" in
  *"$VERSION"*) ;;
  *) echo "WARNING: binary reports a different version than $VERSION" >&2 ;;
esac
