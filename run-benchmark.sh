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
#   -h, --help    show this text
#
# Stages (ram is accepted for mem). info always runs, because report.py needs it.
#   cpu     rows 7, 8, 10-23   default
#   mem     rows 26-28         default
#   disk    rows 33-38, 40-46  default
#   pg      rows 47-49         needs setup-postgres-bench.sh
#   net     rows 51-53         needs --peer
#   web     row 55
#   burnin  row 65             48 hours unless --hours says otherwise
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
#   DB_DIR WAL_DIR  folders for rows 40-43 and 44-46           (default: DATA_DIR; e.g. /pgdata /pgwal)
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
  printf '%-7s %-12s %-8s %-12s %s\n' STAGE ROWS DEFAULT TIME READY
  for s in $ALL_STAGES; do
    case $s in
      cpu)    rows="7,8,10-23";    when=yes; time="14 min" ;;
      mem)    rows="26-28";        when=yes; time="1 min" ;;
      disk)   rows="33-38,40-46";  when=yes; time="71 min" ;;
      pg)     rows="47-49";        when=no;  time="16 min+load" ;;
      net)    rows="51-53";        when=no;  time="3 min" ;;
      web)    rows="55";           when=no;  time="5 min" ;;
      burnin) rows="65";           when=no;  time="$BURNIN_HOURS h" ;;
    esac
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
printf 'row\tmetric\tvalue\tunit\tround\n' > "$RES"
printf 'stage\tstep\tresult\n' > "$STATUS"

T() { if [ "$QUICK" = 1 ]; then echo "$2"; else echo "$1"; fi; }   # T <full> <quick>
log() { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$OUT/run.log"; }
ROUND=1
rec() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$ROUND" >> "$RES"; }
ok() { printf '%s\t%s\tOK\n' "$1" "$2" >> "$STATUS"; }
bad() { printf '%s\t%s\tFAIL %s\n' "$1" "$2" "${3:-}" >> "$STATUS"; log "[FAIL] $1: $2 ${3:-}"; }
skip() { printf '%s\t%s\tSKIP %s\n' "$1" "$2" "${3:-}" >> "$STATUS"; log "[SKIP] $1: $2 ${3:-}"; }

declare -A ROWMAP=( [crypto/aes-gcm]=11 [crypto/ecdsa-p256]=12 [crypto/rsa2048-sign]=13 [crypto/sha256]=14
  [float/fft]=15 [float/matmul]=16 [float/nbody]=17 [int/compress]=18 [int/decompress]=19
  [int/hashmap]=20 [int/json]=21 [int/regex]=22 [int/sort]=23 )

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

# ---------------------------------------------------------------- cpu (rows 7,8,10,11-23)
stage_cpu() {
  log "== cpu"
  local r st mt out
  for r in $(seq 1 "$ROUNDS"); do
    ROUND=$r; log "cpu round $r/$ROUNDS"
    if need sysbench; then
      st=$(sysbench cpu --cpu-max-prime=20000 --threads=1 --time="$(T 60 5)" run 2>&1 | tee "$OUT/sysbench-st-r$r.txt" | awk '/events per second/{print $4}')
      mt=$(sysbench cpu --cpu-max-prime=20000 --threads="$NPROC" --time="$(T 60 5)" run 2>&1 | tee "$OUT/sysbench-mt-r$r.txt" | awk '/events per second/{print $4}')
      [ -n "$st" ] && rec 7 "sysbench cpu 1t" "$st" events/s && ok cpu "sysbench st r$r" || bad cpu "sysbench st r$r"
      [ -n "$mt" ] && rec 8 "sysbench cpu ${NPROC}t" "$mt" events/s && ok cpu "sysbench mt r$r" || bad cpu "sysbench mt r$r"
    else skip cpu sysbench "not installed"; fi
    if need 7z; then
      out=$(7z b -mmt="$NPROC" 2>&1 | tee "$OUT/7z-r$r.txt" | awk '/^Tot:/{print $NF}')
      [ -n "$out" ] && rec 10 "7z rating ${NPROC}t" "$out" MIPS && ok cpu "7z r$r" || bad cpu "7z r$r"
    else skip cpu 7z "not installed"; fi
    if [ -x "$CB/cpubench" ]; then
      local q=(); [ "$QUICK" = 1 ] && q=(--scale 0.05)
      "$CB/cpubench" run --label "$LABEL-r$r" --machine "$LABEL" --threads 1,max --iterations "$(T 5 1)" "${q[@]}" \
        --suite crypto,float/fft,float/matmul,float/nbody,int/json,int/regex,int/sort,int/hashmap,int/compress,int/decompress \
        -o "$OUT/cpubench-r$r.json" > "$OUT/cpubench-r$r.log" 2>&1
      if [ -s "$OUT/cpubench-r$r.json" ]; then
        local n t v u
        while IFS=$'\t' read -r n t v u; do
          [ -n "${ROWMAP[$n]:-}" ] && rec "${ROWMAP[$n]}" "cpubench $n ${t}t" "$v" "$u"
        done < <(jq -r '.benchmarks[] | [.name,.threads,.stats.median,.unit] | @tsv' "$OUT/cpubench-r$r.json")
        ok cpu "cpubench r$r"
      else bad cpu "cpubench r$r" "see cpubench-r$r.log"; fi
    else skip cpu cpubench "$CB/cpubench missing, run setup-cpubench.sh"; fi
    if need openssl; then
      local o1 om
      o1=$(openssl speed -seconds "$(T 10 2)" -mr -evp aes-256-gcm 2>/dev/null | awk -F: '/^\+F:/{v=$NF} END{printf "%.1f", v/1e6}')
      om=$(openssl speed -seconds "$(T 10 2)" -mr -multi "$NPROC" -evp aes-256-gcm 2>/dev/null | awk -F: '/^\+F:/{v=$NF} END{printf "%.1f", v/1e6}')
      rec 11 "openssl aes-256-gcm 1t" "$o1" MB/s; rec 11 "openssl aes-256-gcm ${NPROC}t" "$om" MB/s; ok cpu "openssl r$r"
    fi
  done
  ROUND=1
}

# ---------------------------------------------------------------- mem (rows 26,27,28)
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
      [ -n "$tr" ] && rec 26 "stream triad (N=$n)" "$tr" MB/s && ok mem stream || bad mem stream
      [ -n "$cp" ] && rec 28 "stream copy (N=$n)" "$cp" MB/s
      rm -f "$OUT/stream"
    else bad mem "compile stream" "see stream-build.log"; fi
  else skip mem stream "stream.c or gcc missing"; fi
  local lat; lat=$(dpkg -L lmbench 2>/dev/null | grep -m1 'lat_mem_rd$')
  if [ -n "$lat" ]; then
    local mb; mb=$(awk -v m="$MEM_AVAIL_KB" -v q="$QUICK" 'BEGIN{x=int(m/1024*0.30); lim=(q==1)?64:2048; if(x>lim)x=lim; print x}')
    "$lat" -t -P 1 -N "$(T 3 1)" "$mb" 128 > "$OUT/lat_mem_rd.txt" 2>&1
    local v; v=$(awk 'NF==2 && $1+0>0 {l=$2} END{print l}' "$OUT/lat_mem_rd.txt")
    [ -n "$v" ] && rec 27 "lat_mem_rd -t ${mb}MB" "$v" ns && ok mem lat_mem_rd || bad mem lat_mem_rd
  else skip mem lat_mem_rd "lmbench not installed"; fi
}

# ---------------------------------------------------------------- disk (rows 33-38, 40-46)
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
  # row 33: fill, then 4K random write to steady state
  fio_run pre "$OUT/fio-pre.json" "${tgt[@]}" "${sz[@]}" "${common[@]}" --rw=write --bs=1M --iodepth=16 && rec info "fio fill write 1M" "$(J '.jobs[0].write.bw_bytes/1e6|round' "$OUT/fio-pre.json")" MB/s
  fio_run rw "$OUT/fio-33-randwrite4k.json" "${tgt[@]}" "${sz[@]}" "${common[@]}" --rw=randwrite --bs=4k --iodepth=32 --numjobs=4 \
    --time_based --runtime="$(T 600 8)" --ramp_time="$ramp" --steadystate=iops_slope:1% --steadystate_duration="$(T 180 3)" --group_reporting && {
    rec 33 "fio randwrite 4k qd32x4" "$(J '.jobs[0].write.iops|round' "$OUT/fio-33-randwrite4k.json")" IOPS
    rec 33 "steadystate attained (1=yes)" "$(J '.jobs[0].steadystate.attained // 0' "$OUT/fio-33-randwrite4k.json")" flag; }
  fio_run lat "$OUT/fio-34-lat.json" "${tgt[@]}" "${sz[@]}" "${common[@]}" --rw=randread --bs=4k --iodepth=1 --numjobs=1 \
    --time_based --runtime="$run" --ramp_time="$ramp" --percentile_list=95:99:99.9 && {
    rec 34 "fio randread 4k qd1 p99" "$(J '.jobs[0].read.clat_ns.percentile["99.000000"]/1000' "$OUT/fio-34-lat.json")" us
    rec 34 "fio randread 4k qd1 p99.9" "$(J '.jobs[0].read.clat_ns.percentile["99.900000"]/1000' "$OUT/fio-34-lat.json")" us; }
  fio_run rr "$OUT/fio-35-rr.json" "${tgt[@]}" "${sz[@]}" "${common[@]}" --rw=randread --bs=4k --iodepth=32 --numjobs=4 \
    --time_based --runtime="$run" --ramp_time="$ramp" --group_reporting && rec 35 "fio randread 4k qd32x4" "$(J '.jobs[0].read.iops|round' "$OUT/fio-35-rr.json")" IOPS
  fio_run mix "$OUT/fio-36-mix.json" "${tgt[@]}" "${sz[@]}" "${common[@]}" --rw=randrw --rwmixread=70 --bs=4k --iodepth=32 --numjobs=4 \
    --time_based --runtime="$run" --ramp_time="$ramp" --group_reporting && {
    rec 36 "fio mixed 70/30 read" "$(J '.jobs[0].read.iops|round' "$OUT/fio-36-mix.json")" IOPS
    rec 36 "fio mixed 70/30 write" "$(J '.jobs[0].write.iops|round' "$OUT/fio-36-mix.json")" IOPS; }
  fio_run sw "$OUT/fio-37-sw.json" "${tgt[@]}" "${sz[@]}" "${common[@]}" --rw=write --bs=1M --iodepth=16 --time_based --runtime="$(T 180 5)" --ramp_time="$(T 30 1)" \
    && rec 37 "fio seq write 1M" "$(J '.jobs[0].write.bw_bytes/1e6|round' "$OUT/fio-37-sw.json")" MB/s
  fio_run sr "$OUT/fio-37-sr.json" "${tgt[@]}" "${sz[@]}" "${common[@]}" --rw=read --bs=1M --iodepth=16 --time_based --runtime="$(T 180 5)" --ramp_time="$(T 30 1)" \
    && rec 37 "fio seq read 1M" "$(J '.jobs[0].read.bw_bytes/1e6|round' "$OUT/fio-37-sr.json")" MB/s
  local qd
  for qd in 1 4 16 32 64 128; do
    fio_run "qd$qd" "$OUT/fio-38-qd$qd.json" "${tgt[@]}" "${sz[@]}" "${common[@]}" --rw=randread --bs=4k --iodepth="$qd" --numjobs=1 \
      --time_based --runtime="$(T 120 4)" --ramp_time="$(T 30 1)" && rec 38 "fio randread 4k qd$qd" "$(J '.jobs[0].read.iops|round' "$OUT/fio-38-qd$qd.json")" IOPS
  done
  [ -z "$RAW_DEV" ] && rm -f "$DATA_DIR/fio.dat"

  # rows 40-43: DB-style 8k jobs on files in DB_DIR
  mkdir -p "$DB_DIR" "$WAL_DIR"
  local fsz; fsz=$(T 2g 64m)
  fio_run randwrite8k "$OUT/fio-40.json" --directory="$DB_DIR" --size="$fsz" "${common[@]}" --rw=randwrite --bs=8k --iodepth=32 --numjobs=4 --time_based --runtime="$run" --ramp_time="$ramp" --group_reporting \
    && rec 40 "fio randwrite 8k" "$(J '.jobs[0].write.iops|round' "$OUT/fio-40.json")" IOPS
  fio_run randrw70 "$OUT/fio-41.json" --directory="$DB_DIR" --size="$fsz" "${common[@]}" --rw=randrw --rwmixread=70 --bs=8k --iodepth=32 --numjobs=4 --time_based --runtime="$run" --ramp_time="$ramp" --group_reporting && {
    rec 41 "fio randrw 70/30 8k read" "$(J '.jobs[0].read.iops|round' "$OUT/fio-41.json")" IOPS
    rec 41 "fio randrw 70/30 8k write" "$(J '.jobs[0].write.iops|round' "$OUT/fio-41.json")" IOPS; }
  fio_run seqwrite1m "$OUT/fio-42.json" --directory="$DB_DIR" --size="$(T 8g 128m)" "${common[@]}" --rw=write --bs=1M --iodepth=16 --numjobs=1 --time_based --runtime="$(T 180 5)" --ramp_time="$(T 30 1)" \
    && rec 42 "fio seqwrite 1M" "$(J '.jobs[0].write.bw_bytes/1e6|round' "$OUT/fio-42.json")" MB/s
  fio_run randread8k "$OUT/fio-43.json" --directory="$DB_DIR" --size="$fsz" "${common[@]}" --rw=randread --bs=8k --iodepth=32 --numjobs=4 --time_based --runtime="$run" --ramp_time="$ramp" --group_reporting \
    && rec 43 "fio randread 8k" "$(J '.jobs[0].read.iops|round' "$OUT/fio-43.json")" IOPS
  rm -f "$DB_DIR"/randwrite8k.* "$DB_DIR"/randrw70.* "$DB_DIR"/seqwrite1m.* "$DB_DIR"/randread8k.*
  # rows 44-46: WAL commit latency (8k write + fdatasync, QD1)
  fio_run wal "$OUT/fio-44-wal.json" --directory="$WAL_DIR" --size="$(T 1g 64m)" --rw=write --bs=8k --ioengine=sync --fdatasync=1 --time_based --runtime="$run" && {
    rec 44 "wal fdatasync avg" "$(J '.jobs[0].sync.lat_ns.mean/1e6' "$OUT/fio-44-wal.json")" ms
    rec 45 "wal fdatasync p99" "$(J '.jobs[0].sync.lat_ns.percentile["99.000000"]/1e6' "$OUT/fio-44-wal.json")" ms
    rec 46 "wal commit iops qd1" "$(J '.jobs[0].write.iops|round' "$OUT/fio-44-wal.json")" IOPS; }
  rm -f "$WAL_DIR"/wal.*
}

# ---------------------------------------------------------------- pg (rows 47,48,49)
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
  pgbench -c "$c" -j "$j" -T "$(T 600 10)" -P 10 > "$OUT/pgbench-47.log" 2>&1
  local tps; tps=$(awk '/^tps =/{print $3}' "$OUT/pgbench-47.log")
  if [ -n "$tps" ]; then
    rec 47 "pgbench tpcb-like tps (-c $c)" "$tps" TPS
    awk '/^progress:/{v[++n]=$4} END{ if(n>1){ for(i=2;i<=n;i++){s+=v[i];q+=v[i]*v[i]} k=n-1; m=s/k; sd=sqrt(q/k-m*m); printf "%.2f\n", 100*(1-sd/m)} }' "$OUT/pgbench-47.log" > "$OUT/.stab"
    [ -s "$OUT/.stab" ] && rec 48 "tps stability 100*(1-cv)" "$(cat "$OUT/.stab")" % ; rm -f "$OUT/.stab"
    ok pg "pgbench 47/48"
  else bad pg "pgbench run" "see pgbench-47.log"; fi
  pgbench -c 1 -j 1 -T "$(T 300 10)" -P 10 -r > "$OUT/pgbench-49.log" 2>&1
  local lat; lat=$(awk '/^latency average =/{print $4}' "$OUT/pgbench-49.log")
  [ -n "$lat" ] && rec 49 "pgbench single-session latency" "$lat" ms && ok pg "pgbench 49" || bad pg "pgbench 49"
  log "pgbench data remains in db $PGDATABASE (~$(awk -v s="$scale" 'BEGIN{printf "%.0f", s*0.0157}') GB). Drop with: dropdb $PGDATABASE && createdb $PGDATABASE"
}

# ---------------------------------------------------------------- net (rows 51,52,53)
stage_net() {
  log "== net"
  [ -n "$PEER" ] || { skip net all "PEER not set (peer must run: iperf3 -s -D ; sockperf server -i 0.0.0.0 &)"; return; }
  local d; d=$(T 60 5)
  if need iperf3 && iperf3 -c "$PEER" -t 1 > /dev/null 2>&1; then
    iperf3 -c "$PEER" -P 8 -t "$d" --bidir -J > "$OUT/iperf-tcp.json" 2>/dev/null
    local a b
    a=$(jq -r '.end.sum_received.bits_per_second/1e9' "$OUT/iperf-tcp.json" 2>/dev/null); b=$(jq -r '.end.sum_received_bidir_reverse.bits_per_second/1e9' "$OUT/iperf-tcp.json" 2>/dev/null)
    if [ -n "$a" ] && [ "$a" != null ]; then
      rec 51 "iperf3 tcp tx->peer" "$a" Gbps; rec 51 "iperf3 tcp peer->rx" "${b:-0}" Gbps
      rec 51 "iperf3 tcp bidir total" "$(awk -v x="$a" -v y="${b:-0}" 'BEGIN{print x+y}')" Gbps; ok net iperf-tcp
    else bad net iperf-tcp "see iperf-tcp.json"; fi
    iperf3 -c "$PEER" -u -b 0 -l 64 -P 8 -t "$d" -J > "$OUT/iperf-udp.json" 2>/dev/null
    local p; p=$(jq -r '.end.sum.packets' "$OUT/iperf-udp.json" 2>/dev/null)
    if [ -n "$p" ] && [ "$p" != null ]; then rec 53 "iperf3 udp 64B packets sent" "$(awk -v p="$p" -v d="$d" 'BEGIN{printf "%.3f", p/d/1e6}')" Mpps
      rec 53 "iperf3 udp lost packets %" "$(jq -r '.end.sum.lost_percent' "$OUT/iperf-udp.json")" % ; ok net iperf-udp
    else bad net iperf-udp "see iperf-udp.json"; fi
  else skip net iperf3 "iperf3 missing or $PEER:5201 unreachable"; fi
  if need sockperf; then
    timeout $((d + 30)) sockperf ping-pong -i "$PEER" -t "$d" > "$OUT/sockperf.txt" 2>&1
    local avg p99
    avg=$(grep -oE 'avg-latency=[0-9.]+' "$OUT/sockperf.txt" | head -1 | cut -d= -f2); p99=$(awk '/percentile 99.000/{print $NF}' "$OUT/sockperf.txt")
    if [ -n "$avg" ]; then rec 52 "sockperf ping-pong avg (one-way)" "$avg" us; [ -n "$p99" ] && rec 52 "sockperf ping-pong p99" "$p99" us; ok net sockperf
    else bad net sockperf "see sockperf.txt (is 'sockperf server' running on $PEER?)"; fi
  else skip net sockperf "not installed"; fi
}

# ---------------------------------------------------------------- web (row 55)
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
    cp "$CB"/results/web/"$LABEL-web"-* "$OUT/" 2>/dev/null
  fi
  local f k
  for f in "$OUT/web.json" "$OUT/$LABEL-web-mix.json"; do
    [ -s "$f" ] || continue
    k=$(jq -r '.web.knee_rps // empty' "$f")
    [ -n "$k" ] && { rec 55 "cpubench web mix max RPS @ SLO (loopback)" "$k" RPS; ok web "$(basename "$f")"; }
  done
  [ -n "${k:-}" ] || bad web "max RPS" "see web.log"
  log "web: check that the SERVER CPUs saturated before the load generator (cpustat log, report warnings)"
}

# ---------------------------------------------------------------- burn-in (row 65) - only when asked
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
  rec 65 "burn-in errors (${secs}s)" "$errs" count; ok burnin "rounds=$rounds errors=$errs"
  [ -z "$RAW_DEV" ] && rm -f "$DATA_DIR/burn.dat"
}

# ---------------------------------------------------------------- main
LOGSTEAL=$OUT/mpstat.log
if need mpstat; then ( LC_ALL=C S_TIME_FORMAT=ISO mpstat 5 > "$LOGSTEAL" 2>&1 & echo $! > "$OUT/.mpstat.pid" ); fi
trap '[ -f "$OUT/.mpstat.pid" ] && kill "$(cat "$OUT/.mpstat.pid")" 2>/dev/null; rm -f "$OUT/.mpstat.pid"' EXIT

log "label=$LABEL quick=$QUICK stages=[$STAGES] out=$OUT"
for s in info cpu mem disk pg net web burnin; do
  want "$s" || continue
  "stage_$s"
done

# steal summary (rows: CPU steal during the whole run)
if [ -s "$LOGSTEAL" ]; then
  awk '/%steal/{for(i=1;i<=NF;i++) if($i=="%steal") c=i; next} c && $2=="all"{s+=$c; n++; if($c>m) m=$c} END{if(n) printf "%.2f\t%.2f\n", s/n, m}' "$LOGSTEAL" > "$OUT/.steal"
  if [ -s "$OUT/.steal" ]; then
    rec info "cpu steal avg" "$(cut -f1 "$OUT/.steal")" %; rec info "cpu steal max" "$(cut -f2 "$OUT/.steal")" %
  fi; rm -f "$OUT/.steal"
fi

# summary: median / min / max / cv per metric over the rounds
if need python3; then
  python3 -I - "$RES" "$OUT/summary.tsv" <<'PY'
import csv, statistics, sys, collections
res, out = sys.argv[1], sys.argv[2]
d = collections.OrderedDict()
for r in list(csv.reader(open(res), delimiter='\t'))[1:]:
    if len(r) < 5: continue
    row, metric, val, unit, _ = r
    try: v = float(val)
    except ValueError: continue
    d.setdefault((row, metric, unit), []).append(v)
def key(k):
    try: return (0, int(k[0]), k[1])
    except ValueError: return (1, 0, k[1])
with open(out, 'w') as f:
    f.write('row\tmetric\tunit\tn\tmedian\tmin\tmax\tcv_pct\n')
    for (row, metric, unit), v in sorted(d.items(), key=lambda kv: key(kv[0])):
        m = statistics.median(v); cv = (statistics.pstdev(v) / statistics.mean(v) * 100) if len(v) > 1 and statistics.mean(v) else 0
        f.write(f'{row}\t{metric}\t{unit}\t{len(v)}\t{m:.4g}\t{min(v):.4g}\t{max(v):.4g}\t{cv:.1f}\n')
PY
fi

# tables: stdout plus report.md and report.html in the result folder (report.py sits next to this script)
REPORT=$(dirname "${BASH_SOURCE[0]}")/report.py
if [ -f "$REPORT" ] && need python3; then
  python3 -I "$REPORT" show "$OUT" || log "report.py failed; the raw results are still in $OUT"
fi

log "done. results: $OUT"
log "  summary.tsv (median per metric), results.tsv (every value), status.tsv (OK/FAIL/SKIP per step), info.txt, raw logs"
grep -E 'FAIL' "$STATUS" | sed 's/^/  /'
true
