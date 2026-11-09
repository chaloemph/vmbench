#!/usr/bin/env bash
# lib/stages.sh - finds and loads the stages. Sourced, never executed.
#
# Every stages/<name>.sh is one stage. To add a stage, add one file there: nothing else needs to change.
# A stage file defines these functions (tests/test_stages.sh checks that every file does):
#
#   stage_<name>_order     print a number; stages run, and are listed, in ascending order (info is 0)
#   stage_<name>_default   print yes (runs without --with), no (only when asked) or always (info)
#   stage_<name>_time      print the typical duration shown by --list, for example "14 min"
#   stage_<name>_note      print what the stage needs, shown in --help (may print nothing)
#   stage_<name>_check     add a line to PROBLEMS for everything that stops the stage from running (see lib/preflight.sh)
#   stage_<name>_run       run the stage; record results with rec and steps with ok/bad/skip
#   stage_<name>_rounds    optional: print how many times the stage repeats its measurements in this run. --list scales
#                          the duration with it and meta.json records it (a stage without it is a single pass)
#
# After load_stages:
#   ALL_STAGES       space separated names of the selectable stages, in order (info is not in it)
#   DEFAULT_STAGES   the ones that run by default

load_stages() {
  local f name n list=""
  ALL_STAGES="" DEFAULT_STAGES=""
  for f in "$VMBENCH_HOME"/stages/*.sh; do
    [ -e "$f" ] || continue
    name=$(basename "$f" .sh)
    # shellcheck source=/dev/null
    . "$f"
    n=$("stage_${name}_order")
    list="$list$n $name"$'\n'
  done
  while read -r n name; do
    [ -n "$name" ] || continue
    [ "$name" = info ] && continue
    ALL_STAGES="$ALL_STAGES $name"
    [ "$("stage_${name}_default")" = yes ] && DEFAULT_STAGES="$DEFAULT_STAGES $name"
  done < <(printf '%s' "$list" | sort -n -s -k1,1)
  ALL_STAGES=${ALL_STAGES# } DEFAULT_STAGES=${DEFAULT_STAGES# }
}

# rounds_time MIN_PER_ROUND ROUNDS: a duration text such as "9 min", for stage_<name>_time of a stage that repeats
rounds_time() { echo "$(( $1 * $2 )) min"; }

# want NAME: true when the stage is selected (STAGES holds the selected names, set by `vmbench run`)
want() { case "$STAGES" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# stage_usage_rows: the "name ids name.* note" lines of --help, built from the stage files
stage_usage_rows() {
  local s note
  for s in $ALL_STAGES; do
    note=$("stage_${s}_note")
    if [ -n "$note" ]; then printf '  %-7s ids %-14s %s\n' "$s" "$s.*" "$note"
    else printf '  %-7s ids %s\n' "$s" "$s.*"; fi
  done
}
