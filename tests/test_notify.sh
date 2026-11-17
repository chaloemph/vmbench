#!/usr/bin/env bash
# Tests for `vmbench notify` (lib/notify.sh): settings from the environment and notify.env, --check, messages and
# files in the right order with the right fields, the 50 MB and 4096 character limits, the summary of a result folder,
# and that the bot token never shows in stdout, stderr, `bash -x` output or curl's command line.
# A stub curl on PATH records its arguments and the config it reads on stdin; no network is used.
# Usage: bash tests/test_notify.sh
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
if ! command -v jq >/dev/null 2>&1; then echo "skip notify tests (no jq)"; exit 0; fi

TOKEN="123456:SECRET-token_value"
CHAT="-1009876543210"
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/files"
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
cfg=$(cat)
{ echo "=== call"; for a in "$@"; do printf 'arg: %s\n' "$a"; done; printf '%s\n' "$cfg" | sed 's/^/cfg: /'; } >> "$CURL_LOG"
method=$(sed -n 's|^url = ".*/bot[^/]*/\([A-Za-z]*\)"$|\1|p' <<<"$cfg")
echo "$method" >> "$CURL_LOG.methods"
case ",${CURL_FAIL:-}," in
  *",$method,"*) url=$(sed -n 's/^url = "\(.*\)"$/\1/p' <<<"$cfg"); echo "curl: (22) The requested URL returned error: 400 for $url" >&2; exit 22 ;;
esac
case $method in
  getMe) echo '{"ok":true,"result":{"username":"stub_bot","first_name":"Stub"}}' ;;
  getChat) echo '{"ok":true,"result":{"title":"Bench room","type":"group"}}' ;;
  *) echo '{"ok":true,"result":{}}' ;;
esac
STUB
chmod +x "$TMP/bin/curl"
export CURL_LOG=$TMP/curl.log
reset_log() { rm -f "$CURL_LOG" "$CURL_LOG.methods"; }
methods() { paste -sd' ' "$CURL_LOG.methods" 2>/dev/null; }
# nt [env...] -- args: vmbench notify with the stub curl, a clean HOME and no TELEGRAM_* unless given
nt() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  OUTPUT=$(env -u TELEGRAM_BOT_TOKEN -u TELEGRAM_CHAT_ID -u XDG_CONFIG_HOME HOME="$TMP/home" PATH="$TMP/bin:$PATH" \
    "${envs[@]+"${envs[@]}"}" timeout 30 bash "$ROOT/vmbench" notify "$@" 2>&1); RC=$?
}
WITH=(TELEGRAM_BOT_TOKEN="$TOKEN" TELEGRAM_CHAT_ID="$CHAT")
no_token() { ! grep -qF "$TOKEN" <<<"$1" && ! grep -qF "SECRET" <<<"$1"; }

# --- settings
reset_log; nt -- --text hi
[ "$RC" = 2 ] && [[ $OUTPUT == *TELEGRAM_BOT_TOKEN* ]] && [[ $OUTPUT == *TELEGRAM_CHAT_ID* ]] && [[ $OUTPUT == *"$TMP/home/.config/vmbench/notify.env"* ]] && [ ! -e "$CURL_LOG" ] \
  && check "no settings: exit 2 naming both variables and the notify.env path, nothing sent" 0 || check "no settings: exit 2" 1 "rc=$RC $OUTPUT"
reset_log; nt TELEGRAM_BOT_TOKEN="$TOKEN" -- --text hi
[ "$RC" = 2 ] && [ ! -e "$CURL_LOG" ] && check "only the token: exit 2" 0 || check "only the token: exit 2" 1 "rc=$RC $OUTPUT"

# --- --check: getMe then getChat, names printed, token nowhere
reset_log; nt "${WITH[@]}" -- --check
[ "$RC" = 0 ] && [ "$(methods)" = "getMe getChat" ] && [[ $OUTPUT == *"bot:  @stub_bot"* ]] && [[ $OUTPUT == *"chat: Bench room (group)"* ]] && no_token "$OUTPUT" \
  && check "--check calls getMe and getChat and names the bot and the chat" 0 || check "--check" 1 "rc=$RC $(methods) $OUTPUT"
grep -q '^cfg: url = "https://api.telegram.org/bot123456:SECRET-token_value/getMe"$' "$CURL_LOG" && ! grep -q '^cfg: data-urlencode = "chat_id' <(awk '/=== call/{n++} n==1' "$CURL_LOG") \
  && grep -q "^cfg: data-urlencode = \"chat_id=$CHAT\"" <(awk '/=== call/{n++} n==2' "$CURL_LOG") \
  && check "--check: the URL and chat_id go to curl on stdin (getMe has no chat_id)" 0 || check "--check: curl config" 1 "$(cat "$CURL_LOG")"

# --- a message and two files: sendMessage first, then one sendDocument per file
printf 'one\n' > "$TMP/files/report.md"; printf 'two\n' > "$TMP/files/review.xlsx"
reset_log; nt "${WITH[@]}" -- --text "hello there" "$TMP/files/report.md" "$TMP/files/review.xlsx"
[ "$RC" = 0 ] && [ "$(methods)" = "sendMessage sendDocument sendDocument" ] && no_token "$OUTPUT" \
  && check "text then files: sendMessage, sendDocument, sendDocument" 0 || check "text then files" 1 "rc=$RC $(methods) $OUTPUT"
grep -qx 'arg: text=hello there' "$CURL_LOG" && grep -qx 'arg: --data-urlencode' "$CURL_LOG" \
  && grep -qx "arg: document=@\"$TMP/files/report.md\"" "$CURL_LOG" && grep -qx 'arg: caption=review.xlsx' "$CURL_LOG" \
  && grep -qx "cfg: form-string = \"chat_id=$CHAT\"" "$CURL_LOG" && ! grep -q 'parse_mode' "$CURL_LOG" \
  && check "fields: text (url-encoded, no parse_mode), document=@FILE, caption = file name, chat_id" 0 || check "fields" 1 "$(cat "$CURL_LOG")"
args=$(grep '^arg: ' "$CURL_LOG")
grep -qx 'arg: -fsS' <<<"$args" && grep -qx 'arg: --retry' <<<"$args" && grep -qx 'arg: 3' <<<"$args" && grep -qx 'arg: --max-time' <<<"$args" && grep -qx 'arg: 60' <<<"$args" \
  && no_token "$args" && ! grep -qF -- "$CHAT" <<<"$args" \
  && check "curl -fsS --retry 3 --max-time 60; neither token nor chat id on its command line" 0 || check "curl options and command line" 1 "$args"

# --- files only; a file over 50 MB is skipped with a message and exit 1, the others are still sent
truncate -s 51M "$TMP/files/big.bin"
reset_log; nt "${WITH[@]}" -- "$TMP/files/big.bin" "$TMP/files/report.md"
[ "$RC" = 1 ] && [ "$(methods)" = "sendDocument" ] && [[ $OUTPUT == *"skipped big.bin: 51 MB"* ]] && [[ $OUTPUT == *"sent report.md"* ]] \
  && check "a file over 50 MB is skipped (exit 1), the rest is sent" 0 || check "50 MB limit" 1 "rc=$RC $(methods) $OUTPUT"

# --- 4096 characters at most
long=$(printf 'x%.0s' $(seq 1 5000))
reset_log; nt "${WITH[@]}" -- --text "$long"
sent=$(sed -n 's/^arg: text=//p' "$CURL_LOG")
[ "$RC" = 0 ] && [ "${#sent}" -le 4096 ] && [ "${#sent}" -ge 4000 ] && check "a message is cut to 4096 characters" 0 || check "4096 limit" 1 "rc=$RC len=${#sent}"

# --- notify.env: read (not executed), quotes, export; a mode other than 600 is warned about; the environment wins
mkdir -p "$TMP/home/.config/vmbench"
printf '# vmbench notify\nexport TELEGRAM_BOT_TOKEN="%s"\nTELEGRAM_CHAT_ID=%s\nTOUCH=$(touch %s)\n' "$TOKEN" "$CHAT" "$TMP/executed" > "$TMP/home/.config/vmbench/notify.env"
chmod 644 "$TMP/home/.config/vmbench/notify.env"
reset_log; nt -- --text hi
[ "$RC" = 0 ] && [[ $OUTPUT == *"has mode 644"* ]] && grep -q "bot$TOKEN/sendMessage" "$CURL_LOG" && [ ! -e "$TMP/executed" ] && no_token "$OUTPUT" \
  && check "notify.env: read without running it, quotes and export handled, mode 644 warned about" 0 || check "notify.env" 1 "rc=$RC $OUTPUT"
chmod 600 "$TMP/home/.config/vmbench/notify.env"
reset_log; nt TELEGRAM_CHAT_ID=42 -- --text hi
[ "$RC" = 0 ] && [[ $OUTPUT != *"has mode"* ]] && grep -q '^cfg: data-urlencode = "chat_id=42"$' "$CURL_LOG" && grep -q "bot$TOKEN/" "$CURL_LOG" \
  && check "the environment wins over notify.env, the rest comes from the file; mode 600 is quiet" 0 || check "env over file" 1 "rc=$RC $OUTPUT"
mkdir -p "$TMP/xdg/vmbench"; printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CHAT_ID=7\n' "$TOKEN" > "$TMP/xdg/vmbench/notify.env"; chmod 600 "$TMP/xdg/vmbench/notify.env"
reset_log; nt XDG_CONFIG_HOME="$TMP/xdg" -- --text hi
[ "$RC" = 0 ] && grep -q '"chat_id=7"' "$CURL_LOG" && check "XDG_CONFIG_HOME/vmbench/notify.env is used when XDG_CONFIG_HOME is set" 0 || check "XDG_CONFIG_HOME" 1 "rc=$RC $OUTPUT"
rm -rf "$TMP/home/.config"

# --- failures: Telegram refuses (exit 1), curl's message is shown without the token
reset_log; nt "${WITH[@]}" CURL_FAIL=sendMessage -- --text hi "$TMP/files/report.md"
[ "$RC" = 1 ] && [[ $OUTPUT == *"sendMessage failed"* ]] && [[ $OUTPUT == *"bot<token>/sendMessage"* ]] && no_token "$OUTPUT" \
  && check "a refused sendMessage: exit 1, curl's message with the token masked" 0 || check "refused sendMessage" 1 "rc=$RC $OUTPUT"
reset_log; nt "${WITH[@]}" CURL_FAIL=getChat -- --check
[ "$RC" = 1 ] && [[ $OUTPUT == *"getChat failed"* ]] && no_token "$OUTPUT" && check "--check with a chat the bot cannot see: exit 1" 0 || check "--check getChat failure" 1 "rc=$RC $OUTPUT"

# --- bash -x: the token is not traced
OUTPUT=$(env -u XDG_CONFIG_HOME HOME="$TMP/home" PATH="$TMP/bin:$PATH" "${WITH[@]}" bash -x "$ROOT/vmbench" notify --text hi "$TMP/files/report.md" 2>&1); RC=$?
[ "$RC" = 0 ] && [[ $OUTPUT == *"+ "* ]] && no_token "$OUTPUT" && ! grep -qF -- "$CHAT" <<<"$OUTPUT" \
  && check "bash -x: neither the token nor the chat id is traced" 0 || check "bash -x leaks" 1 "rc=$RC $(grep -F -e SECRET -e "$CHAT" <<<"$OUTPUT" | head -3)"

# --- usage errors
for c in "--text a --summary $ROOT/tests/fixtures/new-a|not both" "--check --text a|use it alone" "--text|needs a value" \
         "$TMP/files/nothing|is not a file" "--summary $TMP/nothing|is not a folder" "--bogus|unknown option" "|needs --text, --summary or files"; do
  IFS='|' read -r a msg <<<"$c"
  # shellcheck disable=SC2086
  reset_log; nt "${WITH[@]}" -- $a
  [ "$RC" = 2 ] && [[ $OUTPUT == *"$msg"* ]] && [ ! -e "$CURL_LOG" ] && check "usage: '${a:-no arguments}' exits 2 ($msg)" 0 || check "usage: '$a'" 1 "rc=$RC $OUTPUT"
done
nt -- --help; [ "$RC" = 0 ] && [[ $OUTPUT == *"vmbench notify --check"* ]] && check "--help exits 0" 0 || check "--help" 1 "rc=$RC"

# --- --summary of a result folder: label, machine, stages, times, failed steps, the first warnings
S=$TMP/run; mkdir -p "$S"; cp "$ROOT"/tests/fixtures/new-a/* "$S/"
printf 'disk\tfio randread8k\tFAIL exit 1, see fio-43.json.err\nsustain\tturbostat\tSKIP no turbostat\n' >> "$S/status.tsv"
printf '# Benchmark results: new-a\n\n## Warnings\n\n- w1\n- w2\n- w3\n- w4\n- w5\n\n## CPU\n\n- not a warning\n' > "$S/report.md"
reset_log; nt "${WITH[@]}" -- --summary "$S" "$S/report.md"
text=$(awk '/^arg: text=/{p=1; sub(/^arg: text=/, ""); print; next} p && /^(arg|cfg): /{p=0} p' "$CURL_LOG")
want="vmbench run finished: new-a
x86_64 · Intel(R) Xeon(R) Gold 6430 · 8 vCPU · 16 GB RAM
stages: cpu mem disk web
2000-01-01T00:00:00Z → 2000-01-01T01:30:00Z (1h 30m)
FAIL 1: disk / fio randread8k
SKIP 1 (see status.tsv)
warnings:
- w1
- w2
- w3
- ... 2 more in report.md
folder: run"
[ "$RC" = 0 ] && [ "$(methods)" = "sendMessage sendDocument" ] && [ "$text" = "$want" ] \
  && check "--summary: label, machine, stages, duration, failed steps, three warnings, then report.md" 0 || check "--summary text" 1 "rc=$RC $(methods)" "$text"
rm -f "$S/hardware.json"; python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); m["end_utc"]=None; json.dump(m, open(sys.argv[1], "w"))' "$S/meta.json"
reset_log; nt "${WITH[@]}" -- --summary "$S"
grep -q '^arg: text=vmbench run did not finish: new-a' "$CURL_LOG" && grep -q '^x86_64 · Fixture CPU A · 8 vCPU' "$CURL_LOG" \
  && check "--summary of an unfinished run without hardware.json: says so, CPU from info.txt" 0 || check "--summary unfinished" 1 "$(cat "$CURL_LOG")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
