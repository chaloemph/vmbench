#!/usr/bin/env bash
# stages/burnin.sh - stressapptest and fio verify, only when asked. Memory (stressapptest) and disk (fio random write
# with data verification) for BURNIN_HOURS, on a file, on RAW_DEV, or on every disk of NVME_DEVS at once.
# Errors are: fio exits (verification failures), stressapptest not passing, new error lines in the kernel log, and
# counters that grew during the run: EDAC memory errors (correctable and uncorrectable), the BMC event log (ipmitool
# sel), and the NVMe media-error and error-log counters of the tested disks (nvme smart-log). Every count is in
# burnin-checks.txt with the values before and after.
# Sourced by lib/stages.sh, never executed. Functions (see lib/stages.sh for the contract):
#   stage_burnin_order, _default, _time, _note, _check, _run
# Metric ids: burnin.* (the table is in lib/metrics.sh)

stage_burnin_order() { echo 70; }
stage_burnin_default() { echo no; }
stage_burnin_time() { echo "$BURNIN_HOURS h"; }
stage_burnin_note() { echo "48 hours unless --hours says otherwise; RAW_DEV or NVME_DEVS for whole disks"; }

stage_burnin_check() {
  check_tools fio stressapptest
  if [ -n "$RAW_DEV" ] && [ -n "${NVME_DEVS:-}" ]; then PROBLEMS+=("set RAW_DEV or NVME_DEVS for the burn-in, not both")
  elif [ -n "${NVME_DEVS:-}" ]; then nvme_devs_problems
  else check_target; fi
}

# burnin_counters FILE DEV...: the error counters that must not grow during the burn-in
burnin_counters() {
  local f=$1 d; shift
  {
    printf 'edac_ce %s\n' "$(cat /sys/devices/system/edac/mc/mc*/ce_count 2>/dev/null | awk '{s+=$1} END{print s+0}')"
    printf 'edac_ue %s\n' "$(cat /sys/devices/system/edac/mc/mc*/ue_count 2>/dev/null | awk '{s+=$1} END{print s+0}')"
    if need ipmitool; then printf 'ipmi_sel %s\n' "$(as_root ipmitool sel list 2>/dev/null | grep -c '|')"; fi
    if need nvme; then
      for d in "$@"; do case $d in /dev/nvme*) ;; *) continue ;; esac
        as_root nvme smart-log "$d" 2>/dev/null | awk -v d="$(basename "$d")" '/^(media_errors|num_err_log_entries)/{gsub(",", "", $NF); print d "_" $1, $NF}'
      done
    fi
  } > "$f"
}

stage_burnin_run() {
  log "== burnin"
  need fio && need stressapptest || { skip burnin all "fio or stressapptest missing"; return; }
  local secs jobs=() sz=() devs=() d why
  secs=$(awk -v h="$BURNIN_HOURS" 'BEGIN{printf "%d", h*3600}')
  [ "$QUICK" = 1 ] && secs=40
  if [ -n "$RAW_DEV" ]; then
    why=$(raw_problem); [ -z "$why" ] || { bad burnin "raw device" "$why"; return; }
    devs=("$RAW_DEV"); jobs=(--name=burn --filename="$RAW_DEV")
  elif [ -n "${NVME_DEVS:-}" ]; then
    while read -r d; do devs+=("$d"); done < <(nvme_dev_list)
    for d in "${devs[@]}"; do why=$(raw_problem "$d"); [ -z "$why" ] || { bad burnin "raw device" "$why"; return; }; done
    for d in "${devs[@]}"; do jobs+=(--name="burn-$(basename "$d")" --filename="$d"); done
  else jobs=(--name=burn --filename="$DATA_DIR/burn.dat"); sz=(--size="$FIO_SIZE"); fi
  local mb=$((RAM_GB * 1024 * 70 / 100)); [ "$QUICK" = 1 ] && mb=256
  dmesg -T > "$OUT/dmesg-before.txt" 2>/dev/null
  burnin_counters "$OUT/burnin-counters-before.txt" "${devs[@]+"${devs[@]}"}"
  log "burnin: ${secs}s, stressapptest ${mb} MB, fio verify on ${devs[*]:-$DATA_DIR/burn.dat}"
  stressapptest -s "$secs" -M "$mb" -W > "$OUT/stressapptest.log" 2>&1 &
  local sapp=$! end=$((SECONDS + secs)) errs=0 rounds=0 rc
  while [ "$SECONDS" -lt "$end" ]; do
    local left=$((end - SECONDS)); [ "$left" -gt 3600 ] && left=3600
    fio "${sz[@]+"${sz[@]}"}" --direct=1 --ioengine=libaio --rw=randwrite --bs=4k --iodepth=32 \
      --verify=crc32c --verify_backlog=1000000 --verify_fatal=1 --time_based --runtime="$left" "${jobs[@]}" > "$OUT/burn-fio-$rounds.log" 2>&1
    rc=$?; rounds=$((rounds + 1))
    if [ $rc -ne 0 ]; then errs=$((errs + 1)); echo "$(date -Is) fio exit $rc (round $rounds)" >> "$OUT/burnin.err"; fi
  done
  wait "$sapp"; local sapprc=$?
  grep -q 'Status: PASS' "$OUT/stressapptest.log" || { errs=$((errs + 1)); echo "stressapptest did not report PASS (exit $sapprc)" >> "$OUT/burnin.err"; }
  dmesg -T 2>/dev/null | grep -iE 'error|mce|i/o' > "$OUT/dmesg-errors.txt"
  local derr; derr=$(diff <(grep -iE 'error|mce|i/o' "$OUT/dmesg-before.txt") "$OUT/dmesg-errors.txt" | grep -c '^>')
  errs=$((errs + derr))
  # counters after the run: every one that grew counts as errors, by how much it grew
  burnin_counters "$OUT/burnin-counters-after.txt" "${devs[@]+"${devs[@]}"}"
  local grew
  grew=$(awk 'NR==FNR{b[$1]=$2; next} ($1 in b) && $2+0 > b[$1]+0 {printf "%s +%d (%s -> %s)\n", $1, $2-b[$1], b[$1], $2; s+=$2-b[$1]} END{printf "total %d\n", s+0}' \
    "$OUT/burnin-counters-before.txt" "$OUT/burnin-counters-after.txt")
  {
    echo "fio exits / stressapptest: $((errs - derr)) error(s), see burnin.err"; echo "new kernel log error lines: $derr (dmesg-errors.txt)"
    echo "counters before:"; sed 's/^/  /' "$OUT/burnin-counters-before.txt"
    echo "counters after:"; sed 's/^/  /' "$OUT/burnin-counters-after.txt"
    echo "counters that grew:"; sed 's/^/  /' <<<"$grew"
    if need ipmitool; then echo "--- ipmitool sel list (after)"; as_root ipmitool sel list 2>&1 | tail -50; fi
    if need ras-mc-ctl; then echo "--- ras-mc-ctl --summary"; as_root ras-mc-ctl --summary 2>&1; fi
    if need edac-util; then echo "--- edac-util -v"; edac-util -v 2>&1; fi
  } > "$OUT/burnin-checks.txt"
  local cerr; cerr=$(awk '$1=="total"{print $2}' <<<"$grew")
  errs=$((errs + ${cerr:-0}))
  rec burnin.errors "$errs" "$secs"; ok burnin "rounds=$rounds errors=$errs (counters +${cerr:-0})"
  [ -z "$RAW_DEV" ] && [ -z "${NVME_DEVS:-}" ] && rm -f "$DATA_DIR/burn.dat"
  log "burnin: $errs error(s); the breakdown is in burnin-checks.txt"
}
