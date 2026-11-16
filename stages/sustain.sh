#!/usr/bin/env bash
# stages/sustain.sh - sustained all-core load (stress-ng matrixprod, 30 minutes by default): the clock the CPU holds
# once it is hot, the package temperature and power (turbostat), and the system power from the BMC at idle, at 50%
# load and at full load (ipmitool dcmi). This is what a bare-metal checklist means by "all-core clock under sustained
# load", "thermal headroom" and "power at idle / 50% / full load". Only when asked (--with sustain).
# Sourced by lib/stages.sh, never executed. Functions (see lib/stages.sh for the contract):
#   stage_sustain_order, _default, _time, _note, _check, _run
# Metric ids: sustain.* (the table is in lib/metrics.sh)
#
# Needs stress-ng. turbostat (root or sudo -n, x86 with MSR access; not inside most VMs) adds Bzy_MHz, PkgTmp and
# PkgWatt; without it the clock comes from /proc/cpuinfo or cpufreq, which a VM may report as a fixed nominal value.
# ipmitool (root or sudo -n, a BMC) adds the system power and fan speeds; without it the power phases are skipped.
# Settings: SUSTAIN_MINUTES (full load, default 30), SUSTAIN_50_MINUTES (50% load, default 15), TJMAX (Tjmax in C when
# turbostat does not print it, for the headroom). QUICK=1 runs that many seconds instead of minutes.
# Files: sustain.txt (what was used and found), turbostat.txt, sustain-mhz.txt (clock samples from the kernel),
# sustain-power-{idle,full,load50}.txt (BMC samples), sustain-sensors.txt (BMC temperatures and fans at the end of
# the full load), stress-ng-*.log.

stage_sustain_order() { echo 65; }
stage_sustain_default() { echo no; }
stage_sustain_time() { echo "$(( ${SUSTAIN_MINUTES:-30} + ${SUSTAIN_50_MINUTES:-15} + 2 )) min"; }
stage_sustain_note() { echo "needs stress-ng; turbostat and ipmitool (as root) add clock, temperature and power"; }

stage_sustain_check() {
  check_tools stress-ng
}

# turbostat_stats FILE K: "<mhz avg> <temp max> <watt avg>" over the last K sample rows of a --Summary turbostat
# file (the temperature maximum is over all rows); a field is "-" when the column is absent. The columns are found
# by name in the header line, because turbostat prints them in its own order and leaves out what the CPU lacks.
turbostat_stats() {
  awk -v k="$2" '
    /Bzy_MHz|PkgTmp|PkgWatt|Busy%/ { delete c; for (i = 1; i <= NF; i++) c[$i] = i; next }
    NF && $1 ~ /^[0-9.]+$/ {
      n++; m[n] = ("Bzy_MHz" in c) ? $c["Bzy_MHz"] : ""; t[n] = ("PkgTmp" in c) ? $c["PkgTmp"] : ""; w[n] = ("PkgWatt" in c) ? $c["PkgWatt"] : "" }
    END { if (!n) exit
          from = (k > 0 && n > k) ? n - k + 1 : 1; tmax = -1
          for (i = 1; i <= n; i++) if (t[i] != "" && t[i] + 0 > tmax) tmax = t[i] + 0
          for (i = from; i <= n; i++) { if (m[i] != "") { ms += m[i]; mn++ }; if (w[i] != "") { ws += w[i]; wn++ } }
          printf "%s %s %s\n", (mn ? sprintf("%.0f", ms / mn) : "-"), (tmax >= 0 ? tmax : "-"), (wn ? sprintf("%.1f", ws / wn) : "-") }' "$1"
}
# tail_avg FILE K: mean of the second column over the last K lines whose second column is a number
tail_avg() { awk '$2 ~ /^[0-9.]+$/{print $2}' "$1" | tail -n "$2" | awk '{s+=$1; n++} END{if (n) printf "%.0f", s/n}'; }

stage_sustain_run() {
  log "== sustain"
  need stress-ng || { skip sustain all "stress-ng missing"; return; }
  local full half idle tail tail50 iv ts=0 ipmi=0 k sp tp="" v w
  # QUICK=1 runs seconds where the real run has minutes (SUSTAIN_MINUTES=30 -> 30 s), sampled every second
  full=$(T $((SUSTAIN_MINUTES * 60)) "$SUSTAIN_MINUTES"); half=$(T $((SUSTAIN_50_MINUTES * 60)) "$SUSTAIN_50_MINUTES"); idle=$(T 120 3)
  tail=$(T 300 5); tail50=$(T 600 3); iv=$(T 10 1); k=$((tail / iv))
  # what is available: turbostat as root (one short probe, which also prints Tjmax on Intel), the BMC power reading
  if need turbostat && as_root turbostat --num_iterations 1 --interval 1 --show Busy%,Bzy_MHz,PkgTmp,PkgWatt > "$OUT/turbostat-probe.txt" 2>&1; then ts=1; fi
  [ -n "$(power_reading)" ] && ipmi=1
  local tjmax=${TJMAX:-}
  [ -n "$tjmax" ] || tjmax=$(grep -oE 'TEMPERATURE_TARGET: 0x[0-9a-fA-F]+ \([0-9]+ C\)' "$OUT/turbostat-probe.txt" 2>/dev/null | head -1 | grep -oE '[0-9]+ C' | cut -d' ' -f1)
  {
    echo "full load: ${full}s stress-ng --cpu 0 --cpu-method matrixprod; averages over the last ${tail}s, samples every ${iv}s"
    echo "turbostat: $([ "$ts" = 1 ] && echo "yes (as root)" || echo "no: not installed, no permission, or no MSR access (a VM)")"
    echo "bmc power: $([ "$ipmi" = 1 ] && echo "yes (ipmitool dcmi power reading as root)" || echo "no: no ipmitool, no permission or no BMC")"
    echo "tjmax: ${tjmax:-unknown (set TJMAX=<C> for the headroom)}$([ -n "${TJMAX:-}" ] && echo " (from TJMAX)")"
  } > "$OUT/sustain.txt"

  # idle power
  if [ "$ipmi" = 1 ]; then
    power_sampler_start "$OUT/sustain-power-idle.txt" "$iv"; sleep "$idle"; power_sampler_stop
    v=$(power_avg "$OUT/sustain-power-idle.txt")
    [ -n "$v" ] && rec sustain.ipmi.power.idle "$v" && ok sustain "power idle" || bad sustain "power idle" "no reading"
  else skip sustain "power idle" "no BMC power reading"; fi

  # full load: stress-ng on every CPU; turbostat and the kernel clock sampled meanwhile, the BMC power too
  stress-ng --cpu 0 --cpu-method matrixprod --timeout "$full" --metrics-brief > "$OUT/stress-ng-full.log" 2>&1 &
  sp=$!
  if [ "$ts" = 1 ]; then
    as_root turbostat --quiet --Summary --interval "$iv" --num_iterations $((full / iv)) --show Busy%,Bzy_MHz,PkgTmp,PkgWatt > "$OUT/turbostat.txt" 2> "$OUT/turbostat.err" &
    tp=$!
  fi
  [ "$ipmi" = 1 ] && power_sampler_start "$OUT/sustain-power-full.txt" "$iv"
  : > "$OUT/sustain-mhz.txt"
  while kill -0 "$sp" 2>/dev/null; do
    printf '%s %s\n' "$(date +%s)" "$(cpu_mhz_now)" >> "$OUT/sustain-mhz.txt"; sleep "$iv"
  done
  wait "$sp"
  [ "$ipmi" = 1 ] && power_sampler_stop
  [ -z "$tp" ] || wait "$tp"
  if [ "$ipmi" = 1 ]; then   # the sensors while the machine is still hot
    { as_root ipmitool sdr type temperature; as_root ipmitool sdr type fan; } > "$OUT/sustain-sensors.txt" 2>&1
  fi
  # the clock: turbostat Bzy_MHz when it ran, else the kernel's view
  local mhz="-" tmax="-" watt="-" src
  if [ "$ts" = 1 ] && [ -s "$OUT/turbostat.txt" ]; then read -r mhz tmax watt < <(turbostat_stats "$OUT/turbostat.txt" "$k"); fi
  if [ "$mhz" != "-" ] && [ -n "$mhz" ]; then src="turbostat Bzy_MHz"
  else mhz=$(tail_avg "$OUT/sustain-mhz.txt" "$k"); src="/proc/cpuinfo or cpufreq (a VM may show a fixed nominal clock)"; fi
  echo "clock source: $src" >> "$OUT/sustain.txt"
  if [ -n "$mhz" ]; then rec sustain.stress-ng.all-core-mhz.max "$mhz" && ok sustain "all-core clock ($src)"
  else bad sustain "all-core clock" "no clock samples"; fi
  if [ "$tmax" != "-" ] && [ -n "$tmax" ]; then
    rec sustain.turbostat.pkg-temp.peak "$tmax"; ok sustain "package temperature"
    if [ -n "$tjmax" ]; then rec sustain.turbostat.thermal-headroom "$(awk -v a="$tjmax" -v b="$tmax" 'BEGIN{printf "%.0f", a - b}')"; echo "headroom: $tjmax - $tmax" >> "$OUT/sustain.txt"
    else skip sustain "thermal headroom" "Tjmax unknown (set TJMAX=<C>)"; fi
  else skip sustain "package temperature" "no turbostat PkgTmp"; fi
  if [ "$watt" != "-" ] && [ -n "$watt" ]; then rec sustain.turbostat.pkg-watt.full "$watt"
  else skip sustain "package power" "no turbostat PkgWatt"; fi
  if [ "$ipmi" = 1 ]; then
    v=$(power_avg "$OUT/sustain-power-full.txt" "$tail")
    [ -n "$v" ] && rec sustain.ipmi.power.full "$v" && ok sustain "power full load" || bad sustain "power full load" "no reading"
    w=$(grep -oE '[0-9]+ RPM' "$OUT/sustain-sensors.txt" 2>/dev/null | awk '{if ($1+0 > m) m = $1+0} END{if (m) print m}')
    [ -z "$w" ] || rec sustain.ipmi.fan.peak "$w"
  fi

  # 50% load: only for the power reading, so only with a BMC
  if [ "$ipmi" = 1 ]; then
    power_sampler_start "$OUT/sustain-power-load50.txt" "$iv"
    stress-ng --cpu 0 --cpu-load 50 --timeout "$half" --metrics-brief > "$OUT/stress-ng-load50.log" 2>&1
    power_sampler_stop
    v=$(power_avg "$OUT/sustain-power-load50.txt" "$tail50")
    [ -n "$v" ] && rec sustain.ipmi.power.load-50 "$v" && ok sustain "power 50% load" || bad sustain "power 50% load" "no reading"
  else skip sustain "power 50% load" "no BMC power reading"; fi
  log "sustain: see sustain.txt (clock source, Tjmax) and turbostat.txt / sustain-power-*.txt for the samples"
}
