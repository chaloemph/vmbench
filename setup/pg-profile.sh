#!/usr/bin/env bash
# setup/pg-profile.sh - the PostgreSQL settings of each setup profile. Sourced by setup/postgres.sh and the tests.
#
#   pg_profile_settings PROFILE RAM_MB CPUS DISK MAXWAL   prints one "name=value" line per setting, exit 2 for an
#                                                          unknown PROFILE or DISK
#
# PROFILE
#   bench       (default) the benchmark rules: shared_buffers 25% RAM, max_wal_size MAXWAL (16GB on /pgdata, 8GB on the
#               OS disk), min_wal_size 2GB, checkpoint_timeout 15min. Everything the planner uses stays at the default.
#   production  a tuned server for a web workload, after the formulas of PGTune (pgtune.leopard.in.ua, "Web application"):
#               shared_buffers 25% RAM, effective_cache_size 75% RAM, maintenance_work_mem RAM/16 (at most 2GB),
#               wal_buffers 3% of shared_buffers (at most 16MB), work_mem (RAM - shared_buffers) /
#               ((max_connections + max_worker_processes) * 3) / max_parallel_workers_per_gather, min/max_wal_size
#               1GB/4GB, random_page_cost and effective_io_concurrency from DISK, and with 4 or more CPUs the parallel
#               worker counts (CPUS, half of them per gather and per maintenance, at most 4). checkpoint_timeout is left
#               at the default (5min), as PGTune does.
# DISK          ssd (random_page_cost 1.1, effective_io_concurrency 200) or hdd (4 and 2); only production uses it.
#
# Both profiles share max_connections 200 and checkpoint_completion_target 0.9. setup/postgres.sh adds the settings
# pinned in every profile (fsync, synchronous_commit, huge_pages=off, jit=off, data checksums, ...) and
# vmbench.profile=<PROFILE>, which the pg stage writes into pg-settings.txt and meta.json.
# Differences from PGTune on purpose: huge_pages stays off (PGTune says "try" from 32 GB of RAM, which silently falls
# back to normal pages) and jit stays off (removes the LLVM difference between x86 and ARM builds).

pg_profile_settings() { # PROFILE RAM_MB CPUS DISK MAXWAL
  local profile=$1 ram=$2 cpus=$3 disk=$4 maxwal=$5
  local shared=$((ram / 4))
  case $profile in
    bench)
      printf '%s\n' "shared_buffers=${shared}MB" "max_wal_size=$maxwal" "min_wal_size=2GB" "checkpoint_timeout=15min" \
        "checkpoint_completion_target=0.9" "maintenance_work_mem=1GB" "max_connections=200"
      ;;
    production)
      local rpc eic
      case $disk in
        ssd) rpc=1.1; eic=200 ;;
        hdd) rpc=4; eic=2 ;;
        *) echo "unknown disk type '$disk' (use ssd or hdd)" >&2; return 2 ;;
      esac
      local conns=200 maint=$((ram / 16)) walbuf workers=8 gather=2 work
      [ "$maint" -le 2048 ] || maint=2048
      walbuf=$((shared * 1024 * 3 / 100))                # kB
      [ "$walbuf" -le 16384 ] || walbuf=16384
      [ "$walbuf" -ge 14336 ] && walbuf=16384            # PGTune rounds 14-16 MB up to 16 MB
      [ "$walbuf" -ge 32 ] || walbuf=32
      if [ "$cpus" -ge 4 ]; then
        workers=$cpus; gather=$(((cpus + 1) / 2)); [ "$gather" -le 4 ] || gather=4
      fi
      work=$(( (ram - shared) * 1024 / ((conns + workers) * 3) / gather ))   # kB
      [ "$work" -ge 64 ] || work=64
      printf '%s\n' "shared_buffers=${shared}MB" "effective_cache_size=$((ram * 3 / 4))MB" \
        "maintenance_work_mem=${maint}MB" "wal_buffers=${walbuf}kB" "work_mem=${work}kB" \
        "min_wal_size=1GB" "max_wal_size=4GB" "checkpoint_completion_target=0.9" "default_statistics_target=100" \
        "random_page_cost=$rpc" "effective_io_concurrency=$eic" "max_connections=$conns"
      if [ "$cpus" -ge 4 ]; then
        printf '%s\n' "max_worker_processes=$cpus" "max_parallel_workers_per_gather=$gather" \
          "max_parallel_workers=$cpus" "max_parallel_maintenance_workers=$gather"
      fi
      ;;
    *) echo "unknown profile '$profile' (use bench or production)" >&2; return 2 ;;
  esac
}
