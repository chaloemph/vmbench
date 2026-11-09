#!/usr/bin/env bash
# Tests for the command line of run-benchmark.sh that need no benchmark tools and no network:
# option parsing, error messages, exit codes, the pre-flight check, --list, and the info stage.
# Usage: bash tests/test_cli.sh
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
SCRIPT=$PWD/run-benchmark.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
check() { # name, ok (0 = pass), details...
  local name=$1 ok=$2; shift 2
  if [ "$ok" = 0 ]; then pass=$((pass + 1)); printf 'ok   %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; [ $# -gt 0 ] && printf '       %s\n' "$@"; fi
}

# run <args...>: sets RC and OUTPUT (stdout and stderr together); every run gets its own HOME so ~ is never touched
# A run that takes longer than RUN_TIMEOUT seconds is a failure (exit 124): if the pre-flight ever broke, these
# tests would otherwise start real benchmarks.
run() {
  OUTPUT=$(HOME=$TMP/home OUT=$TMP/out DATA_DIR=$TMP/data CB=$TMP/no-cpubench PEER="" timeout "${RUN_TIMEOUT:-20}" "$@" 2>&1); RC=$?
}
sb() { run bash "$SCRIPT" "$@"; }
expect_fail() { # name, expected message part, args...
  local name=$1 msg=$2; shift 2
  sb "$@"
  if [ "$RC" = 2 ] && [[ $OUTPUT == *"$msg"* ]]; then check "$name" 0
  else check "$name" 1 "exit=$RC, wanted exit 2 and '$msg'" "got: ${OUTPUT:0:200}"; fi
}

mkdir -p "$TMP/home"

sb --help
if [ "$RC" = 0 ] && [[ $OUTPUT == *"--with LIST"* ]] && [[ $OUTPUT == *"--only LIST"* ]]; then check "--help exits 0 and lists the options" 0
else check "--help exits 0 and lists the options" 1 "exit=$RC"; fi
sb -h
[ "$RC" = 0 ] && check "-h is the same as --help" 0 || check "-h is the same as --help" 1 "exit=$RC"

expect_fail "unknown option"                 "unknown option '--bogus'"          --bogus
expect_fail "stray argument"                 "unknown option 'extra'"            extra
expect_fail "--with without a value"         "--with needs a value"              --with
expect_fail "--only with an empty value"     "--only needs a value"              --only ""
expect_fail "unknown stage"                  "unknown stage 'nope'"              --with nope
expect_fail "--with and --only together"     "use --with or --only, not both"    --with web --only cpu
expect_fail "--peer without the net stage"   "add --with net"                    --peer 192.0.2.10
expect_fail "--hours without the burnin stage" "add --only burnin"               --hours 5
expect_fail "--hours of zero"                "--hours needs a number above 0"    --only burnin --hours 0
expect_fail "--hours not a number"           "--hours needs a number above 0"    --only burnin --hours abc
expect_fail "--hours negative"               "--hours needs a number above 0"    --only burnin --hours -3

# ram is another name for mem: both must be accepted by the parser, so the failure must come from the pre-flight
sb --only ram
if [[ $OUTPUT != *"unknown stage"* ]]; then check "ram is accepted as a stage name" 0
else check "ram is accepted as a stage name" 1 "${OUTPUT:0:200}"; fi

# pre-flight: web needs cpubench, which is deliberately missing here; nothing may run and no result folder may appear
rm -rf "$TMP/out"
sb --only web
if [ "$RC" = 2 ] && [[ $OUTPUT == *"not ready: web"* ]] && [[ $OUTPUT == *"nothing was run"* ]] && [ ! -e "$TMP/out" ]; then
  check "pre-flight stops before anything runs" 0
else check "pre-flight stops before anything runs" 1 "exit=$RC, out exists: $([ -e "$TMP/out" ] && echo yes || echo no)" "got: ${OUTPUT:0:200}"; fi

sb --with net
if [ "$RC" = 2 ] && [[ $OUTPUT == *"not ready: net: no peer"* ]]; then check "net without a peer is refused" 0
else check "net without a peer is refused" 1 "exit=$RC" "got: ${OUTPUT:0:200}"; fi

# one run lists every problem, not only the first
sb --only web,net
n=$(grep -c '^not ready:' <<<"$OUTPUT")
[ "$n" -ge 2 ] && check "all problems are listed in one go" 0 || check "all problems are listed in one go" 1 "only $n line(s)"

# raw device safety: refused without CONFIRM_WIPE, and the message says why
run env RAW_DEV=/dev/null bash "$SCRIPT" --only disk
if [ "$RC" = 2 ] && [[ $OUTPUT == *"CONFIRM_WIPE=yes"* ]]; then check "RAW_DEV without CONFIRM_WIPE is refused" 0
else check "RAW_DEV without CONFIRM_WIPE is refused" 1 "exit=$RC" "got: ${OUTPUT:0:200}"; fi
run env RAW_DEV=/dev/null CONFIRM_WIPE=yes bash "$SCRIPT" --only disk
if [ "$RC" = 2 ] && [[ $OUTPUT == *"is not a block device"* ]]; then check "RAW_DEV that is not a block device is refused" 0
else check "RAW_DEV that is not a block device is refused" 1 "exit=$RC" "got: ${OUTPUT:0:200}"; fi

# --list: always exits 0 and shows all seven stages whatever is installed
sb --list
rows=$(grep -cE '^(cpu|mem|disk|pg|net|web|burnin) ' <<<"$OUTPUT")
if [ "$RC" = 0 ] && [ "$rows" = 7 ] && [[ $OUTPUT == STAGE* ]]; then check "--list shows the seven stages" 0
else check "--list shows the seven stages" 1 "exit=$RC, stage lines=$rows"; fi

# STAGES from the environment is ignored, with a note, once --with or --only is given
run env STAGES="cpu" bash "$SCRIPT" --only=web
if [[ $OUTPUT == *"STAGES is ignored"* ]]; then check "STAGES is ignored when --only is given" 0
else check "STAGES is ignored when --only is given" 1 "got: ${OUTPUT:0:200}"; fi

# the info stage runs anywhere: it only reads the machine
RUN_TIMEOUT=120 run env LABEL=ci-label QUICK=1 bash "$SCRIPT" --only=info
if [ "$RC" = 0 ]; then check "info stage exits 0" 0; else check "info stage exits 0" 1 "exit=$RC" "got: ${OUTPUT:0:300}"; fi
if [ -f "$TMP/out/info.txt" ] && grep -q '^label: ci-label' "$TMP/out/info.txt" && grep -q '^nproc: ' "$TMP/out/info.txt"; then
  check "info.txt records the label and the vCPU count" 0
else check "info.txt records the label and the vCPU count" 1; fi
if grep -qP '^info\tmetadata\tOK$' "$TMP/out/status.tsv" 2>/dev/null; then check "status.tsv records the info step" 0
else check "status.tsv records the info step" 1; fi
if [ -f "$TMP/out/results.tsv" ] && [ "$(head -1 "$TMP/out/results.tsv")" = $'row\tmetric\tvalue\tunit\tround' ]; then
  check "results.tsv has the expected header" 0
else check "results.tsv has the expected header" 1; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
