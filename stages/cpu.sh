#!/usr/bin/env bash
# stages/cpu.sh - sysbench, 7-Zip, OpenSSL and cpubench CPU tests, repeated ROUNDS times
# Sourced by lib/stages.sh, never executed. Functions (see lib/stages.sh for the contract):
#   stage_cpu_order, _default, _time, _note, _check, _run
# Metric ids: cpu.* (the table is in lib/metrics.sh)

stage_cpu_order() { echo 10; }
stage_cpu_default() { echo yes; }
stage_cpu_rounds() { echo "$ROUNDS"; }
# 14 min for the default 3 rounds, so about 4.7 min per round
stage_cpu_time() { echo "$(( (${ROUNDS:-3} * 14 + 2) / 3 )) min"; }
stage_cpu_note() { echo "default"; }

stage_cpu_check() {
  check_tools sysbench 7z openssl jq; check_cpubench
}

stage_cpu_run() {
  log "== cpu"
  local r st mt out
  for r in $(seq 1 "$ROUNDS"); do
    ROUND=$r; log "cpu round $r/$ROUNDS"
    if need sysbench; then
      st=$(sysbench cpu --cpu-max-prime=20000 --threads=1 --time="$(T 60 5)" run 2>&1 | tee "$OUT/sysbench-st-r$r.txt" | awk '/events per second/{print $4}')
      mt=$(sysbench cpu --cpu-max-prime=20000 --threads="$NPROC" --time="$(T 60 5)" run 2>&1 | tee "$OUT/sysbench-mt-r$r.txt" | awk '/events per second/{print $4}')
      [ -n "$st" ] && rec cpu.sysbench.prime.1t "$st" && ok cpu "sysbench st r$r" || bad cpu "sysbench st r$r"
      [ -n "$mt" ] && rec cpu.sysbench.prime.max "$mt" && ok cpu "sysbench mt r$r" || bad cpu "sysbench mt r$r"
    else skip cpu sysbench "not installed"; fi
    if need 7z; then
      out=$(7z b -mmt="$NPROC" 2>&1 | tee "$OUT/7z-r$r.txt" | awk '/^Tot:/{print $NF}')
      [ -n "$out" ] && rec cpu.7z.rating.max "$out" && ok cpu "7z r$r" || bad cpu "7z r$r"
    else skip cpu 7z "not installed"; fi
    if [ -x "$CB/cpubench" ]; then
      local q=(); [ "$QUICK" = 1 ] && q=(--scale 0.05)
      "$CB/cpubench" run --label "$LABEL-r$r" --machine "$LABEL" --threads 1,max --iterations "$(T 5 1)" "${q[@]}" \
        --suite crypto,float/fft,float/matmul,float/nbody,int/json,int/regex,int/sort,int/hashmap,int/compress,int/decompress \
        -o "$OUT/cpubench-r$r.json" > "$OUT/cpubench-r$r.log" 2>&1
      if [ -s "$OUT/cpubench-r$r.json" ]; then
        local n t v u id
        while IFS=$'\t' read -r n t v u; do
          id=cpu.cpubench.${n//\//.}.$(tv "$t")
          [ -n "${M_LABEL[$id]:-}" ] && rec "$id" "$v" "" "$u"   # benchmarks not in the table are ignored
        done < <(jq -r '.benchmarks[] | [.name,.threads,.stats.median,.unit] | @tsv' "$OUT/cpubench-r$r.json")
        ok cpu "cpubench r$r"
      else bad cpu "cpubench r$r" "see cpubench-r$r.log"; fi
    else skip cpu cpubench "$CB/cpubench missing, run setup-cpubench.sh"; fi
    if need openssl; then
      local o1 om
      o1=$(openssl speed -seconds "$(T 10 2)" -mr -evp aes-256-gcm 2>/dev/null | awk -F: '/^\+F:/{v=$NF} END{printf "%.1f", v/1e6}')
      om=$(openssl speed -seconds "$(T 10 2)" -mr -multi "$NPROC" -evp aes-256-gcm 2>/dev/null | awk -F: '/^\+F:/{v=$NF} END{printf "%.1f", v/1e6}')
      rec cpu.openssl.aes-256-gcm.1t "$o1"; rec cpu.openssl.aes-256-gcm.max "$om"; ok cpu "openssl r$r"
    fi
  done
  # shellcheck disable=SC2034  # ROUND is read by rec (lib/metrics.sh)
  ROUND=1
}
