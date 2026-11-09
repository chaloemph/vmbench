#!/usr/bin/env bash
# lib/meta.sh - meta.json: what ran and how, without host names or addresses (only LABEL). Sourced, never executed.
# Written at the start and again at the end of a run; a file whose end_utc is null belongs to a run that did not finish.
#
#   write_meta [END_UTC]   needs OUT, CB, LABEL, STAGES, QUICK, ROUNDS, START_UTC, NPROC, RAM_GB
#
# "rounds" is the cpu repeat count (kept for older readers); "rounds_by_stage" has the count of every selected stage
# that repeats (a stage file's stage_<name>_rounds).

write_meta() { # write_meta [END_UTC]
  need python3 || return 0
  local s by=""
  for s in $ALL_STAGES; do
    want "$s" && declare -F "stage_${s}_rounds" >/dev/null && by="$by $s=$("stage_${s}_rounds")"
  done
  local cbv=""; [ -x "$CB/cpubench" ] && cbv=$("$CB/cpubench" version 2>/dev/null | head -1)
  python3 -I - "$OUT/meta.json" "$(vmbench_version)" "$cbv" "$LABEL" "$STAGES" "$QUICK" "$ROUNDS" \
    "$START_UTC" "${1:-}" "$(uname -m)" "$NPROC" "$RAM_GB" "$by" <<'PY'
import json, os, sys
(path, ver, cbv, label, stages, quick, rounds, start, end, arch, nproc, ram, by) = sys.argv[1:]
meta = {"schema": 1, "vmbench_version": ver, "cpubench_version": cbv or None, "label": label,
        "stages": stages.split(), "quick": quick == "1", "rounds": int(rounds),
        "rounds_by_stage": {k: int(v) for k, v in (p.split("=") for p in by.split())},
        "start_utc": start, "end_utc": end or None, "arch": arch, "nproc": int(nproc), "ram_gb": int(ram)}
with open(path + ".tmp", "w") as f:
    json.dump(meta, f, indent=2)
    f.write("\n")
os.replace(path + ".tmp", path)
PY
}
