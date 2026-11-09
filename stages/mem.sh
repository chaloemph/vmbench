#!/usr/bin/env bash
# stages/mem.sh - STREAM bandwidth and lmbench lat_mem_rd latency
# Sourced by lib/stages.sh, never executed. Functions (see lib/stages.sh for the contract):
#   stage_mem_order, _default, _time, _note, _check, _run
# Metric ids: mem.* (the table is in lib/metrics.sh)

stage_mem_order() { echo 20; }
stage_mem_default() { echo yes; }
stage_mem_time() { echo "1 min"; }
stage_mem_note() { echo "default"; }

stage_mem_check() {
  check_tools gcc
  dpkg -L lmbench 2>/dev/null | grep -q 'lat_mem_rd$' || PROBLEMS+=("lmbench is not installed")
  if [ -n "${STREAM_C:-}" ]; then
    [ -s "$STREAM_C" ] || PROBLEMS+=("STREAM_C=$STREAM_C is not a readable file")
  elif [ ! -s "$HOME/bench-cache/stream.c" ]; then
    check_tools curl
  fi
  [ "${STREAM_SKIP_CHECK:-}" = 1 ] || { need sha256sum || need shasum || PROBLEMS+=("sha256sum is not installed (needed to verify stream.c; see STREAM_SKIP_CHECK in the README)"); }
}

# stream.c is pinned (lib/stream.sh): it is only compiled when it has the pinned sha256, whatever its source
stage_mem_run() {
  log "== mem"
  local src=$OUT/stream.c n nt
  local fetched=0
  if stream_fetch "$src"; then fetched=1; echo "stream: $STREAM_SOURCE_NOTE" >> "$OUT/info.txt"
  else bad mem "stream.c" "not fetched or not verified, see run.log"; fi
  if [ "$fetched" = 1 ] && need gcc; then
    n=$(awk -v m="$MEM_AVAIL_KB" 'BEGIN{n=int(m*1024*0.30/24); if(n>100000000)n=100000000; print n}')
    [ "$QUICK" = 1 ] && n=20000000
    nt=$(T 20 3)
    # same N on both architectures; aarch64 static data must stay under 4 GB (3 arrays x 8 bytes x N = 2.4 GB at N=100M)
    local model=(); [ "$(uname -m)" = x86_64 ] && model=(-mcmodel=medium)
    if gcc -O3 -fopenmp "${model[@]}" -DSTREAM_ARRAY_SIZE="$n" -DNTIMES="$nt" "$src" -o "$OUT/stream" 2> "$OUT/stream-build.log"; then
      OMP_NUM_THREADS=$NPROC OMP_PROC_BIND=spread OMP_PLACES=cores "$OUT/stream" > "$OUT/stream.txt" 2>&1
      local cp tr
      cp=$(awk '/^Copy:/{print $2}' "$OUT/stream.txt"); tr=$(awk '/^Triad:/{print $2}' "$OUT/stream.txt")
      [ -n "$tr" ] && rec mem.stream.triad.max "$tr" "$n" && ok mem stream || bad mem stream
      [ -n "$cp" ] && rec mem.stream.copy.max "$cp" "$n"
      rm -f "$OUT/stream" "$src"
    else bad mem "compile stream" "see stream-build.log"; fi
  elif [ "$fetched" = 1 ]; then skip mem stream "gcc missing"; fi
  local lat; lat=$(dpkg -L lmbench 2>/dev/null | grep -m1 'lat_mem_rd$')
  if [ -n "$lat" ]; then
    local mb; mb=$(awk -v m="$MEM_AVAIL_KB" -v q="$QUICK" 'BEGIN{x=int(m/1024*0.30); lim=(q==1)?64:2048; if(x>lim)x=lim; print x}')
    "$lat" -t -P 1 -N "$(T 3 1)" "$mb" 128 > "$OUT/lat_mem_rd.txt" 2>&1
    local v; v=$(awk 'NF==2 && $1+0>0 {l=$2} END{print l}' "$OUT/lat_mem_rd.txt")
    [ -n "$v" ] && rec mem.lmbench.lat-mem-rd.1t "$v" "$mb" && ok mem lat_mem_rd || bad mem lat_mem_rd
  else skip mem lat_mem_rd "lmbench not installed"; fi
}
