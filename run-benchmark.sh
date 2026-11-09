#!/usr/bin/env bash
# run-benchmark.sh - run the VM performance tests (cpu, mem, disk, pg, net, web, burn-in) on this machine and collect the results.
#
#   bash run-benchmark.sh                       # cpu, mem, disk; results in ~/bench-results/<label>-<time>/
#   bash run-benchmark.sh --with web,pg         # the default stages plus web and pg
#   bash run-benchmark.sh --only disk           # only these stages
#   bash run-benchmark.sh --with net --peer 192.0.2.10
#   bash run-benchmark.sh --only burnin --hours 48
#   QUICK=1 bash run-benchmark.sh               # smoke run: tiny sizes and durations, to check the setup
#
# Options:
#   --with LIST   add stages to the default ones (comma separated)
#   --only LIST   run only these stages (cannot be combined with --with)
#   --peer HOST   peer machine for the net stage; it must run: iperf3 -s -D ; sockperf server -i 0.0.0.0 &
#   --hours N     length of the burn-in (default: 48; QUICK=1 always runs 40 seconds)
#   --list        show the stages, their duration and whether this machine is ready for them
#   --metrics     print the table of metric ids (id|unit|direction|tool|label|what it measures) and exit
#   -h, --help    show this text
#
# Stages (ram is accepted for mem). info always runs, because report.py needs it.
#   cpu     ids cpu.*          default
#   mem     ids mem.*          default
#   disk    ids disk.*         default
#   pg      ids pg.*           needs setup-postgres-bench.sh
#   net     ids net.*          needs --peer
#   web     ids web.*
#   burnin  ids burnin.*       48 hours unless --hours says otherwise
# Every result has a stable id such as cpu.sysbench.prime.1t, listed by --metrics and in docs/tests.md.
#
# Every selected stage is checked before anything runs. If something is missing, the script lists all of it
# and exits with code 2. A run of everything that needs no peer is: --with web,pg  (add net when a peer is available)
#
# Settings (environment variables):
#   STAGES       space separated stage list, ignored when --with or --only is given
#   LABEL        name of this machine in the results           (default: hostname)
#   OUT          result folder                                 (default: ~/bench-results/<label>-<time>)
#   ROUNDS       repeats of cpu stage                          (default: 3)
#   QUICK        1 = short smoke run                           (default: 0)
#   CB           cpubench folder (setup-cpubench.sh output)    (default: ~/cpubench-current)
#   DATA_DIR     folder for fio test files                     (default: ~/bench-data)
#   FIO_SIZE     size of the fio test file                     (default: 8G)
#   RAW_DEV      raw test disk, e.g. /dev/sdb (needs CONFIRM_WIPE=yes, ERASES THE WHOLE DISK)
#   DB_DIR WAL_DIR  folders for disk.fio.db-* and disk.wal.*           (default: DATA_DIR; e.g. /pgdata /pgwal)
#   PGPORT PGHOST PGDATABASE  PostgreSQL to use for the pg stage (default: port 5433, db bench)
#   PEER         same as --peer
#   BURNIN_HOURS same as --hours
set -uo pipefail

LABEL=${LABEL:-$(hostname -s)}
QUICK=${QUICK:-0}
ROUNDS=${ROUNDS:-3}
CB=${CB:-$HOME/cpubench-current}
DATA_DIR=${DATA_DIR:-$HOME/bench-data}
FIO_SIZE=${FIO_SIZE:-8G}
RAW_DEV=${RAW_DEV:-}
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DB_DIR=${DB_DIR:-$DATA_DIR}
WAL_DIR=${WAL_DIR:-$DATA_DIR}
PEER=${PEER:-}
BURNIN_HOURS=${BURNIN_HOURS:-48}
export PGPORT=${PGPORT:-5433} PGDATABASE=${PGDATABASE:-bench}
OUT=${OUT:-$HOME/bench-results/$LABEL-$(date +%Y%m%d-%H%M%S)}
[ "$QUICK" = 1 ] && { ROUNDS=1; FIO_SIZE=256M; }

ALL_STAGES="cpu mem disk pg net web burnin"
DEFAULT_STAGES="cpu mem disk"

die() { printf 'run-benchmark.sh: %s\n' "$*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- metric ids
# The one place where result ids are defined. Columns: id|unit|direction|tool|label|what it measures
#   id         <stage>.<tool>.<test>[.<variant>], lowercase, dots between parts; a .1t or .max suffix means one thread or all vCPUs
#   direction  higher or lower is better; none = context value that is never judged
#   label      the text written to the metric column of results.tsv: {t} is the thread count, {x} a per-run value (see rec)
# docs/tests.md repeats this table, and tests/test_ids.py fails if the two differ.
metric_table() {
  cat <<'METRICS'
cpu.sysbench.prime.1t|events/s|higher|sysbench|sysbench cpu {t}t|Prime-number counting (--cpu-max-prime=20000), 1 thread
cpu.sysbench.prime.max|events/s|higher|sysbench|sysbench cpu {t}t|Prime-number counting (--cpu-max-prime=20000), all vCPUs
cpu.7z.rating.max|MIPS|higher|7-Zip|7z rating {t}t|7-Zip built-in benchmark total rating, all vCPUs
cpu.openssl.aes-256-gcm.1t|MB/s|higher|OpenSSL|openssl aes-256-gcm {t}t|AES-256-GCM throughput (openssl speed -evp), 1 thread
cpu.openssl.aes-256-gcm.max|MB/s|higher|OpenSSL|openssl aes-256-gcm {t}t|AES-256-GCM throughput (openssl speed -evp), all vCPUs
cpu.cpubench.crypto.aes-gcm.1t|varies|higher|cpubench|cpubench crypto/aes-gcm {t}t|AES-GCM (median of cpubench iterations), 1 thread
cpu.cpubench.crypto.aes-gcm.max|varies|higher|cpubench|cpubench crypto/aes-gcm {t}t|AES-GCM (median of cpubench iterations), all vCPUs
cpu.cpubench.crypto.ecdsa-p256.1t|varies|higher|cpubench|cpubench crypto/ecdsa-p256 {t}t|ECDSA P-256 signing (median of cpubench iterations), 1 thread
cpu.cpubench.crypto.ecdsa-p256.max|varies|higher|cpubench|cpubench crypto/ecdsa-p256 {t}t|ECDSA P-256 signing (median of cpubench iterations), all vCPUs
cpu.cpubench.crypto.rsa2048-sign.1t|varies|higher|cpubench|cpubench crypto/rsa2048-sign {t}t|RSA-2048 signing (median of cpubench iterations), 1 thread
cpu.cpubench.crypto.rsa2048-sign.max|varies|higher|cpubench|cpubench crypto/rsa2048-sign {t}t|RSA-2048 signing (median of cpubench iterations), all vCPUs
cpu.cpubench.crypto.sha256.1t|varies|higher|cpubench|cpubench crypto/sha256 {t}t|SHA-256 (median of cpubench iterations), 1 thread
cpu.cpubench.crypto.sha256.max|varies|higher|cpubench|cpubench crypto/sha256 {t}t|SHA-256 (median of cpubench iterations), all vCPUs
cpu.cpubench.float.fft.1t|varies|higher|cpubench|cpubench float/fft {t}t|FFT (median of cpubench iterations), 1 thread
cpu.cpubench.float.fft.max|varies|higher|cpubench|cpubench float/fft {t}t|FFT (median of cpubench iterations), all vCPUs
cpu.cpubench.float.matmul.1t|varies|higher|cpubench|cpubench float/matmul {t}t|Matrix multiplication (median of cpubench iterations), 1 thread
cpu.cpubench.float.matmul.max|varies|higher|cpubench|cpubench float/matmul {t}t|Matrix multiplication (median of cpubench iterations), all vCPUs
cpu.cpubench.float.nbody.1t|varies|higher|cpubench|cpubench float/nbody {t}t|N-body simulation (median of cpubench iterations), 1 thread
cpu.cpubench.float.nbody.max|varies|higher|cpubench|cpubench float/nbody {t}t|N-body simulation (median of cpubench iterations), all vCPUs
cpu.cpubench.int.compress.1t|varies|higher|cpubench|cpubench int/compress {t}t|Compression (median of cpubench iterations), 1 thread
cpu.cpubench.int.compress.max|varies|higher|cpubench|cpubench int/compress {t}t|Compression (median of cpubench iterations), all vCPUs
cpu.cpubench.int.decompress.1t|varies|higher|cpubench|cpubench int/decompress {t}t|Decompression (median of cpubench iterations), 1 thread
cpu.cpubench.int.decompress.max|varies|higher|cpubench|cpubench int/decompress {t}t|Decompression (median of cpubench iterations), all vCPUs
cpu.cpubench.int.hashmap.1t|varies|higher|cpubench|cpubench int/hashmap {t}t|Hash map operations (median of cpubench iterations), 1 thread
cpu.cpubench.int.hashmap.max|varies|higher|cpubench|cpubench int/hashmap {t}t|Hash map operations (median of cpubench iterations), all vCPUs
cpu.cpubench.int.json.1t|varies|higher|cpubench|cpubench int/json {t}t|JSON encode/decode (median of cpubench iterations), 1 thread
cpu.cpubench.int.json.max|varies|higher|cpubench|cpubench int/json {t}t|JSON encode/decode (median of cpubench iterations), all vCPUs
cpu.cpubench.int.regex.1t|varies|higher|cpubench|cpubench int/regex {t}t|Regular expressions (median of cpubench iterations), 1 thread
cpu.cpubench.int.regex.max|varies|higher|cpubench|cpubench int/regex {t}t|Regular expressions (median of cpubench iterations), all vCPUs
cpu.cpubench.int.sort.1t|varies|higher|cpubench|cpubench int/sort {t}t|Sorting (median of cpubench iterations), 1 thread
cpu.cpubench.int.sort.max|varies|higher|cpubench|cpubench int/sort {t}t|Sorting (median of cpubench iterations), all vCPUs
mem.stream.triad.max|MB/s|higher|STREAM|stream triad (N={x})|Memory bandwidth, triad kernel, all vCPUs
mem.stream.copy.max|MB/s|higher|STREAM|stream copy (N={x})|Memory bandwidth, copy kernel, all vCPUs
mem.lmbench.lat-mem-rd.1t|ns|lower|lmbench|lat_mem_rd -t {x}MB|Memory load latency at the largest working set (-t, 1 process)
disk.fio.randwrite-4k.qd32x4|IOPS|higher|fio|fio randwrite 4k qd32x4|4 KiB random write, queue depth 32 x 4 jobs, after fill to steady state
disk.fio.randwrite-4k.steadystate|flag|none|fio|steadystate attained (1=yes)|1 if the random-write run reached fio steady state (context, not scored)
disk.fio.randread-4k.qd1.p99|us|lower|fio|fio randread 4k qd1 p99|4 KiB random read latency, queue depth 1, 99th percentile
disk.fio.randread-4k.qd1.p999|us|lower|fio|fio randread 4k qd1 p99.9|4 KiB random read latency, queue depth 1, 99.9th percentile
disk.fio.randread-4k.qd32x4|IOPS|higher|fio|fio randread 4k qd32x4|4 KiB random read, queue depth 32 x 4 jobs
disk.fio.mixed-70-30-4k.read|IOPS|higher|fio|fio mixed 70/30 read|4 KiB random 70% read / 30% write mix, read side
disk.fio.mixed-70-30-4k.write|IOPS|higher|fio|fio mixed 70/30 write|4 KiB random 70% read / 30% write mix, write side
disk.fio.seq-write-1m|MB/s|higher|fio|fio seq write 1M|1 MiB sequential write, queue depth 16
disk.fio.seq-read-1m|MB/s|higher|fio|fio seq read 1M|1 MiB sequential read, queue depth 16
disk.fio.randread-4k.sweep-qd1|IOPS|higher|fio|fio randread 4k qd1|4 KiB random read at queue depth 1 (queue-depth sweep)
disk.fio.randread-4k.sweep-qd4|IOPS|higher|fio|fio randread 4k qd4|4 KiB random read at queue depth 4 (queue-depth sweep)
disk.fio.randread-4k.sweep-qd16|IOPS|higher|fio|fio randread 4k qd16|4 KiB random read at queue depth 16 (queue-depth sweep)
disk.fio.randread-4k.sweep-qd32|IOPS|higher|fio|fio randread 4k qd32|4 KiB random read at queue depth 32 (queue-depth sweep)
disk.fio.randread-4k.sweep-qd64|IOPS|higher|fio|fio randread 4k qd64|4 KiB random read at queue depth 64 (queue-depth sweep)
disk.fio.randread-4k.sweep-qd128|IOPS|higher|fio|fio randread 4k qd128|4 KiB random read at queue depth 128 (queue-depth sweep)
disk.fio.db-randwrite-8k|IOPS|higher|fio|fio randwrite 8k|8 KiB random write on files in DB_DIR (database data pattern)
disk.fio.db-randrw-8k.read|IOPS|higher|fio|fio randrw 70/30 8k read|8 KiB random 70/30 mix on DB_DIR, read side
disk.fio.db-randrw-8k.write|IOPS|higher|fio|fio randrw 70/30 8k write|8 KiB random 70/30 mix on DB_DIR, write side
disk.fio.db-seqwrite-1m|MB/s|higher|fio|fio seqwrite 1M|1 MiB sequential write on files in DB_DIR
disk.fio.db-randread-8k|IOPS|higher|fio|fio randread 8k|8 KiB random read on files in DB_DIR
disk.wal.fdatasync.avg|ms|lower|fio|wal fdatasync avg|WAL-style 8 KiB write + fdatasync, queue depth 1, mean latency
disk.wal.fdatasync.p99|ms|lower|fio|wal fdatasync p99|WAL-style 8 KiB write + fdatasync, 99th percentile latency
disk.wal.commit-iops.qd1|IOPS|higher|fio|wal commit iops qd1|WAL-style commits per second at queue depth 1
pg.pgbench.tpcb.tps|TPS|higher|pgbench|pgbench tpcb-like tps (-c {x})|TPC-B-like transactions per second with 2 x vCPU clients
pg.pgbench.tpcb.stability|%|higher|pgbench|tps stability 100*(1-cv)|Steadiness of TPS over the run, 100 x (1 - coefficient of variation)
pg.pgbench.latency.single|ms|lower|pgbench|pgbench single-session latency|Average transaction latency with one client
net.iperf3.tcp.tx|Gbps|higher|iperf3|iperf3 tcp tx->peer|TCP throughput to the peer, 8 streams
net.iperf3.tcp.rx|Gbps|higher|iperf3|iperf3 tcp peer->rx|TCP throughput from the peer, 8 streams
net.iperf3.tcp.bidir|Gbps|higher|iperf3|iperf3 tcp bidir total|TCP throughput, both directions added
net.sockperf.pingpong.avg|us|lower|sockperf|sockperf ping-pong avg (one-way)|Average one-way latency (ping-pong)
net.sockperf.pingpong.p99|us|lower|sockperf|sockperf ping-pong p99|99th percentile latency (ping-pong)
net.iperf3.udp.pps|Mpps|higher|iperf3|iperf3 udp 64B packets sent|UDP packets sent per second, 64-byte payload
net.iperf3.udp.loss|%|lower|iperf3|iperf3 udp lost packets %|UDP packet loss at the maximum send rate
web.cpubench.mix.max-rps|RPS|higher|cpubench|cpubench web mix max RPS @ SLO (loopback)|Highest requests per second within the latency target (loopback)
burnin.errors|count|lower|stressapptest, fio|burn-in errors ({x}s)|Errors found by the burn-in (memory, disk verify, kernel log)
info.cpu.steal.avg|%|none|mpstat|cpu steal avg|Average CPU steal during the whole run (context, not scored)
info.cpu.steal.peak|%|none|mpstat|cpu steal max|Highest CPU steal sample during the run (context, not scored)
info.fio.fill-write-1m|MB/s|none|fio|fio fill write 1M|Speed of the 1 MiB sequential fill before the disk tests (context, not scored)
METRICS
}
declare -A M_UNIT M_LABEL
while IFS='|' read -r _id _unit _dir _tool _label _desc; do
  [ -n "$_id" ] || continue
  M_UNIT[$_id]=$_unit; M_LABEL[$_id]=$_label
done < <(metric_table)

usage() { sed -n '2,/^set -uo/{/^set -uo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }

stage_list() { # comma or space separated names -> checked, space separated names
  local name out=""
  for name in ${1//,/ }; do
    [ "$name" = ram ] && name=mem
    case " info $ALL_STAGES " in
      *" $name "*) out="$out $name" ;;
      *) die "unknown stage '$name' (stages: $ALL_STAGES)" ;;
    esac
  done
  printf '%s' "${out# }"
}

raw_problem() { # prints why RAW_DEV cannot be used
  if [ "${CONFIRM_WIPE:-}" != yes ]; then echo "RAW_DEV=$RAW_DEV needs CONFIRM_WIPE=yes (the whole disk is erased)"
  elif [ ! -b "$RAW_DEV" ]; then echo "$RAW_DEV is not a block device"
  elif findmnt -rn -S "$RAW_DEV" >/dev/null || [ -n "$(lsblk -no FSTYPE,MOUNTPOINT "$RAW_DEV" | tr -d ' \n')" ] || [ "$(lsblk -nro NAME "$RAW_DEV" | wc -l)" -gt 1 ]; then
    echo "$RAW_DEV has a filesystem, mount or partitions; refusing"
  elif [ ! -r "$RAW_DEV" ] || [ ! -w "$RAW_DEV" ]; then echo "no read/write permission on $RAW_DEV"
  fi
}

PROBLEMS=()
check_tools() { local t; for t; do need "$t" || PROBLEMS+=("$t is not installed"); done; }
check_cpubench() { [ -x "$CB/cpubench" ] || PROBLEMS+=("$CB/cpubench is missing, run setup-cpubench.sh"); }
check_target() { # RAW_DEV, or free space for the test file
  local p d=$DATA_DIR free
  if [ -n "$RAW_DEV" ]; then
    p=$(raw_problem); [ -z "$p" ] || PROBLEMS+=("$p")
    return
  fi
  while [ ! -e "$d" ]; do d=$(dirname "$d"); done
  free=$(df -BG --output=avail "$d" | tail -1 | tr -dc 0-9)
  [ "${free:-0}" -ge 15 ] || PROBLEMS+=("only ${free:-0} GB free for $DATA_DIR, at least 15 GB is needed")
}
check_stage() { # fills PROBLEMS with what stops this stage from running
  PROBLEMS=()
  case $1 in
    cpu) check_tools sysbench 7z openssl jq; check_cpubench ;;
    mem) check_tools gcc
      dpkg -L lmbench 2>/dev/null | grep -q 'lat_mem_rd$' || PROBLEMS+=("lmbench is not installed")
      [ -s "$HOME/bench-cache/stream.c" ] || check_tools curl ;;
    disk) check_tools fio jq; check_target ;;
    pg) check_tools pgbench psql
      if need psql && ! timeout 10 psql -X -Atc 'select 1' >/dev/null 2>&1; then
        PROBLEMS+=("cannot connect to db $PGDATABASE on port $PGPORT, run setup-postgres-bench.sh first")
      fi ;;
    net) check_tools iperf3 sockperf jq
      if [ -z "$PEER" ]; then PROBLEMS+=("no peer, use --peer HOST")
      elif need iperf3 && ! timeout 10 iperf3 -c "$PEER" -t 1 >/dev/null 2>&1; then
        PROBLEMS+=("no iperf3 server reachable at $PEER (the peer must run: iperf3 -s -D ; sockperf server -i 0.0.0.0 &)")
      fi ;;
    web) check_tools jq; check_cpubench
      [ "$QUICK" = 1 ] || [ -x "$CB/web-loopback.sh" ] || PROBLEMS+=("$CB/web-loopback.sh is missing, run setup-cpubench.sh") ;;
    burnin) check_tools fio stressapptest; check_target ;;
  esac
}

show_stages() {
  local s rows when time
  printf '%-7s %-12s %-8s %-12s %s\n' STAGE METRICS DEFAULT TIME READY
  for s in $ALL_STAGES; do
    case $s in
      cpu)    when=yes; time="14 min" ;;
      mem)    when=yes; time="1 min" ;;
      disk)   when=yes; time="71 min" ;;
      pg)     when=no;  time="16 min+load" ;;
      net)    when=no;  time="3 min" ;;
      web)    when=no;  time="5 min" ;;
      burnin) when=no;  time="$BURNIN_HOURS h" ;;
    esac
    rows=$(metric_table | grep -c "^$s\.")
    check_stage "$s"
    if [ ${#PROBLEMS[@]} -eq 0 ]; then
      printf '%-7s %-12s %-8s %-12s %s\n' "$s" "$rows" "$when" "$time" yes
    else
      printf '%-7s %-12s %-8s %-12s no: %s\n' "$s" "$rows" "$when" "$time" "${PROBLEMS[0]}"
      for ((i = 1; i < ${#PROBLEMS[@]}; i++)); do printf '%43s %s\n' "" "${PROBLEMS[$i]}"; done
    fi
  done
  echo
  echo "TIME: cpu, mem, disk, web were measured on 8 vCPU VMs with an 8 GB test file."
  echo "      pg and net come from the test durations in this script and have not been timed on a real run."
}

ADD="" ONLY="" HAVE_ONLY="" FLAG_PEER="" FLAG_HOURS="" LIST=""
while [ $# -gt 0 ]; do
  opt=$1; val=""; has_val=""
  case $opt in --*=*) val=${opt#*=}; opt=${opt%%=*}; has_val=1 ;; esac
  case $opt in
    --with|--only|--peer|--hours)
      if [ -z "$has_val" ]; then
        [ $# -ge 2 ] || die "$opt needs a value"
        val=$2; shift
      fi
      [ -n "$val" ] || die "$opt needs a value" ;;
  esac
  case $opt in
    --with) ADD="$ADD $(stage_list "$val")" || exit 2 ;;
    --only) ONLY="$ONLY $(stage_list "$val")" || exit 2; HAVE_ONLY=1 ;;
    --peer) PEER=$val; FLAG_PEER=1 ;;
    --hours)
      [[ $val =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v h="$val" 'BEGIN{exit !(h>0)}' || die "--hours needs a number above 0, got '$val'"
      BURNIN_HOURS=$val; FLAG_HOURS=1 ;;
    --list) LIST=1 ;;
    --metrics) metric_table; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option '$1' (see --help)" ;;
  esac
  shift
done

[ -z "$HAVE_ONLY" ] || [ -z "$ADD" ] || die "use --with or --only, not both"
if [ -n "$HAVE_ONLY" ]; then SELECTED=$ONLY
elif [ -n "$ADD" ]; then SELECTED="$DEFAULT_STAGES $ADD"
elif [ -n "${STAGES:-}" ]; then SELECTED=$(stage_list "$STAGES") || exit 2
else SELECTED=$DEFAULT_STAGES
fi
if { [ -n "$HAVE_ONLY" ] || [ -n "$ADD" ]; } && [ -n "${STAGES:-}" ]; then
  echo "note: STAGES is ignored because --with or --only was given" >&2
fi
STAGES=" info $SELECTED "

want() { case "$STAGES" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

if [ -n "$LIST" ]; then show_stages; exit 0; fi
if [ -n "$FLAG_PEER" ] && ! want net; then die "--peer is only used by the net stage, add --with net"; fi
if [ -n "$FLAG_HOURS" ] && ! want burnin; then die "--hours is only used by the burnin stage, add --only burnin"; fi

problems_found=0
for s in $ALL_STAGES; do
  want "$s" || continue
  check_stage "$s"
  for p in "${PROBLEMS[@]+"${PROBLEMS[@]}"}"; do
    printf 'not ready: %s: %s\n' "$s" "$p" >&2
    problems_found=1
  done
done
[ "$problems_found" = 0 ] || die "nothing was run; fix the above or leave those stages out"
need mpstat || echo "note: mpstat is not installed (package sysstat), CPU steal will not be recorded" >&2
STAGES=$(for s in info $ALL_STAGES; do want "$s" && printf '%s ' "$s"; done); STAGES=" $STAGES"

NPROC=$(nproc)
RAM_GB=$(awk '/MemTotal/{printf "%d", $2/1048576+0.5}' /proc/meminfo)
MEM_AVAIL_KB=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
mkdir -p "$OUT" "$DATA_DIR"
RES=$OUT/results.tsv; STATUS=$OUT/status.tsv
printf 'id\tmetric\tvalue\tunit\tround\n' > "$RES"
printf 'stage\tstep\tresult\n' > "$STATUS"


# meta.json: what ran and how, without host names or addresses (only LABEL). Written at the start and
# again at the end; a file whose end_utc is null belongs to a run that did not finish.
vmbench_version() {
  if [ -s "$SELF_DIR/VERSION" ]; then head -1 "$SELF_DIR/VERSION"
  elif need git && git -C "$SELF_DIR" describe --tags --always --dirty 2>/dev/null; then :
  else echo unknown; fi
}
utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
START_UTC=$(utc_now)
write_meta() { # write_meta [END_UTC]
  need python3 || return 0
  local cbv=""; [ -x "$CB/cpubench" ] && cbv=$("$CB/cpubench" version 2>/dev/null | head -1)
  python3 -I - "$OUT/meta.json" "$(vmbench_version)" "$cbv" "$LABEL" "$STAGES" "$QUICK" "$ROUNDS" \
    "$START_UTC" "${1:-}" "$(uname -m)" "$NPROC" "$RAM_GB" <<'PY'
import json, os, sys
(path, ver, cbv, label, stages, quick, rounds, start, end, arch, nproc, ram) = sys.argv[1:]
meta = {"schema": 1, "vmbench_version": ver, "cpubench_version": cbv or None, "label": label,
        "stages": stages.split(), "quick": quick == "1", "rounds": int(rounds),
        "start_utc": start, "end_utc": end or None, "arch": arch, "nproc": int(nproc), "ram_gb": int(ram)}
with open(path + ".tmp", "w") as f:
    json.dump(meta, f, indent=2)
    f.write("\n")
os.replace(path + ".tmp", path)
PY
}

T() { if [ "$QUICK" = 1 ]; then echo "$2"; else echo "$1"; fi; }   # T <full> <quick>
log() { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$OUT/run.log"; }
ROUND=1
# rec ID VALUE [X [UNIT]]: append one value. The label and unit come from the metric table; X fills {x}
# in the label (array size, test size, ...), UNIT overrides the table unit (cpubench reports its own).
rec() {
  local id=$1 label t
  if [ -z "${M_LABEL[$id]:-}" ]; then log "[BUG] unknown metric id '$id', value not recorded"; return 1; fi
  case $id in *.1t) t=1 ;; *) t=$NPROC ;; esac
  label=${M_LABEL[$id]//\{t\}/$t}; label=${label//\{x\}/${3:-}}
  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$label" "$2" "${4:-${M_UNIT[$id]}}" "$ROUND" >> "$RES"
}
tv() { if [ "$1" = 1 ]; then echo 1t; else echo max; fi; }   # thread count -> id suffix
ok() { printf '%s\t%s\tOK\n' "$1" "$2" >> "$STATUS"; }
bad() { printf '%s\t%s\tFAIL %s\n' "$1" "$2" "${3:-}" >> "$STATUS"; log "[FAIL] $1: $2 ${3:-}"; }
skip() { printf '%s\t%s\tSKIP %s\n' "$1" "$2" "${3:-}" >> "$STATUS"; log "[SKIP] $1: $2 ${3:-}"; }


# ---------------------------------------------------------------- info
stage_info() {
  log "== info"
  {
    echo "date: $(date -Is)"; echo "label: $LABEL"; echo "host: $(hostname)"; echo "kernel: $(uname -srm)"
    . /etc/os-release; echo "os: $PRETTY_NAME"; echo "virt: $(systemd-detect-virt 2>/dev/null)"
    echo "nproc: $NPROC  ram_gb: $RAM_GB"; echo "quick: $QUICK  rounds: $ROUNDS  fio_size: $FIO_SIZE  raw_dev: ${RAW_DEV:-none}"
    echo "--- lscpu"; lscpu
    echo "--- cpu flags"; grep -m1 -E '^(flags|Features)' /proc/cpuinfo | grep -o -wE 'aes|avx2|avx512f|sha_ni|pmull|sha2|atomics|sve|hypervisor' | sort -u | tr '\n' ' '; echo
    echo "--- memory"; free -m; echo "--- numa"; numactl -H 2>&1 | head -3
    echo "--- disks"; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,ROTA; df -h / "$DATA_DIR" 2>/dev/null
    echo "--- network"; ip -br addr
    echo "--- load"; uptime; ps -eo pcpu,comm --sort=-pcpu | sed -n 1,6p
    echo "--- services"; systemctl is-active postgresql zabbix-agent zabbix-agent2 docker 2>&1 | paste -sd' '
    echo "--- tmux"; tmux ls 2>&1 | head -3
    echo "--- tools"
    for t in sysbench fio 7z iperf3 sockperf stressapptest gcc pgbench openssl; do printf '%s: ' "$t"; case $t in
      7z) 7z 2>&1 | sed -n 2p ;; sysbench) sysbench --version ;; fio) fio --version ;; iperf3) iperf3 --version | head -1 ;;
      sockperf) sockperf --version 2>&1 | head -1 ;; stressapptest) echo "$(command -v stressapptest)" ;; gcc) gcc --version | head -1 ;;
      pgbench) pgbench --version ;; openssl) openssl version ;; esac; done
    [ -x "$CB/cpubench" ] && echo "cpubench: $("$CB/cpubench" version | head -1)"
  } > "$OUT/info.txt" 2>&1
  [ -x "$CB/cpubench" ] && timeout 120 "$CB/cpubench" doctor > "$OUT/doctor.txt" 2>&1
  ok info metadata
  if [ "$(awk '{print int($1*100)}' /proc/loadavg)" -gt 50 ]; then log "[WARN] load average is $(cut -d' ' -f1 /proc/loadavg), the machine is not idle"; fi
  FREE_GB=$(df -BG --output=avail "$DATA_DIR" | tail -1 | tr -dc 0-9)
  log "free space in $DATA_DIR: ${FREE_GB} GB"
  [ "$FREE_GB" -ge 15 ] || log "[WARN] less than 15 GB free, disk stage will be refused"
}

# ---------------------------------------------------------------- cpu
stage_cpu() {
  log "== cpu"
  local r st mt out
  for r in $(seq 1 "$ROUNDS"); do
    ROUND=$r; log "cpu round $r/$ROUNDS"
    if need sysbench; then
      st=$(sysbench cpu --cpu-max-prime=20000 --threads=1 --time="$(T 60 5)" run 2>&1 | tee "$OUT/sysbench-st-r$r.txt" | awk '/events per second/{print $4}')
      mt=$(sysbench cpu --cpu-max-prime=20000 --threads="$NPROC" --time="$(T 60 5)" run 2>&1 | tee "$OUT/sysbench-mt-r$r.txt" | awk '/events per second/{print $4}')
      [ -n "$st" ] && rec cpu.sysbench.prime.1t "$st" && ok cpu "sysbench st r$r" || bad cpu "sysbench st r$r"
      [ -n "$mt" ] && rec cpu.sysbench.prime.max "$mt" && ok cpu "sysbench mt r$r" || bad cpu "sysbench mt r$r"
    else skip cpu sysbench "not installed"; fi
    if need 7z; then
      out=$(7z b -mmt="$NPROC" 2>&1 | tee "$OUT/7z-r$r.txt" | awk '/^Tot:/{print $NF}')
      [ -n "$out" ] && rec cpu.7z.rating.max "$out" && ok cpu "7z r$r" || bad cpu "7z r$r"
    else skip cpu 7z "not installed"; fi
    if [ -x "$CB/cpubench" ]; then
      local q=(); [ "$QUICK" = 1 ] && q=(--scale 0.05)
      "$CB/cpubench" run --label "$LABEL-r$r" --machine "$LABEL" --threads 1,max --iterations "$(T 5 1)" "${q[@]}" \
        --suite crypto,float/fft,float/matmul,float/nbody,int/json,int/regex,int/sort,int/hashmap,int/compress,int/decompress \
        -o "$OUT/cpubench-r$r.json" > "$OUT/cpubench-r$r.log" 2>&1
      if [ -s "$OUT/cpubench-r$r.json" ]; then
        local n t v u id
        while IFS=$'\t' read -r n t v u; do
          id=cpu.cpubench.${n//\//.}.$(tv "$t")
          [ -n "${M_LABEL[$id]:-}" ] && rec "$id" "$v" "" "$u"   # benchmarks not in the table are ignored
        done < <(jq -r '.benchmarks[] | [.name,.threads,.stats.median,.unit] | @tsv' "$OUT/cpubench-r$r.json")
        ok cpu "cpubench r$r"
      else bad cpu "cpubench r$r" "see cpubench-r$r.log"; fi
    else skip cpu cpubench "$CB/cpubench missing, run setup-cpubench.sh"; fi
    if need openssl; then
      local o1 om
      o1=$(openssl speed -seconds "$(T 10 2)" -mr -evp aes-256-gcm 2>/dev/null | awk -F: '/^\+F:/{v=$NF} END{printf "%.1f", v/1e6}')
      om=$(openssl speed -seconds "$(T 10 2)" -mr -multi "$NPROC" -evp aes-256-gcm 2>/dev/null | awk -F: '/^\+F:/{v=$NF} END{printf "%.1f", v/1e6}')
      rec cpu.openssl.aes-256-gcm.1t "$o1"; rec cpu.openssl.aes-256-gcm.max "$om"; ok cpu "openssl r$r"
    fi
  done
  ROUND=1
}

# ---------------------------------------------------------------- mem 
stage_mem() {
  log "== mem"
  local cache=$HOME/bench-cache; mkdir -p "$cache"
  local src=$cache/stream.c n nt
  if [ ! -s "$src" ]; then
    curl -fsSL --retry 3 --connect-timeout 15 -o "$src" "${STREAM_URL:-https://raw.githubusercontent.com/jeffhammond/STREAM/master/stream.c}" || { rm -f "$src"; bad mem "download stream.c"; }
  fi
  if [ -s "$src" ] && need gcc; then
    n=$(awk -v m="$MEM_AVAIL_KB" 'BEGIN{n=int(m*1024*0.30/24); if(n>100000000)n=100000000; print n}')
    [ "$QUICK" = 1 ] && n=20000000
    nt=$(T 20 3)
    # same N on both architectures; aarch64 static data must stay under 4 GB (3 arrays x 8 bytes x N = 2.4 GB at N=100M)
    local model=(); [ "$(uname -m)" = x86_64 ] && model=(-mcmodel=medium)
    if gcc -O3 -fopenmp "${model[@]}" -DSTREAM_ARRAY_SIZE="$n" -DNTIMES="$nt" "$src" -o "$OUT/stream" 2> "$OUT/stream-build.log"; then
      OMP_NUM_THREADS=$NPROC OMP_PROC_BIND=spread OMP_PLACES=cores "$OUT/stream" > "$OUT/stream.txt" 2>&1
      local cp tr
      cp=$(awk '/^Copy:/{print $2}' "$OUT/stream.txt"); tr=$(awk '/^Triad:/{print $2}' "$OUT/stream.txt")
      [ -n "$tr" ] && rec mem.stream.triad.max "$tr" "$n" && ok mem stream || bad mem stream
      [ -n "$cp" ] && rec mem.stream.copy.max "$cp" "$n"
      rm -f "$OUT/stream"
    else bad mem "compile stream" "see stream-build.log"; fi
  else skip mem stream "stream.c or gcc missing"; fi
  local lat; lat=$(dpkg -L lmbench 2>/dev/null | grep -m1 'lat_mem_rd$')
  if [ -n "$lat" ]; then
    local mb; mb=$(awk -v m="$MEM_AVAIL_KB" -v q="$QUICK" 'BEGIN{x=int(m/1024*0.30); lim=(q==1)?64:2048; if(x>lim)x=lim; print x}')
    "$lat" -t -P 1 -N "$(T 3 1)" "$mb" 128 > "$OUT/lat_mem_rd.txt" 2>&1
    local v; v=$(awk 'NF==2 && $1+0>0 {l=$2} END{print l}' "$OUT/lat_mem_rd.txt")
    [ -n "$v" ] && rec mem.lmbench.lat-mem-rd.1t "$v" "$mb" && ok mem lat_mem_rd || bad mem lat_mem_rd
  else skip mem lat_mem_rd "lmbench not installed"; fi
}

# ---------------------------------------------------------------- disk 
fio_run() { # name outfile args...
  local name=$1 out=$2; shift 2
  fio --name="$name" "$@" --output-format=json --output="$out" > /dev/null 2> "$out.err"
  local rc=$?; if [ $rc -ne 0 ] || [ ! -s "$out" ]; then bad disk "fio $name" "exit $rc, see $(basename "$out").err"; return 1; fi
  ok disk "fio $name"; return 0
}
J() { jq -r "$1" "$2" 2>/dev/null; }

stage_disk() {
  log "== disk"
  need fio || { skip disk fio "not installed"; return; }
  local tgt sz common run ramp
  common=(--direct=1 --ioengine=libaio)
  run=$(T 300 5); ramp=$(T 60 1)
  if [ -n "$RAW_DEV" ]; then
    local why; why=$(raw_problem)   # checked again here: earlier stages may have run for a long time
    [ -z "$why" ] || { bad disk "raw device" "$why"; return; }
    tgt=(--filename="$RAW_DEV"); sz=(--size=100%)
  else
    local free; free=$(df -BG --output=avail "$DATA_DIR" | tail -1 | tr -dc 0-9)
    [ "$free" -ge 15 ] || { bad disk "free space" "only ${free} GB free in $DATA_DIR"; return; }
    tgt=(--filename="$DATA_DIR/fio.dat"); sz=(--size="$FIO_SIZE")
  fi
  # fill, then 4K random write to steady state
  fio_run pre "$OUT/fio-pre.json" "${tgt[@]}" "${sz[@]}" "${common[@]}" --rw=write --bs=1M --iodepth=16 && rec info.fio.fill-write-1m "$(J '.jobs[0].write.bw_bytes/1e6|round' "$OUT/fio-pre.json")"
  fio_run rw "$OUT/fio-33-randwrite4k.json" "${tgt[@]}" "${sz[@]}" "${common[@]}" --rw=randwrite --bs=4k --iodepth=32 --numjobs=4 \
    --time_based --runtime="$(T 600 8)" --ramp_time="$ramp" --steadystate=iops_slope:1% --steadystate_duration="$(T 180 3)" --group_reporting && {
    rec disk.fio.randwrite-4k.qd32x4 "$(J '.jobs[0].write.iops|round' "$OUT/fio-33-randwrite4k.json")"
    rec disk.fio.randwrite-4k.steadystate "$(J '.jobs[0].steadystate.attained // 0' "$OUT/fio-33-randwrite4k.json")"; }
  fio_run lat "$OUT/fio-34-lat.json" "${tgt[@]}" "${sz[@]}" "${common[@]}" --rw=randread --bs=4k --iodepth=1 --numjobs=1 \
    --time_based --runtime="$run" --ramp_time="$ramp" --percentile_list=95:99:99.9 && {
    rec disk.fio.randread-4k.qd1.p99 "$(J '.jobs[0].read.clat_ns.percentile["99.000000"]/1000' "$OUT/fio-34-lat.json")"
    rec disk.fio.randread-4k.qd1.p999 "$(J '.jobs[0].read.clat_ns.percentile["99.900000"]/1000' "$OUT/fio-34-lat.json")"; }
  fio_run rr "$OUT/fio-35-rr.json" "${tgt[@]}" "${sz[@]}" "${common[@]}" --rw=randread --bs=4k --iodepth=32 --numjobs=4 \
    --time_based --runtime="$run" --ramp_time="$ramp" --group_reporting && rec disk.fio.randread-4k.qd32x4 "$(J '.jobs[0].read.iops|round' "$OUT/fio-35-rr.json")"
  fio_run mix "$OUT/fio-36-mix.json" "${tgt[@]}" "${sz[@]}" "${common[@]}" --rw=randrw --rwmixread=70 --bs=4k --iodepth=32 --numjobs=4 \
    --time_based --runtime="$run" --ramp_time="$ramp" --group_reporting && {
    rec disk.fio.mixed-70-30-4k.read "$(J '.jobs[0].read.iops|round' "$OUT/fio-36-mix.json")"
    rec disk.fio.mixed-70-30-4k.write "$(J '.jobs[0].write.iops|round' "$OUT/fio-36-mix.json")"; }
  fio_run sw "$OUT/fio-37-sw.json" "${tgt[@]}" "${sz[@]}" "${common[@]}" --rw=write --bs=1M --iodepth=16 --time_based --runtime="$(T 180 5)" --ramp_time="$(T 30 1)" \
    && rec disk.fio.seq-write-1m "$(J '.jobs[0].write.bw_bytes/1e6|round' "$OUT/fio-37-sw.json")"
  fio_run sr "$OUT/fio-37-sr.json" "${tgt[@]}" "${sz[@]}" "${common[@]}" --rw=read --bs=1M --iodepth=16 --time_based --runtime="$(T 180 5)" --ramp_time="$(T 30 1)" \
    && rec disk.fio.seq-read-1m "$(J '.jobs[0].read.bw_bytes/1e6|round' "$OUT/fio-37-sr.json")"
  local qd
  for qd in 1 4 16 32 64 128; do
    fio_run "qd$qd" "$OUT/fio-38-qd$qd.json" "${tgt[@]}" "${sz[@]}" "${common[@]}" --rw=randread --bs=4k --iodepth="$qd" --numjobs=1 \
      --time_based --runtime="$(T 120 4)" --ramp_time="$(T 30 1)" && rec "disk.fio.randread-4k.sweep-qd$qd" "$(J '.jobs[0].read.iops|round' "$OUT/fio-38-qd$qd.json")"
  done
  [ -z "$RAW_DEV" ] && rm -f "$DATA_DIR/fio.dat"

  # DB-style 8k jobs on files in DB_DIR
  mkdir -p "$DB_DIR" "$WAL_DIR"
  local fsz; fsz=$(T 2g 64m)
  fio_run randwrite8k "$OUT/fio-40.json" --directory="$DB_DIR" --size="$fsz" "${common[@]}" --rw=randwrite --bs=8k --iodepth=32 --numjobs=4 --time_based --runtime="$run" --ramp_time="$ramp" --group_reporting \
    && rec disk.fio.db-randwrite-8k "$(J '.jobs[0].write.iops|round' "$OUT/fio-40.json")"
  fio_run randrw70 "$OUT/fio-41.json" --directory="$DB_DIR" --size="$fsz" "${common[@]}" --rw=randrw --rwmixread=70 --bs=8k --iodepth=32 --numjobs=4 --time_based --runtime="$run" --ramp_time="$ramp" --group_reporting && {
    rec disk.fio.db-randrw-8k.read "$(J '.jobs[0].read.iops|round' "$OUT/fio-41.json")"
    rec disk.fio.db-randrw-8k.write "$(J '.jobs[0].write.iops|round' "$OUT/fio-41.json")"; }
  fio_run seqwrite1m "$OUT/fio-42.json" --directory="$DB_DIR" --size="$(T 8g 128m)" "${common[@]}" --rw=write --bs=1M --iodepth=16 --numjobs=1 --time_based --runtime="$(T 180 5)" --ramp_time="$(T 30 1)" \
    && rec disk.fio.db-seqwrite-1m "$(J '.jobs[0].write.bw_bytes/1e6|round' "$OUT/fio-42.json")"
  fio_run randread8k "$OUT/fio-43.json" --directory="$DB_DIR" --size="$fsz" "${common[@]}" --rw=randread --bs=8k --iodepth=32 --numjobs=4 --time_based --runtime="$run" --ramp_time="$ramp" --group_reporting \
    && rec disk.fio.db-randread-8k "$(J '.jobs[0].read.iops|round' "$OUT/fio-43.json")"
  rm -f "$DB_DIR"/randwrite8k.* "$DB_DIR"/randrw70.* "$DB_DIR"/seqwrite1m.* "$DB_DIR"/randread8k.*
  # WAL commit latency (8k write + fdatasync, QD1)
  fio_run wal "$OUT/fio-44-wal.json" --directory="$WAL_DIR" --size="$(T 1g 64m)" --rw=write --bs=8k --ioengine=sync --fdatasync=1 --time_based --runtime="$run" && {
    rec disk.wal.fdatasync.avg "$(J '.jobs[0].sync.lat_ns.mean/1e6' "$OUT/fio-44-wal.json")"
    rec disk.wal.fdatasync.p99 "$(J '.jobs[0].sync.lat_ns.percentile["99.000000"]/1e6' "$OUT/fio-44-wal.json")"
    rec disk.wal.commit-iops.qd1 "$(J '.jobs[0].write.iops|round' "$OUT/fio-44-wal.json")"; }
  rm -f "$WAL_DIR"/wal.*
}

# ---------------------------------------------------------------- pg 
stage_pg() {
  log "== pg"
  need pgbench && need psql || { skip pg pgbench "not installed"; return; }
  if ! psql -X -Atc 'select 1' > /dev/null 2>&1; then
    skip pg database "cannot connect to db $PGDATABASE on port $PGPORT, run setup-postgres-bench.sh first"; return; fi
  psql -X -Atc "show data_directory" -c "show shared_buffers" -c "show max_wal_size" -c "show synchronous_commit" > "$OUT/pg-settings.txt" 2>&1
  local ddir free scale c j
  ddir=$(psql -X -Atc "show data_directory" 2>/dev/null); ddir=${ddir:-/}
  free=$(df -BG --output=avail "$ddir" 2>/dev/null | tail -1 | tr -dc 0-9); free=${free:-0}
  scale=${PG_SCALE:-$(awk -v r="$RAM_GB" -v f="$free" 'BEGIN{s=r*1.5*64; m=int(f*0.6/0.0157); if(m<s)s=m; if(s<10)s=10; print int(s)}')}
  [ "$QUICK" = 1 ] && scale=${PG_SCALE:-20}
  c=$((NPROC * 2)); j=$((NPROC / 2)); [ "$j" -lt 1 ] && j=1
  log "pgbench scale $scale (~$(awk -v s="$scale" 'BEGIN{printf "%.0f", s*0.0157}') GB), free ${free} GB, -c $c -j $j"
  pgbench -i -s "$scale" -I dtGvp > "$OUT/pgbench-init.log" 2>&1 || { bad pg "pgbench init" "see pgbench-init.log"; return; }
  ok pg "pgbench init"
  pgbench -c "$c" -j "$j" -T "$(T 60 5)" > "$OUT/pgbench-warmup.log" 2>&1
  pgbench -c "$c" -j "$j" -T "$(T 600 10)" -P 10 > "$OUT/pgbench-tpcb.log" 2>&1
  local tps; tps=$(awk '/^tps =/{print $3}' "$OUT/pgbench-tpcb.log")
  if [ -n "$tps" ]; then
    rec pg.pgbench.tpcb.tps "$tps" "$c"
    awk '/^progress:/{v[++n]=$4} END{ if(n>1){ for(i=2;i<=n;i++){s+=v[i];q+=v[i]*v[i]} k=n-1; m=s/k; sd=sqrt(q/k-m*m); printf "%.2f\n", 100*(1-sd/m)} }' "$OUT/pgbench-tpcb.log" > "$OUT/.stab"
    [ -s "$OUT/.stab" ] && rec pg.pgbench.tpcb.stability "$(cat "$OUT/.stab")"; rm -f "$OUT/.stab"
    ok pg "pgbench tpcb"
  else bad pg "pgbench run" "see pgbench-tpcb.log"; fi
  pgbench -c 1 -j 1 -T "$(T 300 10)" -P 10 -r > "$OUT/pgbench-single.log" 2>&1
  local lat; lat=$(awk '/^latency average =/{print $4}' "$OUT/pgbench-single.log")
  [ -n "$lat" ] && rec pg.pgbench.latency.single "$lat" && ok pg "pgbench single-session" || bad pg "pgbench single-session"
  log "pgbench data remains in db $PGDATABASE (~$(awk -v s="$scale" 'BEGIN{printf "%.0f", s*0.0157}') GB). Drop with: dropdb $PGDATABASE && createdb $PGDATABASE"
}

# ---------------------------------------------------------------- net 
stage_net() {
  log "== net"
  [ -n "$PEER" ] || { skip net all "PEER not set (peer must run: iperf3 -s -D ; sockperf server -i 0.0.0.0 &)"; return; }
  local d; d=$(T 60 5)
  if need iperf3 && iperf3 -c "$PEER" -t 1 > /dev/null 2>&1; then
    iperf3 -c "$PEER" -P 8 -t "$d" --bidir -J > "$OUT/iperf-tcp.json" 2>/dev/null
    local a b
    a=$(jq -r '.end.sum_received.bits_per_second/1e9' "$OUT/iperf-tcp.json" 2>/dev/null); b=$(jq -r '.end.sum_received_bidir_reverse.bits_per_second/1e9' "$OUT/iperf-tcp.json" 2>/dev/null)
    if [ -n "$a" ] && [ "$a" != null ]; then
      rec net.iperf3.tcp.tx "$a"; rec net.iperf3.tcp.rx "${b:-0}"
      rec net.iperf3.tcp.bidir "$(awk -v x="$a" -v y="${b:-0}" 'BEGIN{print x+y}')"; ok net iperf-tcp
    else bad net iperf-tcp "see iperf-tcp.json"; fi
    iperf3 -c "$PEER" -u -b 0 -l 64 -P 8 -t "$d" -J > "$OUT/iperf-udp.json" 2>/dev/null
    local p; p=$(jq -r '.end.sum.packets' "$OUT/iperf-udp.json" 2>/dev/null)
    if [ -n "$p" ] && [ "$p" != null ]; then rec net.iperf3.udp.pps "$(awk -v p="$p" -v d="$d" 'BEGIN{printf "%.3f", p/d/1e6}')"
      rec net.iperf3.udp.loss "$(jq -r '.end.sum.lost_percent' "$OUT/iperf-udp.json")"; ok net iperf-udp
    else bad net iperf-udp "see iperf-udp.json"; fi
  else skip net iperf3 "iperf3 missing or $PEER:5201 unreachable"; fi
  if need sockperf; then
    timeout $((d + 30)) sockperf ping-pong -i "$PEER" -t "$d" > "$OUT/sockperf.txt" 2>&1
    local avg p99
    avg=$(grep -oE 'avg-latency=[0-9.]+' "$OUT/sockperf.txt" | head -1 | cut -d= -f2); p99=$(awk '/percentile 99.000/{print $NF}' "$OUT/sockperf.txt")
    if [ -n "$avg" ]; then rec net.sockperf.pingpong.avg "$avg"; [ -n "$p99" ] && rec net.sockperf.pingpong.p99 "$p99"; ok net sockperf
    else bad net sockperf "see sockperf.txt (is 'sockperf server' running on $PEER?)"; fi
  else skip net sockperf "not installed"; fi
}

stage_web() {
  log "== web"
  [ -x "$CB/cpubench" ] || { skip web all "$CB/cpubench missing, run setup-cpubench.sh"; return; }
  local port=18080 sp
  if [ "$QUICK" = 1 ]; then
    "$CB/cpubench" web serve --addr 127.0.0.1:$port > "$OUT/web-serve.log" 2>&1 & sp=$!
    sleep 2
    timeout 120 "$CB/cpubench" web load --target "http://127.0.0.1:$port" --endpoint mix --profile ramp --ramp 500:500:1500 --step-duration 3s --warmup 2s \
      --label "$LABEL-web" --machine "$LABEL" -o "$OUT/web.json" > "$OUT/web.log" 2>&1
    kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
  else
    [ -x "$CB/web-loopback.sh" ] || { bad web all "$CB/web-loopback.sh missing"; return; }
    ( cd "$CB" && MACHINE="$LABEL" ./web-loopback.sh "$LABEL-web" > "$OUT/web.log" 2>&1 )
    cp "$CB/results/web/$LABEL-web"-* "$OUT/" 2>/dev/null
  fi
  local f k
  for f in "$OUT/web.json" "$OUT/$LABEL-web-mix.json"; do
    [ -s "$f" ] || continue
    k=$(jq -r '.web.knee_rps // empty' "$f")
    [ -n "$k" ] && { rec web.cpubench.mix.max-rps "$k"; ok web "$(basename "$f")"; }
  done
  [ -n "${k:-}" ] || bad web "max RPS" "see web.log"
  log "web: check that the SERVER CPUs saturated before the load generator (cpustat log, report warnings)"
}

# ---------------------------------------------------------------- burn-in  - only when asked
stage_burnin() {
  log "== burnin"
  need fio && need stressapptest || { skip burnin all "fio or stressapptest missing"; return; }
  local secs tgt sz
  secs=$(awk -v h="$BURNIN_HOURS" 'BEGIN{printf "%d", h*3600}')
  [ "$QUICK" = 1 ] && secs=40
  if [ -n "$RAW_DEV" ]; then
    local why; why=$(raw_problem)
    [ -z "$why" ] || { bad burnin "raw device" "$why"; return; }
    tgt=(--filename="$RAW_DEV"); sz=()
  else tgt=(--filename="$DATA_DIR/burn.dat"); sz=(--size="$FIO_SIZE"); fi
  local mb=$((RAM_GB * 1024 * 70 / 100)); [ "$QUICK" = 1 ] && mb=256
  dmesg -T > "$OUT/dmesg-before.txt" 2>/dev/null
  stressapptest -s "$secs" -M "$mb" -W > "$OUT/stressapptest.log" 2>&1 &
  local sapp=$! end=$((SECONDS + secs)) errs=0 rounds=0 rc
  while [ "$SECONDS" -lt "$end" ]; do
    local left=$((end - SECONDS)); [ "$left" -gt 3600 ] && left=3600
    fio --name=burn "${tgt[@]}" "${sz[@]}" --direct=1 --ioengine=libaio --rw=randwrite --bs=4k --iodepth=32 \
      --verify=crc32c --verify_backlog=1000000 --verify_fatal=1 --time_based --runtime="$left" > "$OUT/burn-fio-$rounds.log" 2>&1
    rc=$?; rounds=$((rounds + 1))
    if [ $rc -ne 0 ]; then errs=$((errs + 1)); echo "$(date -Is) fio exit $rc (round $rounds)" >> "$OUT/burnin.err"; fi
  done
  wait "$sapp"; local sapprc=$?
  grep -q 'Status: PASS' "$OUT/stressapptest.log" || { errs=$((errs + 1)); echo "stressapptest did not report PASS (exit $sapprc)" >> "$OUT/burnin.err"; }
  dmesg -T 2>/dev/null | grep -iE 'error|mce|i/o' > "$OUT/dmesg-errors.txt"
  local derr; derr=$(diff <(grep -iE 'error|mce|i/o' "$OUT/dmesg-before.txt") "$OUT/dmesg-errors.txt" | grep -c '^>')
  errs=$((errs + derr))
  rec burnin.errors "$errs" "$secs"; ok burnin "rounds=$rounds errors=$errs"
  [ -z "$RAW_DEV" ] && rm -f "$DATA_DIR/burn.dat"
}

# ---------------------------------------------------------------- main
LOGSTEAL=$OUT/mpstat.log
if need mpstat; then ( LC_ALL=C S_TIME_FORMAT=ISO mpstat 5 > "$LOGSTEAL" 2>&1 & echo $! > "$OUT/.mpstat.pid" ); fi
trap '[ -f "$OUT/.mpstat.pid" ] && kill "$(cat "$OUT/.mpstat.pid")" 2>/dev/null; rm -f "$OUT/.mpstat.pid"' EXIT

log "label=$LABEL quick=$QUICK stages=[$STAGES] out=$OUT"
write_meta
for s in info cpu mem disk pg net web burnin; do
  want "$s" || continue
  "stage_$s"
done

# steal summary (CPU steal during the whole run)
if [ -s "$LOGSTEAL" ]; then
  awk '/%steal/{for(i=1;i<=NF;i++) if($i=="%steal") c=i; next} c && $2=="all"{s+=$c; n++; if($c>m) m=$c} END{if(n) printf "%.2f\t%.2f\n", s/n, m}' "$LOGSTEAL" > "$OUT/.steal"
  if [ -s "$OUT/.steal" ]; then
    rec info.cpu.steal.avg "$(cut -f1 "$OUT/.steal")"; rec info.cpu.steal.peak "$(cut -f2 "$OUT/.steal")"
  fi; rm -f "$OUT/.steal"
fi

# summary: median / min / max / cv per metric over the rounds
if need python3; then
  python3 -I - "$RES" "$OUT/summary.tsv" <<'PY'
import csv, statistics, sys, collections
res, out = sys.argv[1], sys.argv[2]
d = collections.OrderedDict()   # in the order the tests ran
for r in list(csv.reader(open(res), delimiter='\t'))[1:]:
    if len(r) < 5: continue
    mid, metric, val, unit, _ = r
    try: v = float(val)
    except ValueError: continue
    d.setdefault((mid, metric, unit), []).append(v)
with open(out, 'w') as f:
    f.write('id\tmetric\tunit\tn\tmedian\tmin\tmax\tcv_pct\n')
    for (mid, metric, unit), v in d.items():
        m = statistics.median(v); cv = (statistics.pstdev(v) / statistics.mean(v) * 100) if len(v) > 1 and statistics.mean(v) else 0
        f.write(f'{mid}\t{metric}\t{unit}\t{len(v)}\t{m:.4g}\t{min(v):.4g}\t{max(v):.4g}\t{cv:.1f}\n')
PY
fi

write_meta "$(utc_now)"

# tables: stdout plus report.md and report.html in the result folder (report.py sits next to this script)
REPORT=$(dirname "${BASH_SOURCE[0]}")/report.py
if [ -f "$REPORT" ] && need python3; then
  python3 -I "$REPORT" show "$OUT" || log "report.py failed; the raw results are still in $OUT"
fi

log "done. results: $OUT"
log "  summary.tsv (median per metric), results.tsv (every value), status.tsv (OK/FAIL/SKIP per step), meta.json, info.txt, raw logs"
grep -E 'FAIL' "$STATUS" | sed 's/^/  /'
true
