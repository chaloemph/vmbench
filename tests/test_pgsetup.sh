#!/usr/bin/env bash
# Tests for `vmbench setup postgres` profiles (setup/postgres.sh, setup/pg-profile.sh): the formulas of the bench and
# production profiles, --print, bad arguments, and the options handed to pg_createcluster (stub sudo, pg_createcluster,
# pg_lsclusters, pg_ctlcluster, psql, ss). Needs no PostgreSQL, no sudo, no network. Usage: bash tests/test_pgsetup.sh
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT=$PWD
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
check() { # name, ok (0 = pass), details...
  local name=$1 ok=$2; shift 2
  if [ "$ok" = 0 ]; then pass=$((pass + 1)); printf 'ok   %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; [ $# -gt 0 ] && printf '       %s\n' "$@"; fi
}
has() { grep -qxF -- "$2" <<<"$1"; }   # has TEXT LINE: TEXT contains LINE exactly
settings() { bash -c '. "$1/setup/pg-profile.sh"; shift; pg_profile_settings "$@"' _ "$ROOT" "$@"; }

# --- production formulas: the 8 CPU / 16 GB case is PGTune's own output for "Web application", PostgreSQL 18, SSD
s=$(settings production 16384 8 ssd 16GB)
ok=0; for l in shared_buffers=4096MB effective_cache_size=12288MB maintenance_work_mem=1024MB wal_buffers=16384kB work_mem=5041kB \
  min_wal_size=1GB max_wal_size=4GB checkpoint_completion_target=0.9 default_statistics_target=100 random_page_cost=1.1 \
  effective_io_concurrency=200 max_connections=200 max_worker_processes=8 max_parallel_workers_per_gather=4 \
  max_parallel_workers=8 max_parallel_maintenance_workers=4; do has "$s" "$l" || { ok=1; echo "       missing $l"; }; done
check "production 16 GB / 8 CPU / ssd matches PGTune" "$ok" "$s"

s=$(settings production 3072 2 ssd 16GB)
has "$s" shared_buffers=768MB && has "$s" effective_cache_size=2304MB && has "$s" maintenance_work_mem=192MB && has "$s" work_mem=1890kB \
  && ! grep -q '^max_parallel' <<<"$s" && ! grep -q '^max_worker_processes' <<<"$s" \
  && check "production with 2 CPUs: no parallel settings, work_mem uses the defaults (8 workers, 2 per gather)" 0 \
  || check "production with 2 CPUs: no parallel settings, work_mem uses the defaults (8 workers, 2 per gather)" 1 "$s"

s=$(settings production 65536 32 ssd 16GB)
has "$s" maintenance_work_mem=2048MB && has "$s" max_parallel_workers_per_gather=4 && has "$s" max_parallel_maintenance_workers=4 && has "$s" max_worker_processes=32 \
  && check "production caps maintenance_work_mem at 2GB and the per-gather workers at 4" 0 || check "production caps maintenance_work_mem at 2GB and the per-gather workers at 4" 1 "$s"

s=$(settings production 1024 1 ssd 16GB)
has "$s" wal_buffers=7864kB && check "production wal_buffers is 3% of shared_buffers below 14 MB" 0 || check "production wal_buffers is 3% of shared_buffers below 14 MB" 1 "$s"

s=$(settings production 16384 8 hdd 16GB)
has "$s" random_page_cost=4 && has "$s" effective_io_concurrency=2 && check "production on hdd: random_page_cost 4, effective_io_concurrency 2" 0 \
  || check "production on hdd: random_page_cost 4, effective_io_concurrency 2" 1 "$s"

# --- bench is the old rule set, unchanged
s=$(settings bench 16384 8 ssd 16GB)
[ "$(printf '%s\n' shared_buffers=4096MB max_wal_size=16GB min_wal_size=2GB checkpoint_timeout=15min checkpoint_completion_target=0.9 maintenance_work_mem=1GB max_connections=200)" = "$s" ] \
  && check "bench keeps the benchmark rules" 0 || check "bench keeps the benchmark rules" 1 "$s"
s=$(settings bench 16384 8 hdd 8GB); has "$s" max_wal_size=8GB && check "bench takes max_wal_size from the caller" 0 || check "bench takes max_wal_size from the caller" 1 "$s"

# --- bad values
settings fast 16384 8 ssd 16GB >/dev/null 2>"$TMP/e"; rc=$?
[ "$rc" = 2 ] && grep -q "unknown profile 'fast'" "$TMP/e" && check "unknown profile: exit 2 with the choices" 0 || check "unknown profile: exit 2 with the choices" 1 "rc=$rc $(cat "$TMP/e")"
settings production 16384 8 nvme 16GB >/dev/null 2>"$TMP/e"; rc=$?
[ "$rc" = 2 ] && grep -q "unknown disk type 'nvme'" "$TMP/e" && check "unknown disk type: exit 2" 0 || check "unknown disk type: exit 2" 1 "rc=$rc $(cat "$TMP/e")"

# --- setup/postgres.sh --print: no sudo, no PostgreSQL needed
out=$(PATH=/usr/bin:/bin PG_RAM_MB=16384 PG_CPUS=8 bash setup/postgres.sh --profile production --print 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q '^# profile production for 16384 MB RAM, 8 CPUs, disk ssd' <<<"$out" && has "$out" work_mem=5041kB \
  && check "--print shows the settings for PG_RAM_MB / PG_CPUS without sudo" 0 || check "--print shows the settings for PG_RAM_MB / PG_CPUS without sudo" 1 "rc=$rc" "$out"
out=$(PG_PROFILE=production PG_DISK=hdd PG_RAM_MB=4096 PG_CPUS=4 bash setup/postgres.sh --print 2>&1)
has "$out" random_page_cost=4 && check "PG_PROFILE and PG_DISK work like --profile" 0 || check "PG_PROFILE and PG_DISK work like --profile" 1 "$out"
out=$(PG_RAM_MB=4096 PG_CPUS=4 bash setup/postgres.sh --profile=bench --print 2>&1)
has "$out" min_wal_size=2GB && check "--profile=VALUE form" 0 || check "--profile=VALUE form" 1 "$out"
out=$(bash setup/postgres.sh --profile 2>&1); rc=$?
[ "$rc" = 2 ] && check "--profile without a value: exit 2" 0 || check "--profile without a value: exit 2" 1 "rc=$rc $out"
out=$(bash setup/postgres.sh --bogus 2>&1); rc=$?
[ "$rc" = 2 ] && [[ $out == *"unknown argument '--bogus'"* ]] && check "unknown argument: exit 2" 0 || check "unknown argument: exit 2" 1 "rc=$rc $out"
out=$(bash setup/postgres.sh --profile x --print 2>&1); rc=$?
[ "$rc" = 2 ] && check "unknown profile through the setup: exit 2, before sudo" 0 || check "unknown profile through the setup: exit 2, before sudo" 1 "rc=$rc $out"
out=$(bash "$ROOT/vmbench" setup postgres --help 2>&1); rc=$?
[ "$rc" = 0 ] && [[ $out == *"--profile production"* ]] && check "vmbench setup postgres --help shows the profiles" 0 || check "vmbench setup postgres --help shows the profiles" 1 "rc=$rc"

# --- the real setup with stub tools: what reaches pg_createcluster
mkdir -p "$TMP/stubs"
cat > "$TMP/stubs/sudo" <<'STUB'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case $1 in -n|-v|-E) shift ;; -u) shift 2 ;; *) break ;; esac; done
[ $# -eq 0 ] && exit 0
exec "$@"
STUB
cat > "$TMP/stubs/pg_createcluster" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$PGSTUB_LOG"
STUB
cat > "$TMP/stubs/pg_lsclusters" <<'STUB'
#!/usr/bin/env bash
[ -n "${PGSTUB_EXISTS:-}" ] && echo "18 bench 5433 online postgres /x /x.log"
exit 0
STUB
cat > "$TMP/stubs/psql" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"vmbench.profile', true), 'bench')"*) echo "${PGSTUB_HAVE:-bench}" ;;
  *count*) echo 1 ;;
esac
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/stubs/pg_ctlcluster"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/stubs/ss"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/stubs/mountpoint"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/stubs/sleep"
chmod +x "$TMP/stubs"/*
setup() { env PATH="$TMP/stubs:$PATH" PGVER=18 PGSTUB_LOG="$TMP/create.args" "$@" bash setup/postgres.sh 2>&1; }

rm -f "$TMP/create.args"
out=$(setup PG_PROFILE=production PG_RAM_MB=16384 PG_CPUS=8); args=$(cat "$TMP/create.args" 2>/dev/null)
has "$args" work_mem=5041kB && has "$args" effective_cache_size=12288MB && has "$args" vmbench.profile=production && has "$args" jit=off \
  && has "$args" huge_pages=off && has "$args" fsync=on && has "$args" --data-checksums && has "$args" --datadir=/var/lib/postgresql/18/bench \
  && ! has "$args" checkpoint_timeout=15min \
  && check "setup --profile production: pg_createcluster gets the profile, the pinned settings and vmbench.profile" 0 \
  || check "setup --profile production: pg_createcluster gets the profile, the pinned settings and vmbench.profile" 1 "$args" "$out"
[[ $out == *"profile production"* ]] && check "setup reports the profile it created" 0 || check "setup reports the profile it created" 1 "$out"

rm -f "$TMP/create.args"
out=$(setup PG_RAM_MB=16384 PG_CPUS=8); args=$(cat "$TMP/create.args" 2>/dev/null)
has "$args" vmbench.profile=bench && has "$args" checkpoint_timeout=15min && has "$args" max_wal_size=8GB && ! grep -q '^work_mem' <<<"$args" \
  && check "setup without a profile: bench rules, 8GB max_wal_size on the OS disk" 0 || check "setup without a profile: bench rules, 8GB max_wal_size on the OS disk" 1 "$args"

rm -f "$TMP/create.args"
out=$(setup PG_PROFILE=production PG_RAM_MB=16384 PG_CPUS=8 PGSTUB_EXISTS=1 PGSTUB_HAVE=bench)
[ ! -e "$TMP/create.args" ] && [[ $out == *"has profile 'bench', not 'production'"* ]] \
  && check "an existing cluster with another profile is kept, with a warning to drop it" 0 || check "an existing cluster with another profile is kept, with a warning to drop it" 1 "$out"
out=$(setup PG_PROFILE=production PG_RAM_MB=16384 PG_CPUS=8 PGSTUB_EXISTS=1 PGSTUB_HAVE=production)
[[ $out != *"[warn] the existing cluster"* ]] && check "an existing cluster with the same profile: no warning" 0 || check "an existing cluster with the same profile: no warning" 1 "$out"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
