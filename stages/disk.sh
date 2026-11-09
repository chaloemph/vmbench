#!/usr/bin/env bash
# stages/disk.sh - fio random and sequential I/O, queue-depth sweep, WAL-style fdatasync latency
# DISK_ROUNDS (default 1): round 1 is the whole sequence. Rounds 2..N repeat only the steady-state read/mix latency and
# IOPS tests and the WAL test (about 20 min each); the fill, the steady-state random write, the sequential tests, the
# queue-depth sweep and the DB-style tests run once. docs/tests.md ("Rounds") says why.
# Sourced by lib/stages.sh, never executed. Functions (see lib/stages.sh for the contract):
#   stage_disk_order, _default, _time, _note, _check, _run
# Metric ids: disk.* (the table is in lib/metrics.sh)

stage_disk_order() { echo 30; }
stage_disk_default() { echo yes; }
stage_disk_rounds() { echo "$DISK_ROUNDS"; }
stage_disk_time() { echo "$(( 71 + 20 * (${DISK_ROUNDS:-1} - 1) )) min"; }   # 71 min, plus about 20 min for every extra round
stage_disk_note() { echo "default"; }

stage_disk_check() {
  check_tools fio jq; check_target
}

fio_run() { # name outfile args...
  local name=$1 out=$2; shift 2
  fio --name="$name" "$@" --output-format=json --output="$out" > /dev/null 2> "$out.err"
  local rc=$?; if [ $rc -ne 0 ] || [ ! -s "$out" ]; then bad disk "fio $name" "exit $rc, see $(basename "$out").err"; return 1; fi
  ok disk "fio $name"; return 0
}
# The tests that DISK_ROUNDS repeats; they read D_TGT, D_SZ, D_COMMON, D_RUN and D_RAMP, set by stage_disk_run.
# Round 1 keeps the plain file names (as in older versions), later rounds add -rN.
disk_rep_name() { if [ "$ROUND" = 1 ]; then echo "$1"; else echo "${1%.json}-r$ROUND.json"; fi; }
disk_lat() {
  local f; f=$OUT/$(disk_rep_name fio-34-lat.json)
  fio_run lat "$f" "${D_TGT[@]}" "${D_SZ[@]}" "${D_COMMON[@]}" --rw=randread --bs=4k --iodepth=1 --numjobs=1 \
    --time_based --runtime="$D_RUN" --ramp_time="$D_RAMP" --percentile_list=95:99:99.9 && {
    rec disk.fio.randread-4k.qd1.p99 "$(J '.jobs[0].read.clat_ns.percentile["99.000000"]/1000' "$f")"
    rec disk.fio.randread-4k.qd1.p999 "$(J '.jobs[0].read.clat_ns.percentile["99.900000"]/1000' "$f")"; }
}
disk_rr() {
  local f; f=$OUT/$(disk_rep_name fio-35-rr.json)
  fio_run rr "$f" "${D_TGT[@]}" "${D_SZ[@]}" "${D_COMMON[@]}" --rw=randread --bs=4k --iodepth=32 --numjobs=4 \
    --time_based --runtime="$D_RUN" --ramp_time="$D_RAMP" --group_reporting && rec disk.fio.randread-4k.qd32x4 "$(J '.jobs[0].read.iops|round' "$f")"
}
disk_mix() {
  local f; f=$OUT/$(disk_rep_name fio-36-mix.json)
  fio_run mix "$f" "${D_TGT[@]}" "${D_SZ[@]}" "${D_COMMON[@]}" --rw=randrw --rwmixread=70 --bs=4k --iodepth=32 --numjobs=4 \
    --time_based --runtime="$D_RUN" --ramp_time="$D_RAMP" --group_reporting && {
    rec disk.fio.mixed-70-30-4k.read "$(J '.jobs[0].read.iops|round' "$f")"
    rec disk.fio.mixed-70-30-4k.write "$(J '.jobs[0].write.iops|round' "$f")"; }
}
disk_wal() { # WAL commit latency (8k write + fdatasync, QD1)
  local f; f=$OUT/$(disk_rep_name fio-44-wal.json)
  fio_run wal "$f" --directory="$WAL_DIR" --size="$(T 1g 64m)" --rw=write --bs=8k --ioengine=sync --fdatasync=1 --time_based --runtime="$D_RUN" && {
    rec disk.wal.fdatasync.avg "$(J '.jobs[0].sync.lat_ns.mean/1e6' "$f")"
    rec disk.wal.fdatasync.p99 "$(J '.jobs[0].sync.lat_ns.percentile["99.000000"]/1e6' "$f")"
    rec disk.wal.commit-iops.qd1 "$(J '.jobs[0].write.iops|round' "$f")"; }
  rm -f "$WAL_DIR"/wal.*
}
J() { jq -r "$1" "$2" 2>/dev/null; }

stage_disk_run() {
  log "== disk"
  need fio || { skip disk fio "not installed"; return; }
  local run ramp r
  D_COMMON=(--direct=1 --ioengine=libaio)
  run=$(T 300 5); ramp=$(T 60 1); D_RUN=$run; D_RAMP=$ramp
  if [ -n "$RAW_DEV" ]; then
    local why; why=$(raw_problem)   # checked again here: earlier stages may have run for a long time
    [ -z "$why" ] || { bad disk "raw device" "$why"; return; }
    D_TGT=(--filename="$RAW_DEV"); D_SZ=(--size=100%)
  else
    local free; free=$(df -BG --output=avail "$DATA_DIR" | tail -1 | tr -dc 0-9)
    [ "$free" -ge 15 ] || { bad disk "free space" "only ${free} GB free in $DATA_DIR"; return; }
    D_TGT=(--filename="$DATA_DIR/fio.dat"); D_SZ=(--size="$FIO_SIZE")
  fi
  # fill, then 4K random write to steady state
  fio_run pre "$OUT/fio-pre.json" "${D_TGT[@]}" "${D_SZ[@]}" "${D_COMMON[@]}" --rw=write --bs=1M --iodepth=16 && rec info.fio.fill-write-1m "$(J '.jobs[0].write.bw_bytes/1e6|round' "$OUT/fio-pre.json")"
  fio_run rw "$OUT/fio-33-randwrite4k.json" "${D_TGT[@]}" "${D_SZ[@]}" "${D_COMMON[@]}" --rw=randwrite --bs=4k --iodepth=32 --numjobs=4 \
    --time_based --runtime="$(T 600 8)" --ramp_time="$ramp" --steadystate=iops_slope:1% --steadystate_duration="$(T 180 3)" --group_reporting && {
    rec disk.fio.randwrite-4k.qd32x4 "$(J '.jobs[0].write.iops|round' "$OUT/fio-33-randwrite4k.json")"
    rec disk.fio.randwrite-4k.steadystate "$(J '.jobs[0].steadystate.attained // 0' "$OUT/fio-33-randwrite4k.json")"; }
  disk_lat
  disk_rr
  disk_mix
  fio_run sw "$OUT/fio-37-sw.json" "${D_TGT[@]}" "${D_SZ[@]}" "${D_COMMON[@]}" --rw=write --bs=1M --iodepth=16 --time_based --runtime="$(T 180 5)" --ramp_time="$(T 30 1)" \
    && rec disk.fio.seq-write-1m "$(J '.jobs[0].write.bw_bytes/1e6|round' "$OUT/fio-37-sw.json")"
  fio_run sr "$OUT/fio-37-sr.json" "${D_TGT[@]}" "${D_SZ[@]}" "${D_COMMON[@]}" --rw=read --bs=1M --iodepth=16 --time_based --runtime="$(T 180 5)" --ramp_time="$(T 30 1)" \
    && rec disk.fio.seq-read-1m "$(J '.jobs[0].read.bw_bytes/1e6|round' "$OUT/fio-37-sr.json")"
  local qd
  for qd in 1 4 16 32 64 128; do
    fio_run "qd$qd" "$OUT/fio-38-qd$qd.json" "${D_TGT[@]}" "${D_SZ[@]}" "${D_COMMON[@]}" --rw=randread --bs=4k --iodepth="$qd" --numjobs=1 \
      --time_based --runtime="$(T 120 4)" --ramp_time="$(T 30 1)" && rec "disk.fio.randread-4k.sweep-qd$qd" "$(J '.jobs[0].read.iops|round' "$OUT/fio-38-qd$qd.json")"
  done
  # rounds 2..N: the steady-state tests again, on the file that is already filled
  for r in $(seq 2 "$DISK_ROUNDS"); do
    ROUND=$r; log "disk round $r/$DISK_ROUNDS (read latency, random read, 70/30 mix)"
    disk_lat; disk_rr; disk_mix
  done
  ROUND=1
  [ -z "$RAW_DEV" ] && rm -f "$DATA_DIR/fio.dat"

  # DB-style 8k jobs on files in DB_DIR
  mkdir -p "$DB_DIR" "$WAL_DIR"
  local fsz; fsz=$(T 2g 64m)
  fio_run randwrite8k "$OUT/fio-40.json" --directory="$DB_DIR" --size="$fsz" "${D_COMMON[@]}" --rw=randwrite --bs=8k --iodepth=32 --numjobs=4 --time_based --runtime="$run" --ramp_time="$ramp" --group_reporting \
    && rec disk.fio.db-randwrite-8k "$(J '.jobs[0].write.iops|round' "$OUT/fio-40.json")"
  fio_run randrw70 "$OUT/fio-41.json" --directory="$DB_DIR" --size="$fsz" "${D_COMMON[@]}" --rw=randrw --rwmixread=70 --bs=8k --iodepth=32 --numjobs=4 --time_based --runtime="$run" --ramp_time="$ramp" --group_reporting && {
    rec disk.fio.db-randrw-8k.read "$(J '.jobs[0].read.iops|round' "$OUT/fio-41.json")"
    rec disk.fio.db-randrw-8k.write "$(J '.jobs[0].write.iops|round' "$OUT/fio-41.json")"; }
  fio_run seqwrite1m "$OUT/fio-42.json" --directory="$DB_DIR" --size="$(T 8g 128m)" "${D_COMMON[@]}" --rw=write --bs=1M --iodepth=16 --numjobs=1 --time_based --runtime="$(T 180 5)" --ramp_time="$(T 30 1)" \
    && rec disk.fio.db-seqwrite-1m "$(J '.jobs[0].write.bw_bytes/1e6|round' "$OUT/fio-42.json")"
  fio_run randread8k "$OUT/fio-43.json" --directory="$DB_DIR" --size="$fsz" "${D_COMMON[@]}" --rw=randread --bs=8k --iodepth=32 --numjobs=4 --time_based --runtime="$run" --ramp_time="$ramp" --group_reporting \
    && rec disk.fio.db-randread-8k "$(J '.jobs[0].read.iops|round' "$OUT/fio-43.json")"
  rm -f "$DB_DIR"/randwrite8k.* "$DB_DIR"/randrw70.* "$DB_DIR"/seqwrite1m.* "$DB_DIR"/randread8k.*
  disk_wal
  for r in $(seq 2 "$DISK_ROUNDS"); do
    ROUND=$r; log "disk round $r/$DISK_ROUNDS (WAL fdatasync)"
    disk_wal
  done
  # shellcheck disable=SC2034  # ROUND is read by rec (lib/metrics.sh)
  ROUND=1
}
