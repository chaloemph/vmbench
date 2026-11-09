#!/usr/bin/env bash
# Tests for the `vmbench` entry script: subcommands, error messages, exit codes, `version`, `list`, the
# compatibility wrappers, and finding its own folder from another directory and through symlinks.
# Needs no benchmark tools and no network. Usage: bash tests/test_vmbench.sh
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT=$PWD
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/elsewhere"

pass=0 fail=0
check() { # name, ok (0 = pass), details...
  local name=$1 ok=$2; shift 2
  if [ "$ok" = 0 ]; then pass=$((pass + 1)); printf 'ok   %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; [ $# -gt 0 ] && printf '       %s\n' "$@"; fi
}
# run <args...>: RC and OUTPUT (stdout and stderr); own HOME, a time limit so nothing can start a real benchmark
run() { OUTPUT=$(HOME=$TMP/home OUT=$TMP/out DATA_DIR=$TMP/data CB=$TMP/no-cpubench PEER="" timeout "${RUN_TIMEOUT:-20}" "$@" 2>&1); RC=$?; }
expect() { # name, expected exit code, expected message part, command...
  local name=$1 rc=$2 msg=$3; shift 3
  run "$@"
  if [ "$RC" = "$rc" ] && [[ $OUTPUT == *"$msg"* ]]; then check "$name" 0
  else check "$name" 1 "exit=$RC, wanted $rc and '$msg'" "got: ${OUTPUT:0:200}"; fi
}
VM=$ROOT/vmbench

# --- top level
expect "no command prints usage and exits 2"      2 "vmbench run [flags]"       bash "$VM"
expect "help exits 0"                             0 "vmbench setup cpubench|postgres" bash "$VM" help
expect "--help exits 0"                           0 "vmbench list"              bash "$VM" --help
expect "unknown command"                          2 "vmbench: unknown command 'bogus'" bash "$VM" bogus
expect "version prints the version"               0 "vmbench "                  bash "$VM" version
v1=$OUTPUT
run bash "$VM" --version; [ "$RC" = 0 ] && [ "$OUTPUT" = "$v1" ] && check "--version is the same as version" 0 || check "--version is the same as version" 1 "$OUTPUT"
[[ $v1 =~ ^vmbench\ [A-Za-z0-9._-]+$ ]] && check "version is one word after the name" 0 || check "version is one word after the name" 1 "$v1"

# --- run
expect "run --help exits 0 and lists the options" 0 "--with LIST"               bash "$VM" run --help
expect "run --help names itself vmbench run"      0 "vmbench run --with web,pg" bash "$VM" run --help
expect "run unknown option"                       2 "vmbench: unknown option '--bogus'" bash "$VM" run --bogus
expect "run unknown stage"                        2 "unknown stage 'nope'"      bash "$VM" run --with nope
expect "run --with and --only together"           2 "use --with or --only, not both" bash "$VM" run --with web --only cpu
expect "run pre-flight stops, exit 2"             2 "nothing was run"           bash "$VM" run --only web
expect "run --hours of zero"                      2 "--hours needs a number above 0" bash "$VM" run --only burnin --hours 0
run bash "$VM" run --metrics; n=$(grep -cE '^[a-z]+(\.[a-z0-9-]+)+\|' <<<"$OUTPUT")
[ "$RC" = 0 ] && [ "$n" -gt 50 ] && check "run --metrics prints the table" 0 || check "run --metrics prints the table" 1 "rc=$RC n=$n"

# --- list
run bash "$VM" list; rows=$(grep -cE '^(cpu|mem|disk|pg|net|web|burnin) ' <<<"$OUTPUT")
[ "$RC" = 0 ] && [ "$rows" = 7 ] && [[ $OUTPUT == STAGE* ]] && check "list shows the seven stages and exits 0" 0 || check "list shows the seven stages and exits 0" 1 "rc=$RC rows=$rows"
list1=$OUTPUT
run bash "$VM" run --list; [ "$OUTPUT" = "$list1" ] && check "list is the same as run --list" 0 || check "list is the same as run --list" 1
expect "list takes no arguments"                  2 "list takes no arguments"   bash "$VM" list extra

# --- report
expect "report without a subcommand"              2 "report needs a subcommand" bash "$VM" report
expect "report with a wrong subcommand"           2 "unknown report subcommand 'bogus'" bash "$VM" report bogus
expect "report show without a folder (report.py error)" 2 "usage:"              bash "$VM" report show
expect "report show of a missing folder"          2 "not found"                 bash "$VM" report show "$TMP/nothing"
fixture=$(find "$ROOT/tests/fixtures" -name results.tsv -print -quit)
if [ -n "$fixture" ]; then
  cp -R "$(dirname "$fixture")" "$TMP/fixture"; d=$TMP/fixture   # report show writes report.md and report.html into the folder
  run bash "$VM" report show "$d"; viavm=$OUTPUT; rcvm=$RC
  run bash -c "cd '$TMP/elsewhere' && python3 -I '$ROOT/report.py' show '$d'"
  [ "$rcvm" = "$RC" ] && [ "$viavm" = "$OUTPUT" ] && [ "$RC" = 0 ] && check "report show is the same as report.py show" 0 || check "report show is the same as report.py show" 1 "rc=$rcvm/$RC"
else check "report show is the same as report.py show" 1 "no fixture found"; fi
run bash "$VM" report show "$ROOT/tests/fixtures/vm-a" --no-files --lang th
[ "$RC" = 0 ] && [[ $OUTPUT == *"สภาพแวดล้อม"* ]] && check "report show --lang th prints Thai" 0 || check "report show --lang th prints Thai" 1 "rc=$RC"
run bash "$VM" report compare "$ROOT/tests/fixtures/vm-a" "$ROOT/tests/fixtures/vm-b" --no-files
[ "$RC" = 0 ] && [[ $OUTPUT == *"Verdict"* ]] && check "report compare is English by default" 0 || check "report compare is English by default" 1 "rc=$RC"
run env VMBENCH_LANG=th bash "$VM" report show "$ROOT/tests/fixtures/vm-a" --no-files
[ "$RC" = 0 ] && [[ $OUTPUT == *"สภาพแวดล้อม"* ]] && check "VMBENCH_LANG=th is passed through vmbench report" 0 || check "VMBENCH_LANG=th is passed through vmbench report" 1 "rc=$RC"

# --- setup (only the error paths: the real scripts download files and use sudo)
expect "setup without a target"                   2 "setup needs a target"      bash "$VM" setup
expect "setup with a wrong target"                2 "unknown setup target 'x'"  bash "$VM" setup x
for f in setup-cpubench.sh setup-postgres-bench.sh setup/cpubench.sh setup/postgres.sh; do
  bash -n "$ROOT/$f" && check "$f parses" 0 || check "$f parses" 1
done
grep -q 'setup/cpubench.sh' "$ROOT/setup-cpubench.sh" && grep -q 'setup/postgres.sh' "$ROOT/setup-postgres-bench.sh" && check "the old setup scripts forward to setup/" 0 || check "the old setup scripts forward to setup/" 1
# the cpubench setup refuses an unsupported pin without touching anything: a bogus REPO fails before any download dir is made
run env VERSION=v0 REPO=invalid/none DIR="$TMP/cb" bash "$ROOT/setup-cpubench.sh"
[ "$RC" != 0 ] && [ ! -e "$TMP/cb/cpubench" ] && check "setup-cpubench.sh wrapper runs the real script (fails cleanly offline)" 0 || check "setup-cpubench.sh wrapper runs the real script (fails cleanly offline)" 1 "rc=$RC"

# --- compatibility wrapper: run-benchmark.sh behaves exactly like vmbench run (names in messages aside)
same() { # name, args...
  local name=$1; shift
  run bash "$ROOT/run-benchmark.sh" "$@"; local a=$OUTPUT ra=$RC
  run bash "$VM" run "$@"
  local b=${OUTPUT//vmbench run/run-benchmark.sh}; b=${b//vmbench:/run-benchmark.sh:}
  a=${a//bash run-benchmark.sh/run-benchmark.sh}; b=${b//bash run-benchmark.sh/run-benchmark.sh}
  if [ "$ra" = "$RC" ] && [ "$a" = "$b" ]; then check "wrapper = vmbench run: $name" 0
  else check "wrapper = vmbench run: $name" 1 "exit $ra vs $RC" "wrapper: ${a:0:150}" "vmbench:  ${b:0:150}"; fi
}
same "--list" --list
same "--metrics" --metrics
same "--only web (pre-flight)" --only web
same "--with net" --with net
same "--only web,net" --only web,net
same "--hours 0" --only burnin --hours 0
same "--bogus" --bogus
expect "wrapper keeps the name run-benchmark.sh in errors" 2 "run-benchmark.sh: unknown option '--bogus'" bash "$ROOT/run-benchmark.sh" --bogus
expect "wrapper --help keeps the old text"        0 "bash run-benchmark.sh --with web,pg" bash "$ROOT/run-benchmark.sh" --help

# --- other directory and symlinks
run bash -c "cd '$TMP/elsewhere' && bash '$VM' list"; [ "$RC" = 0 ] && [ "$OUTPUT" = "$list1" ] && check "works from another directory" 0 || check "works from another directory" 1 "rc=$RC ${OUTPUT:0:150}"
run bash -c "cd '$TMP/elsewhere' && '$VM' version"; [ "$RC" = 0 ] && [ "$OUTPUT" = "$v1" ] && check "runs as an executable from another directory" 0 || check "runs as an executable from another directory" 1 "rc=$RC ${OUTPUT:0:150}"
run bash -c "cd '$TMP/elsewhere' && bash '$ROOT/run-benchmark.sh' --only web"; [ "$RC" = 2 ] && [[ $OUTPUT == *"nothing was run"* ]] && check "wrapper works from another directory" 0 || check "wrapper works from another directory" 1 "rc=$RC"
mkdir -p "$TMP/bin"; ln -s "$VM" "$TMP/bin/vmbench"; ln -s "$ROOT/run-benchmark.sh" "$TMP/bin/run-benchmark.sh"
run "$TMP/bin/vmbench" list; [ "$RC" = 0 ] && [ "$OUTPUT" = "$list1" ] && check "works through a symlink" 0 || check "works through a symlink" 1 "rc=$RC ${OUTPUT:0:150}"
run "$TMP/bin/vmbench" report show "${d:-/nonexistent}"; [ "$RC" = 0 ] && check "report works through a symlink" 0 || check "report works through a symlink" 1 "rc=$RC ${OUTPUT:0:150}"
run bash "$TMP/bin/run-benchmark.sh" --metrics; [ "$RC" = 0 ] && check "wrapper works through a symlink" 0 || check "wrapper works through a symlink" 1 "rc=$RC"
ln -s bin/vmbench "$TMP/second-link"; run "$TMP/second-link" version; [ "$RC" = 0 ] && [ "$OUTPUT" = "$v1" ] && check "works through a relative symlink to a symlink" 0 || check "works through a relative symlink to a symlink" 1 "rc=$RC ${OUTPUT:0:150}"
mkdir -p "$TMP/with space"; ln -s "$VM" "$TMP/with space/vm link"; run "$TMP/with space/vm link" version; [ "$RC" = 0 ] && [ "$OUTPUT" = "$v1" ] && check "works through a symlink in a path with spaces" 0 || check "works through a symlink in a path with spaces" 1 "rc=$RC ${OUTPUT:0:150}"

# --- an end-to-end run through each entry point gives the same results (info stage only: it reads the machine)
for how in vmbench wrapper; do
  rm -rf "$TMP/out"
  if [ $how = vmbench ]; then RUN_TIMEOUT=120 run env LABEL=eq QUICK=1 bash "$VM" run --only=info
  else RUN_TIMEOUT=120 run env LABEL=eq QUICK=1 bash "$ROOT/run-benchmark.sh" --only=info; fi
  [ "$RC" = 0 ] && check "info run via $how exits 0" 0 || check "info run via $how exits 0" 1 "rc=$RC ${OUTPUT:0:200}"
  cp "$TMP/out/results.tsv" "$TMP/res-$how.tsv"; cp "$TMP/out/status.tsv" "$TMP/st-$how.tsv"
  [ -s "$TMP/out/meta.json" ] && [ -s "$TMP/out/summary.tsv" ] && [ -s "$TMP/out/info.txt" ] && check "info run via $how writes meta.json, summary.tsv, info.txt" 0 || check "info run via $how writes meta.json, summary.tsv, info.txt" 1
done
cmp -s "$TMP/res-vmbench.tsv" "$TMP/res-wrapper.tsv" && cmp -s "$TMP/st-vmbench.tsv" "$TMP/st-wrapper.tsv" && check "results.tsv and status.tsv are identical for both entry points" 0 || check "results.tsv and status.tsv are identical for both entry points" 1

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
