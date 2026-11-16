#!/usr/bin/env bash
# setup/postgres.sh (also: vmbench setup postgres, setup-postgres-bench.sh) - create a dedicated PostgreSQL cluster, a role and the database "bench" for pgbench.
#
#   bash setup-postgres-bench.sh                 # needs sudo (asks for the password)
#   PGVER=16 PGPORT=5433 bash setup-postgres-bench.sh
#
# It does NOT touch the default cluster (16/main on port 5432). It creates a separate cluster "bench":
#   data dir : /pgdata/pg<ver>  if /pgdata is a mountpoint, else /var/lib/postgresql/<ver>/bench (OS disk)
#   WAL dir  : /pgwal/wal       if /pgwal  is a mountpoint, else inside the data dir
#   port     : 5433 (default)
# and a role named like your OS user, so `psql -p 5433 -d bench` works without a password over the unix socket.
# The role is a member of pg_checkpoint (PostgreSQL 15+), because the pg stage runs CHECKPOINT before every measured run.
#
# Settings are derived from RAM so that both machines get the same *rules* (not the same numbers):
#   shared_buffers = 25% RAM, max_wal_size = 16GB (8GB on the OS disk, or MAX_WAL_SIZE=), checkpoint_timeout = 15min,
#   synchronous_commit = on, fsync = on, max_connections = 200, listen_addresses = localhost
# The rest is pinned to one value on every machine, so a different default (another version, another package) cannot
# change a result without showing up in pg-settings.txt:
#   huge_pages = off (not "try", which silently falls back to normal pages when vm.nr_hugepages is 0),
#   data checksums on (initdb --data-checksums; PostgreSQL 18 turns them on by default, older versions do not),
#   wal_level = replica, wal_compression = off, checkpoint_completion_target = 0.9, autovacuum = on,
#   jit = off (removes the LLVM difference between x86 and ARM builds), track_io_timing = on,
#   maintenance_work_mem = 1GB (faster index build in pgbench -i; not measured)
# To remove everything again (manual, not automated here):
#   sudo pg_dropcluster --stop <ver> bench
set -euo pipefail

PGVER=${PGVER:-$(ls /usr/lib/postgresql 2>/dev/null | sort -V | tail -1)}
PGPORT=${PGPORT:-5433}
CLUSTER=${CLUSTER:-bench}
DB=${DB:-bench}
ROLE=${ROLE:-$(id -un)}

[ -n "$PGVER" ] || { echo "PostgreSQL is not installed (no /usr/lib/postgresql/<ver>)" >&2; exit 1; }
command -v pg_createcluster >/dev/null || { echo "pg_createcluster not found (install postgresql-common)" >&2; exit 1; }
sudo -v || { echo "sudo is required" >&2; exit 1; }

RAM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
SHARED_MB=$((RAM_MB / 4))

if mountpoint -q /pgdata; then DATADIR=/pgdata/pg$PGVER; MAXWAL=16GB; else DATADIR=/var/lib/postgresql/$PGVER/$CLUSTER; MAXWAL=8GB; fi
MAXWAL=${MAX_WAL_SIZE:-$MAXWAL}
WALDIR=""
if mountpoint -q /pgwal; then WALDIR=/pgwal/wal; fi

if sudo pg_lsclusters -h | awk -v v="$PGVER" -v c="$CLUSTER" '$1==v && $2==c{f=1} END{exit !f}'; then
  echo "[skip] cluster $PGVER/$CLUSTER already exists (its settings are not changed; drop it to apply new ones)"
else
  if ss -ltn | awk -v p=":$PGPORT" '$4 ~ p"$"{f=1} END{exit !f}'; then
    echo "port $PGPORT is already in use, choose another with PGPORT=" >&2; exit 1
  fi
  INITARGS=(-- --data-checksums)
  if [ -n "$WALDIR" ]; then
    sudo install -d -o postgres -g postgres -m 700 "$WALDIR"
    INITARGS+=(--waldir="$WALDIR/pg_wal")
  fi
  sudo pg_createcluster "$PGVER" "$CLUSTER" --port="$PGPORT" --datadir="$DATADIR" \
    -o shared_buffers="${SHARED_MB}MB" -o max_wal_size="$MAXWAL" -o min_wal_size=2GB \
    -o checkpoint_timeout=15min -o checkpoint_completion_target=0.9 \
    -o synchronous_commit=on -o fsync=on -o wal_level=replica -o wal_compression=off \
    -o huge_pages=off -o autovacuum=on -o jit=off -o track_io_timing=on -o maintenance_work_mem=1GB \
    -o max_connections=200 -o listen_addresses=localhost -o log_checkpoints=on \
    "${INITARGS[@]}"
  echo "[ok] created cluster $PGVER/$CLUSTER (data=$DATADIR${WALDIR:+, wal=$WALDIR/pg_wal}, max_wal_size=$MAXWAL)"
fi

sudo pg_ctlcluster "$PGVER" "$CLUSTER" start 2>/dev/null || true
sleep 2

PSQL=(sudo -u postgres psql -X -p "$PGPORT" -v ON_ERROR_STOP=1 -At)
if [ "$("${PSQL[@]}" -d postgres -c "select count(*) from pg_roles where rolname='$ROLE'")" = 0 ]; then
  "${PSQL[@]}" -d postgres -c "create role \"$ROLE\" login createdb"
  echo "[ok] created role $ROLE"
else
  echo "[skip] role $ROLE exists"
fi
"${PSQL[@]}" -d postgres -c "grant pg_read_all_settings to \"$ROLE\""   # lets the role run SHOW data_directory
"${PSQL[@]}" -d postgres -c "grant pg_read_all_stats to \"$ROLE\""      # pg_stat_checkpointer / pg_stat_bgwriter counts
if [ "$("${PSQL[@]}" -d postgres -c "select count(*) from pg_roles where rolname='pg_checkpoint'")" = 1 ]; then
  "${PSQL[@]}" -d postgres -c "grant pg_checkpoint to \"$ROLE\""        # the pg stage runs CHECKPOINT before each measured run
else
  echo "[warn] PostgreSQL $PGVER has no pg_checkpoint role (added in 15): the pg stage cannot run CHECKPOINT as $ROLE"
fi
if [ "$("${PSQL[@]}" -d postgres -c "select count(*) from pg_database where datname='$DB'")" = 0 ]; then
  "${PSQL[@]}" -d postgres -c "create database \"$DB\" owner \"$ROLE\""
  echo "[ok] created database $DB"
else
  echo "[skip] database $DB exists"
fi

echo
echo "--- verification (as $ROLE, no sudo)"
psql -X -At -p "$PGPORT" -d "$DB" \
  -c "select current_user, version()" \
  -c "show data_directory" -c "show shared_buffers" -c "show max_wal_size" -c "show checkpoint_timeout" \
  -c "show synchronous_commit" -c "show fsync" -c "show huge_pages" -c "show data_checksums" \
  -c "show wal_compression" -c "show jit" \
  -c "select 'checkpoint allowed: '||(pg_has_role(current_user, 'pg_checkpoint', 'member') or rolsuper)::text from pg_roles where rolname = current_user"
echo "WAL location: $(readlink -f "$(psql -X -At -p "$PGPORT" -d "$DB" -c 'show data_directory')/pg_wal" 2>/dev/null || echo unknown)"
echo
echo "Use it with:  export PGPORT=$PGPORT PGDATABASE=$DB"
