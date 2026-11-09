#!/usr/bin/env bash
# lib/preflight.sh - pre-flight checks and the --list table. Sourced, never executed.
#
# A stage's own check lives in its stage file (stage_<name>_check) and calls the helpers below to add to PROBLEMS.
#
#   PROBLEMS            array of reasons the stage being checked cannot run
#   check_tools T...    add "T is not installed" for each missing tool
#   check_cpubench      add a problem when $CB/cpubench is missing
#   check_target        RAW_DEV safety, or 15 GB free in DATA_DIR
#   check_stage NAME    fill PROBLEMS by running stage_<NAME>_check
#   show_stages         print the --list table (also `vmbench list`)

# shellcheck source=lib/rawdev.sh
. "$VMBENCH_HOME/lib/rawdev.sh"

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
  if declare -F "stage_${1}_check" >/dev/null; then "stage_${1}_check"; fi
}

show_stages() {
  local s rows when time
  printf '%-7s %-12s %-8s %-12s %s\n' STAGE METRICS DEFAULT TIME READY
  for s in $ALL_STAGES; do
    when=$("stage_${s}_default"); time=$("stage_${s}_time")
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
  echo "TIME: cpu, mem, disk, web were measured on 8 vCPU VMs with an 8 GB test file; cpu, mem and web grow with the"
  echo "      rounds (--rounds N, now cpu $ROUNDS, mem $MEM_ROUNDS, web $WEB_ROUNDS), disk only with --disk-rounds N (now $DISK_ROUNDS)."
  echo "      pg and net come from the test durations in this script and have not been timed on a real run."
}
