#!/usr/bin/env bash
# Tests for the stage plug-in layout: every file in stages/ is loaded by lib/stages.sh and defines the functions
# that the rest of vmbench calls. Adding a stage must mean adding one file, so nothing else may be needed.
# Usage: bash tests/test_stages.sh
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

REQUIRED="order default time note check run"
EXPECTED="cpu mem disk nvme pg net web sustain burnin"

# load the stages in a subshell the same way vmbench does and report what each one defines
report=$(
  VMBENCH_HOME=$ROOT
  # shellcheck source=lib/common.sh
  . "$ROOT/lib/common.sh"
  # shellcheck source=lib/stages.sh
  . "$ROOT/lib/stages.sh"
  load_stages
  echo "ALL=$ALL_STAGES"
  echo "DEFAULT=$DEFAULT_STAGES"
  for f in "$ROOT"/stages/*.sh; do
    name=$(basename "$f" .sh)
    for fn in $REQUIRED; do
      declare -F "stage_${name}_$fn" >/dev/null && echo "has $name $fn" || echo "missing $name $fn"
    done
    echo "order $name $("stage_${name}_order")"
    echo "default $name $("stage_${name}_default")"
  done
)

# every file in stages/ defines every required function
files=$(ls "$ROOT"/stages/*.sh | wc -l)
missing=$(grep '^missing ' <<<"$report")
[ -z "$missing" ] && check "every stage file defines: $REQUIRED" 0 || check "every stage file defines: $REQUIRED" 1 "$missing"
[ "$files" = 10 ] && check "stages/ holds the ten stages (info + $EXPECTED)" 0 || check "stages/ holds the ten stages" 1 "files=$files"

# the sourced stages are what vmbench lists, in order, and info is not a selectable stage
all=$(sed -n 's/^ALL=//p' <<<"$report")
[ "$all" = "$EXPECTED" ] && check "load_stages finds the stages in the documented order" 0 || check "load_stages finds the stages in the documented order" 1 "got: $all"
def=$(sed -n 's/^DEFAULT=//p' <<<"$report")
[ "$def" = "cpu mem disk" ] && check "default stages are cpu mem disk" 0 || check "default stages are cpu mem disk" 1 "got: $def"
[ "$(sed -n 's/^default info //p' <<<"$report")" = always ] && check "info is always" 0 || check "info is always" 1

# the file name is the stage name, and every stage has ids in the metric table
bad=""
for f in "$ROOT"/stages/*.sh; do
  name=$(basename "$f" .sh)
  grep -q "^stage_${name}_run()" "$f" || bad="$bad $name(no stage_${name}_run in its own file)"
  bash "$ROOT/vmbench" run --metrics | grep -q "^$name\." || bad="$bad $name(no metric ids)"
done
[ -z "$bad" ] && check "each stage file defines its own functions and has metric ids" 0 || check "each stage file defines its own functions and has metric ids" 1 "$bad"

# plug-in test: a new stage file in a copy of the tree is picked up with no other change
cp -R "$ROOT" "$TMP/tree" && rm -rf "$TMP/tree/.git"
cat > "$TMP/tree/stages/zzz.sh" <<'STAGE'
#!/usr/bin/env bash
stage_zzz_order() { echo 99; }
stage_zzz_default() { echo no; }
stage_zzz_time() { echo "1 min"; }
stage_zzz_note() { echo "test stage"; }
stage_zzz_check() { PROBLEMS+=("zzz is a test stage"); }
stage_zzz_run() { :; }
STAGE
out=$(HOME=$TMP/home bash "$TMP/tree/vmbench" list 2>&1)
if grep -qE '^zzz +0 +no +1 min +no: zzz is a test stage' <<<"$out"; then check "a new stages/<name>.sh shows up in vmbench list" 0
else check "a new stages/<name>.sh shows up in vmbench list" 1 "${out: -300}"; fi
out=$(HOME=$TMP/home bash "$TMP/tree/vmbench" run --help 2>&1)
if grep -q '^  zzz     ids zzz\.\* *test stage' <<<"$out"; then check "a new stage shows up in run --help" 0
else check "a new stage shows up in run --help" 1; fi
out=$(HOME=$TMP/home bash "$TMP/tree/vmbench" run --only zzz 2>&1); rc=$?
if [ "$rc" = 2 ] && [[ $out == *"not ready: zzz: zzz is a test stage"* ]]; then check "a new stage is pre-flight checked" 0
else check "a new stage is pre-flight checked" 1 "rc=$rc ${out:0:200}"; fi

# --- pipefail: vmbench runs with `set -o pipefail`, so `cmd | grep -q` fails whenever grep stops reading before cmd
# is done (cmd gets SIGPIPE). v0.2.1 said "lmbench is not installed" now and then because of that (14 in 200 on a VM).
mkdir -p "$TMP/pf"
cat > "$TMP/pf/dpkg" <<'STUB'
#!/usr/bin/env bash
# dpkg -L lmbench: the match comes first and a long list follows, so a reader that stops early always breaks the pipe
[ "${DPKG_STUB_NONE:-}" = 1 ] && exit 1
echo /usr/lib/lmbench/bin/x86_64-linux-gnu/lat_mem_rd
for i in $(seq 1 20000); do echo "/usr/share/lmbench/file$i"; done
STUB
chmod +x "$TMP/pf/dpkg"
mem_problems() { # env... : the PROBLEMS of stage_mem_check, run like vmbench (pipefail), 20 times
  env PATH="$TMP/pf:$PATH" HOME="$TMP/home" "$@" bash -c '
    set -uo pipefail
    VMBENCH_HOME=$1; . "$1/lib/common.sh"; . "$1/lib/preflight.sh"; . "$1/stages/mem.sh"
    for i in $(seq 1 20); do PROBLEMS=(); stage_mem_check; printf "%s\n" "${PROBLEMS[@]}"; done' _ "$ROOT" 2>&1 | grep -c "lmbench is not installed"
}
n=$(mem_problems); [ "$n" = 0 ] && check "mem pre-flight finds lmbench every time under pipefail (no SIGPIPE false negative)" 0 \
  || check "mem pre-flight finds lmbench every time under pipefail (no SIGPIPE false negative)" 1 "reported missing $n/20"
n=$(mem_problems DPKG_STUB_NONE=1); [ "$n" = 20 ] && check "mem pre-flight still reports a missing lmbench" 0 || check "mem pre-flight still reports a missing lmbench" 1 "reported missing $n/20"
lat=$(env PATH="$TMP/pf:$PATH" bash -c 'set -uo pipefail; . "$1/stages/mem.sh"; lmbench_lat_mem_rd' _ "$ROOT")
[ "$lat" = /usr/lib/lmbench/bin/x86_64-linux-gnu/lat_mem_rd ] && check "lmbench_lat_mem_rd prints the first match" 0 || check "lmbench_lat_mem_rd prints the first match" 1 "got '$lat'"
# no pipe into an early-exit grep whose status is tested, in the code vmbench runs with pipefail
hits=$(grep -nE '\|[^|]*\bgrep +(-[a-zA-Z]*[qm]|--quiet|--max-count)' "$ROOT/vmbench" "$ROOT"/lib/*.sh "$ROOT"/stages/*.sh "$ROOT"/setup/*.sh | grep -vE ':[0-9]+:\s*#')
[ -z "$hits" ] && check "no 'cmd | grep -q/-m' in vmbench, lib/, stages/, setup/ (pipefail)" 0 || check "no 'cmd | grep -q/-m' in vmbench, lib/, stages/, setup/ (pipefail)" 1 "$hits"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
