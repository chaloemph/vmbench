#!/usr/bin/env bash
# stages/info.sh - records the kernel, CPU model, flags, NUMA layout, disks and tool versions (always runs)
# Sourced by lib/stages.sh, never executed. Functions (see lib/stages.sh for the contract):
#   stage_info_order, _default, _time, _note, _check, _run
# Metric ids: info.* (the table is in lib/metrics.sh)
# Files: info.txt (the machine as the OS sees it), hardware.txt (the facts a bare-metal checklist asks the vendor
# for: CPU stepping and microcode, firmware and BIOS settings, DIMMs, NICs, disks; diff two of them), doctor.txt.

stage_info_order() { echo 0; }
stage_info_default() { echo always; }
stage_info_time() { echo ""; }
stage_info_note() { echo ""; }

stage_info_check() { :; }   # nothing to check: it only reads the machine

# info_hardware: hardware.txt. Everything comes from what the OS exposes without root (/sys, lscpu, ethtool);
# dmidecode, ipmitool, nvme and smartctl add more when they are installed and we are root or `sudo -n` works.
# No serial numbers: the file is meant to be shared and compared between machines.
info_hardware() {
  local f i c d p
  {
    echo "--- cpu (model, stepping, microcode)"
    lscpu | grep -E '^(Vendor ID|Model name|CPU family|Model|Stepping|Socket\(s\)|Core\(s\) per socket|Thread\(s\) per core|NUMA node\(s\)|CPU max MHz|CPU min MHz|L1d|L1i|L2|L3)'
    echo "microcode: $(grep -m1 microcode /proc/cpuinfo | awk '{print $3}')  /sys: $(cat /sys/devices/system/cpu/cpu0/microcode/version 2>/dev/null)"
    echo "--- cpu frequency and idle (the BIOS power profile, turbo and C-states show here)"
    for f in scaling_driver scaling_governor cpuinfo_min_freq cpuinfo_max_freq scaling_min_freq scaling_max_freq; do
      printf '%s=%s ' "$f" "$(cat "/sys/devices/system/cpu/cpu0/cpufreq/$f" 2>/dev/null)"; done; echo
    echo "boost: intel_pstate/no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null) cpufreq/boost=$(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null)"
    echo "smt: $(cat /sys/devices/system/cpu/smt/control 2>/dev/null)  cpuidle: driver=$(cat /sys/devices/system/cpu/cpuidle/current_driver 2>/dev/null) governor=$(cat /sys/devices/system/cpu/cpuidle/current_governor_ro 2>/dev/null)"
    if need cpupower; then echo "--- cpupower frequency-info"; cpupower frequency-info 2>&1; echo "--- cpupower idle-info"; cpupower idle-info 2>&1; fi
    echo "--- system and firmware (BIOS version and date; BMC firmware from ipmitool)"
    for f in sys_vendor product_name product_version board_vendor board_name board_version bios_vendor bios_version bios_date bios_release; do
      printf '%s: %s\n' "$f" "$(cat "/sys/class/dmi/id/$f" 2>/dev/null)"; done
    if need dmidecode; then echo "--- dmidecode -t bios"; as_root dmidecode -t bios 2>&1 | grep -E 'Vendor|Version|Release|Revision' || echo "(not available: needs root or sudo -n)"; fi
    if need ipmitool; then echo "--- ipmitool mc info"; as_root ipmitool mc info 2>&1 | grep -vi 'serial' || echo "(not available: needs root or sudo -n, and a BMC)"; fi
    echo "--- memory (DIMMs: slots, size, configured speed; every channel populated?)"
    if need dmidecode && as_root dmidecode -t memory > "$OUT/.dmi-mem" 2>/dev/null && [ -s "$OUT/.dmi-mem" ]; then
      grep -E '^\s*(Locator|Size|Type|Speed|Configured Memory Speed|Manufacturer|Part Number):' "$OUT/.dmi-mem"
      echo "dimms populated: $(grep -cE '^\s*Size: [0-9]+ [MG]B' "$OUT/.dmi-mem") of $(grep -c '^Memory Device$' "$OUT/.dmi-mem") slots"
      echo "configured speed:"; grep 'Configured Memory Speed' "$OUT/.dmi-mem" | sort | uniq -c
    else
      echo "(dmidecode -t memory not available without root; the EDAC view, when the kernel has it:)"
      for d in /sys/devices/system/edac/mc/mc*/dimm*; do [ -d "$d" ] || continue
        printf '%s: %s %s MB %s\n' "$(basename "$d")" "$(cat "$d/dimm_label" 2>/dev/null)" "$(cat "$d/size" 2>/dev/null)" "$(cat "$d/dimm_mem_type" 2>/dev/null)"; done
    fi
    rm -f "$OUT/.dmi-mem"
    echo "--- network interfaces (driver, firmware, offloads; physical interfaces only)"
    for d in /sys/class/net/*; do
      i=$(basename "$d"); [ "$i" = lo ] && continue; [ -e "$d/device" ] || continue
      echo "[$i] state=$(cat "$d/operstate" 2>/dev/null) speed=$(cat "$d/speed" 2>/dev/null) Mb/s mtu=$(cat "$d/mtu" 2>/dev/null)"
      p=$(basename "$(readlink -f "$d/device")"); need lspci && lspci -s "$p" 2>/dev/null | sed 's/^/  /'
      if need ethtool; then
        ethtool -i "$i" 2>/dev/null | grep -E '^(driver|version|firmware-version|bus-info):' | sed 's/^/  /'
        ethtool -k "$i" 2>/dev/null | grep -E 'offload|segmentation' | grep -v '\[fixed\]' | sed 's/^/  /'
      fi
    done
    echo "--- disks (model, firmware revision, size; how many of each model)"
    lsblk -dno NAME,MODEL,REV,SIZE,TRAN,ROTA 2>/dev/null | grep -vE '^(loop|ram|sr|zram)'
    for c in /sys/class/nvme/nvme*; do [ -d "$c" ] || continue
      printf '%s: model=%s firmware=%s\n' "$(basename "$c")" "$(sed 's/ *$//' "$c/model" 2>/dev/null)" "$(sed 's/ *$//' "$c/firmware_rev" 2>/dev/null)"; done
    if ls /sys/class/nvme/nvme* >/dev/null 2>&1; then echo "nvme controllers per model:"; cat /sys/class/nvme/nvme*/model 2>/dev/null | sed 's/ *$//' | sort | uniq -c; fi
    if need smartctl; then
      for d in /dev/nvme*n1; do [ -b "$d" ] || continue
        echo "--- smartctl -i $d"; as_root smartctl -i "$d" 2>&1 | sed -n '/^===/,$p' | grep -vi 'serial' || echo "(not available: needs root or sudo -n)"; done
    fi
    if need ipmitool; then
      echo "--- bmc sensors at the start of the run (ipmitool sdr: temperature, fan; dcmi power)"
      { as_root ipmitool sdr type temperature; as_root ipmitool sdr type fan; as_root ipmitool dcmi power reading; } 2>&1 || echo "(not available: needs root or sudo -n, and a BMC)"
    fi
  } > "$OUT/hardware.txt" 2>&1
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
