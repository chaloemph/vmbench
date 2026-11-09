#!/usr/bin/env bash
# Runs every test: the Python tests for report.py and the metric ids, and the command line tests for
# run-benchmark.sh, the vmbench entry script and the stage files.
#   bash tests/run.sh
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
status=0
echo "== report.py"
python3 -I -B -W error::ResourceWarning -m unittest discover -s tests || status=1
echo
echo "== run-benchmark.sh"
bash tests/test_cli.sh || status=1
echo
echo "== vmbench"
bash tests/test_vmbench.sh || status=1
echo
echo "== stages"
bash tests/test_stages.sh || status=1
echo
[ "$status" = 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit "$status"
