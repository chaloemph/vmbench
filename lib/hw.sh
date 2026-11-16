#!/usr/bin/env bash
# lib/hw.sh - helpers for the hardware facts and BMC readings that a bare-metal checklist asks for: running a tool as
# root when that is possible without a prompt, and the power reading of the BMC. Sourced, never executed.
#
#   as_root CMD...                 run CMD as root: directly when we are root, through `sudo -n` when sudo needs no
#                                  password; otherwise return 127 (the caller treats that as "not available"). The
#                                  answer of sudo is asked once and kept in SUDO_OK.
#   power_reading                  one reading of the system power from the BMC (ipmitool dcmi power reading), in W;
#                                  prints nothing when there is no BMC, no ipmitool or no permission
#   power_sampler_start FILE SEC   append "<epoch> <W>" to FILE every SEC seconds in the background (POWER_PID)
#   power_sampler_stop             stop it
#   power_avg FILE [TAIL_SEC]      mean of the samples of FILE in its last TAIL_SEC seconds (all of them without
#                                  TAIL_SEC), one decimal; prints nothing when the file has no sample
#   cpu_mhz_now                    the average clock of all CPUs right now, from /proc/cpuinfo (x86) or cpufreq

as_root() {
  if [ "$(id -u)" = 0 ]; then "$@"; return; fi
  if [ -z "${SUDO_OK:-}" ]; then
    if need sudo && sudo -n true 2>/dev/null; then SUDO_OK=1; else SUDO_OK=0; fi
  fi
  [ "$SUDO_OK" = 1 ] || return 127
  sudo -n "$@"
}

power_reading() {
  need ipmitool || return 0
  as_root ipmitool dcmi power reading 2>/dev/null | awk '/Instantaneous power reading/{v=$(NF-1)} END{if(v ~ /^[0-9.]+$/) print v}'
}

POWER_PID=""
power_sampler_start() { # FILE SEC
  local f=$1 iv=$2
  ( while :; do w=$(power_reading); [ -n "$w" ] && printf '%s %s\n' "$(date +%s)" "$w" >> "$f"; sleep "$iv"; done ) &
  POWER_PID=$!
}
power_sampler_stop() {
  [ -n "$POWER_PID" ] || return 0
  kill "$POWER_PID" 2>/dev/null; wait "$POWER_PID" 2>/dev/null
  POWER_PID=""
}

power_avg() { # FILE [TAIL_SEC]
  [ -s "$1" ] || return 0
  awk -v tail="${2:-0}" '
    $2 ~ /^[0-9.]+$/ { t[++n] = $1; v[n] = $2 }
    END { if (!n) exit; from = (tail > 0) ? t[n] - tail : 0
          for (i = 1; i <= n; i++) if (t[i] >= from) { s += v[i]; k++ }
          if (k) printf "%.1f\n", s / k }' "$1"
}

cpu_mhz_now() {
  local v
  v=$(awk '/^cpu MHz/{s+=$4; n++} END{if (n) printf "%.0f", s/n}' /proc/cpuinfo 2>/dev/null)
  if [ -z "$v" ]; then
    v=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null | awk '{s+=$1; n++} END{if (n) printf "%.0f", s/n/1000}')
  fi
  printf '%s' "$v"
}
