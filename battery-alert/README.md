# battery-alert

A last-ditch low-battery warning for macOS. The built-in warning is easy to miss; this one
isn't — it puts a modal dialog on screen when the battery drops to **1–2% while discharging**,
which is about the last thing standing between you and losing unsaved work.

```
┌─────────────────────────────┐
│  Battery Warning            │
│                             │
│  Plugin now! Battery is     │
│  almost gone.               │
│                    [  OK  ] │
└─────────────────────────────┘
```

---

## Contents

| File | Role |
|---|---|
| `battery_alert.sh` | The check. Reads battery state and shows the dialog when it's critical. |
| `com.user.batteryalert.plist` | A macOS **launch agent** that runs the script every 60 seconds and at login. |

---

## How it works

`battery_alert.sh` runs `pmset -g batt`, pulls out the charge percentage and whether the
battery is discharging, then:

- **At 1–2% and discharging** → shows the dialog (via `osascript`), but only *once* per drain.
  It writes a lock file at `/tmp/battery_warning_shown` so the next run 60 seconds later doesn't
  stack another dialog on top.
- **Back above 20%** → deletes the lock file, re-arming the warning for the next time you run
  the battery down.

The launch agent (`com.user.batteryalert.plist`) is what actually keeps it alive:
`StartInterval` of 60 fires the script every minute, and `RunAtLoad` runs it once at login.

> **Why 1–2% and not 10%?** This is deliberately a *floor* alarm — the point is to catch the
> moment right before shutdown, not to nag. Bump the threshold in the script if you want an
> earlier warning (see [Customize](#customize)).

---

## Requirements

- **macOS.** It relies on `pmset` (battery state) and `osascript` (the dialog) — both are
  built in. This one is Mac-only; there's no cross-platform version.
- A laptop with a battery, obviously. On a desktop it just never triggers.

No `brew install` needed — everything it uses ships with macOS.

---

## Install

### Option A — just ask Claude to do it

If you have Claude Code, the easiest installer is Claude. Open it in this repo (or point it at
these files) and paste something like:

> Install the battery-alert launch agent from this repo: copy `battery-alert/battery_alert.sh`
> to `~/battery_alert.sh` and make it executable, copy
> `battery-alert/com.user.batteryalert.plist` to `~/Library/LaunchAgents/`, edit the plist's
> hardcoded script path to match my username, then `launchctl load` it and confirm it's running.

Claude will handle the copies, the `chmod`, the **username-path fix in the plist** (the common
gotcha — see below), and loading the agent.

### Option B — do it by hand

```bash
# 1. Script into your home dir, made executable
cp battery-alert/battery_alert.sh ~/battery_alert.sh
chmod +x ~/battery_alert.sh

# 2. Launch agent into place
cp battery-alert/com.user.batteryalert.plist ~/Library/LaunchAgents/

# 3. Load it (starts now, and at every login)
launchctl load ~/Library/LaunchAgents/com.user.batteryalert.plist
```

> ⚠️ **The plist hardcodes the script path** as `/Users/Admin/battery_alert.sh`. On a machine
> with a different username, edit that `<string>` in the plist before loading it — otherwise the
> agent loads fine but silently does nothing, because the file it points at doesn't exist.

---

## Verify & test

```bash
launchctl list | grep batteryalert   # should print a line (a loaded agent)
bash ~/battery_alert.sh              # runs the check once, right now
```

The `launchctl list` line looks like `-   0   com.user.batteryalert` — the `0` is the last exit
status (clean). Running the script by hand is safe: it only shows the dialog if you're actually
at 1–2% and discharging, so normally it just does nothing and returns.

To force-see the dialog without draining the battery, temporarily loosen the threshold in the
script (e.g. change `-le 2` to `-le 100`), run `bash ~/battery_alert.sh`, then change it back.

---

## Customize

Edit `~/battery_alert.sh`:

- **Warning threshold** — the `[ "$PERCENTAGE" -le 2 ] && [ "$PERCENTAGE" -ge 1 ]` test. Widen
  it (e.g. `-le 10`) for an earlier heads-up.
- **Re-arm point** — `[ "$PERCENTAGE" -gt 20 ]` decides when the lock file clears. Raise or
  lower to taste.
- **Message / title** — the `display dialog "…" with title "…"` string.

Change how often it checks by editing `StartInterval` (seconds) in the plist, then reload:

```bash
launchctl unload ~/Library/LaunchAgents/com.user.batteryalert.plist
launchctl load   ~/Library/LaunchAgents/com.user.batteryalert.plist
```

---

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.user.batteryalert.plist
rm ~/Library/LaunchAgents/com.user.batteryalert.plist
rm ~/battery_alert.sh
rm -f /tmp/battery_warning_shown
```
