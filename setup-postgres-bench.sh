#!/usr/bin/env bash
# setup-postgres-bench.sh - compatibility wrapper: the same as `vmbench setup postgres` (the script itself is setup/postgres.sh).
# Settings are the same environment variables (PGVER, PGPORT, CLUSTER, DB, ROLE), see the header of setup/postgres.sh.
src=${BASH_SOURCE[0]}
while [ -L "$src" ]; do
  dir=$(cd -P "$(dirname "$src")" && pwd)
  src=$(readlink "$src")
  case $src in /*) ;; *) src=$dir/$src ;; esac
done
here=$(cd -P "$(dirname "$src")" && pwd)
exec bash "$here/setup/postgres.sh" "$@"
