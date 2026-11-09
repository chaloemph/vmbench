#!/usr/bin/env bash
# stages/burnin.sh - stressapptest and fio verify, only when asked
# Sourced by lib/stages.sh, never executed. Functions (see lib/stages.sh for the contract):
#   stage_burnin_order, _default, _time, _note, _check, _run
# Metric ids: burnin.* (the table is in lib/metrics.sh)

stage_burnin_order() { echo 70; }
stage_burnin_default() { echo no; }
stage_burnin_time() { echo "$BURNIN_HOURS h"; }
stage_burnin_note() { echo "48 hours unless --hours says otherwise"; }

stage_burnin_check() {
  check_tools fio stressapptest; check_target
}

stage_burnin_run() {
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
