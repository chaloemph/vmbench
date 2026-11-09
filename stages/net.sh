#!/usr/bin/env bash
# stages/net.sh - iperf3 TCP and UDP and sockperf latency against a peer machine
# Sourced by lib/stages.sh, never executed. Functions (see lib/stages.sh for the contract):
#   stage_net_order, _default, _time, _note, _check, _run
# Metric ids: net.* (the table is in lib/metrics.sh)

stage_net_order() { echo 50; }
stage_net_default() { echo no; }
stage_net_time() { echo "3 min"; }
stage_net_note() { echo "needs --peer"; }

stage_net_check() {
  check_tools iperf3 sockperf jq
  if [ -z "$PEER" ]; then PROBLEMS+=("no peer, use --peer HOST")
  elif need iperf3 && ! timeout 10 iperf3 -c "$PEER" -t 1 >/dev/null 2>&1; then
    PROBLEMS+=("no iperf3 server reachable at $PEER (the peer must run: iperf3 -s -D ; sockperf server -i 0.0.0.0 &)")
  fi
}

stage_net_run() {
  log "== net"
  [ -n "$PEER" ] || { skip net all "PEER not set (peer must run: iperf3 -s -D ; sockperf server -i 0.0.0.0 &)"; return; }
  local d; d=$(T 60 5)
  if need iperf3 && iperf3 -c "$PEER" -t 1 > /dev/null 2>&1; then
    iperf3 -c "$PEER" -P 8 -t "$d" --bidir -J > "$OUT/iperf-tcp.json" 2>/dev/null
    local a b
    a=$(jq -r '.end.sum_received.bits_per_second/1e9' "$OUT/iperf-tcp.json" 2>/dev/null); b=$(jq -r '.end.sum_received_bidir_reverse.bits_per_second/1e9' "$OUT/iperf-tcp.json" 2>/dev/null)
    if [ -n "$a" ] && [ "$a" != null ]; then
      rec net.iperf3.tcp.tx "$a"; rec net.iperf3.tcp.rx "${b:-0}"
      rec net.iperf3.tcp.bidir "$(awk -v x="$a" -v y="${b:-0}" 'BEGIN{print x+y}')"; ok net iperf-tcp
    else bad net iperf-tcp "see iperf-tcp.json"; fi
    iperf3 -c "$PEER" -u -b 0 -l 64 -P 8 -t "$d" -J > "$OUT/iperf-udp.json" 2>/dev/null
    local p; p=$(jq -r '.end.sum.packets' "$OUT/iperf-udp.json" 2>/dev/null)
    if [ -n "$p" ] && [ "$p" != null ]; then rec net.iperf3.udp.pps "$(awk -v p="$p" -v d="$d" 'BEGIN{printf "%.3f", p/d/1e6}')"
      rec net.iperf3.udp.loss "$(jq -r '.end.sum.lost_percent' "$OUT/iperf-udp.json")"; ok net iperf-udp
    else bad net iperf-udp "see iperf-udp.json"; fi
  else skip net iperf3 "iperf3 missing or $PEER:5201 unreachable"; fi
  if need sockperf; then
    timeout $((d + 30)) sockperf ping-pong -i "$PEER" -t "$d" > "$OUT/sockperf.txt" 2>&1
    local avg p99
    avg=$(grep -oE 'avg-latency=[0-9.]+' "$OUT/sockperf.txt" | head -1 | cut -d= -f2); p99=$(awk '/percentile 99.000/{print $NF}' "$OUT/sockperf.txt")
    if [ -n "$avg" ]; then rec net.sockperf.pingpong.avg "$avg"; [ -n "$p99" ] && rec net.sockperf.pingpong.p99 "$p99"; ok net sockperf
    else bad net sockperf "see sockperf.txt (is 'sockperf server' running on $PEER?)"; fi
  else skip net sockperf "not installed"; fi
}
