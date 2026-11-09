#!/usr/bin/env bash
# lib/stream.sh - fetches and verifies the STREAM source (stream.c) for stages/mem.sh. Sourced by the mem stage; it can
# also be run on its own to pre-fetch or check the file:   bash lib/stream.sh [DEST]    (default ./stream.c)
#
# stream.c is pinned: an immutable URL (one commit of the official jeffhammond/STREAM repository) and the sha256 of
# the file. A file that does not match is never compiled. Where the file comes from, in this order:
#   STREAM_C=/path/to/stream.c   offline override (copied, then checked like any other source)
#   the cache  $HOME/bench-cache/stream.c   (checked too; a stale or edited copy is ignored and downloaded again)
#   the download   STREAM_URL, by default the pinned URL below
# STREAM_SKIP_CHECK=1 turns the check off for all three (warns loudly, and the run records that the source is unverified).
#
#   stream_fetch DEST    put a checked copy of stream.c at DEST; returns 1 with a message when it cannot
#   stream_sha256 FILE   print the sha256 of FILE
# Sets STREAM_SOURCE_NOTE (one line saying which source was used) for the result folder.

# To move the pin: pick a commit of https://github.com/jeffhammond/STREAM, download its stream.c, read it, run sha256sum
# on it, and change these two lines together (docs/tests.md and README.md name them too; tests/test_stream.sh checks).
STREAM_COMMIT=6703f7504a38a8da96b353cadafa64d3c2d7a2d3
STREAM_SHA256=c388924eb140fda95f534cdb808ae7f1f8ebb18da41d8aec1b512a3c8d303c9b
STREAM_PINNED_URL=https://raw.githubusercontent.com/jeffhammond/STREAM/$STREAM_COMMIT/stream.c

# a message goes to the run log inside a run, to stderr otherwise
stream_say() {
  if [ -n "${OUT:-}" ] && declare -F log >/dev/null; then log "$*"; else printf '%s\n' "$*" >&2; fi
}

stream_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else return 1; fi
}

# stream_check FILE LABEL: 0 when FILE has the pinned hash (or the check is off), 1 otherwise
stream_check() {
  local file=$1 label=$2 got
  if [ "${STREAM_SKIP_CHECK:-}" = 1 ]; then
    stream_say "WARNING: STREAM_SKIP_CHECK=1, stream.c ($label) is NOT verified against the pinned sha256 ($STREAM_SHA256). The STREAM result is only as trustworthy as that file."
    STREAM_SOURCE_NOTE="$label, UNVERIFIED (STREAM_SKIP_CHECK=1)"
    return 0
  fi
  got=$(stream_sha256 "$file") || { stream_say "stream.c cannot be verified: neither sha256sum nor shasum is installed"; return 1; }
  if [ "$got" != "$STREAM_SHA256" ]; then
    stream_say "stream.c ($label) does not match the pinned sha256: expected $STREAM_SHA256, got $got"
    return 1
  fi
  STREAM_SOURCE_NOTE="$label, sha256 verified (pinned commit $STREAM_COMMIT)"
}

stream_fetch() {
  local dest=$1 cache=${STREAM_CACHE_DIR:-$HOME/bench-cache} url=${STREAM_URL:-$STREAM_PINNED_URL}
  STREAM_SOURCE_NOTE=""
  rm -f "$dest"
  if [ -n "${STREAM_C:-}" ]; then
    [ -s "$STREAM_C" ] || { stream_say "STREAM_C=$STREAM_C is not a readable, non-empty file"; return 1; }
    cp "$STREAM_C" "$dest" || { stream_say "cannot copy STREAM_C to $dest"; return 1; }
    stream_check "$dest" "local file (STREAM_C)" || { rm -f "$dest"; return 1; }
    return 0
  fi
  if [ -s "$cache/stream.c" ]; then
    if cp "$cache/stream.c" "$dest" 2>/dev/null && stream_check "$dest" "cache"; then return 0; fi
    stream_say "cached $cache/stream.c is not the pinned file, downloading it again"
    rm -f "$dest"
  fi
  command -v curl >/dev/null 2>&1 || { stream_say "curl is required to download stream.c (or set STREAM_C=/path/to/stream.c)"; return 1; }
  curl -fsSL --retry 3 --connect-timeout 15 -o "$dest" "$url" || { rm -f "$dest"; stream_say "download of stream.c failed: $url"; return 1; }
  [ -s "$dest" ] || { rm -f "$dest"; stream_say "download of stream.c was empty: $url"; return 1; }
  stream_check "$dest" "download $url" || { rm -f "$dest"; return 1; }
  if [ "${STREAM_SKIP_CHECK:-}" != 1 ] && mkdir -p "$cache" 2>/dev/null && cp "$dest" "$cache/stream.c.$$" 2>/dev/null; then mv -f "$cache/stream.c.$$" "$cache/stream.c"; fi
  return 0
}

# run on its own: bash lib/stream.sh [DEST]
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if stream_fetch "${1:-stream.c}"; then
    echo "stream.c ready at ${1:-stream.c}: $STREAM_SOURCE_NOTE"
  else
    echo "stream.c NOT usable, see the message above" >&2
    exit 1
  fi
fi
