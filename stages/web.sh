#!/usr/bin/env bash
# stages/web.sh - maximum requests per second within a latency target (loopback, cpubench), repeated WEB_ROUNDS times
# Sourced by lib/stages.sh, never executed. Functions (see lib/stages.sh for the contract):
#   stage_web_order, _default, _time, _note, _check, _run
# Metric ids: web.* (the table is in lib/metrics.sh)
# The full (non-QUICK) run pins the server and the load generator to two halves of the vCPUs: 2 -> 0 | 1,
# 8 -> 0-3 | 4-7, 16 -> 0-7 | 8-15 (an odd count gives the extra CPU to the server). cpubench's web-loopback.sh alone
# always uses 0-3 | 4-7, which fails on fewer than 5 vCPUs (taskset: Invalid argument) and leaves CPUs idle on more
# than 8. WEB_SERVER_CPUS and WEB_LOAD_CPUS (taskset lists) replace the split; the split used goes to the log and to
# meta.json (web_cpus, "SERVER|LOAD"). One vCPU cannot be split: the stage is skipped.

stage_web_order() { echo 60; }
stage_web_default() { echo no; }
stage_web_rounds() { echo "$WEB_ROUNDS"; }
stage_web_time() { rounds_time 6 "${WEB_ROUNDS:-3}"; }   # about 6 min per round (measured: 5.5 to 7)
stage_web_note() { echo ""; }

# web_cpu_split NPROC: "SERVER LOAD" taskset lists, from WEB_SERVER_CPUS / WEB_LOAD_CPUS or the two halves of
# 0..NPROC-1; nothing (exit 1) when NPROC < 2 and no override is set
web_cpu_split() {
  local n=$1 half srv ld
  if [ -n "${WEB_SERVER_CPUS:-}" ] || [ -n "${WEB_LOAD_CPUS:-}" ]; then
    [ -n "${WEB_SERVER_CPUS:-}" ] && [ -n "${WEB_LOAD_CPUS:-}" ] || return 1
    echo "$WEB_SERVER_CPUS $WEB_LOAD_CPUS"; return 0
  fi
  [ "$n" -ge 2 ] 2>/dev/null || return 1
  half=$(( n / 2 ))                       # load gets the smaller half: an odd count gives the server the extra CPU
  srv=$(( n - half ))
  if [ "$srv" = 1 ]; then srv=0; else srv="0-$(( srv - 1 ))"; fi
  if [ "$half" = 1 ]; then ld=$(( n - 1 )); else ld="$(( n - half ))-$(( n - 1 ))"; fi
  echo "$srv $ld"
}

stage_web_check() {
  check_tools jq; check_cpubench
  [ "$QUICK" = 1 ] || [ -x "$CB/web-loopback.sh" ] || PROBLEMS+=("$CB/web-loopback.sh is missing, run setup-cpubench.sh")
  if [ "$QUICK" != 1 ]; then
    if [ -n "${WEB_SERVER_CPUS:-}${WEB_LOAD_CPUS:-}" ] && { [ -z "${WEB_SERVER_CPUS:-}" ] || [ -z "${WEB_LOAD_CPUS:-}" ]; }; then
      PROBLEMS+=("set both WEB_SERVER_CPUS and WEB_LOAD_CPUS, or neither")
    elif ! web_cpu_split "$(nproc)" >/dev/null; then
      PROBLEMS+=("web needs 2 or more vCPUs to split between the server and the load generator (or WEB_SERVER_CPUS and WEB_LOAD_CPUS)")
    fi
  fi
}

stage_web_run() {
  log "== web"
  [ -x "$CB/cpubench" ] || { skip web all "$CB/cpubench missing, run setup-cpubench.sh"; return; }
  local port=18080 sp r f k split srv ld
  if [ "$QUICK" != 1 ]; then
    split=$(web_cpu_split "${NPROC:-$(nproc)}") || { skip web all "needs 2 or more vCPUs to split between server and load generator (or WEB_SERVER_CPUS and WEB_LOAD_CPUS)"; return; }
    srv=${split% *}; ld=${split#* }
    # shellcheck disable=SC2034  # WEB_CPUS_USED is read by write_meta (lib/meta.sh)
    WEB_CPUS_USED="$srv|$ld"
    log "web: server on CPUs $srv, load generator on CPUs $ld (of ${NPROC:-$(nproc)} vCPUs)"
  fi
  for r in $(seq 1 "$WEB_ROUNDS"); do
    ROUND=$r; log "web round $r/$WEB_ROUNDS"; k=""
    if [ "$QUICK" = 1 ]; then
      "$CB/cpubench" web serve --addr 127.0.0.1:$port > "$OUT/web-serve-r$r.log" 2>&1 & sp=$!
      sleep 2
      timeout 120 "$CB/cpubench" web load --target "http://127.0.0.1:$port" --endpoint mix --profile ramp --ramp 500:500:1500 --step-duration 3s --warmup 2s \
        --label "$LABEL-web-r$r" --machine "$LABEL" -o "$OUT/web-r$r.json" > "$OUT/web-r$r.log" 2>&1
      kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
    else
      [ -x "$CB/web-loopback.sh" ] || { bad web all "$CB/web-loopback.sh missing"; return; }
      ( cd "$CB" && MACHINE="$LABEL" SERVER_CPUS="$srv" LOAD_CPUS="$ld" ./web-loopback.sh "$LABEL-web-r$r" > "$OUT/web-r$r.log" 2>&1 )
      cp "$CB/results/web/$LABEL-web-r$r"-* "$OUT/" 2>/dev/null
    fi
    for f in "$OUT/web-r$r.json" "$OUT/$LABEL-web-r$r-mix.json"; do
      [ -s "$f" ] || continue
      k=$(jq -r '.web.knee_rps // empty' "$f")
      [ -n "$k" ] && { rec web.cpubench.mix.max-rps "$k"; ok web "$(basename "$f")"; break; }
    done
    [ -n "$k" ] || bad web "max RPS r$r" "see web-r$r.log"
  done
  # shellcheck disable=SC2034  # ROUND is read by rec (lib/metrics.sh)
  ROUND=1
  log "web: check that the SERVER CPUs saturated before the load generator (cpustat log, report warnings)"
}
