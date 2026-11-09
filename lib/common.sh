#!/usr/bin/env bash
# lib/common.sh - small helpers shared by every part of vmbench: errors, tool checks, time, logging, step status.
# Sourced, never executed. Needs VMBENCH_HOME (set by the vmbench entry script).
#
# Functions defined here:
#   die MSG...        print "<prog>: MSG" on stderr and exit 2 (usage and pre-flight errors always exit 2)
#   need TOOL         true when TOOL is on PATH
#   vmbench_version   the version string (VERSION file, else git describe, else "unknown")
#   utc_now           current UTC time as 2006-01-02T15:04:05Z
# Needing a result folder (OUT, set by `vmbench run`):
#   T FULL QUICK      FULL normally, QUICK when QUICK=1
#   log MSG...        timestamped line on stdout and in $OUT/run.log
#   ok|bad|skip STAGE STEP [WHY]   record a step in status.tsv (bad and skip also log)
#   tv N              thread count to id suffix: 1 -> 1t, else max

# The program name in error messages: run-benchmark.sh when called through the compatibility wrapper.
die() { printf '%s: %s\n' "${VMBENCH_PROG:-vmbench}" "$*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1; }

vmbench_version() {
  if [ -s "$VMBENCH_HOME/VERSION" ]; then head -1 "$VMBENCH_HOME/VERSION"
  elif need git && git -C "$VMBENCH_HOME" describe --tags --always --dirty 2>/dev/null; then :
  else echo unknown; fi
}
utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

T() { if [ "$QUICK" = 1 ]; then echo "$2"; else echo "$1"; fi; }   # T <full> <quick>
log() { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$OUT/run.log"; }
tv() { if [ "$1" = 1 ]; then echo 1t; else echo max; fi; }   # thread count -> id suffix
ok() { printf '%s\t%s\tOK\n' "$1" "$2" >> "$STATUS"; }
bad() { printf '%s\t%s\tFAIL %s\n' "$1" "$2" "${3:-}" >> "$STATUS"; log "[FAIL] $1: $2 ${3:-}"; }
skip() { printf '%s\t%s\tSKIP %s\n' "$1" "$2" "${3:-}" >> "$STATUS"; log "[SKIP] $1: $2 ${3:-}"; }
