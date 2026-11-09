#!/usr/bin/env bash
# lib/rawdev.sh - safety check for RAW_DEV, the whole-disk mode of the disk and burnin stages (which ERASES the device).
# Sourced, never executed.
#
#   raw_problem       print why RAW_DEV cannot be used (nothing when it is fine). Refuses without CONFIRM_WIPE=yes,
#                     a device that is not a block device, one with a filesystem, mount or partitions, or no permission.

raw_problem() { # prints why RAW_DEV cannot be used
  if [ "${CONFIRM_WIPE:-}" != yes ]; then echo "RAW_DEV=$RAW_DEV needs CONFIRM_WIPE=yes (the whole disk is erased)"
  elif [ ! -b "$RAW_DEV" ]; then echo "$RAW_DEV is not a block device"
  elif findmnt -rn -S "$RAW_DEV" >/dev/null || [ -n "$(lsblk -no FSTYPE,MOUNTPOINT "$RAW_DEV" | tr -d ' \n')" ] || [ "$(lsblk -nro NAME "$RAW_DEV" | wc -l)" -gt 1 ]; then
    echo "$RAW_DEV has a filesystem, mount or partitions; refusing"
  elif [ ! -r "$RAW_DEV" ] || [ ! -w "$RAW_DEV" ]; then echo "no read/write permission on $RAW_DEV"
  fi
}
