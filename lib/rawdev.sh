#!/usr/bin/env bash
# lib/rawdev.sh - safety checks for whole-disk tests, which ERASE the device: RAW_DEV (disk and burnin stages) and
# NVME_DEVS (nvme and burnin stages). Sourced, never executed.
#
#   raw_problem [DEV]     print why DEV (default RAW_DEV) cannot be used, nothing when it is fine. Refuses without
#                         CONFIRM_WIPE=yes, a device that is not a block device, one with a filesystem, mount or
#                         partitions (so never the OS disk), or no permission.
#   nvme_dev_list         the devices of NVME_DEVS ("nvme1n1 nvme2n1", names or /dev paths, space or comma separated)
#                         as /dev paths, one per line
#   nvme_dev_count        how many there are (0 when NVME_DEVS is empty)
#   nvme_devs_problems    add to PROBLEMS everything that stops NVME_DEVS from being used (pre-flight)

raw_problem() { # [DEV]: prints why the device cannot be used
  local dev=${1:-$RAW_DEV}
  if [ "${CONFIRM_WIPE:-}" != yes ]; then echo "$dev needs CONFIRM_WIPE=yes (the whole disk is erased)"
  elif [ ! -b "$dev" ]; then echo "$dev is not a block device"
  elif findmnt -rn -S "$dev" >/dev/null || [ -n "$(lsblk -no FSTYPE,MOUNTPOINT "$dev" | tr -d ' \n')" ] || [ "$(lsblk -nro NAME "$dev" | wc -l)" -gt 1 ]; then
    echo "$dev has a filesystem, mount or partitions; refusing"
  elif [ ! -r "$dev" ] || [ ! -w "$dev" ]; then echo "no read/write permission on $dev"
  fi
}

nvme_dev_list() {
  local d
  for d in ${NVME_DEVS//,/ }; do
    case $d in /dev/*) echo "$d" ;; *) echo "/dev/$d" ;; esac
  done
}
nvme_dev_count() { if [ -n "${NVME_DEVS:-}" ]; then nvme_dev_list | wc -l; else echo 0; fi; }

nvme_devs_problems() {
  local d p seen=" "
  if [ -z "${NVME_DEVS:-}" ]; then
    PROBLEMS+=("no devices: set NVME_DEVS=\"nvme1n1 nvme2n1\" (every listed disk is ERASED, never list the OS disk)"); return
  fi
  while read -r d; do
    case $seen in *" $d "*) PROBLEMS+=("$d is listed twice in NVME_DEVS"); continue ;; esac
    seen="$seen$d "
    p=$(raw_problem "$d"); [ -z "$p" ] || PROBLEMS+=("$p")
  done < <(nvme_dev_list)
}
