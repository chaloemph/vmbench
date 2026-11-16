#!/usr/bin/env bash
# lib/notify.sh - `vmbench notify`: send a message and files to a Telegram chat (Bot API, curl + jq). Sourced, never
# executed.
#
#   cmd_notify [--text TEXT] [--summary DIR] [--check] [FILE...]
#                       exit codes: 0 sent, 1 Telegram or the network refused, 2 usage or configuration error
#   notify_config       load TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID (environment first, then the notify.env file);
#                       returns 1 with NOTIFY_PROBLEM set when one is missing
#   notify_env_file     the path of notify.env: ${XDG_CONFIG_HOME:-~/.config}/vmbench/notify.env
#   notify_summary DIR  the plain-text summary of a result folder (meta.json, status.tsv, report.md)
#
# The token and the chat id never appear on a command line (ps), in stdout or stderr, or in `set -x` output: they go
# to curl as a config file on its stdin, xtrace is switched off around them, and curl's messages are filtered.

NOTIFY_MAX_FILE=$((50 * 1024 * 1024))   # Telegram bots may send files up to 50 MB
NOTIFY_MAX_TEXT=4096                    # characters of one message
NOTIFY_MAX_CAPTION=1024

notify_env_file() { printf '%s/vmbench/notify.env' "${XDG_CONFIG_HOME:-$HOME/.config}"; }

# notify_config: TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID from the environment, else from notify.env (KEY=VALUE lines,
# optional "export " and quotes; the file is read, never executed). Warns when the file is readable by others.
notify_config() {
  { local xt=$-; set +x; } 2>/dev/null
  local f k v line mode
  NOTIFY_PROBLEM=""
  f=$(notify_env_file)
  if { [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; } && [ -f "$f" ]; then
    mode=$(stat -c %a "$f" 2>/dev/null)
    case $mode in 600|400) ;; *) echo "warning: $f has mode ${mode:-unknown}, make it private: chmod 600 $f" >&2 ;; esac
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line#"${line%%[![:space:]]*}"}; line=${line#export }
      case $line in TELEGRAM_BOT_TOKEN=*|TELEGRAM_CHAT_ID=*) ;; *) continue ;; esac
      k=${line%%=*}; v=${line#*=}; v=${v%"${v##*[![:space:]]}"}
      case $v in \"*\") v=${v#\"}; v=${v%\"} ;; \'*\') v=${v#\'}; v=${v%\'} ;; esac
      [ -n "${!k:-}" ] || printf -v "$k" '%s' "$v"
    done < "$f"
  fi
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    NOTIFY_PROBLEM="set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in the environment or in $f (mode 600)"
    case $xt in *x*) set -x ;; esac
    return 1
  fi
  case $xt in *x*) set -x ;; esac
  return 0
}

# _tg_quote TEXT: TEXT for a double-quoted value of a curl config file
_tg_quote() { local s=${1//\\/\\\\}; printf '"%s"' "${s//\"/\\\"}"; }

# tg_call METHOD [CURL ARGS...]: POST to the Bot API; the JSON answer on stdout. 0 when Telegram said "ok": true.
# chat_id is added as a form field: url-encoded, or multipart when an argument is -F / --form-string.
tg_call() {
  { local xt=$-; set +x; } 2>/dev/null
  local method=$1 out err rc chat="data-urlencode" a; shift
  for a in "$@"; do case $a in -F|--form-string) chat="form-string" ;; esac; done
  err=$(mktemp)
  out=$({
    printf 'url = %s\n' "$(_tg_quote "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/$method")"
    [ "$method" = getMe ] || printf '%s = %s\n' "$chat" "$(_tg_quote "chat_id=$TELEGRAM_CHAT_ID")"
  } | curl -fsS --retry 3 --max-time 60 -K - "$@" 2> "$err")
  rc=$?
  if [ -s "$err" ]; then
    sed -e "s|$(printf '%s' "$TELEGRAM_BOT_TOKEN" | sed 's/[][\.*^$|/]/\\&/g')|<token>|g" "$err" >&2
  fi
  rm -f "$err"
  case $xt in *x*) set -x ;; esac
  printf '%s' "$out"
  [ "$rc" = 0 ] && jq -e '.ok == true' >/dev/null 2>&1 <<<"$out"
}

tg_error() { # what Telegram said, or the curl exit
  local d; d=$(jq -r '.description // empty' 2>/dev/null <<<"$1")
  printf '%s' "${d:-no answer from api.telegram.org (network, proxy or a wrong token)}"
}

_dur() { # seconds -> 2h 05m / 4m 10s
  local s=$1
  if [ "$s" -ge 3600 ]; then printf '%dh %02dm' $((s / 3600)) $((s % 3600 / 60)); else printf '%dm %02ds' $((s / 60)) $((s % 60)); fi
}

# notify_summary DIR: what happened in a run, in a few lines of plain text (no Markdown: Telegram shows it as it is)
notify_summary() {
  local d=$1 m=$1/meta.json label arch nproc ram stages start end cpu took fails skips warn line n=0 more=0
  [ -f "$m" ] || { printf 'vmbench: %s has no meta.json\n' "$d"; return 0; }
  label=$(jq -r '.label // "?"' "$m" 2>/dev/null); arch=$(jq -r '.arch // "?"' "$m" 2>/dev/null)
  nproc=$(jq -r '.nproc // "?"' "$m" 2>/dev/null); ram=$(jq -r '.ram_gb // "?"' "$m" 2>/dev/null)
  stages=$(jq -r '[.stages[]? | select(. != "info")] | join(" ")' "$m" 2>/dev/null)
  start=$(jq -r '.start_utc // ""' "$m" 2>/dev/null); end=$(jq -r '.end_utc // ""' "$m" 2>/dev/null)
  cpu=""
  [ -f "$d/hardware.json" ] && cpu=$(jq -r '.cpu.model // empty' "$d/hardware.json" 2>/dev/null)
  [ -n "$cpu" ] || cpu=$(sed -n 's/^Model name:[[:space:]]*//p' "$d/info.txt" 2>/dev/null | head -1)
  if [ -n "$end" ]; then echo "vmbench run finished: $label"; else echo "vmbench run did not finish: $label"; fi
  echo "$arch · ${cpu:-CPU unknown} · $nproc vCPU · $ram GB RAM"
  echo "stages: ${stages:--}"
  if [ -n "$end" ] && took=$(( $(date -d "$end" +%s 2>/dev/null || echo 0) - $(date -d "$start" +%s 2>/dev/null || echo 0) )) && [ "$took" -ge 0 ] 2>/dev/null; then
    echo "$start → $end ($(_dur "$took"))"
  else
    echo "start $start, no end time"
  fi
  if [ -f "$d/status.tsv" ]; then
    fails=$(awk -F'\t' 'NR > 1 && $3 ~ /^FAIL/ {print $1 " / " $2}' "$d/status.tsv")
    skips=$(awk -F'\t' 'NR > 1 && $3 ~ /^SKIP/' "$d/status.tsv" | wc -l)
    if [ -n "$fails" ]; then
      echo "FAIL $(grep -c . <<<"$fails"): $(paste -sd';' <<<"$fails" | sed 's/;/; /g')"
    else
      echo "FAIL 0"
    fi
    [ "$skips" -gt 0 ] && echo "SKIP $skips (see status.tsv)"
  fi
  if [ -f "$d/report.md" ]; then
    # the bullets of the first section after the title, when it is the warnings section (English or Thai)
    warn=$(awk 'NR > 1 && /^## / {if (seen) exit; seen = 1; ok = ($0 == "## Warnings" || $0 == "## ข้อควรระวัง"); next} seen && ok && /^- / {print substr($0, 3)}' "$d/report.md")
    if [ -n "$warn" ]; then
      echo "warnings:"
      while IFS= read -r line; do
        n=$((n + 1)); if [ "$n" -le 3 ]; then echo "- $line"; else more=$((more + 1)); fi
      done <<<"$warn"
      [ "$more" = 0 ] || echo "- ... $more more in report.md"
    fi
  fi
  echo "folder: $(basename "$d")"
}

notify_usage() {
  cat <<'EOF'
vmbench notify - send a message and files to a Telegram chat

  vmbench notify --check                          check the bot token and the chat (getMe, getChat); sends nothing
  vmbench notify --text "TEXT" [FILE...]          send TEXT, then each FILE as a document
  vmbench notify --summary DIR [FILE...]          send a summary of the result folder DIR, then the files
  vmbench notify FILE...                          send only the files

Settings: TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in the environment, or in ~/.config/vmbench/notify.env
(KEY=VALUE lines, mode 600; ${XDG_CONFIG_HOME}/vmbench/notify.env when XDG_CONFIG_HOME is set).
Files over 50 MB are skipped (a Telegram limit for bots). Needs curl and jq.
Exit codes: 0 sent, 1 Telegram or the network refused, 2 usage or configuration error.
EOF
}

cmd_notify() {
  local text="" summary="" check="" files=() f size name ans rc=0 have_text=""
  while [ $# -gt 0 ]; do
    case $1 in
      --text) [ $# -ge 2 ] || die "--text needs a value"; text=$2; have_text=1; shift ;;
      --text=*) text=${1#*=}; have_text=1 ;;
      --summary) [ $# -ge 2 ] || die "--summary needs a result folder"; summary=$2; shift ;;
      --summary=*) summary=${1#*=} ;;
      --check) check=1 ;;
      -h|--help) notify_usage; return 0 ;;
      --) shift; files+=("$@"); break ;;
      -*) die "notify: unknown option '$1' (see: vmbench notify --help)" ;;
      *) files+=("$1") ;;
    esac
    shift
  done
  need curl || die "notify needs curl"
  need jq || die "notify needs jq"
  if [ -n "$check" ]; then
    [ -z "$have_text$summary" ] && [ ${#files[@]} = 0 ] || die "notify: --check sends nothing, use it alone"
  else
    [ -n "$have_text$summary" ] || [ ${#files[@]} -gt 0 ] || die "notify needs --text, --summary or files (see: vmbench notify --help)"
    [ -z "$have_text" ] || [ -z "$summary" ] || die "notify: use --text or --summary, not both"
    [ -z "$have_text" ] || [ -n "$text" ] || die "notify: --text is empty"
    [ -z "$summary" ] || [ -d "$summary" ] || die "notify: $summary is not a folder"
    for f in "${files[@]+"${files[@]}"}"; do [ -f "$f" ] || die "notify: $f is not a file"; done
  fi
  notify_config || die "notify: $NOTIFY_PROBLEM"

  if [ -n "$check" ]; then
    ans=$(tg_call getMe) || { echo "getMe failed: $(tg_error "$ans")" >&2; return 1; }
    echo "bot:  @$(jq -r '.result.username // "?"' <<<"$ans") ($(jq -r '.result.first_name // ""' <<<"$ans"))"
    ans=$(tg_call getChat) || { echo "getChat failed: $(tg_error "$ans") (has the bot been added to the chat, or sent /start?)" >&2; return 1; }
    echo "chat: $(jq -r '.result.title // .result.username // .result.first_name // "?"' <<<"$ans") ($(jq -r '.result.type // "?"' <<<"$ans"))"
    return 0
  fi

  [ -z "$summary" ] || text=$(notify_summary "$summary")
  if [ -n "$text" ]; then
    [ "${#text}" -le "$NOTIFY_MAX_TEXT" ] || text="${text:0:$((NOTIFY_MAX_TEXT - 2))} …"
    ans=$(tg_call sendMessage --data-urlencode "text=$text") || { echo "sendMessage failed: $(tg_error "$ans")" >&2; return 1; }
    echo "sent the message"
  fi
  for f in "${files[@]+"${files[@]}"}"; do
    size=$(stat -c %s "$f" 2>/dev/null || echo 0)
    name=$(basename "$f")
    if [ "$size" -gt "$NOTIFY_MAX_FILE" ]; then
      echo "skipped $name: $((size / 1048576)) MB, Telegram takes at most 50 MB from a bot" >&2
      rc=1; continue
    fi
    ans=$(tg_call sendDocument -F "document=@\"${f//\"/\\\"}\"" --form-string "caption=${name:0:$NOTIFY_MAX_CAPTION}") \
      || { echo "sendDocument $name failed: $(tg_error "$ans")" >&2; rc=1; continue; }
    echo "sent $name"
  done
  return "$rc"
}
