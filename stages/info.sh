#!/usr/bin/env bash
# stages/info.sh - records the kernel, CPU model, flags, NUMA layout, disks and tool versions (always runs)
# Sourced by lib/stages.sh, never executed. Functions (see lib/stages.sh for the contract):
#   stage_info_order, _default, _time, _note, _check, _run
# Metric ids: info.* (the table is in lib/metrics.sh)

stage_info_order() { echo 0; }
stage_info_default() { echo always; }
stage_info_time() { echo ""; }
stage_info_note() { echo ""; }

stage_info_check() { :; }   # nothing to check: it only reads the machine

stage_info_run() {
  log "== info"
  {
    echo "date: $(date -Is)"; echo "label: $LABEL"; echo "host: $(hostname)"; echo "kernel: $(uname -srm)"
    . /etc/os-release; echo "os: $PRETTY_NAME"; echo "virt: $(systemd-detect-virt 2>/dev/null)"
    echo "nproc: $NPROC  ram_gb: $RAM_GB"; echo "quick: $QUICK  rounds: $ROUNDS  fio_size: $FIO_SIZE  raw_dev: ${RAW_DEV:-none}"
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
  if [ "$(awk '{print int($1*100)}' /proc/loadavg)" -gt 50 ]; then log "[WARN] load average is $(cut -d' ' -f1 /proc/loadavg), the machine is not idle"; fi
  FREE_GB=$(df -BG --output=avail "$DATA_DIR" | tail -1 | tr -dc 0-9)
  log "free space in $DATA_DIR: ${FREE_GB} GB"
  [ "$FREE_GB" -ge 15 ] || log "[WARN] less than 15 GB free, disk stage will be refused"
}
