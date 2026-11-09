#!/usr/bin/env bash
# lib/run.sh - `vmbench run`: option parsing, stage selection, pre-flight, the run itself and the summary.
# Sourced, never executed. The environment variables it reads are listed in lib/run-usage.txt (--help).
#
#   cmd_run [OPTIONS]   exit codes: 0 done (or --help, --list, --metrics), 2 usage or pre-flight error
#   usage               print the --help text (lib/run-usage.txt with the stage rows filled in)

# The variables set below are read by lib/metrics.sh, lib/meta.sh and the stage files.
# shellcheck disable=SC2034

# @NAME@ is run-benchmark.sh through the compatibility wrapper, "vmbench run" otherwise
usage() {
  local name="vmbench run" cmd="vmbench run" line
  if [ "${VMBENCH_PROG:-}" = run-benchmark.sh ]; then name=run-benchmark.sh; cmd="bash run-benchmark.sh"; fi
  while IFS= read -r line; do
    if [ "$line" = '@STAGES@' ]; then stage_usage_rows; continue; fi
    line=${line//@NAME@/$name}; line=${line//@CMD@/$cmd}
    printf '%s\n' "$line"
  done < "$VMBENCH_HOME/lib/run-usage.txt"
}

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

# positive_int NAME VALUE: die unless VALUE is a whole number of 1 or more (NAME is the flag or variable, for the message)
positive_int() {
  [[ $2 =~ ^[1-9][0-9]*$ ]] || die "$1 needs a whole number of 1 or more, got '$2'"
}

# tmux_session_name: vmbench-<label>, or the --session value; made safe for tmux (no dots or colons)
tmux_session_name() {
  local n=${SESSION:-vmbench-$LABEL}
  printf '%s' "${n//[^A-Za-z0-9_-]/-}"
}

# detach_run NAME: start this run, with the same stage selection and settings, in a new tmux session and return.
# The settings go through a small launcher file in the result folder (a tmux server that is already running would
# otherwise give the new session its own environment, not ours).
detach_run() {
  local name=$1 v launcher=$OUT/.launch.sh
  need tmux || die "--detach needs tmux, which is not installed (apt-get install tmux); or run without --detach under nohup or screen"
  if tmux has-session -t "=$name" 2>/dev/null; then
    die "tmux session '$name' already exists: attach with 'tmux attach -t $name', or pick another name with --session NAME"
  fi
  mkdir -p "$OUT" || die "cannot create $OUT"
  {
    echo '#!/usr/bin/env bash'
    echo "# written by vmbench run (the detach option): the settings of the run that tmux session '$name' starts"
    for v in LABEL OUT QUICK ROUNDS MEM_ROUNDS WEB_ROUNDS DISK_ROUNDS CB DATA_DIR FIO_SIZE RAW_DEV DB_DIR WAL_DIR PEER \
             BURNIN_HOURS PGPORT PGDATABASE PGHOST PGUSER CONFIRM_WIPE STREAM_C STREAM_URL STREAM_SKIP_CHECK \
             STREAM_CACHE_DIR VMBENCH_LANG VMBENCH_PROG HOME PATH; do
      [ -n "${!v+x}" ] && printf 'export %s=%q\n' "$v" "${!v}"
    done
    echo 'unset STAGES'
    printf 'cd %q || exit 1\n' "$PWD"
    printf 'exec bash %q run' "$VMBENCH_HOME/vmbench"
    printf ' %q' "${FWD_ARGS[@]+"${FWD_ARGS[@]}"}"
    echo
  } > "$launcher"
  tmux new-session -d -s "$name" "bash $(printf '%q' "$launcher")" || die "tmux could not start the session '$name'"
  printf '%s\n' "$name" > "$OUT/.session"
  printf '%s\n' "Started in the background: tmux session '$name'." \
    "  attach:         tmux attach -t $name     (leave it with Ctrl-b d, the run keeps going)" \
    "  follow the log: tail -f $OUT/run.log" \
    "  status:         vmbench status $OUT" \
    "  results:        $OUT"
  exit 0
}

cmd_run() {
  LABEL=${LABEL:-$(hostname -s)}
  QUICK=${QUICK:-0}
  # Repeats per stage. ROUNDS is the default of cpu, mem and web; MEM_ROUNDS and WEB_ROUNDS set one of them;
  # --rounds N sets all three. disk has its own setting because one disk round is long (docs/tests.md, "Rounds").
  local rounds_given=${ROUNDS:+1}${MEM_ROUNDS:+1}${WEB_ROUNDS:+1}${DISK_ROUNDS:+1}
  [ -z "${ROUNDS:-}" ] || positive_int ROUNDS "$ROUNDS"
  [ -z "${MEM_ROUNDS:-}" ] || positive_int MEM_ROUNDS "$MEM_ROUNDS"
  [ -z "${WEB_ROUNDS:-}" ] || positive_int WEB_ROUNDS "$WEB_ROUNDS"
  [ -z "${DISK_ROUNDS:-}" ] || positive_int DISK_ROUNDS "$DISK_ROUNDS"
  [ "$QUICK" != 1 ] || [ -n "$rounds_given" ] || ROUNDS=1   # a smoke run is one round unless rounds were asked for
  ROUNDS=${ROUNDS:-3}
  MEM_ROUNDS=${MEM_ROUNDS:-$ROUNDS}
  WEB_ROUNDS=${WEB_ROUNDS:-$ROUNDS}
  DISK_ROUNDS=${DISK_ROUNDS:-1}
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
  [ "$QUICK" = 1 ] && FIO_SIZE=256M

  ADD="" ONLY="" HAVE_ONLY="" FLAG_PEER="" FLAG_HOURS="" LIST="" DETACH="" SESSION="" FLAG_ROUNDS="" FLAG_DISK_ROUNDS=""
  FWD_ARGS=()   # what a detached run is started with: every argument except --detach and --session
  local fwd
  while [ $# -gt 0 ]; do
    opt=$1; val=""; has_val=""; fwd=("$1")
    case $opt in --*=*) val=${opt#*=}; opt=${opt%%=*}; has_val=1 ;; esac
    case $opt in
      --with|--only|--peer|--hours|--rounds|--disk-rounds|--session)
        if [ -z "$has_val" ]; then
          [ $# -ge 2 ] || die "$opt needs a value"
          val=$2; fwd+=("$2"); shift
        fi
        [ -n "$val" ] || die "$opt needs a value" ;;
    esac
    case $opt in --detach|--session) ;; *) FWD_ARGS+=("${fwd[@]}") ;; esac
    case $opt in
      --with) ADD="$ADD $(stage_list "$val")" || exit 2 ;;
      --only) ONLY="$ONLY $(stage_list "$val")" || exit 2; HAVE_ONLY=1 ;;
      --peer) PEER=$val; FLAG_PEER=1 ;;
      --hours)
        [[ $val =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v h="$val" 'BEGIN{exit !(h>0)}' || die "--hours needs a number above 0, got '$val'"
        BURNIN_HOURS=$val; FLAG_HOURS=1 ;;
      --rounds) positive_int --rounds "$val"; ROUNDS=$val; MEM_ROUNDS=$val; WEB_ROUNDS=$val; FLAG_ROUNDS=1 ;;
      --disk-rounds) positive_int --disk-rounds "$val"; DISK_ROUNDS=$val; FLAG_DISK_ROUNDS=1 ;;
      --detach) DETACH=1 ;;
      --session)
        [[ $val =~ ^[A-Za-z0-9_-]+$ ]] || die "--session needs a name of letters, digits, - and _, got '$val'"
        SESSION=$val ;;
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
  if [ -n "$LIST" ]; then show_stages; exit 0; fi
  if [ -n "$FLAG_PEER" ] && ! want net; then die "--peer is only used by the net stage, add --with net"; fi
  if [ -n "$FLAG_ROUNDS" ] && ! want cpu && ! want mem && ! want web; then die "--rounds is used by cpu, mem and web: add one of them (disk has --disk-rounds)"; fi
  if [ -n "$FLAG_DISK_ROUNDS" ] && ! want disk; then die "--disk-rounds is only used by the disk stage, add --with disk or --only disk"; fi
  if [ -n "$SESSION" ] && [ -z "$DETACH" ]; then die "--session names the tmux session of --detach, add --detach"; fi
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
  if [ -n "$DETACH" ]; then
    # nothing has run yet: when the arguments came from STAGES, pass the selection on explicitly
    [ -n "$HAVE_ONLY$ADD" ] || FWD_ARGS+=(--only "$SELECTED")
    detach_run "$(tmux_session_name)"
  fi
  need mpstat || echo "note: mpstat is not installed (package sysstat), CPU steal will not be recorded" >&2
  STAGES=$(for s in info $ALL_STAGES; do want "$s" && printf '%s ' "$s"; done); STAGES=" $STAGES"
  NPROC=$(nproc)
  RAM_GB=$(awk '/MemTotal/{printf "%d", $2/1048576+0.5}' /proc/meminfo)
  MEM_AVAIL_KB=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
  mkdir -p "$OUT" "$DATA_DIR"
  RES=$OUT/results.tsv; STATUS=$OUT/status.tsv
  printf 'id\tmetric\tvalue\tunit\tround\n' > "$RES"
  printf 'stage\tstep\tresult\n' > "$STATUS"
  START_UTC=$(utc_now)
  LOGSTEAL=$OUT/mpstat.log
  if need mpstat; then ( LC_ALL=C S_TIME_FORMAT=ISO mpstat 5 > "$LOGSTEAL" 2>&1 & echo $! > "$OUT/.mpstat.pid" ); fi
  echo $$ > "$OUT/.run.pid"   # vmbench status looks for this process
  trap '[ -f "$OUT/.mpstat.pid" ] && kill "$(cat "$OUT/.mpstat.pid")" 2>/dev/null; rm -f "$OUT/.mpstat.pid" "$OUT/.run.pid"' EXIT

  log "label=$LABEL quick=$QUICK stages=[$STAGES] out=$OUT"
  write_meta
  for s in info $ALL_STAGES; do
    want "$s" || continue
    "stage_${s}_run"
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

  # tables: stdout plus report.md and report.html in the result folder (report.py sits next to vmbench)
  REPORT=$VMBENCH_HOME/report.py
  if [ -f "$REPORT" ] && need python3; then
    python3 -I "$REPORT" show "$OUT" || log "report.py failed; the raw results are still in $OUT"
  fi

  log "done. results: $OUT"
  log "  summary.tsv (median per metric), results.tsv (every value), status.tsv (OK/FAIL/SKIP per step), meta.json, info.txt, raw logs"
  grep -E 'FAIL' "$STATUS" | sed 's/^/  /'
  true
}
