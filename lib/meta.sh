#!/usr/bin/env bash
# lib/meta.sh - meta.json: what ran and how, without host names or addresses (only LABEL). Sourced, never executed.
# Written at the start and again at the end of a run; a file whose end_utc is null belongs to a run that did not finish.
#
#   write_meta [END_UTC]   needs OUT, CB, LABEL, STAGES, QUICK, ROUNDS, START_UTC, NPROC, RAM_GB

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
