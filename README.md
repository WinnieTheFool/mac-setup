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
MCP servers and calls, and cost.

### The credit meter

Past the cost figure sits a meter that tracks **how much of this session's spend
came out of paid usage credits** rather than plan quota. It has three states:

| State | When | Looks like |
|---|---|---|
| Off | No rate-limit window has maxed out yet | *nothing — the segment is absent* |
| Counting | A window is at 100% | `$4.47 CREDITS` — bold white on a red block, ticking up live |
| Paused | The window has room again | `$6.00 credits` — dim grey, frozen, stays put for the rest of the session |

The number is credit spend alone, not total spend. When a window hits 100% the
script anchors `total_cost_usd` and counts only the delta from there, so the line
can read `💰 $11.00 (session $6.00)` next to `$6.00 credits` — the meter started
when the limit tripped and stopped adding when the window reset. Dropping back
into overage resumes counting *on top of* the accumulated figure, so a session
that bounces in and out of the limit still shows one cumulative number.

State lives in `~/.claude/.statusline-credit/<session_id>` as
`accum anchor active`, written only on transitions and pruned after 7 days.

Three things worth knowing if you ever edit it:

- **Cost is per-session, not per-process.** Claude Code's `total_cost_usd` keeps
  climbing across a `/clear`, but `/clear` starts a new session. The script
  records the running total the first time it sees a session ID and subtracts
  that baseline, so the `(session $…)` figure reflects only the conversation
  actually on screen.
- **The MCP server list is cached for 60s** in the background, because
  `claude mcp list` does live health checks and takes ~2 seconds — far too slow
  to run on every render.
- **"On credits" is inferred, not reported.** The payload carries no overage or
  credit flag — checked directly, and it's absent even with credits enabled. A
  window sitting at 100% is the only observable proxy, so that's what the meter
  latches on. If Claude Code ever exposes a real flag, that's the one line to
  change. Note also that a resumed session (`--continue` / `--resume`) restarts
  the process cost counter at 0, which would strand the anchor above it; the
  script re-anchors instead of reporting a negative.

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
