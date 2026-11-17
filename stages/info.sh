#!/usr/bin/env bash
# stages/info.sh - records the kernel, CPU model, flags, NUMA layout, disks and tool versions (always runs)
# Sourced by lib/stages.sh, never executed. Functions (see lib/stages.sh for the contract):
#   stage_info_order, _default, _time, _note, _check, _run
# Metric ids: info.* (the table is in lib/metrics.sh)
# Files: info.txt (the machine as the OS sees it), hardware.txt (the facts a bare-metal checklist asks the vendor
# for: CPU stepping and microcode, firmware and BIOS settings, DIMMs, NICs, disks; diff two of them), hardware.json
# (the same facts as fields, written by hw.py from the raw command outputs kept in hw/), doctor.txt.

stage_info_order() { echo 0; }
stage_info_default() { echo always; }
stage_info_time() { echo ""; }
stage_info_note() { echo ""; }

stage_info_check() { :; }   # nothing to check: it only reads the machine

# info_hardware: hw/ (the raw output of every command), hardware.txt (the same, readable, for a diff) and
# hardware.json (hw.py: the same facts as fields, for the Excel review sheet and later comparisons).
# Everything comes from what the OS exposes without root (/sys, lscpu, ethtool); dmidecode, ipmitool and smartctl add
# more when they are installed and we are root or `sudo -n` works. A part that cannot be read leaves no file (or an
# empty one) and a line in hw/unavailable.txt. No serial numbers, asset tags or UUIDs: the files are meant to be
# shared and compared between machines (no MAC or IP either: those are only in info.txt).
hw_unavailable() { printf '%s\n' "$*" >> "$OUT/hw/unavailable.txt"; }

# hw_root_save FILE WHAT HINT CMD...: CMD as root (as_root) into hw/FILE without serial numbers; on failure no file
# and "WHAT: <reason>" in unavailable.txt (HINT is added to "needs root or sudo -n", e.g. ", and a BMC"; a tool
# that runs as root and fails, e.g. ipmitool without a BMC, is "failed (exit N)")
hw_root_save() {
  local file=$OUT/hw/$1 what=$2 hint=$3 rc; shift 3
  if ! need "$1"; then hw_unavailable "$what: $1 is not installed"; return 1; fi
  if ! can_root; then hw_unavailable "$what: needs root or sudo -n$hint"; return 1; fi
  as_root "$@" 2>/dev/null | grep -viE 'serial|asset tag|uuid' > "$file"
  rc=${PIPESTATUS[0]}
  if [ "$rc" = 0 ] && [ -s "$file" ]; then return 0; fi
  rm -f "$file"
  if [ "$rc" = 0 ]; then hw_unavailable "$what: printed nothing"; else hw_unavailable "$what: failed (exit $rc)"; fi
  return 1
}

info_hardware_raw() {
  local hw=$OUT/hw f i d p c
  mkdir -p "$hw" || return 1
  : > "$hw/unavailable.txt"
  lscpu > "$hw/lscpu.txt" 2>/dev/null || hw_unavailable "lscpu: failed"
  printf 'proc=%s\nsysfs=%s\n' "$(grep -m1 microcode /proc/cpuinfo 2>/dev/null | awk '{print $3}')" \
    "$(cat /sys/devices/system/cpu/cpu0/microcode/version 2>/dev/null)" > "$hw/cpuinfo-microcode.txt"
  {
    for f in scaling_driver scaling_governor cpuinfo_min_freq cpuinfo_max_freq scaling_min_freq scaling_max_freq; do
      printf '%s=%s\n' "$f" "$(cat "/sys/devices/system/cpu/cpu0/cpufreq/$f" 2>/dev/null)"; done
    printf 'no_turbo=%s\n' "$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null)"
    printf 'boost=%s\n' "$(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null)"
    printf 'smt=%s\n' "$(cat /sys/devices/system/cpu/smt/control 2>/dev/null)"
    printf 'cpuidle_driver=%s\n' "$(cat /sys/devices/system/cpu/cpuidle/current_driver 2>/dev/null)"
    printf 'cpuidle_governor=%s\n' "$(cat /sys/devices/system/cpu/cpuidle/current_governor_ro 2>/dev/null)"
  } > "$hw/cpufreq.txt"
  [ -d /sys/devices/system/cpu/cpu0/cpufreq ] || hw_unavailable "cpufreq: not exposed by the kernel (usual in a VM)"
  if need cpupower; then
    cpupower frequency-info > "$hw/cpupower-frequency-info.txt" 2>&1
    cpupower idle-info > "$hw/cpupower-idle-info.txt" 2>&1
  fi
  for f in sys_vendor product_name product_version board_vendor board_name board_version bios_vendor bios_version bios_date bios_release; do
    printf '%s: %s\n' "$f" "$(cat "/sys/class/dmi/id/$f" 2>/dev/null)"; done > "$hw/dmi-id.txt"
  [ -d /sys/class/dmi/id ] || hw_unavailable "dmi: /sys/class/dmi/id is missing (usual on ARM and in some VMs)"
  hw_root_save dmidecode-bios.txt "dmidecode -t bios" "" dmidecode -t bios
  if ! hw_root_save dmidecode-memory.txt "dmidecode -t memory" "" dmidecode -t memory; then
    for d in /sys/devices/system/edac/mc/mc*/dimm*; do [ -d "$d" ] || continue
      printf '%s|%s|%s|%s\n' "$(basename "$d")" "$(cat "$d/dimm_label" 2>/dev/null)" "$(cat "$d/size" 2>/dev/null)" "$(cat "$d/dimm_mem_type" 2>/dev/null)"
    done > "$hw/edac-dimms.txt"
    [ -s "$hw/edac-dimms.txt" ] || { rm -f "$hw/edac-dimms.txt"; hw_unavailable "edac: no DIMMs in /sys/devices/system/edac"; }
  fi
  if hw_root_save ipmitool-mc-info.txt "ipmitool mc info" ", and a BMC" ipmitool mc info; then
    hw_root_save ipmi-sdr-temp.txt "ipmitool sdr type temperature" ", and a BMC" ipmitool sdr type temperature
    hw_root_save ipmi-sdr-fan.txt "ipmitool sdr type fan" ", and a BMC" ipmitool sdr type fan
    hw_root_save ipmi-dcmi-power.txt "ipmitool dcmi power reading" ", and a BMC" ipmitool dcmi power reading
  fi
  for d in /sys/class/net/*; do
    i=$(basename "$d"); [ "$i" = lo ] && continue; [ -e "$d/device" ] || continue
    p=$(basename "$(readlink -f "$d/device")")
    {
      printf 'state=%s\nspeed=%s\nmtu=%s\npci=%s\n' "$(cat "$d/operstate" 2>/dev/null)" "$(cat "$d/speed" 2>/dev/null)" "$(cat "$d/mtu" 2>/dev/null)" "$p"
      if need lspci; then echo "--- lspci"; lspci -s "$p" 2>/dev/null; fi
      if need ethtool; then
        echo "--- ethtool -i"; ethtool -i "$i" 2>/dev/null
        echo "--- ethtool -k"; ethtool -k "$i" 2>/dev/null
      fi
    } > "$hw/net-$i.txt"
  done
  need ethtool || hw_unavailable "nics: ethtool is not installed (no driver, firmware or offloads)"
  lsblk -dn -P -o NAME,MODEL,REV,SIZE,TRAN,ROTA > "$hw/lsblk.txt" 2>/dev/null || hw_unavailable "lsblk: failed"
  for c in /sys/class/nvme/nvme*; do [ -d "$c" ] || continue
    printf 'model=%s\nfirmware=%s\n' "$(sed 's/ *$//' "$c/model" 2>/dev/null)" "$(sed 's/ *$//' "$c/firmware_rev" 2>/dev/null)" > "$hw/nvme-$(basename "$c").txt"
  done
  if need smartctl; then
    for d in /dev/nvme*n1; do [ -b "$d" ] || continue
      hw_root_save "smartctl-$(basename "$d").txt" "smartctl -i $d" "" smartctl -i "$d"; done
  fi
}

# hw_section FILE: the lines of one "--- name" section of a net-<if>.txt
hw_section() { awk -v s="--- $2" '$0 == s {p = 1; next} /^--- / {p = 0} p' "$1"; }

info_hardware() {
  local hw=$OUT/hw f i n
  info_hardware_raw
  {
    echo "--- cpu (model, stepping, microcode)"
    grep -E '^ *(Vendor ID|Model name|CPU family|Model|Stepping|Socket\(s\)|Core\(s\) per socket|Thread\(s\) per core|NUMA node\(s\)|CPU max MHz|CPU min MHz|L1d|L1i|L2|L3)' "$hw/lscpu.txt"
    echo "microcode: $(sed -n 's/^proc=//p' "$hw/cpuinfo-microcode.txt")  /sys: $(sed -n 's/^sysfs=//p' "$hw/cpuinfo-microcode.txt")"
    echo "--- cpu frequency and idle (the BIOS power profile, turbo and C-states show here)"
    grep -E '^(scaling|cpuinfo)_' "$hw/cpufreq.txt" | paste -sd' '
    echo "boost: intel_pstate/no_turbo=$(sed -n 's/^no_turbo=//p' "$hw/cpufreq.txt") cpufreq/boost=$(sed -n 's/^boost=//p' "$hw/cpufreq.txt")"
    echo "smt: $(sed -n 's/^smt=//p' "$hw/cpufreq.txt")  cpuidle: driver=$(sed -n 's/^cpuidle_driver=//p' "$hw/cpufreq.txt") governor=$(sed -n 's/^cpuidle_governor=//p' "$hw/cpufreq.txt")"
    if [ -f "$hw/cpupower-frequency-info.txt" ]; then
      echo "--- cpupower frequency-info"; cat "$hw/cpupower-frequency-info.txt"; echo "--- cpupower idle-info"; cat "$hw/cpupower-idle-info.txt"
    fi
    echo "--- system and firmware (BIOS version and date; BMC firmware from ipmitool)"
    cat "$hw/dmi-id.txt"
    if need dmidecode; then echo "--- dmidecode -t bios"; grep -E 'Vendor|Version|Release|Revision' "$hw/dmidecode-bios.txt" 2>/dev/null || echo "(not available: needs root or sudo -n)"; fi
    if need ipmitool; then echo "--- ipmitool mc info"; cat "$hw/ipmitool-mc-info.txt" 2>/dev/null || echo "(not available: needs root or sudo -n, and a BMC)"; fi
    echo "--- memory (DIMMs: slots, size, configured speed; every channel populated?)"
    if [ -s "$hw/dmidecode-memory.txt" ]; then
      grep -E '^\s*(Locator|Size|Type|Speed|Configured Memory Speed|Manufacturer|Part Number):' "$hw/dmidecode-memory.txt"
      echo "dimms populated: $(grep -cE '^\s*Size: [0-9]+ [MGT]B' "$hw/dmidecode-memory.txt") of $(grep -c '^Memory Device$' "$hw/dmidecode-memory.txt") slots"
      echo "configured speed:"; grep 'Configured Memory Speed' "$hw/dmidecode-memory.txt" | sort | uniq -c
    else
      echo "(dmidecode -t memory not available without root; the EDAC view, when the kernel has it:)"
      [ -f "$hw/edac-dimms.txt" ] && awk -F'|' '{printf "%s: %s %s MB %s\n", $1, $2, $3, $4}' "$hw/edac-dimms.txt"
    fi
    echo "--- network interfaces (driver, firmware, offloads; physical interfaces only)"
    for f in "$hw"/net-*.txt; do [ -f "$f" ] || continue
      i=${f##*/net-}; i=${i%.txt}
      echo "[$i] state=$(sed -n 's/^state=//p' "$f") speed=$(sed -n 's/^speed=//p' "$f") Mb/s mtu=$(sed -n 's/^mtu=//p' "$f")"
      hw_section "$f" lspci | sed 's/^/  /'
      hw_section "$f" "ethtool -i" | grep -E '^(driver|version|firmware-version|bus-info):' | sed 's/^/  /'
      hw_section "$f" "ethtool -k" | grep -E 'offload|segmentation' | grep -v '\[fixed\]' | sed 's/^/  /'
    done
    echo "--- disks (model, firmware revision, size; how many of each model)"
    lsblk -dno NAME,MODEL,REV,SIZE,TRAN,ROTA 2>/dev/null | grep -vE '^(loop|ram|sr|zram)'
    for f in "$hw"/nvme-*.txt; do [ -f "$f" ] || continue
      n=${f##*/nvme-}; n=${n%.txt}
      printf '%s: model=%s firmware=%s\n' "$n" "$(sed -n 's/^model=//p' "$f")" "$(sed -n 's/^firmware=//p' "$f")"; done
    if ls "$hw"/nvme-*.txt >/dev/null 2>&1; then echo "nvme controllers per model:"; sed -n 's/^model=//p' "$hw"/nvme-*.txt | sort | uniq -c; fi
    for f in "$hw"/smartctl-*.txt; do [ -f "$f" ] || continue
      n=${f##*/smartctl-}; echo "--- smartctl -i /dev/${n%.txt}"; sed -n '/^===/,$p' "$f"; done
    if need ipmitool; then
      echo "--- bmc sensors at the start of the run (ipmitool sdr: temperature, fan; dcmi power)"
      if [ -f "$hw/ipmi-sdr-temp.txt" ] || [ -f "$hw/ipmi-sdr-fan.txt" ] || [ -f "$hw/ipmi-dcmi-power.txt" ]; then
        cat "$hw/ipmi-sdr-temp.txt" "$hw/ipmi-sdr-fan.txt" "$hw/ipmi-dcmi-power.txt" 2>/dev/null
      else echo "(not available: needs root or sudo -n, and a BMC)"; fi
    fi
    if [ -s "$hw/unavailable.txt" ]; then echo "--- not recorded (also in hardware.json \"unavailable\")"; cat "$hw/unavailable.txt"; fi
  } > "$OUT/hardware.txt" 2>&1
  # hardware.json: a failure here is logged and the run goes on (hardware.txt and hw/ are already written)
  if need python3 && python3 -I "$VMBENCH_HOME/hw.py" "$hw" > "$OUT/hardware.json.tmp" 2>> "$OUT/hw/hw-py.err"; then
    mv "$OUT/hardware.json.tmp" "$OUT/hardware.json"; [ -s "$OUT/hw/hw-py.err" ] || rm -f "$OUT/hw/hw-py.err"
  else
    rm -f "$OUT/hardware.json.tmp"; log "[WARN] hardware.json was not written (hw.py failed or no python3); hardware.txt and hw/ are complete"
  fi
}

stage_info_run() {
  log "== info"
  {
    echo "date: $(date -Is)"; echo "label: $LABEL"; echo "host: $(hostname)"; echo "kernel: $(uname -srm)"
    . /etc/os-release; echo "os: $PRETTY_NAME"; echo "virt: $(systemd-detect-virt 2>/dev/null)"
    echo "nproc: $NPROC  ram_gb: $RAM_GB"; echo "quick: $QUICK  rounds: $ROUNDS  fio_size: $FIO_SIZE  raw_dev: ${RAW_DEV:-none}  nvme_devs: ${NVME_DEVS:-none}"
    echo "--- lscpu"; lscpu
    echo "--- cpu flags"; grep -m1 -E '^(flags|Features)' /proc/cpuinfo | grep -o -wE 'aes|avx2|avx512f|sha_ni|pmull|sha2|atomics|sve|hypervisor' | sort -u | tr '\n' ' '; echo
    echo "--- memory"; free -m; echo "--- numa"; numactl -H 2>&1 | head -3
    echo "--- disks"; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,ROTA; df -h / "$DATA_DIR" 2>/dev/null
    # kernel settings that change database and disk results (compare them between machines before comparing pg.*)
    echo "--- kernel (memory, writeback)"
    echo "transparent_hugepage: $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)  defrag: $(cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null)"
    echo "hugepages: nr_hugepages=$(cat /proc/sys/vm/nr_hugepages 2>/dev/null) size=$(awk '/Hugepagesize/{print $2 $3}' /proc/meminfo)"
    for k in swappiness dirty_background_ratio dirty_ratio dirty_background_bytes dirty_bytes dirty_expire_centisecs overcommit_memory; do
      printf 'vm.%s=%s ' "$k" "$(cat /proc/sys/vm/$k 2>/dev/null)"; done; echo
    echo "--- i/o scheduler"
    for d in /sys/block/*/queue; do [ -e "$d/scheduler" ] || continue; case $d in /sys/block/loop*|/sys/block/ram*) continue ;; esac
      printf '%s: %s  nr_requests=%s read_ahead_kb=%s\n' \
      "$(basename "$(dirname "$d")")" "$(cat "$d/scheduler")" "$(cat "$d/nr_requests" 2>/dev/null)" "$(cat "$d/read_ahead_kb" 2>/dev/null)"; done
    echo "--- mounts (data, db, wal)"
    for d in "$DATA_DIR" "$DB_DIR" "$WAL_DIR" /pgdata /pgwal; do
      [ -e "$d" ] && findmnt -T "$d" -no TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null | sed "s|^|$d -> |"; done | sort -u
    echo "--- network"; ip -br addr
    echo "--- load"; uptime; ps -eo pcpu,comm --sort=-pcpu | sed -n 1,6p
    echo "--- services"; systemctl is-active postgresql zabbix-agent zabbix-agent2 docker 2>&1 | paste -sd' '
    echo "--- tmux"; tmux ls 2>&1 | head -3
    echo "--- tools"
    for t in sysbench fio 7z iperf3 sockperf stressapptest gcc pgbench openssl; do printf '%s: ' "$t"; case $t in
      7z) 7z 2>&1 | sed -n 2p ;; sysbench) sysbench --version ;; fio) fio --version ;; iperf3) iperf3 --version | head -1 ;;
      sockperf) sockperf --version 2>&1 | head -1 ;; stressapptest) echo "$(command -v stressapptest)" ;; gcc) gcc --version | head -1 ;;
      pgbench) pgbench --version ;; openssl) openssl version ;; esac; done
    [ -x "$CB/cpubench" ] && echo "cpubench: $("$CB/cpubench" version | head -1)"
  } > "$OUT/info.txt" 2>&1
  [ -x "$CB/cpubench" ] && timeout 120 "$CB/cpubench" doctor > "$OUT/doctor.txt" 2>&1
  ok info metadata
  info_hardware
  ok info hardware
  if [ "$(awk '{print int($1*100)}' /proc/loadavg)" -gt 50 ]; then log "[WARN] load average is $(cut -d' ' -f1 /proc/loadavg), the machine is not idle"; fi
  FREE_GB=$(df -BG --output=avail "$DATA_DIR" | tail -1 | tr -dc 0-9)
  log "free space in $DATA_DIR: ${FREE_GB} GB"
  [ "$FREE_GB" -ge 15 ] || log "[WARN] less than 15 GB free, disk stage will be refused"
}
