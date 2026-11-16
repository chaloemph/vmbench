#!/usr/bin/env bash
# stages/nvme.sh - fio on several raw NVMe disks (NVME_DEVS), as a bare-metal acceptance checklist asks: first every
# disk at once (the total the machine can deliver), then each disk on its own, one after the other (the same tests on
# each disk, so a slow disk stands out). Only when asked (--with nvme); the disks are ERASED (CONFIRM_WIPE=yes).
# Sourced by lib/stages.sh, never executed. Functions (see lib/stages.sh for the contract):
#   stage_nvme_order, _default, _time, _note, _check, _run, _rounds
# Metric ids: nvme.* (the table is in lib/metrics.sh)
#
# Per-disk values are one results.tsv row per disk: the round column is the disk's index in NVME_DEVS, so report.py
# shows the median over the disks and a CV that says how alike they are. nvme-per-disk.tsv has the value of every disk
# by device name, nvme-devices.txt the model and firmware of each (no serial numbers). Raw fio output: nvme-*.json.

stage_nvme_order() { echo 35; }
stage_nvme_default() { echo no; }
stage_nvme_rounds() { nvme_dev_count; }   # one row per disk for the per-disk tests
stage_nvme_time() { echo "$(( 9 + 46 * $(nvme_dev_count) )) min"; }   # 9 min for the all-disk tests, about 46 min per disk
stage_nvme_note() { echo "needs NVME_DEVS=\"nvme1n1 nvme2n1\" CONFIRM_WIPE=yes (ERASES those disks)"; }

stage_nvme_check() {
  check_tools fio jq; nvme_devs_problems
}

# nvme_fio STEP OUTFILE fio-args...: one fio run with JSON output. The global options come first, then the
# --name/--filename pair(s) of the job(s), so one call can drive several disks at once.
nvme_fio() {
  local step=$1 out=$2; shift 2
  fio "$@" --output-format=json --output="$out" > /dev/null 2> "$out.err"
  local rc=$?; if [ $rc -ne 0 ] || [ ! -s "$out" ]; then bad nvme "fio $step" "exit $rc, see $(basename "$out").err"; return 1; fi
  ok nvme "fio $step"; return 0
}
nvme_jq() { jq -r "$1" "$2" 2>/dev/null; }
# nvme_rec ID VALUE DEV: record a per-disk value (ROUND is the disk index) and keep it by device name as well
nvme_rec() { rec "$1" "$2"; printf '%s\t%s\t%s\n' "$3" "$1" "$2" >> "$OUT/nvme-per-disk.tsv"; }
# nvme_describe DEV: model, firmware revision and size, no serial number
nvme_describe() {
  local d=$1 c; c=/sys/class/block/$(basename "$d")/device
  printf '%s: %s' "$d" "$(lsblk -dno MODEL,REV,SIZE,TRAN "$d" 2>/dev/null | tr -s ' ')"
  [ -r "$c/firmware_rev" ] && printf ' firmware=%s' "$(tr -d ' ' < "$c/firmware_rev")"
  echo
}

stage_nvme_run() {
  log "== nvme"
  need fio || { skip nvme fio "not installed"; return; }
  local devs=() d why n i b f qd run ramp
  while read -r d; do devs+=("$d"); done < <(nvme_dev_list)
  n=${#devs[@]}
  [ "$n" -gt 0 ] || { skip nvme all "NVME_DEVS is empty"; return; }
  for d in "${devs[@]}"; do   # checked again here: earlier stages may have run for hours
    why=$(raw_problem "$d"); [ -z "$why" ] || { bad nvme "raw device" "$why"; return; }
  done
  run=$(T 300 5); ramp=$(T 60 1)
  local G=(--direct=1 --ioengine=libaio --group_reporting)
  printf 'device\tid\tvalue\n' > "$OUT/nvme-per-disk.tsv"
  { echo "devices: $n"; for d in "${devs[@]}"; do nvme_describe "$d"; done; } > "$OUT/nvme-devices.txt"
  log "nvme: $n disk(s): ${devs[*]}"

  # every disk at once: one fio job per disk, the value is the total over the disks
  local jobs=()
  for d in "${devs[@]}"; do jobs+=(--name="$(basename "$d")" --filename="$d"); done
  f=$OUT/nvme-all-randread4k.json
  nvme_fio "all disks randread 4k" "$f" "${G[@]}" --rw=randread --bs=4k --iodepth=32 --numjobs=4 --time_based --runtime="$run" --ramp_time="$ramp" "${jobs[@]}" \
    && rec nvme.fio.randread-4k.qd32x4.all-disks "$(nvme_jq '[.jobs[].read.iops]|add|round' "$f")"
  f=$OUT/nvme-all-seqread1m.json
  nvme_fio "all disks seq read 1M" "$f" "${G[@]}" --rw=read --bs=1M --iodepth=16 --numjobs=1 --time_based --runtime="$(T 180 5)" "${jobs[@]}" \
    && rec nvme.fio.seq-read-1m.all-disks "$(nvme_jq '(([.jobs[].read.bw_bytes]|add)/1e7|round)/100' "$f")"

  # each disk on its own, in the order of NVME_DEVS; ROUND is the disk's index
  for i in $(seq 1 "$n"); do
    d=${devs[$((i - 1))]}; b=$(basename "$d"); ROUND=$i
    log "nvme disk $i/$n: $d"
    f=$OUT/nvme-$b-randwrite4k.json
    nvme_fio "$b randwrite 4k" "$f" "${G[@]}" --rw=randwrite --bs=4k --iodepth=32 --numjobs=4 --time_based --runtime="$(T 600 8)" --ramp_time="$ramp" --name=rw --filename="$d" \
      && nvme_rec nvme.fio.randwrite-4k.qd32x4.per-disk "$(nvme_jq '.jobs[0].write.iops|round' "$f")" "$d"
    f=$OUT/nvme-$b-lat.json
    nvme_fio "$b randread 4k qd1 latency" "$f" "${G[@]}" --rw=randread --bs=4k --iodepth=1 --numjobs=1 --time_based --runtime="$run" --percentile_list=95:99:99.9 --name=lat --filename="$d" && {
      nvme_rec nvme.fio.randread-4k.qd1.p99.per-disk "$(nvme_jq '.jobs[0].read.clat_ns.percentile["99.000000"]/1000' "$f")" "$d"
      nvme_rec nvme.fio.randread-4k.qd1.p999.per-disk "$(nvme_jq '.jobs[0].read.clat_ns.percentile["99.900000"]/1000' "$f")" "$d"; }
    f=$OUT/nvme-$b-randread4k.json
    nvme_fio "$b randread 4k" "$f" "${G[@]}" --rw=randread --bs=4k --iodepth=32 --numjobs=4 --time_based --runtime="$run" --ramp_time="$ramp" --name=rr --filename="$d" \
      && nvme_rec nvme.fio.randread-4k.qd32x4.per-disk "$(nvme_jq '.jobs[0].read.iops|round' "$f")" "$d"
    f=$OUT/nvme-$b-mix.json
    nvme_fio "$b mixed 70/30" "$f" "${G[@]}" --rw=randrw --rwmixread=70 --bs=4k --iodepth=32 --numjobs=4 --time_based --runtime="$run" --name=mix --filename="$d" && {
      nvme_rec nvme.fio.mixed-70-30-4k.read.per-disk "$(nvme_jq '.jobs[0].read.iops|round' "$f")" "$d"
      nvme_rec nvme.fio.mixed-70-30-4k.write.per-disk "$(nvme_jq '.jobs[0].write.iops|round' "$f")" "$d"; }
    f=$OUT/nvme-$b-sr.json
    nvme_fio "$b seq read 1M" "$f" "${G[@]}" --rw=read --bs=1M --iodepth=16 --numjobs=1 --time_based --runtime="$(T 180 5)" --name=sr --filename="$d" \
      && nvme_rec nvme.fio.seq-read-1m.per-disk "$(nvme_jq '.jobs[0].read.bw_bytes/1e6|round' "$f")" "$d"
    f=$OUT/nvme-$b-sw.json
    nvme_fio "$b seq write 1M" "$f" "${G[@]}" --rw=write --bs=1M --iodepth=16 --numjobs=1 --time_based --runtime="$(T 180 5)" --name=sw --filename="$d" \
      && nvme_rec nvme.fio.seq-write-1m.per-disk "$(nvme_jq '.jobs[0].write.bw_bytes/1e6|round' "$f")" "$d"
    for qd in 1 4 16 32 64 128; do
      f=$OUT/nvme-$b-qd$qd.json
      nvme_fio "$b randread 4k qd$qd" "$f" "${G[@]}" --rw=randread --bs=4k --iodepth="$qd" --numjobs=4 --time_based --runtime="$(T 120 4)" --name="qd$qd" --filename="$d" \
        && nvme_rec "nvme.fio.randread-4k.sweep-qd$qd.per-disk" "$(nvme_jq '.jobs[0].read.iops|round' "$f")" "$d"
    done
  done
  # shellcheck disable=SC2034  # ROUND is read by rec (lib/metrics.sh)
  ROUND=1
  log "nvme: per-disk values by device are in nvme-per-disk.tsv, the models and firmware in nvme-devices.txt"
}
