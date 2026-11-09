#!/usr/bin/env bash
# stages/web.sh - maximum requests per second within a latency target (loopback, cpubench), repeated WEB_ROUNDS times
# Sourced by lib/stages.sh, never executed. Functions (see lib/stages.sh for the contract):
#   stage_web_order, _default, _time, _note, _check, _run
# Metric ids: web.* (the table is in lib/metrics.sh)

stage_web_order() { echo 60; }
stage_web_default() { echo no; }
stage_web_rounds() { echo "$WEB_ROUNDS"; }
stage_web_time() { rounds_time 5 "${WEB_ROUNDS:-3}"; }   # about 5 min per round
stage_web_note() { echo ""; }

stage_web_check() {
  check_tools jq; check_cpubench
  [ "$QUICK" = 1 ] || [ -x "$CB/web-loopback.sh" ] || PROBLEMS+=("$CB/web-loopback.sh is missing, run setup-cpubench.sh")
}

stage_web_run() {
  log "== web"
  [ -x "$CB/cpubench" ] || { skip web all "$CB/cpubench missing, run setup-cpubench.sh"; return; }
  local port=18080 sp r f k
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
      ( cd "$CB" && MACHINE="$LABEL" ./web-loopback.sh "$LABEL-web-r$r" > "$OUT/web-r$r.log" 2>&1 )
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
