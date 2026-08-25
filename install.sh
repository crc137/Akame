#!/bin/sh
# loginwatch installer — curl -sSL https://raw.coonlink.com/cloud/Akame/install.sh | sudo sh
set -eu
BASE="${LOGINWATCH_BASE:-https://raw.coonlink.com/cloud/Akame}"
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

DUSER="${SUDO_USER:-}"
[ "$DUSER" = root ] && DUSER=""
[ -z "$DUSER" ] && DUSER=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3!="root" && $3!="lightdm" {print $3; exit}')
[ -z "$DUSER" ] && DUSER=$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd)
[ -n "$DUSER" ] && [ "$DUSER" != root ] || { echo "cannot determine desktop user"; exit 1; }
DHOME=$(getent passwd "$DUSER" | cut -d: -f6); DUID=$(id -u "$DUSER")
ICONDIR="$DHOME/.local/share/loginwatch"; BUS="/run/user/$DUID/bus"
asuser() { sudo -u "$DUSER" env HOME="$DHOME" DISPLAY="${DISPLAY:-:0}" DBUS_SESSION_BUS_ADDRESS="unix:path=$BUS" "$@"; }

if [ "${1:-}" = "--uninstall" ]; then
  systemctl disable --now loginwatch.timer loginwatch-heartbeat.timer loginwatch-follow.service loginwatch-tgbot.service 2>/dev/null || true
  for p in $(asuser xfconf-query -c xfce4-panel -p /plugins -l 2>/dev/null | sed -n 's|^/plugins/\(plugin-[0-9]*\)$|\1|p'); do
    case $(asuser xfconf-query -c xfce4-panel -p "/plugins/$p/command" 2>/dev/null || true) in
      */loginwatch-icon)
        asuser xfconf-query -c xfce4-panel -p "/plugins/$p" -rR 2>/dev/null || true
        gone=${p#plugin-}
        for pn in $(asuser xfconf-query -c xfce4-panel -p /panels -l 2>/dev/null | sed -n 's|^/panels/panel-\([0-9]*\)$|\1|p'); do
          cur=$(asuser xfconf-query -c xfce4-panel -p "/panels/panel-$pn/plugin-ids" 2>/dev/null | tail -n +3)
          set --; for i in $cur; do [ "$i" = "$gone" ] || set -- "$@" -t int -s "$i"; done
          [ $# -gt 0 ] && asuser xfconf-query -c xfce4-panel -p "/panels/panel-$pn/plugin-ids" -n "$@" 2>/dev/null || true
        done;;
    esac
  done
  asuser xfce4-panel -r 2>/dev/null || true
  sleep 2; pgrep -u "$DUSER" -x xfce4-panel >/dev/null || asuser sh -c 'nohup xfce4-panel >/dev/null 2>&1 &'
  rm -f /etc/systemd/system/loginwatch*.service /etc/systemd/system/loginwatch*.timer \
        /usr/local/sbin/loginwatch-check /usr/local/sbin/loginwatch-notify /usr/local/sbin/loginwatch-follow \
        /usr/local/sbin/loginwatch-tgbot /usr/local/sbin/loginwatch-config /usr/local/sbin/loginwatch-config-set \
        /usr/local/sbin/loginwatch-config-show /usr/local/sbin/loginwatch-heartbeat \
        /usr/local/bin/loginwatch-icon /usr/local/bin/loginwatch-ui /etc/sudoers.d/loginwatch
  rm -rf /var/lib/loginwatch /run/loginwatch /etc/loginwatch "$ICONDIR"
  systemctl daemon-reload; echo "removed"; exit 0
fi

install -d -m 700 /etc/loginwatch
[ -f /etc/loginwatch/conf ] || cat > /etc/loginwatch/conf <<'CONF'
# loginwatch settings
TG_TOKEN=""
TG_CHAT=""
FAIL_ALERT=1          # failed attempts since last reset before the icon goes red
TG_MIN_INTERVAL=60    # seconds between telegram messages
CONF
chmod 600 /etc/loginwatch/conf

cat > /usr/local/sbin/loginwatch-check <<'CHECK'
#!/bin/sh
set -u
cget() { sed -n "s/^$1=//p" /etc/loginwatch/conf 2>/dev/null | tail -1 | sed 's/^"//; s/"$//'; }
FAIL_ALERT=$(cget FAIL_ALERT)
case "$FAIL_ALERT" in ''|*[!0-9]*) FAIL_ALERT=1;; esac
STATE=/var/lib/loginwatch/state; OUT=/run/loginwatch/status
WATCH="/etc/pam.d /etc/passwd /etc/group /etc/shadow /etc/sudoers /etc/sudoers.d /root/.ssh"
mkdir -p /var/lib/loginwatch /run/loginwatch; chmod 700 /var/lib/loginwatch
[ -f "$STATE" ] || : > "$STATE"
get() { sed -n "s/^$1=//p" "$STATE" | tail -1; }
put() { t=$(grep -v "^$1=" "$STATE" 2>/dev/null); { [ -n "$t" ] && printf '%s\n' "$t"; printf '%s=%s\n' "$1" "$2"; } > "$STATE"; }
level=green; msg=""
note() { msg="$msg$1
"; }
red() { level=red; note "$1"; }
yellow() { [ "$level" = red ] || level=yellow; note "$1"; }
GREP='authentication failure|Failed password|Invalid user|FAILED su|BAD SU|Failed publickey|maximum authentication attempts'

now_last=$(last 2>/dev/null | wc -l)
now_ll=$(stat -c %s /var/lib/lastlog/lastlog2.db 2>/dev/null || echo 0)
now_cfg=$(find $WATCH -xdev -type f -exec sha256sum {} + 2>/dev/null | sort -k2 | sha256sum | cut -d' ' -f1)
now_jrn=$(journalctl -q -o short-unix --no-pager 2>/dev/null | head -1 | cut -d. -f1)
fails=$(journalctl -q --no-pager -g "$GREP" 2>/dev/null | wc -l)

if [ "${1:-}" = "--ack" ]; then
  put last_lines "$now_last"; put lastlog_size "$now_ll"; put cfg_hash "$now_cfg"
  put journal_start "${now_jrn:-0}"; put ack_time "$(date +%s)"
  printf 'level=green\ntime=%s\nfails=0\nmsg=reset at %s\n' "$(date -Is)" "$(date +%H:%M)" > "$OUT"
  chmod 644 "$OUT"; exit 0
fi

# failures are only counted since the last reset
ackt=$(get ack_time)
if [ -n "$ackt" ]; then
  fails=$(journalctl --since "@$ackt" -q --no-pager -g "$GREP" 2>/dev/null | wc -l)
fi

prev=$(get last_lines)
if [ "$now_last" -eq 0 ]; then red "'last' returned nothing — wtmpdb wiped or unreadable"
elif [ -n "$prev" ] && [ "$now_last" -lt "$prev" ]; then red "login history shrank ($prev -> $now_last)"
else put last_lines "$now_last"; fi

old_first=$(last 2>/dev/null | sed -n 's/^wtmpdb begins //p' | tail -1)
if [ -n "$old_first" ]; then
  fe=$(date -d "$old_first" +%s 2>/dev/null || echo)
  prevfe=$(get wtmp_first)
  if [ -n "$fe" ] && [ -n "$prevfe" ] && [ "$fe" -gt $((prevfe + 60)) ]; then
    red "oldest login record moved forward — history trimmed from the start"
  elif [ -n "$fe" ]; then put wtmp_first "$fe"; fi
fi

prev=$(get lastlog_size)
if [ "$now_ll" -eq 0 ]; then red "lastlog2.db missing"
elif [ -n "$prev" ] && [ "$now_ll" -lt "$prev" ]; then red "lastlog2.db shrank"
else put lastlog_size "$now_ll"; fi

for m in pam_wtmpdb.so pam_lastlog2.so; do
  grep -qE "^[^#]*$m" /etc/pam.d/common-session 2>/dev/null || red "$m disabled — login logging is OFF"
done

prev=$(get journal_start)
if [ -n "${now_jrn:-}" ] && [ -n "$prev" ] && [ "$now_jrn" -gt $((prev + 86400)) ]; then
  yellow "journal history cleared or rotated"
else [ -n "${now_jrn:-}" ] && put journal_start "$now_jrn"; fi

[ "$fails" -ge "$FAIL_ALERT" ] && red "$fails failed login attempt(s) since last reset"

extra=$(awk -F: '$3==0 && $1!="root" {printf "%s ", $1}' /etc/passwd)
[ -n "$extra" ] && red "extra uid-0 account(s): $extra"

prev=$(get cfg_hash)
if [ -z "$prev" ]; then put cfg_hash "$now_cfg"
elif [ "$now_cfg" != "$prev" ]; then yellow "auth config changed (pam.d / passwd / sudoers / ssh keys)"; fi

{ printf 'level=%s\ntime=%s\nfails=%s\n' "$level" "$(date -Is)" "$fails"
  printf '%s' "$msg" | sed '/^$/d; s/^/msg=/'; } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
chmod 644 "$OUT"
CHECK

cat > /usr/local/sbin/loginwatch-notify <<'NOTIFY'
#!/bin/sh
set -u
cget() { sed -n "s/^$1=//p" /etc/loginwatch/conf 2>/dev/null | tail -1 | sed 's/^"//; s/"$//'; }
TG_TOKEN=$(cget TG_TOKEN); TG_CHAT=$(cget TG_CHAT); TG_MIN_INTERVAL=$(cget TG_MIN_INTERVAL)
[ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ] || exit 0
case "$TG_MIN_INTERVAL" in ''|*[!0-9]*) TG_MIN_INTERVAL=60;; esac
S=/run/loginwatch/last-notify
now=$(date +%s); prev=$(cat "$S" 2>/dev/null || echo 0)
[ $((now - prev)) -lt "$TG_MIN_INTERVAL" ] && exit 0
echo "$now" > "$S"
TXT="loginwatch @ $(hostname)
$1"
KB='{"inline_keyboard":[[{"text":"Status","callback_data":"status"}]]}'
curl -fsS -m 10 "https://api.telegram.org/bot$TG_TOKEN/sendMessage" --data-urlencode "chat_id=$TG_CHAT" --data-urlencode "text=$TXT" --data-urlencode "reply_markup=$KB" >/dev/null 2>&1 || true
NOTIFY

cat > /usr/local/sbin/loginwatch-heartbeat <<'HB'
#!/bin/sh
# proof of life — absence of this message is itself the alarm
set -u
cget() { sed -n "s/^$1=//p" /etc/loginwatch/conf 2>/dev/null | tail -1 | sed 's/^"//; s/"$//'; }
TG_TOKEN=$(cget TG_TOKEN); TG_CHAT=$(cget TG_CHAT)
[ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ] || exit 0
/usr/local/sbin/loginwatch-check
st=$(cat /run/loginwatch/status 2>/dev/null || echo "level=unknown")
lvl=$(printf '%s' "$st" | sed -n 's/^level=//p' | tail -1)
n=$(printf '%s' "$st" | sed -n 's/^fails=//p' | tail -1)
up=$(uptime -p 2>/dev/null)
TXT="loginwatch alive @ $(hostname)
state: ${lvl:-unknown}   fails: ${n:-?}
$(date -Is)
$up"
curl -fsS -m 15 "https://api.telegram.org/bot$TG_TOKEN/sendMessage" --data-urlencode "chat_id=$TG_CHAT" --data-urlencode "text=$TXT" >/dev/null 2>&1
HB

cat > /usr/local/sbin/loginwatch-follow <<'FOLLOW'
#!/bin/sh
# reacts within ~1s instead of waiting for the timer
set -u
GREP='authentication failure|Failed password|Invalid user|FAILED su|BAD SU|Failed publickey|maximum authentication attempts'
/usr/local/sbin/loginwatch-check
journalctl -f -n0 -q -o cat --no-pager -g "$GREP" 2>/dev/null | while IFS= read -r line; do
  /usr/local/sbin/loginwatch-check
  # telegram follows FAIL_ALERT: only alert once the status is actually red
  grep -q '^level=red' /run/loginwatch/status 2>/dev/null && /usr/local/sbin/loginwatch-notify "$line"
done
FOLLOW

cat > /usr/local/sbin/loginwatch-config <<'CFG'
#!/bin/sh
# convenience CLI: loginwatch-config TOKEN CHAT [N]  |  --show  |  --clear
# note: values given here appear in this process's argv; the GUI path uses stdin instead.
set -eu
[ "${1:-}" = "--show" ] && exec /usr/local/sbin/loginwatch-config-show
printf 'token=%s\nchat=%s\nalert=%s\n' "${1:-}" "${2:-}" "${3:-}" \
  | /usr/local/sbin/loginwatch-config-set
CFG

cat > /usr/local/sbin/loginwatch-config-show <<'SHOW'
#!/bin/sh
# prints whether a token is set (never the token), chat id, threshold. No arguments.
set -u
cget() { sed -n "s/^$1=//p" /etc/loginwatch/conf 2>/dev/null | tail -1 | sed 's/^"//; s/"$//'; }
t=$(cget TG_TOKEN); [ -n "$t" ] && t=set || t=unset
printf '%s|%s|%s\n' "$t" "$(cget TG_CHAT)" "$(cget FAIL_ALERT)"
SHOW

cat > /usr/local/sbin/loginwatch-config-set <<'SET'
#!/bin/sh
# the only writer. reads settings from stdin, never from argv. No arguments.
set -eu
[ $# -eq 0 ] || { echo "takes no arguments" >&2; exit 2; }
cget() { sed -n "s/^$1=//p" /etc/loginwatch/conf 2>/dev/null | tail -1 | sed 's/^"//; s/"$//'; }
t=""; c=""; f=""
while IFS= read -r ln; do
  case "$ln" in
    token=*) t=${ln#token=};;
    chat=*)  c=${ln#chat=};;
    alert=*) f=${ln#alert=};;
  esac
done
if [ "$t" = "--clear" ]; then t=""; c=""
elif [ -z "$t" ]; then t=$(cget TG_TOKEN); fi
[ -n "$c" ] || c=$(cget TG_CHAT)
[ -n "$f" ] || f=$(cget FAIL_ALERT); [ -n "$f" ] || f=1
case "$f" in ''|*[!0-9]*) f=1;; esac
if [ -n "$t" ]; then
  case "$t" in *[!0-9A-Za-z:_-]*|:*|*:) echo "invalid bot token" >&2; exit 1;; esac
  case "$t" in *:*) :;; *) echo "invalid bot token" >&2; exit 1;; esac
fi
if [ -n "$c" ]; then
  case "$c" in *[!0-9-]*|-|*-*-*) echo "invalid chat id" >&2; exit 1;; esac
fi
umask 077
{ grep -vE '^(TG_TOKEN|TG_CHAT|FAIL_ALERT)=' /etc/loginwatch/conf 2>/dev/null
  printf 'TG_TOKEN="%s"\n' "$t"
  printf 'TG_CHAT="%s"\n'  "$c"
  printf 'FAIL_ALERT=%s\n' "$f"
} > /etc/loginwatch/conf.new && mv /etc/loginwatch/conf.new /etc/loginwatch/conf
chmod 600 /etc/loginwatch/conf
systemctl restart loginwatch-follow.service 2>/dev/null || true
if [ -n "$t" ] && [ -n "$c" ]; then
  systemctl enable --now loginwatch-tgbot.service loginwatch-heartbeat.timer 2>/dev/null || true
  rm -f /run/loginwatch/last-notify
  /usr/local/sbin/loginwatch-heartbeat
else
  systemctl disable --now loginwatch-tgbot.service loginwatch-heartbeat.timer 2>/dev/null || true
fi
SET

cat > /usr/local/sbin/loginwatch-tgbot <<'BOT'
#!/usr/bin/env python3
# handles the Reset / Status buttons sent to telegram
import json, os, subprocess, time, urllib.parse, urllib.request

def conf():
    d = {}
    for ln in open('/etc/loginwatch/conf'):
        if '=' in ln and not ln.startswith('#'):
            k, v = ln.split('=', 1); d[k.strip()] = v.strip().strip('"')
    return d

c = conf(); tok, chat = c.get('TG_TOKEN'), c.get('TG_CHAT')
if not tok or not chat: raise SystemExit(0)
api = f'https://api.telegram.org/bot{tok}/'

def call(m, **kw):
    try:
        return json.load(urllib.request.urlopen(api + m + '?' + urllib.parse.urlencode(kw), timeout=35))
    except Exception:
        return {}

def status():
    try:
        return open('/run/loginwatch/status').read().strip()
    except Exception:
        return 'no status'

off = 0
while True:
    r = call('getUpdates', offset=off, timeout=30)
    for u in r.get('result', []):
        off = u['update_id'] + 1
        q = u.get('callback_query'); msg = u.get('message', {})
        data = q['data'] if q else msg.get('text', '').lstrip('/')
        if str((q['message']['chat']['id'] if q else msg.get('chat', {}).get('id'))) != str(chat):
            continue
        if data.startswith('ack') or data.startswith('reset'):
            out = 'reset is local-only — use the panel icon on the machine'
        elif data.startswith('status'):
            out = status()
        else:
            continue
        if q: call('answerCallbackQuery', callback_query_id=q['id'])
        call('sendMessage', chat_id=chat, text=out)
    time.sleep(1)
BOT

cat > /usr/local/bin/loginwatch-icon <<'ICON'
#!/bin/sh
set -u
S=/run/loginwatch/status; D="$HOME/.local/share/loginwatch"
level=threat; tip="loginwatch: no status yet"
if [ -r "$S" ]; then
  case $(sed -n 's/^level=//p' "$S" | tail -1) in green) level=quiet;; *) level=threat;; esac
  det=$(sed -n 's/^msg=//p' "$S" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
  fails=$(sed -n 's/^fails=//p' "$S" | tail -1)
  age=$(( $(date +%s) - $(stat -c %Y "$S") ))
  if [ "$age" -gt 180 ]; then
    level=threat; det="status is ${age}s old — checker stopped"
  elif ! systemctl is-active --quiet loginwatch-follow.service 2>/dev/null; then
    level=threat; det="loginwatch-follow is not running"
  fi
  tip="loginwatch: $level
failed attempts: ${fails:-0}
${det:-nothing unusual}
(click for details)"
fi
printf '<img>%s/%s.ico</img><txt></txt><tool>%s</tool><txtclick>/usr/local/bin/loginwatch-ui</txtclick>\n' "$D" "$level" "$tip"
ICON

cat > /usr/local/bin/loginwatch-ui <<'UI'
#!/bin/sh
# left-click window: attempt list + Reset + Settings
set -u
GREP='authentication failure|Failed password|Invalid user|FAILED su|BAD SU|Failed publickey|maximum authentication attempts'
GUI=$(command -v yad || command -v zenity)
[ -n "$GUI" ] || { xmessage "install yad or zenity"; exit 1; }
body=$( { sed -n 's/^msg=/! /p' /run/loginwatch/status 2>/dev/null; echo
          echo "--- recent failed attempts (24h) ---"
          journalctl --since -24h -q --no-pager -g "$GREP" 2>/dev/null | tail -100
          echo "--- last logins ---"; last -n 15 2>/dev/null; } )

if [ "${GUI##*/}" = yad ]; then
  echo "$body" | yad --text-info --width=760 --height=520 --title="loginwatch" \
    --button="Settings:2" --button="Reset:3" --button="Close:0"
else
  echo "$body" | zenity --text-info --width=760 --height=520 --title="loginwatch" \
    --extra-button="Settings" --extra-button="Reset" --ok-label="Close"
fi
rc=$?; out=""
case $rc in 3) out=reset;; 2) out=settings;; esac
[ "$rc" = 0 ] && exit 0

if [ "$out" = reset ]; then sudo -n /usr/local/sbin/loginwatch-check --ack; exit 0; fi

cur=$(sudo -n /usr/local/sbin/loginwatch-config-show 2>/dev/null || echo 'unset||1')
cur_t=$(echo "$cur" | cut -d'|' -f1); cur_c=$(echo "$cur" | cut -d'|' -f2); cur_f=$(echo "$cur" | cut -d'|' -f3)
if [ "${GUI##*/}" = yad ]; then
  res=$(yad --form --title="loginwatch settings" --width=460 \
        --field="Bot token (blank = keep, token is $cur_t)":  "" \
        --field="Telegram chat id":    "$cur_c" \
        --field="Alert after N fails":NUM "${cur_f:-1}!1..50!1") || exit 0
  t=$(echo "$res" | cut -d'|' -f1); c=$(echo "$res" | cut -d'|' -f2); f=$(echo "$res" | cut -d'|' -f3 | cut -d. -f1)
else
  t=$(zenity --entry --title="loginwatch" --text="Bot token (blank = keep current: $cur_t)") || exit 0
  c=$(zenity --entry --title="loginwatch" --text="Telegram chat id" --entry-text="$cur_c") || exit 0
  f=$(zenity --entry --title="loginwatch" --text="Alert after N fails" --entry-text="${cur_f:-1}") || exit 0
fi
printf 'token=%s\nchat=%s\nalert=%s\n' "$t" "$c" "${f:-1}" | sudo -n /usr/local/sbin/loginwatch-config-set
UI

cat > /etc/systemd/system/loginwatch.service <<'SVC'
[Unit]
Description=loginwatch periodic full check
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/loginwatch-check
SVC

cat > /etc/systemd/system/loginwatch.timer <<'TMR'
[Unit]
Description=Run loginwatch every minute
[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=10s
[Install]
WantedBy=timers.target
TMR

cat > /etc/systemd/system/loginwatch-follow.service <<'FSVC'
[Unit]
Description=loginwatch live journal follower
After=systemd-journald.service
[Service]
ExecStart=/usr/local/sbin/loginwatch-follow
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
FSVC

cat > /etc/systemd/system/loginwatch-heartbeat.service <<'HSVC'
[Unit]
Description=loginwatch daily proof of life
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/loginwatch-heartbeat
HSVC

cat > /etc/systemd/system/loginwatch-heartbeat.timer <<'HTMR'
[Unit]
Description=Send loginwatch heartbeat once a day
[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=15m
[Install]
WantedBy=timers.target
HTMR

cat > /etc/systemd/system/loginwatch-tgbot.service <<'BSVC'
[Unit]
Description=loginwatch telegram button handler
After=network-online.target
[Service]
ExecStart=/usr/local/sbin/loginwatch-tgbot
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
BSVC

cat > /etc/sudoers.d/loginwatch <<SUDO
$DUSER ALL=(root) NOPASSWD: /usr/local/sbin/loginwatch-check --ack
$DUSER ALL=(root) NOPASSWD: /usr/local/sbin/loginwatch-config-set
$DUSER ALL=(root) NOPASSWD: /usr/local/sbin/loginwatch-config-show
SUDO
chmod 440 /etc/sudoers.d/loginwatch
visudo -cf /etc/sudoers.d/loginwatch >/dev/null \
  || { rm -f /etc/sudoers.d/loginwatch; echo "ERROR: sudoers rule rejected — Reset/Settings buttons will not work"; }

for f in check notify follow heartbeat config config-set config-show tgbot; do chmod 755 "/usr/local/sbin/loginwatch-$f"; done
for f in icon ui; do chmod 755 "/usr/local/bin/loginwatch-$f"; done

install -d -o "$DUSER" -g "$DUSER" "$ICONDIR"
for i in quiet threat; do curl -fsSL -o "$ICONDIR/$i.ico" "$BASE/$i.ico" || echo "warn: $i.ico not fetched"; done
chown "$DUSER":"$DUSER" "$ICONDIR"/*.ico 2>/dev/null || true

dpkg -s xfce4-genmon-plugin >/dev/null 2>&1 || apt-get -qq install -y xfce4-genmon-plugin >/dev/null 2>&1 || true
command -v yad >/dev/null || apt-get -qq install -y yad >/dev/null 2>&1 || true

systemctl daemon-reload
systemctl enable --now loginwatch.timer loginwatch-follow.service >/dev/null 2>&1
/usr/local/sbin/loginwatch-check --ack

panel_add() {
  command -v xfconf-query >/dev/null || return 1
  [ -S "$BUS" ] || { echo "no session bus at $BUS"; return 1; }
  asuser xfconf-query -c xfce4-panel -l >/dev/null 2>&1 || return 1
  ids=$(asuser xfconf-query -c xfce4-panel -p /plugins -l 2>/dev/null | sed -n 's|^/plugins/plugin-\([0-9]*\)$|\1|p')
  for p in $ids; do
    case $(asuser xfconf-query -c xfce4-panel -p "/plugins/plugin-$p/command" 2>/dev/null || true) in
      */loginwatch-icon) echo "panel item already present (plugin-$p)"; return 0;;
    esac
  done
  n=1; for p in $ids; do [ "$p" -ge "$n" ] && n=$((p+1)); done
  pnl=$(asuser xfconf-query -c xfce4-panel -p /panels -l 2>/dev/null | sed -n 's|^/panels/panel-\([0-9]*\)$|\1|p' | head -1); : "${pnl:=1}"
  asuser xfconf-query -c xfce4-panel -p "/plugins/plugin-$n" -n -t string -s genmon
  asuser xfconf-query -c xfce4-panel -p "/plugins/plugin-$n/command" -n -t string -s /usr/local/bin/loginwatch-icon
  asuser xfconf-query -c xfce4-panel -p "/plugins/plugin-$n/use-label" -n -t bool -s false
  asuser xfconf-query -c xfce4-panel -p "/plugins/plugin-$n/update-interval" -n -t int -s 5
  cur=$(asuser xfconf-query -c xfce4-panel -p "/panels/panel-$pnl/plugin-ids" 2>/dev/null | tail -n +3)
  set --; for i in $(printf '%s\n' $cur $n | awk '!s[$0]++'); do set -- "$@" -t int -s "$i"; done
  asuser xfconf-query -c xfce4-panel -p "/panels/panel-$pnl/plugin-ids" -n "$@" 2>/dev/null \
    || asuser xfconf-query -c xfce4-panel -p "/panels/panel-$pnl/plugin-ids" "$@"
  asuser xfconf-query -c xfce4-panel -p "/plugins/plugin-$n/command" >/dev/null 2>&1 || return 1
  if ! asuser xfce4-panel -r >/dev/null 2>&1; then
    asuser sh -c 'nohup xfce4-panel >/dev/null 2>&1 &'
  fi
  sleep 2
  pgrep -u "$DUSER" -x xfce4-panel >/dev/null || asuser sh -c 'nohup xfce4-panel >/dev/null 2>&1 &'
  echo "panel item added (plugin-$n on panel-$pnl)"
}
panel_add || echo "panel item NOT added — run from a terminal inside $DUSER's session"

echo "done. user=$DUSER"
echo "  left-click the icon for details / Reset / Settings"
echo "  telegram: set token+chat id in Settings"
