#!/usr/bin/env bash
# lib/status.sh - `vmbench status [DIR]`: is a run in progress, in which stage, for how long. Sourced, never executed.
#
#   cmd_status [DIR]   DIR is a result folder; without it the newest folder in $VMBENCH_RESULTS (default ~/bench-results).
#                      Exit codes: 0 shown (whatever the state), 2 no such folder or not a result folder.
#
# A run is "running" when meta.json has end_utc null and either the process that wrote .run.pid is alive or the
# tmux session in .session exists. With end_utc null and neither alive, the run was killed or crashed ("stopped").
# The current stage is the last "== <stage>" line of run.log, else the last stage in status.tsv.

# epoch_of UTC_TIMESTAMP: seconds since 1970 (GNU date), empty when it cannot be parsed
epoch_of() { date -u -d "$1" +%s 2>/dev/null; }

# human_duration SECONDS: 1h 02m 05s
human_duration() {
  local s=$1
  if [ "$s" -ge 3600 ]; then printf '%dh %02dm %02ds' $((s / 3600)) $((s % 3600 / 60)) $((s % 60))
  elif [ "$s" -ge 60 ]; then printf '%dm %02ds' $((s / 60)) $((s % 60))
  else printf '%ds' "$s"; fi
}

cmd_status() {
  local dir=${1:-} root=${VMBENCH_RESULTS:-$HOME/bench-results}
  [ $# -le 1 ] || die "status takes at most one folder, got '$2'"
  if [ -z "$dir" ]; then
    dir=$(ls -dt "$root"/*/ 2>/dev/null | head -1)
    [ -n "$dir" ] || die "no result folders in $root; give the folder: vmbench status DIR"
  fi
  dir=${dir%/}
  [ -d "$dir" ] || die "$dir is not a folder"
  [ -f "$dir/meta.json" ] || [ -f "$dir/.launch.sh" ] || die "$dir is not a vmbench result folder (no meta.json)"

  local start="" end="" label="" stages="" state session="" session_alive="" pid="" pid_alive="" stage="" step_counts="" last="" now elapsed text
  if [ -f "$dir/meta.json" ]; then
    # one python call reads everything; the fields are separated by | (not a tab: read would merge empty fields)
    IFS='|' read -r start end label stages < <(python3 -I - "$dir/meta.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
print("|".join(str(m.get(k) or "") if k != "stages" else " ".join(s for s in m.get("stages", []) if s != "info")
                for k in ("start_utc", "end_utc", "label", "stages")))
PY
) || true
  fi
  [ -f "$dir/.session" ] && session=$(head -1 "$dir/.session")
  if [ -n "$session" ] && need tmux && tmux has-session -t "=$session" 2>/dev/null; then session_alive=1; fi
  if [ -f "$dir/.run.pid" ]; then pid=$(head -1 "$dir/.run.pid"); [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && pid_alive=1; fi

  if [ ! -f "$dir/meta.json" ]; then
    if [ -n "$session_alive" ]; then state="starting (the tmux session is up, the run has not written meta.json yet)"
    else state="stopped before it started (no meta.json, the tmux session is gone; see run.log if there is one)"; fi
  elif [ -n "$end" ]; then state="finished"
  elif [ -n "$pid_alive" ] || [ -n "$session_alive" ]; then state="running"
  else state="stopped without finishing (end_utc is null and nothing is running: killed or crashed)"; fi

  [ -f "$dir/run.log" ] && stage=$(sed -n 's/^[0-9:]* == \([a-z]*\)$/\1/p' "$dir/run.log" | tail -1)
  if [ -z "$stage" ] && [ -f "$dir/status.tsv" ]; then stage=$(awk -F'\t' 'NR>1{s=$1} END{print s}' "$dir/status.tsv"); fi
  if [ -f "$dir/status.tsv" ]; then
    step_counts=$(awk -F'\t' 'NR>1{ if ($3=="OK") o++; else if ($3 ~ /^FAIL/) f++; else if ($3 ~ /^SKIP/) s++ }
      END{printf "%d OK, %d FAIL, %d SKIP", o, f, s}' "$dir/status.tsv")
  fi
  [ -f "$dir/run.log" ] && last=$(tail -1 "$dir/run.log")

  echo "folder:   $dir"
  [ -z "$label" ] || echo "label:    $label"
  echo "state:    $state"
  [ -z "$stages" ] || echo "stages:   $stages"
  case $state in
    running*) [ -z "$stage" ] || echo "stage:    $stage (now)" ;;
    *) [ -z "$stage" ] || echo "stage:    $stage (the last one that started)" ;;
  esac
  [ -z "$step_counts" ] || echo "steps:    $step_counts (status.tsv)"
  if [ -n "$start" ]; then
    now=$(date -u +%s); text=""
    if [ -n "$end" ]; then elapsed=$(( $(epoch_of "$end") - $(epoch_of "$start") )); text=" (start to end)"
    elif [ "$state" = running ]; then elapsed=$(( now - $(epoch_of "$start") )); text=" (since $start)"
    else elapsed=""; fi
    [ -z "$elapsed" ] || echo "elapsed:  $(human_duration "$elapsed")$text"
  fi
  [ -z "$session" ] || echo "session:  $session ($([ -n "$session_alive" ] && echo "alive: tmux attach -t $session" || echo "not running"))"
  [ -z "$last" ] || echo "last log: $last"
  [ ! -f "$dir/run.log" ] || echo "follow:   tail -f $dir/run.log"
  return 0
}
