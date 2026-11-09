#!/usr/bin/env bash
# stages/pg.sh - pgbench TPC-B-like throughput, stability and single-session latency
# Sourced by lib/stages.sh, never executed. Functions (see lib/stages.sh for the contract):
#   stage_pg_order, _default, _time, _note, _check, _run
# Metric ids: pg.* (the table is in lib/metrics.sh)

stage_pg_order() { echo 40; }
stage_pg_default() { echo no; }
stage_pg_time() { echo "16 min+load"; }
stage_pg_note() { echo "needs setup-postgres-bench.sh"; }

stage_pg_check() {
  check_tools pgbench psql
  if need psql && ! timeout 10 psql -X -Atc 'select 1' >/dev/null 2>&1; then
    PROBLEMS+=("cannot connect to db $PGDATABASE on port $PGPORT, run setup-postgres-bench.sh first")
  fi
}

stage_pg_run() {
  log "== pg"
  need pgbench && need psql || { skip pg pgbench "not installed"; return; }
  if ! psql -X -Atc 'select 1' > /dev/null 2>&1; then
    skip pg database "cannot connect to db $PGDATABASE on port $PGPORT, run setup-postgres-bench.sh first"; return; fi
  psql -X -Atc "show data_directory" -c "show shared_buffers" -c "show max_wal_size" -c "show synchronous_commit" > "$OUT/pg-settings.txt" 2>&1
  local ddir free scale c j
  ddir=$(psql -X -Atc "show data_directory" 2>/dev/null); ddir=${ddir:-/}
  free=$(df -BG --output=avail "$ddir" 2>/dev/null | tail -1 | tr -dc 0-9); free=${free:-0}
  scale=${PG_SCALE:-$(awk -v r="$RAM_GB" -v f="$free" 'BEGIN{s=r*1.5*64; m=int(f*0.6/0.0157); if(m<s)s=m; if(s<10)s=10; print int(s)}')}
  [ "$QUICK" = 1 ] && scale=${PG_SCALE:-20}
  c=$((NPROC * 2)); j=$((NPROC / 2)); [ "$j" -lt 1 ] && j=1
  log "pgbench scale $scale (~$(awk -v s="$scale" 'BEGIN{printf "%.0f", s*0.0157}') GB), free ${free} GB, -c $c -j $j"
  pgbench -i -s "$scale" -I dtGvp > "$OUT/pgbench-init.log" 2>&1 || { bad pg "pgbench init" "see pgbench-init.log"; return; }
  ok pg "pgbench init"
  pgbench -c "$c" -j "$j" -T "$(T 60 5)" > "$OUT/pgbench-warmup.log" 2>&1
  pgbench -c "$c" -j "$j" -T "$(T 600 10)" -P 10 > "$OUT/pgbench-tpcb.log" 2>&1
  local tps; tps=$(awk '/^tps =/{print $3}' "$OUT/pgbench-tpcb.log")
  if [ -n "$tps" ]; then
    rec pg.pgbench.tpcb.tps "$tps" "$c"
    awk '/^progress:/{v[++n]=$4} END{ if(n>1){ for(i=2;i<=n;i++){s+=v[i];q+=v[i]*v[i]} k=n-1; m=s/k; sd=sqrt(q/k-m*m); printf "%.2f\n", 100*(1-sd/m)} }' "$OUT/pgbench-tpcb.log" > "$OUT/.stab"
    [ -s "$OUT/.stab" ] && rec pg.pgbench.tpcb.stability "$(cat "$OUT/.stab")"; rm -f "$OUT/.stab"
    ok pg "pgbench tpcb"
  else bad pg "pgbench run" "see pgbench-tpcb.log"; fi
  pgbench -c 1 -j 1 -T "$(T 300 10)" -P 10 -r > "$OUT/pgbench-single.log" 2>&1
  local lat; lat=$(awk '/^latency average =/{print $4}' "$OUT/pgbench-single.log")
  [ -n "$lat" ] && rec pg.pgbench.latency.single "$lat" && ok pg "pgbench single-session" || bad pg "pgbench single-session"
  log "pgbench data remains in db $PGDATABASE (~$(awk -v s="$scale" 'BEGIN{printf "%.0f", s*0.0157}') GB). Drop with: dropdb $PGDATABASE && createdb $PGDATABASE"
}
