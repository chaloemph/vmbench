#!/usr/bin/env bash
# Tests for the bare-metal additions: NVME_DEVS parsing and its pre-flight refusals, the nvme stage (every disk at
# once, then one row per disk), the sustain stage with and without turbostat and a BMC, the burn-in error counters,
# hardware.txt, and report.py with the new sections. Everything runs with stub tools on PATH (fio, stress-ng,
# turbostat, ipmitool, nvme, stressapptest, sudo, lsblk; dpkg, so that a real lmbench is never run), so no benchmark
# tool, root or hardware is needed.
# Usage: bash tests/test_hw.sh
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT=$PWD
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
check() { # name, ok (0 = pass), details...
  local name=$1 ok=$2; shift 2
  if [ "$ok" = 0 ]; then pass=$((pass + 1)); printf 'ok   %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; [ $# -gt 0 ] && printf '       %s\n' "$@"; fi
}
count() { grep -c -P "$1" <<<"$2" || true; }
mkdir -p "$TMP/home" "$TMP/stubs"
run() { OUTPUT=$(HOME=$TMP/home LABEL=lbl OUT=$TMP/out DATA_DIR=$TMP/data CB=$TMP/no-cpubench PEER="" timeout 30 "$@" 2>&1); RC=$?; }
expect_fail() { # name, message part, command...
  local name=$1 msg=$2; shift 2
  run "$@"
  if [ "$RC" = 2 ] && [[ $OUTPUT == *"$msg"* ]]; then check "$name" 0
  else check "$name" 1 "rc=$RC wanted exit 2 and '$msg'" "got: ${OUTPUT:0:300}"; fi
}

# --- NVME_DEVS: parsing and the pre-flight (nothing may run)
rm -rf "$TMP/out"
expect_fail "nvme without NVME_DEVS"                 'set NVME_DEVS="nvme1n1 nvme2n1"'          bash "$ROOT/vmbench" run --only nvme
expect_fail "nvme without CONFIRM_WIPE"              "/dev/null needs CONFIRM_WIPE=yes"         env NVME_DEVS=null bash "$ROOT/vmbench" run --only nvme
expect_fail "nvme with a non-block device"           "/dev/null is not a block device"          env NVME_DEVS=/dev/null CONFIRM_WIPE=yes bash "$ROOT/vmbench" run --only nvme
expect_fail "nvme with a device listed twice"        "/dev/null is listed twice"                env NVME_DEVS="null,/dev/null" CONFIRM_WIPE=yes bash "$ROOT/vmbench" run --only nvme
expect_fail "burnin with RAW_DEV and NVME_DEVS"      "not both"                                  env RAW_DEV=/dev/null NVME_DEVS=null CONFIRM_WIPE=yes bash "$ROOT/vmbench" run --only burnin
expect_fail "SUSTAIN_MINUTES=0"                      "SUSTAIN_MINUTES needs a whole number"     env SUSTAIN_MINUTES=0 bash "$ROOT/vmbench" run --only sustain
expect_fail "TJMAX=hot"                              "TJMAX needs a whole number"               env TJMAX=hot bash "$ROOT/vmbench" run --only sustain
[ ! -e "$TMP/out" ] && check "a refused run leaves no result folder" 0 || check "a refused run leaves no result folder" 1
devs=$(NVME_DEVS="nvme1n1, /dev/nvme2n1 sdb" bash -c '. "$1/lib/common.sh"; . "$1/lib/rawdev.sh"; nvme_dev_list | paste -sd" "; nvme_dev_count' _ "$ROOT")
[ "$devs" = $'/dev/nvme1n1 /dev/nvme2n1 /dev/sdb\n3' ] && check "nvme_dev_list accepts names and paths, commas and spaces" 0 || check "nvme_dev_list accepts names and paths, commas and spaces" 1 "got: $devs"
n=$(bash -c '. "$1/lib/common.sh"; . "$1/lib/rawdev.sh"; nvme_dev_count' _ "$ROOT")
[ "$n" = 0 ] && check "nvme_dev_count is 0 without NVME_DEVS" 0 || check "nvme_dev_count is 0 without NVME_DEVS" 1 "got: $n"

# --list: the time of nvme follows the disk count, sustain the minutes
OUTPUT=$(HOME=$TMP/home CB=$TMP/x NVME_DEVS="a b c" bash "$ROOT/vmbench" list 2>&1)
t=$(awk '$1=="nvme"{print $4, $5}' <<<"$OUTPUT"); [ "$t" = "147 min" ] && check "list: nvme with 3 disks is 9 + 3 x 46 min" 0 || check "list: nvme with 3 disks is 9 + 3 x 46 min" 1 "got '$t'"
t=$(awk '$1=="sustain"{print $4, $5}' <<<"$OUTPUT"); [ "$t" = "47 min" ] && check "list: sustain default is 30 + 15 + 2 min" 0 || check "list: sustain default is 30 + 15 + 2 min" 1 "got '$t'"
OUTPUT=$(HOME=$TMP/home CB=$TMP/x SUSTAIN_MINUTES=10 SUSTAIN_50_MINUTES=5 bash "$ROOT/vmbench" list 2>&1)
t=$(awk '$1=="sustain"{print $4, $5}' <<<"$OUTPUT"); [ "$t" = "17 min" ] && check "list: SUSTAIN_MINUTES and SUSTAIN_50_MINUTES change the time" 0 || check "list: SUSTAIN_MINUTES and SUSTAIN_50_MINUTES change the time" 1 "got '$t'"
# whatever else this machine lacks (fio, stress-ng), the nvme stage lists the missing devices among its problems
nv=$(awk '$1=="nvme"{p=1; print; next} p && /^ {20,}/{print; next} {p=0}' <<<"$OUTPUT")
grep -q 'no devices: set NVME_DEVS=' <<<"$nv" && grep -qE '^sustain .*no: ' <<<"$OUTPUT" && check "list: nvme says it needs NVME_DEVS, sustain is not ready without its tools" 0 \
  || check "list: nvme says it needs NVME_DEVS, sustain is not ready without its tools" 1 "$OUTPUT"

# --- stub tools. fio writes a JSON with one job per --name it was given (so totals over disks can be checked).
cat > "$TMP/stubs/fio" <<'STUB'
#!/usr/bin/env bash
n=0; for a in "$@"; do case $a in --output=*) out=${a#--output=} ;; --name=*) n=$((n + 1)) ;; esac; done
[ -n "${FIO_LOG:-}" ] && printf '%s\n' "$*" >> "$FIO_LOG"
job='{"read":{"iops":1000,"bw_bytes":2000000000,"clat_ns":{"percentile":{"99.000000":100000,"99.900000":200000}}},"write":{"iops":500,"bw_bytes":1000000000}}'
jobs=$job; for ((i = 2; i <= n; i++)); do jobs="$jobs,$job"; done
[ -n "${out:-}" ] && echo "{\"jobs\":[$jobs]}" > "$out"
sleep "${FIO_SLEEP:-0}"
exit "${FIO_RC:-0}"
STUB
cat > "$TMP/stubs/stress-ng" <<'STUB'
#!/usr/bin/env bash
t=0; while [ $# -gt 0 ]; do [ "$1" = --timeout ] && t=$2; shift; done
[ -n "${STRESS_LOG:-}" ] && printf 'stress-ng %s\n' "$t" >> "$STRESS_LOG"
sleep "$t"
STUB
cat > "$TMP/stubs/turbostat" <<'STUB'
#!/usr/bin/env bash
[ "${TURBOSTAT_OK:-1}" = 1 ] || { echo "turbostat: no /dev/cpu/0/msr" >&2; exit 1; }
n=1; iv=1; while [ $# -gt 0 ]; do case $1 in --num_iterations) n=$2; shift ;; --interval) iv=$2; shift ;; esac; shift; done
echo "cpu0: MSR_IA32_TEMPERATURE_TARGET: 0x00641400 (100 C) (100 default - 0 offset)" >&2
# the columns in turbostat's own order, not the --show order; temperature rises, the clock settles
printf 'Busy%%\tBzy_MHz\tPkgTmp\tPkgWatt\n'
for ((i = 1; i <= n; i++)); do sleep "$iv"; printf '99.90\t%d\t%d\t%s\n' $((3600 - i * 100 > 3000 ? 3600 - i * 100 : 3000)) $((60 + i)) "150.5"; done
STUB
cat > "$TMP/stubs/ipmitool" <<'STUB'
#!/usr/bin/env bash
[ "${IPMI_OK:-1}" = 1 ] || { echo "Could not open device at /dev/ipmi0" >&2; exit 1; }
case "$*" in
  "dcmi power reading") echo "    Instantaneous power reading:                   ${IPMI_WATTS:-250} Watts" ;;
  "sdr type temperature") echo "Inlet Temp       | 04h | ok  |  7.1 | 24 degrees C"; echo "CPU1 Temp        | 05h | ok  |  3.1 | 71 degrees C" ;;
  "sdr type fan") echo "FAN1             | 30h | ok  | 29.1 | 5040 RPM"; echo "FAN2             | 31h | ok  | 29.2 | 6120 RPM" ;;
  "sel list") for ((i = 1; i <= ${IPMI_SEL:-2}; i++)); do echo "   $i | 01/01/2000 | 00:00:00 | Event | Asserted"; done ;;
  "mc info") echo "Firmware Revision         : 1.23" ;;
esac
STUB
cat > "$TMP/stubs/nvme" <<'STUB'
#!/usr/bin/env bash
case "$1" in smart-log) printf 'media_errors                        : %s\nnum_err_log_entries                 : %s\n' "${NVME_MEDIA:-0}" "${NVME_ERRLOG:-0}" ;; esac
STUB
cat > "$TMP/stubs/stressapptest" <<'STUB'
#!/usr/bin/env bash
sleep 1; echo "Status: PASS - please verify no corrected errors"
STUB
cat > "$TMP/stubs/sudo" <<'STUB'
#!/usr/bin/env bash
[ "$1" = -n ] && shift
exec "$@"
STUB
cat > "$TMP/stubs/lsblk" <<'STUB'
#!/usr/bin/env bash
echo "STUBMODEL 1.0 1.8T nvme"
STUB
cat > "$TMP/stubs/dmesg" <<'STUB'
#!/usr/bin/env bash
echo "[Mon Jan  1 00:00:00 2000] nothing"
STUB
cat > "$TMP/stubs/dpkg" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$TMP"/stubs/*

# stage_run STAGE env...: run stage_<STAGE>_run with the stubs on PATH and the raw-device check stubbed out (a test
# cannot make block devices), print results.tsv and status.tsv
stage_run() {
  local s=$1 extra=${EXTRA_PATH:-}; shift
  env PATH="${extra:+$extra:}$TMP/stubs:$PATH" "$@" bash -c '
    VMBENCH_HOME=$1; s=$2; OUT=$3
    for f in common metrics stream hw rawdev stages; do . "$VMBENCH_HOME/lib/$f.sh"; done
    . "$VMBENCH_HOME/stages/$s.sh"
    raw_problem() { :; }
    # the kernel clock differs per machine (x86 has cpu MHz, many ARM VMs have nothing): CPU_MHZ_STUB fixes it, "none" = no source
    [ -z "${CPU_MHZ_STUB+x}" ] || cpu_mhz_now() { [ "$CPU_MHZ_STUB" = none ] || printf %s "$CPU_MHZ_STUB"; }
    RES=$OUT/results.tsv; STATUS=$OUT/status.tsv; : > "$STATUS"; NPROC=4; RAM_GB=8; QUICK=${QUICK:-1}; LABEL=lbl; DATA_DIR=$OUT/data; DB_DIR=$DATA_DIR; WAL_DIR=$DATA_DIR
    FIO_SIZE=64M; RAW_DEV=${RAW_DEV:-}; NVME_DEVS=${NVME_DEVS:-}; CB=$OUT/cb; MEM_AVAIL_KB=1000000; BURNIN_HOURS=${BURNIN_HOURS:-1}
    SUSTAIN_MINUTES=${SUSTAIN_MINUTES:-8}; SUSTAIN_50_MINUTES=${SUSTAIN_50_MINUTES:-4}   # QUICK: seconds
    printf "id\tmetric\tvalue\tunit\tround\n" > "$RES"; mkdir -p "$DATA_DIR"
    "stage_${s}_run" > "$OUT/stage.out" 2>&1
    cat "$RES"; echo "--status"; cat "$STATUS"
  ' _ "$ROOT" "$s" "$TMP/st-$s"
}

if command -v jq >/dev/null 2>&1; then
  # --- nvme: 3 disks. The all-disk values are totals (3 jobs x 1000 IOPS), the per-disk values have rounds 1..3
  rm -rf "$TMP/st-nvme"; mkdir -p "$TMP/st-nvme"
  res=$(stage_run nvme NVME_DEVS="nvme1n1 nvme2n1 nvme3n1" FIO_LOG="$TMP/fio-nvme.log")
  [ "$(count '^nvme\.fio\.randread-4k\.qd32x4\.all-disks\tnvme randread 4k qd32x4 all disks\t3000\tIOPS\t1$' "$res")" = 1 ] \
    && [ "$(count '^nvme\.fio\.seq-read-1m\.all-disks\t[^\t]*\t6\tGB/s\t1$' "$res")" = 1 ] \
    && check "nvme: the all-disk values are the totals over the 3 disks (3000 IOPS, 6 GB/s)" 0 || check "nvme: the all-disk values are the totals over the 3 disks" 1 "$res"
  ok=0
  for id in 'nvme\.fio\.randwrite-4k\.qd32x4\.per-disk' 'nvme\.fio\.randread-4k\.qd1\.p99\.per-disk' 'nvme\.fio\.randread-4k\.qd1\.p999\.per-disk' 'nvme\.fio\.randread-4k\.qd32x4\.per-disk' \
            'nvme\.fio\.mixed-70-30-4k\.read\.per-disk' 'nvme\.fio\.mixed-70-30-4k\.write\.per-disk' 'nvme\.fio\.seq-read-1m\.per-disk' 'nvme\.fio\.seq-write-1m\.per-disk' \
            'nvme\.fio\.randread-4k\.sweep-qd1\.per-disk' 'nvme\.fio\.randread-4k\.sweep-qd128\.per-disk'; do
    for r in 1 2 3; do [ "$(count "^$id\t.*\t$r$" "$res")" = 1 ] || { ok=1; echo "   $id round $r: $(count "^$id\t.*\t$r$" "$res") rows"; }; done
  done
  [ "$ok" = 0 ] && check "nvme: every per-disk value has one row per disk (rounds 1, 2, 3)" 0 || check "nvme: every per-disk value has one row per disk (rounds 1, 2, 3)" 1
  [ "$(count '^nvme\.' "$res")" = $((2 + 14 * 3)) ] && check "nvme: 2 all-disk rows and 14 per-disk ids x 3 disks" 0 || check "nvme: 2 all-disk rows and 14 per-disk ids x 3 disks" 1 "rows: $(count '^nvme\.' "$res")"
  [ "$(count '^nvme\.fio\.randread-4k\.qd1\.p99\.per-disk\t[^\t]*\t100\tus\t' "$res")" = 3 ] && check "nvme: latency percentiles are in microseconds" 0 || check "nvme: latency percentiles are in microseconds" 1 "$res"
  per=$(cat "$TMP/st-nvme/nvme-per-disk.tsv")
  [ "$(count '^/dev/nvme2n1\tnvme\.fio\.seq-write-1m\.per-disk\t1000$' "$per")" = 1 ] && [ "$(count '^/dev/nvme' "$per")" = $((14 * 3)) ] \
    && check "nvme: nvme-per-disk.tsv names the device of every per-disk value" 0 || check "nvme: nvme-per-disk.tsv names the device of every per-disk value" 1 "$per"
  grep -q '^devices: 3$' "$TMP/st-nvme/nvme-devices.txt" && grep -q '^/dev/nvme3n1: STUBMODEL' "$TMP/st-nvme/nvme-devices.txt" \
    && check "nvme: nvme-devices.txt lists the disks with model and firmware" 0 || check "nvme: nvme-devices.txt lists the disks with model and firmware" 1 "$(cat "$TMP/st-nvme/nvme-devices.txt")"
  # the all-disk fio run has one job per disk after the global options; the per-disk runs one job on that disk
  all=$(grep -- '--rw=randread --bs=4k --iodepth=32 --numjobs=4 .*--name=nvme1n1 --filename=/dev/nvme1n1 --name=nvme2n1 --filename=/dev/nvme2n1 --name=nvme3n1 --filename=/dev/nvme3n1' "$TMP/fio-nvme.log" | head -1)
  [ -n "$all" ] && [[ $all == --direct=1\ --ioengine=libaio\ --group_reporting* ]] && check "nvme: the all-disk run is one fio with a job per disk after the global options" 0 || check "nvme: the all-disk run is one fio with a job per disk after the global options" 1 "$(head -3 "$TMP/fio-nvme.log")"
  [ "$(grep -c -- '--iodepth=128 --numjobs=4 .*--name=qd128 --filename=/dev/nvme2n1 ' "$TMP/fio-nvme.log")" = 1 ] && check "nvme: the sweep uses 4 jobs on one disk, as the checklist says" 0 || check "nvme: the sweep uses 4 jobs on one disk" 1
  [ "$(count '^nvme\tfio .*\tOK$' "$res")" = $((2 + 12 * 3)) ] && check "nvme: every fio step is an OK line in status.tsv" 0 || check "nvme: every fio step is an OK line in status.tsv" 1 "$(count '^nvme\tfio' "$res") steps"
  # a failing fio is a FAIL step and no value
  rm -rf "$TMP/st-nvme"; mkdir -p "$TMP/st-nvme"
  res=$(stage_run nvme NVME_DEVS="nvme1n1" FIO_RC=1)
  [ "$(count '^nvme\.' "$res")" = 0 ] && [ "$(count '^nvme\tfio .*\tFAIL exit 1' "$res")" -ge 10 ] && check "nvme: a failing fio records FAIL and no value" 0 || check "nvme: a failing fio records FAIL and no value" 1 "$res"

  # --- sustain with turbostat and a BMC: clock from Bzy_MHz, temperature, headroom from the Tjmax line, power phases
  rm -rf "$TMP/st-sustain"; mkdir -p "$TMP/st-sustain"
  res=$(stage_run sustain CPU_MHZ_STUB=2400 STRESS_LOG="$TMP/stress.log")
  mhz=$(awk -F'\t' '$1=="sustain.stress-ng.all-core-mhz.max"{print $3}' <<<"$res")
  [ -n "$mhz" ] && [ "$mhz" -ge 3000 ] && [ "$mhz" -le 3600 ] && grep -q 'clock source: turbostat' "$TMP/st-sustain/sustain.txt" \
    && check "sustain: the all-core clock is the turbostat Bzy_MHz average ($mhz)" 0 || check "sustain: the all-core clock is the turbostat Bzy_MHz average" 1 "$res" "$(cat "$TMP/st-sustain/sustain.txt")"
  tmax=$(awk -F'\t' '$1=="sustain.turbostat.pkg-temp.peak"{print $3}' <<<"$res"); head=$(awk -F'\t' '$1=="sustain.turbostat.thermal-headroom"{print $3}' <<<"$res")
  [ -n "$tmax" ] && [ "$head" = $((100 - tmax)) ] && check "sustain: peak temperature and headroom = Tjmax (100, from turbostat) - peak" 0 || check "sustain: peak temperature and headroom" 1 "tmax=$tmax head=$head"
  [ "$(count '^sustain\.turbostat\.pkg-watt\.full\t[^\t]*\t150\.5\tW\t1$' "$res")" = 1 ] && check "sustain: package power from turbostat" 0 || check "sustain: package power from turbostat" 1 "$res"
  [ "$(count '^sustain\.ipmi\.power\.idle\t[^\t]*\t250\.0\tW\t1$' "$res")" = 1 ] && [ "$(count '^sustain\.ipmi\.power\.full\t[^\t]*\t250\.0\tW' "$res")" = 1 ] && [ "$(count '^sustain\.ipmi\.power\.load-50\t[^\t]*\t250\.0\tW' "$res")" = 1 ] \
    && check "sustain: BMC power at idle, full load and 50% load" 0 || check "sustain: BMC power at idle, full load and 50% load" 1 "$res"
  [ "$(count '^sustain\.ipmi\.fan\.peak\t[^\t]*\t6120\tRPM\t1$' "$res")" = 1 ] && check "sustain: the highest fan speed from the BMC" 0 || check "sustain: the highest fan speed from the BMC" 1 "$res"
  [ "$(cat "$TMP/stress.log")" = $'stress-ng 8\nstress-ng 4' ] && check "sustain: QUICK runs SUSTAIN_MINUTES (8) s of full load and SUSTAIN_50_MINUTES (4) s at 50%" 0 || check "sustain: QUICK runs 8 s of full load and 4 s at 50%" 1 "$(cat "$TMP/stress.log")"
  [ -s "$TMP/st-sustain/turbostat.txt" ] && [ -s "$TMP/st-sustain/sustain-sensors.txt" ] && [ -s "$TMP/st-sustain/sustain-power-full.txt" ] && [ -s "$TMP/st-sustain/sustain-mhz.txt" ] \
    && check "sustain: the samples are kept (turbostat.txt, sensors, power, kernel clock)" 0 || check "sustain: the samples are kept" 1 "$(ls "$TMP/st-sustain")"
  # TJMAX overrides what turbostat says
  rm -rf "$TMP/st-sustain"; mkdir -p "$TMP/st-sustain"
  res=$(stage_run sustain TJMAX=95 CPU_MHZ_STUB=2400)
  tmax=$(awk -F'\t' '$1=="sustain.turbostat.pkg-temp.peak"{print $3}' <<<"$res"); head=$(awk -F'\t' '$1=="sustain.turbostat.thermal-headroom"{print $3}' <<<"$res")
  [ -n "$tmax" ] && [ "$head" = $((95 - tmax)) ] && check "sustain: TJMAX=95 sets the Tjmax of the headroom" 0 || check "sustain: TJMAX=95 sets the Tjmax of the headroom" 1 "tmax=$tmax head=$head"
  # without turbostat and without a BMC (a VM): the clock comes from the kernel, everything else is skipped, not failed
  rm -rf "$TMP/st-sustain"; mkdir -p "$TMP/st-sustain"
  res=$(stage_run sustain TURBOSTAT_OK=0 IPMI_OK=0 CPU_MHZ_STUB=2400 STRESS_LOG="$TMP/stress2.log")
  [ "$(count '^sustain\.stress-ng\.all-core-mhz\.max\t[^\t]*\t2400\tMHz\t1$' "$res")" = 1 ] && grep -q 'clock source: /proc/cpuinfo' "$TMP/st-sustain/sustain.txt" \
    && check "sustain without turbostat: the clock comes from the kernel" 0 || check "sustain without turbostat: the clock comes from the kernel" 1 "$res" "$(cat "$TMP/st-sustain/sustain.txt")"
  [ "$(count '^sustain\.(turbostat|ipmi)\.' "$res")" = 0 ] && [ "$(count '^sustain\t.*\tSKIP' "$res")" -ge 4 ] && [ "$(count '\tFAIL' "$res")" = 0 ] \
    && check "sustain without turbostat and BMC: temperature and power are SKIP, nothing FAILs" 0 || check "sustain without turbostat and BMC: temperature and power are SKIP, nothing FAILs" 1 "$res"
  [ "$(cat "$TMP/stress2.log")" = "stress-ng 8" ] && check "sustain without a BMC: the 50% load phase is not run" 0 || check "sustain without a BMC: the 50% load phase is not run" 1 "$(cat "$TMP/stress2.log")"
  # no clock source at all (no turbostat, no cpu MHz, no cpufreq: an ARM VM): SKIP, not FAIL
  rm -rf "$TMP/st-sustain"; mkdir -p "$TMP/st-sustain"
  res=$(stage_run sustain TURBOSTAT_OK=0 IPMI_OK=0 CPU_MHZ_STUB=none)
  [ "$(count '^sustain\.' "$res")" = 0 ] && [ "$(count '^sustain\tall-core clock\tSKIP no clock source' "$res")" = 1 ] && [ "$(count '\tFAIL' "$res")" = 0 ] \
    && grep -q '^clock source: none' "$TMP/st-sustain/sustain.txt" \
    && check "sustain without any clock source: the clock is SKIP, nothing FAILs" 0 || check "sustain without any clock source: the clock is SKIP, nothing FAILs" 1 "$res"

  # --- burnin: counters that grow during the run are errors (the BMC log gains 3 entries, a disk 2 media errors)
  rm -rf "$TMP/st-burnin"; mkdir -p "$TMP/st-burnin"
  cat > "$TMP/stubs/ipmitool-grow" <<'STUB'
#!/usr/bin/env bash
f=$IPMI_COUNT_FILE; n=$(cat "$f" 2>/dev/null || echo 0); echo $((n + 1)) > "$f"
case "$*" in "sel list") k=$(( n == 0 ? 2 : 5 )); for ((i = 1; i <= k; i++)); do echo "   $i | 01/01/2000 | 00:00:00 | Event | Asserted"; done ;; esac
STUB
  cat > "$TMP/stubs/nvme-grow" <<'STUB'
#!/usr/bin/env bash
f=$NVME_COUNT_FILE; n=$(cat "$f" 2>/dev/null || echo 0); echo $((n + 1)) > "$f"
case "$1 $2" in "smart-log /dev/nvme1n1") printf 'media_errors : %s\nnum_err_log_entries : 7\n' $(( n == 0 ? 0 : 2 )) ;; *) printf 'media_errors : 0\nnum_err_log_entries : 1\n' ;; esac
STUB
  chmod +x "$TMP/stubs/ipmitool-grow" "$TMP/stubs/nvme-grow"
  mkdir -p "$TMP/stubs2"; cp "$TMP/stubs/ipmitool-grow" "$TMP/stubs2/ipmitool"; cp "$TMP/stubs/nvme-grow" "$TMP/stubs2/nvme"
  rm -f "$TMP/ipmi.count" "$TMP/nvme.count"
  res=$(EXTRA_PATH=$TMP/stubs2 stage_run burnin QUICK=0 BURNIN_HOURS=0.001 FIO_SLEEP=1 NVME_DEVS="nvme1n1 nvme2n1" IPMI_COUNT_FILE="$TMP/ipmi.count" NVME_COUNT_FILE="$TMP/nvme.count" FIO_LOG="$TMP/fio-burn.log")
  [ "$(count '^burnin\.errors\t[^\t]*\t5\tcount\t1$' "$res")" = 1 ] && check "burnin: 3 new BMC log entries + 2 media errors = 5 errors" 0 || check "burnin: 3 new BMC log entries + 2 media errors = 5 errors" 1 "$res" "$(cat "$TMP/st-burnin/burnin-checks.txt")"
  chk=$(cat "$TMP/st-burnin/burnin-checks.txt")
  grep -q '^  ipmi_sel +3 (2 -> 5)$' <<<"$chk" && grep -q '^  nvme1n1_media_errors +2 (0 -> 2)$' <<<"$chk" && grep -q '^  total 5$' <<<"$chk" && grep -q '^  edac_ce 0$' <<<"$chk" \
    && check "burnin: burnin-checks.txt shows the counters before, after and what grew" 0 || check "burnin: burnin-checks.txt shows the counters" 1 "$chk"
  grep -q -- '--name=burn-nvme1n1 --filename=/dev/nvme1n1 --name=burn-nvme2n1 --filename=/dev/nvme2n1' "$TMP/fio-burn.log" && ! grep -q -- '--size=' "$TMP/fio-burn.log" \
    && check "burnin: NVME_DEVS runs one fio verify job per disk, no --size" 0 || check "burnin: NVME_DEVS runs one fio verify job per disk" 1 "$(cat "$TMP/fio-burn.log")"
  # a clean run on a file: 0 errors, the counters did not move
  rm -rf "$TMP/st-burnin"; mkdir -p "$TMP/st-burnin"
  res=$(stage_run burnin QUICK=0 BURNIN_HOURS=0.001 FIO_SLEEP=1)
  [ "$(count '^burnin\.errors\t[^\t]*\t0\tcount\t1$' "$res")" = 1 ] && grep -q '^  total 0$' "$TMP/st-burnin/burnin-checks.txt" && check "burnin: a clean run on a file has 0 errors" 0 || check "burnin: a clean run on a file has 0 errors" 1 "$res"

  # --- pg: tps per watt from the BMC during the TPC-B run (the pgbench and psql stubs of test_rounds.sh, shortened)
  cat > "$TMP/stubs/psql" <<'STUB'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case $1 in -c|-Atc) case $2 in *data_directory*) echo /tmp ;; *pg_stat_checkpointer*) echo "1 0" ;; "select 1") echo 1 ;; esac; shift ;; esac; shift; done
STUB
  cat > "$TMP/stubs/pgbench" <<'STUB'
#!/usr/bin/env bash
case " $* " in *" -i "*) exit 0 ;; esac
sleep 2; for i in 1 2 3; do echo "progress: $((i * 10)).0 s, 100$i.0 tps, lat 1.0 ms stddev 0.1"; done
case " $* " in *" -r "*) echo "latency average = 1.234 ms" ;; esac
echo "tps = 1000.0 (without initial connection time)"
STUB
  chmod +x "$TMP/stubs/psql" "$TMP/stubs/pgbench"
  rm -rf "$TMP/st-pg"; mkdir -p "$TMP/st-pg"
  res=$(stage_run pg PG_ROUNDS=1 IPMI_WATTS=400)
  [ "$(count '^pg\.pgbench\.tpcb\.tps-per-watt\t[^\t]*\t2\.50\tTPS/W\t1$' "$res")" = 1 ] && [ -s "$TMP/st-pg/pg-power-tpcb.log" ] \
    && check "pg: tps per watt = 1000 TPS / 400 W from the BMC samples" 0 || check "pg: tps per watt = 1000 TPS / 400 W" 1 "$res"
  rm -rf "$TMP/st-pg"; mkdir -p "$TMP/st-pg"
  res=$(stage_run pg PG_ROUNDS=1 IPMI_OK=0)
  [ "$(count '^pg\.pgbench\.tpcb\.tps\t' "$res")" = 1 ] && [ "$(count 'tps-per-watt' "$res")" = 0 ] && [ "$(count '\tFAIL' "$res")" = 0 ] \
    && check "pg without a BMC: tps is recorded, tps per watt is not, nothing FAILs" 0 || check "pg without a BMC: tps is recorded, tps per watt is not" 1 "$res"

  # --- mem cross-NUMA: with a two-node numactl stub the triad is recorded, with one node it is skipped
  cat > "$TMP/stubs/numactl" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = -H ]; then printf 'available: %s nodes (0-1)\nnode 0 cpus: 0 1\nnode 1 cpus: 2 3\n' "${NUMA_NODES:-2}"; exit 0; fi
while [ $# -gt 0 ]; do case $1 in --*) shift ;; *) break ;; esac; done
exec "$@"
STUB
  chmod +x "$TMP/stubs/numactl"
  if command -v gcc >/dev/null 2>&1; then
    mkdir -p "$TMP/stubs/gccstub"
    cat > "$TMP/stubs/gccstub/gcc" <<'STUB'
#!/usr/bin/env bash
out=$(for ((i = 1; i <= $#; i++)); do [ "${!i}" = -o ] && { j=$((i + 1)); echo "${!j}"; }; done)
printf '#!/usr/bin/env bash\necho "Copy: 20000.0 1 1 1"\necho "Triad: 30000.0 1 1 1"\n' > "$out"; chmod +x "$out"
STUB
    chmod +x "$TMP/stubs/gccstub/gcc"
    rm -rf "$TMP/st-mem"; mkdir -p "$TMP/st-mem"
    res=$(PATH="$TMP/stubs/gccstub:$PATH" stage_run mem MEM_ROUNDS=2 STREAM_C="$ROOT/tests/fixtures/new-a/results.tsv" STREAM_SKIP_CHECK=1)
    [ "$(count '^mem\.stream\.triad\.cross-numa\t[^\t]*\t30000\.0\tMB/s\t[12]$' "$res")" = 2 ] && [ "$(count '^mem\tstream cross-numa r[12]\tOK' "$res")" = 2 ] \
      && check "mem: with two NUMA nodes the cross-numa triad has one row per round" 0 || check "mem: with two NUMA nodes the cross-numa triad has one row per round" 1 "$res" "$(cat "$TMP/st-mem/stage.out")"
    rm -rf "$TMP/st-mem"; mkdir -p "$TMP/st-mem"
    res=$(PATH="$TMP/stubs/gccstub:$PATH" stage_run mem MEM_ROUNDS=1 NUMA_NODES=1 STREAM_C="$ROOT/tests/fixtures/new-a/results.tsv" STREAM_SKIP_CHECK=1)
    [ "$(count 'cross-numa' "$res")" = 1 ] && [ "$(count '^mem\tstream cross-numa\tSKIP one NUMA node' "$res")" = 1 ] \
      && check "mem: with one NUMA node the cross-numa triad is skipped" 0 || check "mem: with one NUMA node the cross-numa triad is skipped" 1 "$res"
  else echo "skip mem cross-numa tests (no gcc)"; fi
else
  echo "skip stage tests (no jq)"
fi

# --- info: hw/ keeps the raw outputs, hardware.txt is written from them, hw.py turns them into hardware.json.
# lscpu, dmidecode, ipmitool and sudo are stubs; /sys is this machine's (any content is fine for these checks).
mkdir -p "$TMP/stubs-info"
cat > "$TMP/stubs-info/lscpu" <<'STUB'
#!/usr/bin/env bash
printf 'Vendor ID:            StubVendor\nModel name:           Stub CPU 9000\nCPU family:           6\nModel:                143\nStepping:             8\nSocket(s):            2\n'
STUB
cat > "$TMP/stubs-info/dmidecode" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "-t bios") printf 'BIOS Information\n\tVendor: Stub BIOS\n\tVersion: 9.9\n\tRelease Date: 01/01/2026\n' ;;
  "-t memory") for l in A1 A2; do printf 'Memory Device\n\tSize: 16 GB\n\tLocator: %s\n\tType: DDR5\n\tSpeed: 4800 MT/s\n\tSerial Number: SN-SECRET-%s\n\tAsset Tag: AT-SECRET\n\tPart Number: STUB-16G\n\tConfigured Memory Speed: 4800 MT/s\n\n' "$l" "$l"; done ;;
esac
STUB
cat > "$TMP/stubs-info/sudo-no" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$TMP"/stubs-info/*
info_hw() { # OUT DIR, extra PATH: run info_hardware alone
  rm -rf "$1"; mkdir -p "$1"
  PATH="$2:$PATH" bash -c 'VMBENCH_HOME=$1; OUT=$2
    for f in common hw; do . "$VMBENCH_HOME/lib/$f.sh"; done; . "$VMBENCH_HOME/stages/info.sh"
    info_hardware' _ "$ROOT" "$1" > "$1/stage.out" 2>&1
}
info_hw "$TMP/info1" "$TMP/stubs-info:$TMP/stubs"
j=$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["schema"], d["cpu"]["model"], d["cpu"]["stepping"], d["system"]["bmc"]["firmware"], d["memory"]["source"], d["memory"]["populated"], d["bmc"]["power_w"], d["bmc"]["fans"]["FAN1"])' "$TMP/info1/hardware.json" 2>&1)
[ "$j" = "1 Stub CPU 9000 8 1.23 dmidecode 2 250 5040" ] && check "info: hardware.json loads, cpu.model, DIMMs, BMC firmware and power from the stubs" 0 \
  || check "info: hardware.json from the stubs" 1 "got: $j" "$(cat "$TMP/info1/stage.out")"
[ -s "$TMP/info1/hw/lscpu.txt" ] && grep -q "^midr_el1=" "$TMP/info1/hw/cpu-id.txt" && [ -s "$TMP/info1/hw/dmidecode-memory.txt" ] && [ -s "$TMP/info1/hw/ipmi-dcmi-power.txt" ] && [ -s "$TMP/info1/hw/cpufreq.txt" ] \
  && check "info: hw/ keeps the raw output of each command" 0 || check "info: hw/ keeps the raw output of each command" 1 "$(ls "$TMP/info1/hw")"
grep -q '^Model name: *Stub CPU 9000' "$TMP/info1/hardware.txt" && grep -q '^dimms populated: 2 of 2 slots' "$TMP/info1/hardware.txt" && grep -q 'Firmware Revision *: 1.23' "$TMP/info1/hardware.txt" \
  && grep -q '^--- disks' "$TMP/info1/hardware.txt" && check "info: hardware.txt still has the cpu, memory, BMC and disk sections" 0 || check "info: hardware.txt sections" 1 "$(cat "$TMP/info1/hardware.txt")"
grep -rqiE 'SECRET|serial|asset tag' "$TMP/info1/hw" "$TMP/info1/hardware.txt" "$TMP/info1/hardware.json" \
  && check "info: no serial numbers or asset tags in hw/, hardware.txt, hardware.json" 1 "$(grep -rliE 'SECRET|serial|asset tag' "$TMP/info1")" \
  || check "info: no serial numbers or asset tags in hw/, hardware.txt, hardware.json" 0
# without root (sudo asks for a password): the root-only parts are listed in "unavailable", the rest is still there
mkdir -p "$TMP/stubs-noroot"; cp "$TMP/stubs-info/lscpu" "$TMP/stubs-info/dmidecode" "$TMP/stubs/ipmitool" "$TMP/stubs-noroot/"; cp "$TMP/stubs-info/sudo-no" "$TMP/stubs-noroot/sudo"
if [ "$(id -u)" != 0 ]; then
  info_hw "$TMP/info2" "$TMP/stubs-noroot"
  j=$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["cpu"]["model"], d["memory"]["source"] or "-", d["bmc"]["power_w"], "|".join(d["unavailable"]))' "$TMP/info2/hardware.json" 2>&1)
  [[ $j == "Stub CPU 9000 "* ]] && [[ $j == *"dmidecode -t memory: needs root or sudo -n"* ]] && [[ $j == *"ipmitool mc info: needs root or sudo -n, and a BMC"* ]] && [[ $j == *" None "* ]] \
    && [ ! -e "$TMP/info2/hw/dmidecode-memory.txt" ] && check "info without root: dmidecode and ipmitool are listed as unavailable, nothing else is lost" 0 \
    || check "info without root: unavailable parts" 1 "got: $j"
  grep -q 'dmidecode -t memory: needs root or sudo -n' "$TMP/info2/hardware.txt" && check "info without root: hardware.txt says what was not recorded" 0 || check "info without root: hardware.txt says what was not recorded" 1 "$(tail -5 "$TMP/info2/hardware.txt")"
fi
# a broken hw.py does not stop the stage: no hardware.json, a warning, hardware.txt is complete
mkdir -p "$TMP/brokenhome/lib" "$TMP/brokenhome/stages"; cp "$ROOT"/lib/*.sh "$TMP/brokenhome/lib/"; cp "$ROOT/stages/info.sh" "$TMP/brokenhome/stages/"
echo 'raise SystemExit(1)' > "$TMP/brokenhome/hw.py"
rm -rf "$TMP/info3"; mkdir -p "$TMP/info3"
PATH="$TMP/stubs-info:$TMP/stubs:$PATH" bash -c 'VMBENCH_HOME=$1; OUT=$2; for f in common hw; do . "$VMBENCH_HOME/lib/$f.sh"; done; . "$VMBENCH_HOME/stages/info.sh"; info_hardware; echo "rc=$?"' _ "$TMP/brokenhome" "$TMP/info3" > "$TMP/info3/stage.out" 2>&1
[ ! -e "$TMP/info3/hardware.json" ] && [ ! -e "$TMP/info3/hardware.json.tmp" ] && grep -q 'hardware.json was not written' "$TMP/info3/stage.out" && grep -q '^rc=0' "$TMP/info3/stage.out" && [ -s "$TMP/info3/hardware.txt" ] \
  && check "info: a failing hw.py is a warning, hardware.txt is still written" 0 || check "info: a failing hw.py is a warning" 1 "$(cat "$TMP/info3/stage.out")"

# --- report.py: the new sections, directions and a per-disk comparison from a synthetic folder
mkdir -p "$TMP/ra" "$TMP/rb"
for d in ra rb; do
  printf 'id\tmetric\tvalue\tunit\tround\n' > "$TMP/$d/results.tsv"
  printf 'label: %s\nnproc: 8  ram_gb: 64\nkernel: Linux 6.8 x86_64\n' "$d" > "$TMP/$d/info.txt"
done
cat >> "$TMP/ra/results.tsv" <<'TSV'
nvme.fio.randread-4k.qd32x4.all-disks	nvme randread 4k qd32x4 all disks	3000000	IOPS	1
nvme.fio.randread-4k.qd1.p99.per-disk	nvme randread 4k qd1 p99 per disk	90	us	1
nvme.fio.randread-4k.qd1.p99.per-disk	nvme randread 4k qd1 p99 per disk	95	us	2
sustain.stress-ng.all-core-mhz.max	all-core clock under load	3100	MHz	1
sustain.ipmi.power.full	bmc power full load	600	W	1
sustain.turbostat.pkg-temp.peak	pkg temp peak	80	C	1
sustain.ipmi.fan.peak	fan speed peak	9000	RPM	1
pg.pgbench.tpcb.tps-per-watt	pgbench tpcb-like tps per watt	20	TPS/W	1
TSV
cat >> "$TMP/rb/results.tsv" <<'TSV'
nvme.fio.randread-4k.qd32x4.all-disks	nvme randread 4k qd32x4 all disks	2000000	IOPS	1
nvme.fio.randread-4k.qd1.p99.per-disk	nvme randread 4k qd1 p99 per disk	70	us	1
nvme.fio.randread-4k.qd1.p99.per-disk	nvme randread 4k qd1 p99 per disk	72	us	2
sustain.stress-ng.all-core-mhz.max	all-core clock under load	2800	MHz	1
sustain.ipmi.power.full	bmc power full load	500	W	1
sustain.turbostat.pkg-temp.peak	pkg temp peak	70	C	1
sustain.ipmi.fan.peak	fan speed peak	7000	RPM	1
pg.pgbench.tpcb.tps-per-watt	pgbench tpcb-like tps per watt	25	TPS/W	1
TSV
out=$(python3 -I "$ROOT/report.py" compare "$TMP/ra" "$TMP/rb" --no-files 2>&1); rc=$?
verdict() { grep -F "$1" <<<"$out" | head -1 | grep -oE '(ra|rb) better|not clearly different|no data' | head -1; }
[ "$rc" = 0 ] && grep -q '^NVMe' <<<"$out" && grep -q '^Sustained load' <<<"$out" && check "report compare: NVMe and Sustained load sections" 0 || check "report compare: NVMe and Sustained load sections" 1 "rc=$rc ${out:0:400}"
v1=$(verdict "nvme.fio.randread-4k.qd32x4.all-disks"); v2=$(verdict "nvme.fio.randread-4k.qd1.p99.per-disk"); v3=$(verdict "sustain.ipmi.power.full"); v4=$(verdict "sustain.stress-ng.all-core-mhz "); v5=$(verdict "pg.pgbench.tpcb.tps-per-watt")
[ "$v1" = "ra better" ] && [ "$v2" = "rb better" ] && [ "$v3" = "rb better" ] && [ "$v4" = "ra better" ] && [ "$v5" = "rb better" ] \
  && check "report compare: IOPS, MHz and TPS/W higher is better; latency and W lower is better" 0 || check "report compare: directions of the new units" 1 "$v1 / $v2 / $v3 / $v4 / $v5" "$out"
t=$(grep -F "sustain.turbostat.pkg-temp.peak" <<<"$out" | head -1); f=$(grep -F "sustain.ipmi.fan.peak" <<<"$out" | head -1)
[[ $t != *"better"* ]] && [[ $f != *"better"* ]] && [ -n "$t" ] && [ -n "$f" ] && check "report compare: temperature and fan speed are context, never a win" 0 || check "report compare: temperature and fan speed are context" 1 "$t" "$f"
grep -F "nvme.fio.randread-4k.qd1.p99.per-disk" <<<"$out" | head -1 | grep -q '92\.5' && check "report: a per-disk value is the median over the disks" 0 || check "report: a per-disk value is the median over the disks" 1 "$(grep -F 'p99.per-disk' <<<"$out" | head -1)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
