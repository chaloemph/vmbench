#!/usr/bin/env bash
# run-benchmark.sh - compatibility wrapper: the same as `vmbench run`, so existing commands and docs keep working.
#   bash run-benchmark.sh [--with LIST | --only LIST] [--peer HOST] [--hours N] [--list] [--metrics] [--help]
# The real work is in vmbench, lib/ and stages/. Error messages keep the name run-benchmark.sh.
src=${BASH_SOURCE[0]}
while [ -L "$src" ]; do
  dir=$(cd -P "$(dirname "$src")" && pwd)
  src=$(readlink "$src")
  case $src in /*) ;; *) src=$dir/$src ;; esac
done
here=$(cd -P "$(dirname "$src")" && pwd)
VMBENCH_PROG=run-benchmark.sh exec bash "$here/vmbench" run "$@"
