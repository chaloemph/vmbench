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
#
# Settings are derived from RAM so that both machines get the same *rules* (not the same numbers):
#   shared_buffers = 25% RAM, max_wal_size = 16GB (8GB on the OS disk), checkpoint_timeout = 15min,
#   synchronous_commit = on, fsync = on, max_connections = 200, listen_addresses = localhost
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
WALDIR=""
if mountpoint -q /pgwal; then WALDIR=/pgwal/wal; fi

if sudo pg_lsclusters -h | awk -v v="$PGVER" -v c="$CLUSTER" '$1==v && $2==c{f=1} END{exit !f}'; then
  echo "[skip] cluster $PGVER/$CLUSTER already exists"
else
  if ss -ltn | awk -v p=":$PGPORT" '$4 ~ p"$"{f=1} END{exit !f}'; then
    echo "port $PGPORT is already in use, choose another with PGPORT=" >&2; exit 1
  fi
  INITARGS=()
  if [ -n "$WALDIR" ]; then
    sudo install -d -o postgres -g postgres -m 700 "$WALDIR"
    INITARGS=(-- --waldir="$WALDIR/pg_wal")
  fi
  sudo pg_createcluster "$PGVER" "$CLUSTER" --port="$PGPORT" --datadir="$DATADIR" \
    -o shared_buffers="${SHARED_MB}MB" -o max_wal_size="$MAXWAL" -o min_wal_size=2GB \
    -o checkpoint_timeout=15min -o synchronous_commit=on -o fsync=on \
    -o max_connections=200 -o listen_addresses=localhost -o log_checkpoints=on \
    "${INITARGS[@]}"
  echo "[ok] created cluster $PGVER/$CLUSTER (data=$DATADIR${WALDIR:+, wal=$WALDIR/pg_wal})"
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
  -c "show data_directory" -c "show shared_buffers" -c "show max_wal_size" \
  -c "show synchronous_commit" -c "show fsync"
echo "WAL location: $(readlink -f "$(psql -X -At -p "$PGPORT" -d "$DB" -c 'show data_directory')/pg_wal" 2>/dev/null || echo unknown)"
echo
echo "Use it with:  export PGPORT=$PGPORT PGDATABASE=$DB"
