#!/usr/bin/env bash
# setup-cpubench.sh - compatibility wrapper: the same as `vmbench setup cpubench` (the script itself is setup/cpubench.sh).
# Settings are the same environment variables (VERSION, DIR, REPO), see the header of setup/cpubench.sh.
src=${BASH_SOURCE[0]}
while [ -L "$src" ]; do
  dir=$(cd -P "$(dirname "$src")" && pwd)
  src=$(readlink "$src")
  case $src in /*) ;; *) src=$dir/$src ;; esac
done
here=$(cd -P "$(dirname "$src")" && pwd)
exec bash "$here/setup/cpubench.sh" "$@"
