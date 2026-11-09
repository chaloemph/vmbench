#!/usr/bin/env bash
# Tests for `vmbench run --detach` and `vmbench status`. Most use a fake tmux on PATH (it records its arguments and
# pretends sessions exist), so CI needs no real tmux; with a real tmux installed, the last group uses it too.
# Only the info stage runs (it needs no benchmark tool). Usage: bash tests/test_detach.sh
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

mkdir -p "$TMP/home" "$TMP/bin" "$TMP/sessions"
# fake tmux: log every call; has-session succeeds for a file in $TMP/sessions; new-session -d -s NAME CMD creates the
# file and stores CMD without running it
cat > "$TMP/bin/tmux" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_TMUX_DIR/calls.log"
case ${1:-} in
  has-session) n=${3#=}; [ -e "$FAKE_TMUX_DIR/sessions/$n" ] ;;
  new-session) shift; while [ $# -gt 1 ]; do case $1 in -d) shift ;; -s) name=$2; shift 2 ;; *) break ;; esac; done
    echo "$1" > "$FAKE_TMUX_DIR/sessions/$name"; echo "$1" > "$FAKE_TMUX_DIR/command" ;;
  kill-session) n=${3#=}; rm -f "$FAKE_TMUX_DIR/sessions/$n" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/tmux"
export FAKE_TMUX_DIR=$TMP

OUTDIR=$TMP/out
run() { OUTPUT=$(HOME=$TMP/home LABEL=lbl OUT=$OUTDIR DATA_DIR=$TMP/data CB=$TMP/no-cpubench PEER="" PATH=$TMP/bin:$PATH \
  timeout "${RUN_TIMEOUT:-60}" "$@" 2>&1); RC=$?; }
vb() { run bash "$ROOT/vmbench" "$@"; }
new_calls() { grep -c '^new-session' "$TMP/calls.log" 2>/dev/null || true; }

# --- run --detach with the fake tmux
rm -f "$TMP/calls.log"
start=$(date +%s)
vb run --detach --only info
took=$(( $(date +%s) - start ))
if [ "$RC" = 0 ] && [[ $OUTPUT == *"tmux attach -t vmbench-lbl"* ]] && [[ $OUTPUT == *"tail -f $OUTDIR/run.log"* ]] && [[ $OUTPUT == *"$OUTDIR"* ]] && [[ $OUTPUT == *"vmbench status"* ]]; then
  check "--detach prints how to attach, follow the log and where the results are" 0
else check "--detach prints how to attach, follow the log and where the results are" 1 "rc=$RC ${OUTPUT:0:400}"; fi
[ "$took" -lt 10 ] && check "--detach returns at once" 0 || check "--detach returns at once" 1 "took ${took}s"
if grep -q '^new-session -d -s vmbench-lbl ' "$TMP/calls.log" && grep -q '^has-session -t =vmbench-lbl' "$TMP/calls.log"; then
  check "tmux is asked: has-session first, then new-session -d -s vmbench-<label>" 0
else check "tmux is asked: has-session first, then new-session -d -s vmbench-<label>" 1 "$(cat "$TMP/calls.log" 2>/dev/null)"; fi
if [ ! -e "$OUTDIR/results.tsv" ] && [ ! -e "$OUTDIR/meta.json" ] && [ "$(cat "$OUTDIR/.session" 2>/dev/null)" = vmbench-lbl ]; then
  check "nothing runs in the foreground: no results, only the launcher and the session name" 0
else check "nothing runs in the foreground: no results, only the launcher and the session name" 1 "$(ls -A "$OUTDIR")"; fi
if grep -q "^export OUT=" "$OUTDIR/.launch.sh" && grep -q "^export LABEL=lbl" "$OUTDIR/.launch.sh" && grep -q 'vmbench run --only info$' "$OUTDIR/.launch.sh" \
   && ! grep -q -e '--detach' -e '--session' "$OUTDIR/.launch.sh" && [[ "$(cat "$TMP/command")" == "bash "*"$OUTDIR/.launch.sh"* ]]; then
  check "the launcher carries the settings and the arguments, without --detach" 0
else check "the launcher carries the settings and the arguments, without --detach" 1 "$(cat "$OUTDIR/.launch.sh" 2>/dev/null)" "cmd: $(cat "$TMP/command" 2>/dev/null)"; fi

# status of a run that was started but whose session is "alive" and which has not written meta.json yet
vb status "$OUTDIR"
if [ "$RC" = 0 ] && [[ $OUTPUT == *"state:    starting"* ]] && [[ $OUTPUT == *"session:  vmbench-lbl (alive: tmux attach -t vmbench-lbl)"* ]]; then
  check "status: a started session without meta.json is 'starting'" 0
else check "status: a started session without meta.json is 'starting'" 1 "rc=$RC $OUTPUT"; fi

# what tmux would run: the launcher does the real run, and status reports it finished
rm -f "$TMP/sessions/"*
RUN_TIMEOUT=120 run bash "$OUTDIR/.launch.sh"
if [ "$RC" = 0 ] && python3 -I - "$OUTDIR/meta.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
assert m["end_utc"] and m["stages"] == ["info"], m
PY
then check "the launcher runs the same stages and finishes (meta.json end_utc set)" 0
else check "the launcher runs the same stages and finishes (meta.json end_utc set)" 1 "rc=$RC ${OUTPUT: -300}"; fi
[ ! -e "$OUTDIR/.run.pid" ] && check "the pid file is gone after a finished run" 0 || check "the pid file is gone after a finished run" 1
vb status "$OUTDIR"
if [ "$RC" = 0 ] && [[ $OUTPUT == *"state:    finished"* ]] && [[ $OUTPUT == *"elapsed:  "* ]] && [[ $OUTPUT == *"stage:    info"* ]] && [[ $OUTPUT == *"not running"* ]]; then
  check "status: a finished run says finished, with elapsed time and its last stage" 0
else check "status: a finished run says finished, with elapsed time and its last stage" 1 "rc=$RC $OUTPUT"; fi

# --- refusals
rm -f "$TMP/sessions/"* "$TMP/calls.log"; rm -rf "$OUTDIR"
touch "$TMP/sessions/vmbench-lbl"
vb run --detach --only info
if [ "$RC" = 2 ] && [[ $OUTPUT == *"tmux session 'vmbench-lbl' already exists"* ]] && [[ $OUTPUT == *"--session"* ]] && [ "$(new_calls)" = 0 ] && [ ! -e "$OUTDIR" ]; then
  check "a session with that name already exists: exit 2, nothing started" 0
else check "a session with that name already exists: exit 2, nothing started" 1 "rc=$RC ${OUTPUT:0:300}"; fi
rm -f "$TMP/sessions/"*

vb run --detach --session night.1 --only info
[ "$RC" = 2 ] && [[ $OUTPUT == *"--session needs a name"* ]] && check "--session rejects a name tmux would mangle" 0 || check "--session rejects a name tmux would mangle" 1 "rc=$RC $OUTPUT"
vb run --session night --only info
[ "$RC" = 2 ] && [[ $OUTPUT == *"add --detach"* ]] && check "--session without --detach is refused" 0 || check "--session without --detach is refused" 1 "rc=$RC $OUTPUT"

vb run --detach --only web
if [ "$RC" = 2 ] && [[ $OUTPUT == *"not ready: web"* ]] && [[ $OUTPUT == *"nothing was run"* ]] && [ "$(new_calls)" = 0 ] && [ ! -e "$OUTDIR" ]; then
  check "pre-flight errors are reported in the foreground (exit 2), no session, no folder" 0
else check "pre-flight errors are reported in the foreground (exit 2), no session, no folder" 1 "rc=$RC ${OUTPUT:0:300}"; fi

# no tmux at all: a PATH with the tools vmbench needs, but not tmux
mkdir -p "$TMP/nobin"
for t in bash sed awk date nproc hostname grep ls head tail mkdir df tr dirname basename readlink sort cat uname python3 env seq tee timeout \
         rm cp mv sleep kill cut printf wc lscpu free lsblk ip uptime ps paste id git; do
  p=$(command -v "$t") && [ -x "$p" ] && ln -sf "$p" "$TMP/nobin/$t"
done
OUTPUT=$(HOME=$TMP/home LABEL=lbl OUT=$OUTDIR DATA_DIR=$TMP/data CB=$TMP/no-cpubench PEER="" PATH=$TMP/nobin timeout 30 "$TMP/nobin/bash" "$ROOT/vmbench" run --detach --only info 2>&1); RC=$?
if [ "$RC" = 2 ] && [[ $OUTPUT == *"--detach needs tmux"* ]] && [ ! -e "$OUTDIR" ]; then check "tmux missing: a clear message, exit 2, nothing started" 0
else check "tmux missing: a clear message, exit 2, nothing started" 1 "rc=$RC ${OUTPUT:0:300}"; fi

# STAGES from the environment (no --with/--only) is passed on as --only
rm -rf "$OUTDIR"
OUTPUT=$(HOME=$TMP/home LABEL=lbl OUT=$OUTDIR DATA_DIR=$TMP/data CB=$TMP/no-cpubench STAGES=info PATH=$TMP/bin:$PATH timeout 30 bash "$ROOT/vmbench" run --detach --session mine 2>&1); RC=$?
if [ "$RC" = 0 ] && [[ $OUTPUT == *"tmux attach -t mine"* ]] && grep -q 'run --only info$' "$OUTDIR/.launch.sh" && grep -q '^unset STAGES' "$OUTDIR/.launch.sh"; then
  check "--session NAME is used, and STAGES from the environment is passed on as --only" 0
else check "--session NAME is used, and STAGES from the environment is passed on as --only" 1 "rc=$RC $OUTPUT" "$(cat "$OUTDIR/.launch.sh" 2>/dev/null)"; fi
rm -f "$TMP/sessions/"*

# settings with spaces or quotes survive the launcher
rm -rf "$OUTDIR"
OUTPUT=$(HOME=$TMP/home LABEL="my lab" OUT=$OUTDIR DATA_DIR="$TMP/data dir" CB=$TMP/no-cpubench PATH=$TMP/bin:$PATH timeout 30 bash "$ROOT/vmbench" run --detach --only info --with-nothing 2>&1); RC=$?
[ "$RC" = 2 ] && check "an unknown option is still refused with --detach" 0 || check "an unknown option is still refused with --detach" 1 "rc=$RC $OUTPUT"
OUTPUT=$(HOME=$TMP/home LABEL="my lab" OUT=$OUTDIR DATA_DIR="$TMP/data dir" CB=$TMP/no-cpubench PATH=$TMP/bin:$PATH timeout 30 bash "$ROOT/vmbench" run --detach --only info 2>&1); RC=$?
if [ "$RC" = 0 ] && [[ $OUTPUT == *"tmux attach -t vmbench-my-lab"* ]] \
   && grep -q "my.lab" "$OUTDIR/.launch.sh" && bash -n "$OUTDIR/.launch.sh"; then
  check "a label with a space gives a safe session name and a quoted launcher" 0
else check "a label with a space gives a safe session name and a quoted launcher" 1 "rc=$RC $OUTPUT"; fi
rm -f "$TMP/sessions/"*

# --- status on hand-made folders
mkfolder() { # dir end_utc
  mkdir -p "$1"
  printf '{"schema":1,"label":"x","stages":["info","cpu","mem"],"start_utc":"%s","end_utc":%s}\n' "$(date -u -d '-90 seconds' +%Y-%m-%dT%H:%M:%SZ)" "$2" > "$1/meta.json"
  printf 'stage\tstep\tresult\ncpu\tsysbench st r1\tOK\ncpu\t7z r1\tFAIL x\n' > "$1/status.tsv"
  printf '10:00:00 label=x\n10:00:01 == info\n10:00:02 == cpu\n10:00:03 cpu round 2/3\n' > "$1/run.log"
}
sleep 60 & live=$!
mkfolder "$TMP/r1" null; echo "$live" > "$TMP/r1/.run.pid"
vb status "$TMP/r1"
if [ "$RC" = 0 ] && [[ $OUTPUT == *"state:    running"* ]] && [[ $OUTPUT == *"stage:    cpu (now)"* ]] && [[ $OUTPUT == *"1 OK, 1 FAIL, 0 SKIP"* ]] \
   && [[ $OUTPUT == *"elapsed:  1m "* ]] && [[ $OUTPUT == *"last log: 10:00:03 cpu round 2/3"* ]]; then
  check "status: end_utc null and the run process alive = running, with stage, steps and elapsed time" 0
else check "status: end_utc null and the run process alive = running, with stage, steps and elapsed time" 1 "rc=$RC $OUTPUT"; fi
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null

mkfolder "$TMP/r2" null; echo 999999 > "$TMP/r2/.run.pid"
vb status "$TMP/r2"
if [ "$RC" = 0 ] && [[ $OUTPUT == *"state:    stopped without finishing"* ]] && [[ $OUTPUT == *"stage:    cpu (the last one that started)"* ]]; then
  check "status: end_utc null and nothing alive = stopped without finishing" 0
else check "status: end_utc null and nothing alive = stopped without finishing" 1 "rc=$RC $OUTPUT"; fi

mkfolder "$TMP/r3" null; echo night > "$TMP/r3/.session"; touch "$TMP/sessions/night"
vb status "$TMP/r3"
if [[ $OUTPUT == *"state:    running"* ]] && [[ $OUTPUT == *"session:  night (alive: tmux attach -t night)"* ]]; then check "status: a live tmux session counts as running" 0
else check "status: a live tmux session counts as running" 1 "rc=$RC $OUTPUT"; fi
rm -f "$TMP/sessions/night"
vb status "$TMP/r3"
[[ $OUTPUT == *"state:    stopped without finishing"* ]] && [[ $OUTPUT == *"night (not running)"* ]] && check "status: a session that is gone is not running" 0 || check "status: a session that is gone is not running" 1 "$OUTPUT"

mkfolder "$TMP/r4" '"2000-01-01T00:20:00Z"'
sed -i 's/"start_utc":"[^"]*"/"start_utc":"2000-01-01T00:00:00Z"/' "$TMP/r4/meta.json"
vb status "$TMP/r4"
[[ $OUTPUT == *"state:    finished"* ]] && [[ $OUTPUT == *"elapsed:  20m 00s (start to end)"* ]] && check "status: finished run shows start-to-end time" 0 || check "status: finished run shows start-to-end time" 1 "$OUTPUT"

# no argument: the newest folder in the results root
mkdir -p "$TMP/root"; mkfolder "$TMP/root/old" '"2000-01-01T00:20:00Z"'; touch -d '-2 hours' "$TMP/root/old"
mkfolder "$TMP/root/new" null; echo 999999 > "$TMP/root/new/.run.pid"
run env VMBENCH_RESULTS="$TMP/root" bash "$ROOT/vmbench" status
[[ $OUTPUT == *"folder:   $TMP/root/new"* ]] && check "status without a folder picks the newest result folder" 0 || check "status without a folder picks the newest result folder" 1 "$OUTPUT"
run env VMBENCH_RESULTS="$TMP/empty" bash "$ROOT/vmbench" status
[ "$RC" = 2 ] && [[ $OUTPUT == *"no result folders"* ]] && check "status with no result folders: exit 2 and a message" 0 || check "status with no result folders: exit 2 and a message" 1 "rc=$RC $OUTPUT"
vb status "$TMP/nope"
[ "$RC" = 2 ] && [[ $OUTPUT == *"is not a folder"* ]] && check "status of a missing folder: exit 2" 0 || check "status of a missing folder: exit 2" 1 "rc=$RC $OUTPUT"
mkdir -p "$TMP/plain"; vb status "$TMP/plain"
[ "$RC" = 2 ] && [[ $OUTPUT == *"not a vmbench result folder"* ]] && check "status of a folder that is not a result folder: exit 2" 0 || check "status of a folder that is not a result folder: exit 2" 1 "rc=$RC $OUTPUT"
vb status a b
[ "$RC" = 2 ] && check "status with two folders is a usage error" 0 || check "status with two folders is a usage error" 1 "rc=$RC $OUTPUT"

# --- with a real tmux, when there is one (its own socket directory, so no session of the user is touched)
if command -v tmux >/dev/null 2>&1 && tmux -V >/dev/null 2>&1; then
  export TMUX_TMPDIR=$TMP/tmux; mkdir -p "$TMUX_TMPDIR"; unset TMUX
  RB=$TMP/realbin; mkdir -p "$RB"   # PATH without the fake
  rrun() { OUTPUT=$(HOME=$TMP/home LABEL=real OUT=$TMP/realout DATA_DIR=$TMP/data CB=$TMP/no-cpubench PEER="" QUICK=1 timeout 60 "$@" 2>&1); RC=$?; }
  rrun bash "$ROOT/vmbench" run --detach --only info
  if [ "$RC" = 0 ] && [[ $OUTPUT == *"tmux attach -t vmbench-real"* ]]; then check "real tmux: --detach starts a session and returns" 0
  else check "real tmux: --detach starts a session and returns" 1 "rc=$RC $OUTPUT"; fi
  done=""
  for _ in $(seq 1 60); do
    if grep -q '"end_utc": "' "$TMP/realout/meta.json" 2>/dev/null; then done=1; break; fi
    sleep 1
  done
  [ -n "$done" ] && check "real tmux: the run inside the session finishes and writes its results" 0 || check "real tmux: the run inside the session finishes and writes its results" 1 "$(ls -A "$TMP/realout")"
  grep -q 'done. results' "$TMP/realout/run.log" && [ ! -e "$TMP/realout/.run.pid" ] && check "real tmux: run.log is complete and the pid file is gone" 0 || check "real tmux: run.log is complete and the pid file is gone" 1
  rrun bash -c "OUT=$TMP/realout2 bash '$ROOT/vmbench' run --detach --session twin --only info; OUT=$TMP/realout3 bash '$ROOT/vmbench' run --detach --session twin --only info"
  if [[ $OUTPUT == *"tmux session 'twin' already exists"* ]] || [[ $OUTPUT == *"Started in the background"*"Started in the background"* ]]; then
    check "real tmux: a second --detach with a name in use is refused while the first session lives (or has already ended)" 0
  else check "real tmux: a second --detach with a name in use is refused while the first session lives (or has already ended)" 1 "$OUTPUT"; fi
  # a session that is still alive: status says running through the real has-session
  mkfolder "$TMP/live" null; echo livesess > "$TMP/live/.session"
  tmux new-session -d -s livesess 'sleep 30'
  rrun bash "$ROOT/vmbench" status "$TMP/live"
  [[ $OUTPUT == *"state:    running"* ]] && check "real tmux: status sees a live session" 0 || check "real tmux: status sees a live session" 1 "$OUTPUT"
  tmux kill-session -t =livesess 2>/dev/null
  rrun bash "$ROOT/vmbench" status "$TMP/live"
  [[ $OUTPUT == *"stopped without finishing"* ]] && check "real tmux: after kill-session, status says stopped" 0 || check "real tmux: after kill-session, status says stopped" 1 "$OUTPUT"
  tmux kill-server 2>/dev/null
else
  echo "skip real tmux tests (tmux is not installed)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
