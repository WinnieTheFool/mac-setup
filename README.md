# mac-setup

Small scripts and config that make this Mac work the way I want. Kept here so
they survive a wiped disk or a new machine.

Each folder is self-contained. Nothing here depends on anything else.

| Folder | What it does |
|---|---|
| [`claude-statusline/`](#claude-statusline) | The status bar under the Claude Code prompt — context used, rate limits, tokens, cost |
| [`battery-alert/`](#battery-alert) | Pops a dialog when the battery is nearly dead, so the laptop doesn't just die |

---

## claude-statusline

`statusline.sh` renders the line under the Claude Code prompt. It reads a JSON
payload on stdin (Claude Code sends it on every render) and prints one line:

```
[Opus 4.8] ▓▓▓░░░░░░░ 32% (64.0k/200.0k) | 5h:▓▓░░░░░░░░ 21% (resets 3h12m) | 🔤 io:1.2k cache:410.0k | MCP 2:5 | 💰 $1.84 (session $0.42)
```

Left to right: model, context-window bar, the rolling 5-hour rate-limit window
and when it resets, token totals split into fresh input/output vs. cache, active
MCP servers and calls, and cost. A red `$` appears at the end once a rate-limit
window hits 100% — i.e. when spend is coming out of paid credits rather than
plan quota.

Two things worth knowing if you ever edit it:

- **Cost is per-session, not per-process.** Claude Code's `total_cost_usd` keeps
  climbing across a `/clear`, but `/clear` starts a new session. The script
  records the running total the first time it sees a session ID and subtracts
  that baseline, so the `(session $…)` figure reflects only the conversation
  actually on screen.
- **The MCP server list is cached for 60s** in the background, because
  `claude mcp list` does live health checks and takes ~2 seconds — far too slow
  to run on every render.

`statusline_5hr.py` is an earlier companion that computed this session's share
of the 5-hour window by scanning transcripts on disk. **It is not wired up
anymore** — `statusline.sh` now gets rate-limit data directly from the payload.
Kept because it was real work and the transcript-scanning approach may be useful
again.

### Install

```bash
cp claude-statusline/statusline.sh ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

Then point `~/.claude/settings.json` at it:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/Users/Admin/.claude/statusline.sh"
  }
}
```

Requires `jq` (`brew install jq`).

---

## battery-alert

macOS gives you a low-battery warning that's easy to miss. This one is not
missable: it puts a dialog box on screen at **1–2% while discharging**, which is
about the last thing standing between you and an unsaved-work situation.

A lock file at `/tmp/battery_warning_shown` means you get the dialog *once* per
drain, not every minute. It clears once the battery is back above 20%, arming it
for the next time.

`com.user.batteryalert.plist` is what actually runs it: a launch agent that fires
the script every 60 seconds, and at login.

### Install

```bash
cp battery-alert/battery_alert.sh ~/battery_alert.sh
chmod +x ~/battery_alert.sh
cp battery-alert/com.user.batteryalert.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.user.batteryalert.plist
```

⚠️ **The plist hardcodes `/Users/Admin/battery_alert.sh`.** On a machine with a
different username, edit that path or the agent will silently do nothing.

Check it's running, and test it without draining the battery:

```bash
launchctl list | grep batteryalert    # should print a line
bash ~/battery_alert.sh               # runs the check once, right now
```

To stop it:

```bash
launchctl unload ~/Library/LaunchAgents/com.user.batteryalert.plist
```
