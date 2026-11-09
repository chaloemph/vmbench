#!/usr/bin/env bash
# stages/web.sh - maximum requests per second within a latency target (loopback, cpubench)
# Sourced by lib/stages.sh, never executed. Functions (see lib/stages.sh for the contract):
#   stage_web_order, _default, _time, _note, _check, _run
# Metric ids: web.* (the table is in lib/metrics.sh)

stage_web_order() { echo 60; }
stage_web_default() { echo no; }
stage_web_time() { echo "5 min"; }
stage_web_note() { echo ""; }

stage_web_check() {
  check_tools jq; check_cpubench
  [ "$QUICK" = 1 ] || [ -x "$CB/web-loopback.sh" ] || PROBLEMS+=("$CB/web-loopback.sh is missing, run setup-cpubench.sh")
}

stage_web_run() {
  log "== web"
  [ -x "$CB/cpubench" ] || { skip web all "$CB/cpubench missing, run setup-cpubench.sh"; return; }
  local port=18080 sp
  if [ "$QUICK" = 1 ]; then
    "$CB/cpubench" web serve --addr 127.0.0.1:$port > "$OUT/web-serve.log" 2>&1 & sp=$!
    sleep 2
    timeout 120 "$CB/cpubench" web load --target "http://127.0.0.1:$port" --endpoint mix --profile ramp --ramp 500:500:1500 --step-duration 3s --warmup 2s \
      --label "$LABEL-web" --machine "$LABEL" -o "$OUT/web.json" > "$OUT/web.log" 2>&1
    kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
  else
    [ -x "$CB/web-loopback.sh" ] || { bad web all "$CB/web-loopback.sh missing"; return; }
    ( cd "$CB" && MACHINE="$LABEL" ./web-loopback.sh "$LABEL-web" > "$OUT/web.log" 2>&1 )
    cp "$CB/results/web/$LABEL-web"-* "$OUT/" 2>/dev/null
  fi
  local f k
  for f in "$OUT/web.json" "$OUT/$LABEL-web-mix.json"; do
    [ -s "$f" ] || continue
    k=$(jq -r '.web.knee_rps // empty' "$f")
    [ -n "$k" ] && { rec web.cpubench.mix.max-rps "$k"; ok web "$(basename "$f")"; }
  done
  [ -n "${k:-}" ] || bad web "max RPS" "see web.log"
  log "web: check that the SERVER CPUs saturated before the load generator (cpustat log, report warnings)"
}
