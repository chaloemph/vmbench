#!/usr/bin/env bash
# stages/pg.sh - pgbench TPC-B-like throughput, stability and single-session latency, repeated PG_ROUNDS times
# The data is loaded once (pgbench -i). Every round then runs CHECKPOINT, a warm-up, the 10 minute TPC-B run and the
# single-session run, so each round starts from the same state (no dirty buffers left by the load or by the previous
# round); without it a checkpoint lands somewhere inside the measured run and the stability value depends on when.
# Sourced by lib/stages.sh, never executed. Functions (see lib/stages.sh for the contract):
#   stage_pg_order, _default, _time, _note, _check, _run, _rounds
# Metric ids: pg.* (the table is in lib/metrics.sh)
# With a BMC (ipmitool dcmi power reading as root), the system power is sampled during the TPC-B run and
# pg.pgbench.tpcb.tps-per-watt is TPS / average W; the samples are in pg-power-tpcb.log (-rN for later rounds).
# The setup profile of the cluster (vmbench.profile, see setup/pg-profile.sh) goes to pg-settings.txt and to meta.json
# (pg_profile). Files in the result folder: pg-settings.txt (server and pgbench version, every non-default setting and the ones that
# matter for the result), pg-checkpoints.txt (checkpoints that happened during each measured run), pgbench-*.log (raw output; round 1
# keeps the plain names, later rounds add -rN).

stage_pg_order() { echo 40; }
stage_pg_default() { echo no; }
stage_pg_rounds() { echo "${PG_ROUNDS:-1}"; }
stage_pg_time() { echo "$(( 16 * ${PG_ROUNDS:-1} )) min+load"; }   # per round: 1 min warm-up, 10 min TPC-B, 5 min single
stage_pg_note() { echo "needs setup-postgres-bench.sh"; }

stage_pg_check() {
  check_tools pgbench psql
  if need psql && ! timeout 10 psql -X -Atc 'select 1' >/dev/null 2>&1; then
    PROBLEMS+=("cannot connect to db $PGDATABASE on port $PGPORT, run setup-postgres-bench.sh first")
  elif need psql && [ "$(timeout 10 psql -X -Atc "select exists(select 1 from pg_roles where rolname = 'pg_checkpoint') and not (pg_has_role(current_user, 'pg_checkpoint', 'member') or (select rolsuper from pg_roles where rolname = current_user))" 2>/dev/null)" = t ]; then
    PROBLEMS+=("role $(psql -X -Atc 'select current_user' 2>/dev/null) cannot run CHECKPOINT, run setup-postgres-bench.sh again (it grants pg_checkpoint)")
  fi
}

pg_rep_name() { if [ "$ROUND" = 1 ]; then echo "$1"; else echo "${1%.log}-r$ROUND.log"; fi; }

# pg_settings_dump FILE: version and settings. Everything that is not at its default, plus the settings that decide a
# pgbench result even when they are at the default (so two pg-settings.txt files can be diffed).
pg_settings_dump() {
  echo "pgbench client = $(pgbench --version 2>&1)" > "$1"
  psql -X -At -c "select 'version = '||version()" \
    -c "select 'vmbench.profile = '||coalesce(current_setting('vmbench.profile', true), 'unset (cluster set up before vmbench 0.2.1)')" \
    -c "select 'huge_pages_status = '||coalesce(current_setting('huge_pages_status', true), 'n/a (PostgreSQL < 17)')" \
    -c "select name||' = '||setting||coalesce(' '||unit, '')||'   ['||source||']' from pg_settings
        where source <> 'default' or name in ('autovacuum','checkpoint_completion_target','checkpoint_timeout','data_checksums',
          'effective_cache_size','effective_io_concurrency','fsync','full_page_writes','huge_pages','jit','maintenance_work_mem',
          'max_connections','max_wal_size','min_wal_size','random_page_cost','shared_buffers','synchronous_commit','track_io_timing',
          'wal_buffers','wal_compression','wal_level','wal_sync_method','work_mem')
        order by name" >> "$1" 2>&1
}
# pg_ckpt: "timed requested" checkpoint counters, from pg_stat_checkpointer (17+) or pg_stat_bgwriter (older)
pg_ckpt() {
  psql -X -Atc "select num_timed||' '||num_requested from pg_stat_checkpointer" 2>/dev/null \
    || psql -X -Atc "select checkpoints_timed||' '||checkpoints_req from pg_stat_bgwriter" 2>/dev/null
}
# pg_checkpoint WHAT: force a checkpoint so the next measured run starts clean; a refusal is logged, not fatal
pg_checkpoint() {
  if psql -X -Atc "checkpoint" >/dev/null 2>&1; then ok pg "checkpoint before $1"
  else log "[WARN] pg: CHECKPOINT refused before $1 (grant pg_checkpoint to the role: run setup-postgres-bench.sh again); the result may include a checkpoint"; fi
}
# pg_measured WHAT LOGFILE pgbench-args...: CHECKPOINT, run pgbench, and note the checkpoints that happened meanwhile
pg_measured() {
  local what=$1 logf=$2 before after; shift 2
  pg_checkpoint "$what"
  before=$(pg_ckpt)
  pgbench "$@" > "$logf" 2>&1
  after=$(pg_ckpt)
  if [ -n "$before" ] && [ -n "$after" ]; then
    printf 'round %s %s: timed=%s requested=%s (counters before: %s, after: %s)\n' "$ROUND" "$what" \
      "$(( ${after% *} - ${before% *} ))" "$(( ${after#* } - ${before#* } ))" "$before" "$after" >> "$OUT/pg-checkpoints.txt"
  fi
}

stage_pg_run() {
  log "== pg"
  need pgbench && need psql || { skip pg pgbench "not installed"; return; }
  if ! psql -X -Atc 'select 1' > /dev/null 2>&1; then
    skip pg database "cannot connect to db $PGDATABASE on port $PGPORT, run setup-postgres-bench.sh first"; return; fi
  pg_settings_dump "$OUT/pg-settings.txt"
  # the setup profile (vmbench setup postgres --profile): into meta.json, so report compare can warn about a mix
  PG_PROFILE_USED=$(psql -X -Atc "select coalesce(current_setting('vmbench.profile', true), '')" 2>/dev/null)
  log "pg setup profile: ${PG_PROFILE_USED:-unset (cluster set up before vmbench 0.2.1)}"
  local ddir free scale c j r f tps lat
  ddir=$(psql -X -Atc "show data_directory" 2>/dev/null); ddir=${ddir:-/}
  free=$(df -BG --output=avail "$ddir" 2>/dev/null | tail -1 | tr -dc 0-9); free=${free:-0}
  scale=${PG_SCALE:-$(awk -v r="$RAM_GB" -v f="$free" 'BEGIN{s=r*1.5*64; m=int(f*0.6/0.0157); if(m<s)s=m; if(s<10)s=10; print int(s)}')}
  [ "$QUICK" = 1 ] && scale=${PG_SCALE:-20}
  c=$((NPROC * 2)); j=$((NPROC / 2)); [ "$j" -lt 1 ] && j=1
  log "pgbench scale $scale (~$(awk -v s="$scale" 'BEGIN{printf "%.0f", s*0.0157}') GB), free ${free} GB, -c $c -j $j, rounds ${PG_ROUNDS:-1}"
  pgbench -i -s "$scale" -I dtGvp > "$OUT/pgbench-init.log" 2>&1 || { bad pg "pgbench init" "see pgbench-init.log"; return; }
  ok pg "pgbench init"
  local pw="" w; [ -n "$(power_reading)" ] && pw=1
  [ -n "$pw" ] || log "pg: no BMC power reading (ipmitool dcmi power reading as root), tps-per-watt is not recorded"
  : > "$OUT/pg-checkpoints.txt"
  for r in $(seq 1 "${PG_ROUNDS:-1}"); do
    ROUND=$r; [ "${PG_ROUNDS:-1}" = 1 ] || log "pg round $r/$PG_ROUNDS"
    pg_checkpoint "warm-up"
    pgbench -c "$c" -j "$j" -T "$(T 60 5)" > "$OUT/$(pg_rep_name pgbench-warmup.log)" 2>&1
    f=$OUT/$(pg_rep_name pgbench-tpcb.log)
    [ -n "$pw" ] && power_sampler_start "$OUT/$(pg_rep_name pg-power-tpcb.log)" "$(T 10 1)"
    pg_measured "tpcb" "$f" -c "$c" -j "$j" -T "$(T 600 10)" -P "$(T 10 2)"   # progress every 10 s (2 s in QUICK, so stability has samples)
    [ -n "$pw" ] && power_sampler_stop
    tps=$(awk '/^tps =/{print $3}' "$f")
    if [ -n "$tps" ]; then
      rec pg.pgbench.tpcb.tps "$tps" "$c"
      if [ -n "$pw" ]; then
        w=$(power_avg "$OUT/$(pg_rep_name pg-power-tpcb.log)")
        if [ -n "$w" ] && awk -v w="$w" 'BEGIN{exit !(w > 0)}'; then
          rec pg.pgbench.tpcb.tps-per-watt "$(awk -v t="$tps" -v w="$w" 'BEGIN{printf "%.2f", t/w}')"; ok pg "tps per watt (avg ${w} W)"
        else bad pg "tps per watt" "no power samples"; fi
      fi
      awk '/^progress:/{v[++n]=$4} END{ if(n>1){ for(i=2;i<=n;i++){s+=v[i];q+=v[i]*v[i]} k=n-1; m=s/k; sd=sqrt(q/k-m*m); printf "%.2f\n", 100*(1-sd/m)} }' "$f" > "$OUT/.stab"
      [ -s "$OUT/.stab" ] && rec pg.pgbench.tpcb.stability "$(cat "$OUT/.stab")"; rm -f "$OUT/.stab"
      ok pg "pgbench tpcb"
    else bad pg "pgbench run" "see $(basename "$f")"; fi
    f=$OUT/$(pg_rep_name pgbench-single.log)
    pg_measured "single" "$f" -c 1 -j 1 -T "$(T 300 10)" -P 10 -r
    lat=$(awk '/^latency average =/{print $4}' "$f")
    [ -n "$lat" ] && rec pg.pgbench.latency.single "$lat" && ok pg "pgbench single-session" || bad pg "pgbench single-session"
  done
  # shellcheck disable=SC2034  # ROUND is read by rec (lib/metrics.sh)
  ROUND=1
  [ -s "$OUT/pg-checkpoints.txt" ] && log "checkpoints during the measured runs: $(paste -sd';' "$OUT/pg-checkpoints.txt" | cut -c1-200)"
  log "pgbench data remains in db $PGDATABASE (~$(awk -v s="$scale" 'BEGIN{printf "%.0f", s*0.0157}') GB). Drop with: dropdb $PGDATABASE && createdb $PGDATABASE"
}
