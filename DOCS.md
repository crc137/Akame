[![← Back](https://img.shields.io/badge/←_Back_to_README-0080ff?style=flat)](README.md)
[![Русский](https://img.shields.io/badge/язык-Русский%20🇷🇺-white)](DOCS.ru.md)

## Install

```bash
curl -sSL https://raw.coonlink.com/cloud/Akame/install.sh | sudo sh
```

Requires two icons on the same server: `quiet.png` and `threat.png` (`.ico` also works). Any square size — the panel scales them.

The installer detects the desktop user, installs the components, enables the systemd units, adds the Xfce panel item and sets the first baseline. No follow-up steps.

The one-liner form (`curl … | sudo sh`) works, but it hands root to whatever the server returns, with no verification. That is the weakest link in this project and it is a property of the delivery, not the code. For a single machine, `scp` the file across instead.

### Uninstall

```bash
curl -sSL https://raw.coonlink.com/cloud/Akame/install.sh | sudo sh -s -- --uninstall
```

Removes the units, the binaries, the sudoers rule, the config, the state, the panel item and the icons.

## What it checks

**`threat`:**

- login history shrank (`last` output shorter than before, or the oldest record moved forward)
- `lastlog2.db` missing or smaller than before
- `pam_wtmpdb.so` or `pam_lastlog2.so` no longer active in `common-session` — login logging switched off
- `/etc/sudoers`, `/etc/sudoers.d` or `/root/.ssh` changed
- a second uid-0 account appeared
- failed login attempts reached `FAIL_ALERT` since the last reset
- the status file is older than 180s, or `akame-follow` is not running

**Also `threat`, but marked in the tooltip as a lesser anomaly:**

- `/etc/pam.d`, `/etc/passwd`, `/etc/group`, `/etc/shadow` changed
- journal history rotated or cleared

The live watcher tails the journal, so a failed password is reflected in about a second. The timer re-runs the full check every minute as a backstop.

## Telegram

Optional. Set it from the panel icon → **Settings**, or:

```bash
sudo akame-config '<bot token>' '<chat id>' 1
```

Chat id: message the bot first (Telegram forbids bots from opening conversations), then

```bash
curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | grep -o '"id":[0-9-]*' | head -3
```

Telegram is **read-only by design**: alerts and `Status` only. Reset is local-only — otherwise the bot token becomes a remote way to silence the alarms it raises.

The daily heartbeat reports `alive`, current level, fail count and uptime. It is enabled automatically once a token and chat id are set. Alerts fire on a level change, so config tampering notifies too, not only failed logins.

Alert messages contain journal lines, which may include usernames and source IPs. That is log data leaving the machine — deliberate, but worth knowing.

## Components

| Path | Runs as | Purpose |
|---|---|---|
| `/usr/local/sbin/akame-check` | root | the checks; writes `/run/akame/status` |
| `/usr/local/sbin/akame-follow` | root | tails the journal, reacts in ~1s |
| `/usr/local/sbin/akame-notify` | root | sends one Telegram alert on level change |
| `/usr/local/sbin/akame-heartbeat` | root | daily proof of life |
| `/usr/local/sbin/akame-tgbot` | root | handles the `Status` button |
| `/usr/local/sbin/akame-config-set` | root | the only config writer; reads stdin, takes no arguments |
| `/usr/local/sbin/akame-config-show` | root | reports whether a token is set — never the token |
| `/usr/local/sbin/akame-config` | root | CLI convenience wrapper around the two above |
| `/usr/local/bin/akame-icon` | user | genmon script — picks the icon |
| `/usr/local/bin/akame-ui` | user | left-click window: attempts, Reset, Settings |

Units: `akame.timer` (full check every minute), `akame-follow.service` (live), `akame-heartbeat.timer` (daily), `akame-tgbot.service`.

State in `/var/lib/akame/state` (0700), config in `/etc/akame/conf` (0600), status in `/run/akame/status` (0640).

## Privilege model

The desktop user gets exactly three commands, no wildcards:

```
NOPASSWD: /usr/local/sbin/akame-check --ack
NOPASSWD: /usr/local/sbin/akame-config-set ""
NOPASSWD: /usr/local/sbin/akame-config-show ""
```

The `""` matters — in sudoers, a command listed without arguments permits *any* arguments. Both helpers also reject arguments themselves.

The config file is never sourced as shell. Values are parsed with `sed` and validated on write (token must match `<digits>:<base64url>`, chat id must be an integer), so a crafted value cannot become code. The bot token reaches `curl` via `-K -` on stdin, so it never appears in any process's argv.

## Configuration

`/etc/akame/conf`:

| Key | Default | Meaning |
|---|---|---|
| `TG_TOKEN` | empty | bot token; empty disables Telegram |
| `TG_CHAT` | empty | chat id |
| `FAIL_ALERT` | `1` | failed attempts before `threat` |
| `TG_MIN_INTERVAL` | `60` | seconds between messages |
| `UI_USER` | set at install | owns the status file's group |

`FAIL_ALERT` is settable from the GUI; the rest by editing the file as root.

## Everyday use

```bash
cat /run/akame/status              # current state
sudo akame-check --ack             # reset after you have looked
systemctl status akame-follow      # is the live watcher alive
journalctl -u akame-tgbot -n20     # telegram bot problems
```

The icon flips to `threat` after any `apt` run that touches `/etc/pam.d` — that is the integrity check working, not a false alarm. Look at *why* it changed, then reset.

## Known limits

- Debian/Kali with `wtmpdb` and `lastlog2` only. On systems with classic `wtmp`, several checks stay in `threat` permanently.
- The panel item needs a live Xfce session; installing from a VT skips it.
- `akame-ui` reads the journal as the desktop user — if that user is not in `adm`, the attempts list will be empty. Fix: `usermod -aG adm <user>`.
- logrotate on the journal can trip the "history cleared" check once.
- Icons are fetched over plain HTTPS with no integrity check.
- Anyone with root can silence everything. See the note in the README.
