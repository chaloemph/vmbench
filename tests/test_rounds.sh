#!/usr/bin/env bash
# Tests for the repeats (rounds) of the mem, web and disk stages and the options that set them: validation, the
# defaults, QUICK, the times in --list, meta.json, and one results.tsv row per value per round. The stages run with
# fake tools (a stub fio and a stub cpubench) so no benchmark is needed. Usage: bash tests/test_rounds.sh
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
mkdir -p "$TMP/home"
run() { OUTPUT=$(HOME=$TMP/home LABEL=lbl OUT=$TMP/out DATA_DIR=$TMP/data CB=$TMP/no-cpubench PEER="" timeout 30 "$@" 2>&1); RC=$?; }
vb() { run bash "$ROOT/vmbench" "$@"; }
expect_fail() { # name, message part, env assignments or args...
  local name=$1 msg=$2; shift 2
  run "$@"
  if [ "$RC" = 2 ] && [[ $OUTPUT == *"$msg"* ]]; then check "$name" 0
  else check "$name" 1 "rc=$RC wanted exit 2 and '$msg'" "got: ${OUTPUT:0:200}"; fi
}

# --- validation (exit 2 before anything runs, no result folder)
rm -rf "$TMP/out"
expect_fail "--rounds 0"                  "--rounds needs a whole number of 1 or more, got '0'"   bash "$ROOT/vmbench" run --only mem --rounds 0
expect_fail "--rounds -2"                 "--rounds needs a whole number of 1 or more, got '-2'"  bash "$ROOT/vmbench" run --only mem --rounds -2
expect_fail "--rounds abc"                "got 'abc'"                                             bash "$ROOT/vmbench" run --only mem --rounds abc
expect_fail "--rounds 2.5"                "got '2.5'"                                             bash "$ROOT/vmbench" run --only mem --rounds 2.5
expect_fail "--rounds 03 (leading zero)"  "got '03'"                                              bash "$ROOT/vmbench" run --only mem --rounds 03
expect_fail "--rounds without a value"    "--rounds needs a value"                                bash "$ROOT/vmbench" run --only mem --rounds
expect_fail "--disk-rounds 0"             "--disk-rounds needs a whole number of 1 or more, got '0'" bash "$ROOT/vmbench" run --only disk --disk-rounds 0
expect_fail "--disk-rounds x"             "got 'x'"                                               bash "$ROOT/vmbench" run --only disk --disk-rounds x
expect_fail "ROUNDS=0 in the environment" "ROUNDS needs a whole number of 1 or more, got '0'"     env ROUNDS=0 bash "$ROOT/vmbench" run --only mem
expect_fail "MEM_ROUNDS=two"              "MEM_ROUNDS needs a whole number of 1 or more, got 'two'" env MEM_ROUNDS=two bash "$ROOT/vmbench" run --only mem
expect_fail "WEB_ROUNDS=-1"               "WEB_ROUNDS needs a whole number"                       env WEB_ROUNDS=-1 bash "$ROOT/vmbench" run --only mem
expect_fail "DISK_ROUNDS=0"               "DISK_ROUNDS needs a whole number"                      env DISK_ROUNDS=0 bash "$ROOT/vmbench" run --only mem
expect_fail "a bad value is refused for --list too" "ROUNDS needs a whole number"                 env ROUNDS=x bash "$ROOT/vmbench" list
expect_fail "--rounds with only disk selected"  "--rounds is used by cpu, mem and web"            bash "$ROOT/vmbench" run --only disk --rounds 2
expect_fail "--disk-rounds without the disk stage" "--disk-rounds is only used by the disk stage" bash "$ROOT/vmbench" run --only mem --disk-rounds 2
[ ! -e "$TMP/out" ] && check "a refused run leaves no result folder" 0 || check "a refused run leaves no result folder" 1
run env ROUNDS=2 bash "$ROOT/vmbench" run --only mem
if [[ $OUTPUT != *"needs a whole number"* ]]; then check "valid values pass validation (the failure, if any, is pre-flight)" 0
else check "valid values pass validation (the failure, if any, is pre-flight)" 1 "${OUTPUT:0:200}"; fi

# --- the time estimates in --list scale with the rounds
list_time() { # stage, env...: the TIME column of one stage
  local s=$1; shift
  OUTPUT=$(env HOME="$TMP/home" CB="$TMP/no-cpubench" "$@" bash "$ROOT/vmbench" list 2>&1)
  awk -v s="$s" '$1==s{print $4, $5; exit}' <<<"$OUTPUT"
}
t=$(list_time cpu);  [ "$t" = "14 min" ] && check "list: cpu 3 rounds is 14 min (as before)" 0 || check "list: cpu 3 rounds is 14 min (as before)" 1 "got '$t'"
t=$(list_time mem);  [ "$t" = "3 min" ]  && check "list: mem 3 rounds is 3 min" 0 || check "list: mem 3 rounds is 3 min" 1 "got '$t'"
t=$(list_time mem MEM_ROUNDS=5); [ "$t" = "5 min" ] && check "list: MEM_ROUNDS=5 is 5 min" 0 || check "list: MEM_ROUNDS=5 is 5 min" 1 "got '$t'"
t=$(list_time web);  [ "$t" = "15 min" ] && check "list: web 3 rounds is 15 min" 0 || check "list: web 3 rounds is 15 min" 1 "got '$t'"
t=$(list_time web ROUNDS=1); [ "$t" = "5 min" ] && check "list: ROUNDS=1 makes web 5 min" 0 || check "list: ROUNDS=1 makes web 5 min" 1 "got '$t'"
t=$(list_time disk); [ "$t" = "71 min" ] && check "list: disk default (1 round) is 71 min" 0 || check "list: disk default (1 round) is 71 min" 1 "got '$t'"
t=$(list_time disk DISK_ROUNDS=3); [ "$t" = "111 min" ] && check "list: DISK_ROUNDS=3 is 71 + 2 x 20 = 111 min" 0 || check "list: DISK_ROUNDS=3 is 71 + 2 x 20 = 111 min" 1 "got '$t'"
OUTPUT=$(HOME=$TMP/home CB=$TMP/x bash "$ROOT/vmbench" run --rounds 2 --disk-rounds 4 --list 2>&1)
t=$(awk '$1=="disk"{print $4, $5}' <<<"$OUTPUT"); [ "$t" = "131 min" ] && [[ $OUTPUT == *"now cpu 2, mem 2, web 2"* ]] && check "list: --rounds and --disk-rounds change the times" 0 || check "list: --rounds and --disk-rounds change the times" 1 "got '$t'"

# --- defaults and QUICK, seen through meta.json of an info-only run (it needs no tool)
meta_rounds() { # env... : prints "<rounds> <rounds_by_stage>" of an info-only run... info does not repeat, so use write_meta directly
  env "$@" bash -c '
    VMBENCH_HOME=$1; . "$VMBENCH_HOME/lib/common.sh"; . "$VMBENCH_HOME/lib/stages.sh"; . "$VMBENCH_HOME/lib/meta.sh"; . "$VMBENCH_HOME/lib/run.sh"
    load_stages; for f in "$VMBENCH_HOME"/stages/*.sh; do :; done
    OUT=$2; mkdir -p "$OUT"; CB=/nonexistent LABEL=l STAGES=" info cpu mem disk web "; QUICK=${QUICK:-0}; START_UTC=2000-01-01T00:00:00Z; NPROC=2; RAM_GB=4
    ROUNDS=${ROUNDS:-3}; MEM_ROUNDS=${MEM_ROUNDS:-3}; WEB_ROUNDS=${WEB_ROUNDS:-3}; DISK_ROUNDS=${DISK_ROUNDS:-1}
    write_meta; python3 -I -c "import json,sys; m=json.load(open(sys.argv[1])); print(m[\"rounds\"], m[\"rounds_by_stage\"])" "$OUT/meta.json"
  ' _ "$ROOT" "$TMP/meta$$"
}
r=$(meta_rounds ROUNDS=3 WEB_ROUNDS=2 DISK_ROUNDS=4)
[ "$r" = "3 {'cpu': 3, 'mem': 3, 'disk': 4, 'web': 2}" ] && check "meta.json records the rounds of every stage" 0 || check "meta.json records the rounds of every stage" 1 "got: $r"

# the real option parser: print what cmd_run decided, by stopping at --list (stub show_stages)
decide() { # args... : "<ROUNDS> <MEM> <WEB> <DISK>" after parsing, with the environment given by the caller
  bash -c '
    VMBENCH_HOME=$1; shift
    for f in common metrics stream stages preflight meta run; do . "$VMBENCH_HOME/lib/$f.sh"; done
    load_stages
    show_stages() { echo "$ROUNDS $MEM_ROUNDS $WEB_ROUNDS $DISK_ROUNDS"; }
    cmd_run "$@" --list
  ' _ "$ROOT" "$@" 2>&1
}
export HOME=$TMP/home CB=$TMP/no-cpubench
r=$(decide);                                    [ "$r" = "3 3 3 1" ] && check "defaults: cpu, mem, web 3 rounds, disk 1" 0 || check "defaults: cpu, mem, web 3 rounds, disk 1" 1 "got: $r"
r=$(decide --rounds 5);                         [ "$r" = "5 5 5 1" ] && check "--rounds N sets cpu, mem and web, not disk" 0 || check "--rounds N sets cpu, mem and web, not disk" 1 "got: $r"
r=$(decide --rounds=4 --disk-rounds=2);         [ "$r" = "4 4 4 2" ] && check "--rounds=N and --disk-rounds=N forms" 0 || check "--rounds=N and --disk-rounds=N forms" 1 "got: $r"
r=$(MEM_ROUNDS=7 decide);                       [ "$r" = "3 7 3 1" ] && check "MEM_ROUNDS sets mem only" 0 || check "MEM_ROUNDS sets mem only" 1 "got: $r"
r=$(ROUNDS=2 WEB_ROUNDS=6 decide);              [ "$r" = "2 2 6 1" ] && check "ROUNDS is the default of mem and web, WEB_ROUNDS overrides it" 0 || check "ROUNDS is the default of mem and web, WEB_ROUNDS overrides it" 1 "got: $r"
r=$(MEM_ROUNDS=7 decide --rounds 2);            [ "$r" = "2 2 2 1" ] && check "--rounds wins over MEM_ROUNDS" 0 || check "--rounds wins over MEM_ROUNDS" 1 "got: $r"
r=$(DISK_ROUNDS=3 decide);                      [ "$r" = "3 3 3 3" ] && check "DISK_ROUNDS=3 sets the disk rounds" 0 || check "DISK_ROUNDS=3 sets the disk rounds" 1 "got: $r"
r=$(QUICK=1 decide);                            [ "$r" = "1 1 1 1" ] && check "QUICK=1 is one round everywhere" 0 || check "QUICK=1 is one round everywhere" 1 "got: $r"
r=$(QUICK=1 decide --rounds 2 --disk-rounds 2); [ "$r" = "2 2 2 2" ] && check "QUICK=1 with --rounds still repeats (smoke test of the rounds)" 0 || check "QUICK=1 with --rounds still repeats (smoke test of the rounds)" 1 "got: $r"
r=$(QUICK=1 MEM_ROUNDS=2 decide);               [ "$r" = "3 2 3 1" ] && check "QUICK=1 with MEM_ROUNDS set keeps the explicit value (other stages keep their defaults)" 0 || check "QUICK=1 with MEM_ROUNDS set keeps the explicit value" 1 "got: $r"

# --- the stages, with stub tools. rec is the real one: results.tsv gets its round column
stage_run() { # stage, env...: runs stage_<stage>_run with the stubs on PATH, prints results.tsv
  local s=$1; shift
  env PATH="$TMP/stubs:$PATH" "$@" bash -c '
    VMBENCH_HOME=$1; s=$2; OUT=$3
    for f in common metrics stream stages; do . "$VMBENCH_HOME/lib/$f.sh"; done
    . "$VMBENCH_HOME/stages/$s.sh"
    RES=$OUT/results.tsv; STATUS=$OUT/status.tsv; : > "$STATUS"; NPROC=4; QUICK=${QUICK:-1}; LABEL=lbl; DATA_DIR=$OUT/data; DB_DIR=$DATA_DIR; WAL_DIR=$DATA_DIR
    FIO_SIZE=64M; RAW_DEV=; CB=${CB:-$OUT/cb}; MEM_AVAIL_KB=1000000
    printf "id\tmetric\tvalue\tunit\tround\n" > "$RES"; mkdir -p "$DATA_DIR"
    "stage_${s}_run" > "$OUT/stage.out" 2>&1
    cat "$RES"; echo "--status"; cat "$STATUS"
  ' _ "$ROOT" "$s" "$TMP/st-$s"
}
mkdir -p "$TMP/stubs"
cat > "$TMP/stubs/fio" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do case $a in --output=*) out=${a#--output=} ;; esac; done
echo '{"jobs":[{"read":{"iops":1000.4,"bw_bytes":2000000000,"clat_ns":{"percentile":{"99.000000":100000,"99.900000":200000}}},"write":{"iops":500.2,"bw_bytes":1000000000},"sync":{"lat_ns":{"mean":1000000,"percentile":{"99.000000":2000000}}},"steadystate":{"attained":true}}]}' > "$out"
STUB
chmod +x "$TMP/stubs/fio"
count() { grep -c -P "$1" <<<"$2" || true; }

if command -v jq >/dev/null 2>&1; then
  mkdir -p "$TMP/st-disk"
  res=$(stage_run disk DISK_ROUNDS=3)
  p99=$(count '^disk\.fio\.randread-4k\.qd1\.p99\t.*\t[123]$' "$res")
  [ "$(count '^disk\.fio\.randread-4k\.qd1\.p99\t.*\t1$' "$res")" = 1 ] && [ "$(count '^disk\.fio\.randread-4k\.qd1\.p99\t.*\t3$' "$res")" = 1 ] && [ "$p99" = 3 ] \
    && check "disk, 3 rounds: the latency test has one row per round (1, 2, 3)" 0 || check "disk, 3 rounds: the latency test has one row per round" 1 "$res"
  ok=0
  for id in 'disk\.fio\.randread-4k\.qd32x4' 'disk\.fio\.mixed-70-30-4k\.read' 'disk\.fio\.mixed-70-30-4k\.write' 'disk\.wal\.fdatasync\.avg' 'disk\.wal\.fdatasync\.p99' 'disk\.wal\.commit-iops\.qd1' 'disk\.fio\.randread-4k\.qd1\.p999'; do
    [ "$(count "^$id\t" "$res")" = 3 ] || { ok=1; echo "   $id: $(count "^$id\t" "$res") rows"; }
  done
  [ "$ok" = 0 ] && check "disk, 3 rounds: random read, mixed, WAL and p99.9 are repeated 3 times" 0 || check "disk, 3 rounds: random read, mixed, WAL and p99.9 are repeated 3 times" 1
  ok=0
  for id in 'disk\.fio\.randwrite-4k\.qd32x4' 'disk\.fio\.seq-write-1m' 'disk\.fio\.seq-read-1m' 'disk\.fio\.randread-4k\.sweep-qd1' 'disk\.fio\.db-randwrite-8k' 'disk\.fio\.db-seqwrite-1m' 'info\.fio\.fill-write-1m'; do
    [ "$(count "^$id\t" "$res")" = 1 ] || { ok=1; echo "   $id: $(count "^$id\t" "$res") rows"; }
  done
  [ "$ok" = 0 ] && check "disk, 3 rounds: fill, steady-state write, sequential, sweep and DB tests run once" 0 || check "disk, 3 rounds: fill, steady-state write, sequential, sweep and DB tests run once" 1
  [ -s "$TMP/st-disk/fio-34-lat-r2.json" ] && [ -s "$TMP/st-disk/fio-34-lat.json" ] && [ -s "$TMP/st-disk/fio-44-wal-r3.json" ] && check "disk: round 1 keeps the old file names, later rounds add -rN" 0 || check "disk: round 1 keeps the old file names, later rounds add -rN" 1 "$(ls "$TMP/st-disk")"
  mkdir -p "$TMP/st-disk"; rm -rf "${TMP:?}/st-disk"; mkdir -p "$TMP/st-disk"
  res=$(stage_run disk DISK_ROUNDS=1)
  if [ "$(count '^disk\.' "$res")" = 23 ] && [ "$(count '\t1$' "$res")" = 24 ] && ! grep -qP '\t[2-9]$' <<<"$res"; then check "disk, default 1 round: 23 disk rows and the fill row, all round 1" 0
  else check "disk, default 1 round: 17 disk rows and the fill row, all round 1" 1 "disk rows $(count '^disk\.' "$res")"; fi
  [ ! -e "$TMP/st-disk/data/fio.dat" ] && check "disk: the test file is removed after the repeated rounds" 0 || check "disk: the test file is removed after the repeated rounds" 1

  # web: a stub cpubench; QUICK path writes web-rN.json, full path runs web-loopback.sh
  mkdir -p "$TMP/cb"
  cat > "$TMP/cb/cpubench" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "web serve") exec sleep 30 ;;
  "web load") while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
    n=$(( 1000 + $(date +%N | cut -c7-8) )); echo "{\"web\":{\"knee_rps\":$n}}" > "$out" ;;
  version) echo "cpubench stub" ;;
esac
STUB
  chmod +x "$TMP/cb/cpubench"
  rm -rf "$TMP/st-web"; mkdir -p "$TMP/st-web"
  res=$(stage_run web CB="$TMP/cb" WEB_ROUNDS=3)
  if [ "$(count '^web\.cpubench\.mix\.max-rps\t' "$res")" = 3 ] && [ "$(count '^web\.cpubench\.mix\.max-rps\t.*\t[123]$' "$res")" = 3 ] && [ "$(count '^web	web-r[123].json	OK' "$res")" = 3 ]; then
    check "web, 3 rounds: three rows (rounds 1, 2, 3) and three OK steps" 0
  else check "web, 3 rounds: three rows (rounds 1, 2, 3) and three OK steps" 1 "$res"; fi
  [ -s "$TMP/st-web/web-r2.json" ] && [ -e "$TMP/st-web/web-r3.log" ] && check "web: every round keeps its own raw files" 0 || check "web: every round keeps its own raw files" 1 "$(ls "$TMP/st-web")"
  # the full (non-quick) path: web-loopback.sh gets a label per round and its <label>-mix.json is read
  cat > "$TMP/cb/web-loopback.sh" <<'STUB'
#!/usr/bin/env bash
mkdir -p results/web; echo "{\"web\":{\"knee_rps\":2222}}" > "results/web/$1-mix.json"
STUB
  chmod +x "$TMP/cb/web-loopback.sh"
  rm -rf "$TMP/st-web"; mkdir -p "$TMP/st-web"
  res=$(stage_run web CB="$TMP/cb" WEB_ROUNDS=2 QUICK=0)
  if [ "$(count '^web\.cpubench\.mix\.max-rps\t[^\t]*\t2222\t[^\t]*\t[12]$' "$res")" = 2 ] && [ "$(count '^web	lbl-web-r[12]-mix.json	OK' "$res")" = 2 ] && [ -s "$TMP/st-web/lbl-web-r2-mix.json" ]; then
    check "web, full path: web-loopback.sh gets a label per round and each round is read" 0
  else check "web, full path: web-loopback.sh gets a label per round and each round is read" 1 "$res"; fi
else
  echo "skip stage tests (no jq)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
