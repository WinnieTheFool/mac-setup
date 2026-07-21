#!/bin/bash
input=$(cat)
MODEL=$(echo "$input" | jq -r '.model.display_name')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
USED=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
MAX=$(echo "$input" | jq -r '.context_window.context_window_size // 0')
fmt_num() {
  awk -v n="$1" 'BEGIN {
    r = int(n/100 + 0.5) * 100
    if (r >= 1000000) printf "%.1fM", r/1000000
    else if (r >= 1000) printf "%.1fk", r/1000
    else printf "%d", r
  }'
}
USED_FMT=$(fmt_num "$USED")
MAX_FMT=$(fmt_num "$MAX")
BAR_WIDTH=10
make_bar() {
  local pct="$1" filled empty bar fill pad
  filled=$((pct * BAR_WIDTH / 100))
  empty=$((BAR_WIDTH - filled))
  bar=""
  [ "$filled" -gt 0 ] && printf -v fill "%${filled}s" "" && bar="${fill// /▓}"
  [ "$empty" -gt 0 ] && printf -v pad "%${empty}s" "" && bar="${bar}${pad// /░}"
  echo "$bar"
}
BAR=$(make_bar "$PCT")

# 5-hour rolling session usage (Claude.ai subscription rate limit), if available
FIVEH_PCT=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
FIVEH_RESET=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
FIVEH_STR=""
if [ -n "$FIVEH_PCT" ]; then
  FIVEH_PCT_INT=$(printf "%.0f" "$FIVEH_PCT")
  FIVEH_BAR=$(make_bar "$FIVEH_PCT_INT")
  FIVEH_STR="5h:${FIVEH_BAR} ${FIVEH_PCT_INT}%"
  if [ -n "$FIVEH_RESET" ]; then
    NOW=$(date +%s)
    SECS_LEFT=$((FIVEH_RESET - NOW))
    if [ "$SECS_LEFT" -gt 0 ]; then
      HRS_LEFT=$((SECS_LEFT / 3600))
      MIN_LEFT=$(((SECS_LEFT % 3600) / 60))
      FIVEH_STR="${FIVEH_STR} (resets ${HRS_LEFT}h${MIN_LEFT}m)"
    fi
  fi
fi

# True cumulative session token totals, summed from the transcript JSONL
# (mirrors how .cost.total_cost_usd accumulates across the whole session,
# rather than only reflecting the most recent API response). Combined into
# two buckets: io (fresh input+output) and cache (cache-write+cache-read),
# since those are the two economically meaningful groupings. The same
# single pass also counts mcp__ tool_use blocks for the MCP segment below.
TRANSCRIPT=$(echo "$input" | jq -r '.transcript_path // empty')
if [ -n "$TRANSCRIPT" ] && [ -s "$TRANSCRIPT" ]; then
  TOK_LINE=$(jq -n -r '
    reduce inputs as $m (
      {"io":0,"cache":0,"mcp":0};
      (if $m.message?.usage? then
        .io += (($m.message.usage.input_tokens // 0) + ($m.message.usage.output_tokens // 0))
        | .cache += (($m.message.usage.cache_creation_input_tokens // 0) + ($m.message.usage.cache_read_input_tokens // 0))
      else . end)
      | .mcp += ([($m.message?.content? // [])[]? | select(.type == "tool_use" and ((.name // "") | startswith("mcp__")))] | length)
    ) | "\(.io)\t\(.cache)\t\(.mcp)"
  ' "$TRANSCRIPT" 2>/dev/null)
  IFS=$'\t' read -r TOK_IO TOK_CACHE MCP_CALLS <<< "$TOK_LINE"
fi
TOK_IO=${TOK_IO:-0}
TOK_CACHE=${TOK_CACHE:-0}
MCP_CALLS=${MCP_CALLS:-0}
TOK_IO_FMT=$(fmt_num "$TOK_IO")
TOK_CACHE_FMT=$(fmt_num "$TOK_CACHE")
TOK_STR="🔤 io:${TOK_IO_FMT} cache:${TOK_CACHE_FMT}"

# MCP segment: terse "servers:calls", only shown when more than one MCP
# server is enabled for this project. "claude mcp list" covers both
# locally-configured servers and account-level connectors (e.g. claude.ai
# Todoist), but does live health checks (~2s) and doesn't know about
# per-project enable/disable toggles - so the raw connected-name list is
# cached/refreshed in the background, and the disabledMcpServers /
# enabledMcpServers overrides for the current project (~/.claude.json) are
# applied fresh on every render, since those are cheap local reads.
MCP_CACHE="$HOME/.claude/.statusline-mcp-cache"
MCP_CACHE_TTL=60
CACHE_AGE=9999
if [ -f "$MCP_CACHE" ]; then
  CACHE_MTIME=$(stat -f %m "$MCP_CACHE" 2>/dev/null || stat -c %Y "$MCP_CACHE" 2>/dev/null)
  [ -n "$CACHE_MTIME" ] && CACHE_AGE=$(( $(date +%s) - CACHE_MTIME ))
fi
if [ "$CACHE_AGE" -ge "$MCP_CACHE_TTL" ]; then
  ( claude mcp list 2>/dev/null | grep '✔ Connected' | sed -E 's/^([^:]+):.*/\1/' | sed -E 's/ +$//' > "${MCP_CACHE}.tmp" 2>/dev/null && mv "${MCP_CACHE}.tmp" "$MCP_CACHE" ) &
  disown 2>/dev/null
fi
CWD_DIR=$(echo "$input" | jq -r '.cwd // .workspace.current_dir // empty')
DISABLED_SRVS=$(jq -r --arg d "$CWD_DIR" '.projects[$d].disabledMcpServers[]? // empty' "$HOME/.claude.json" 2>/dev/null)
ENABLED_EXTRA_SRVS=$(jq -r --arg d "$CWD_DIR" '.projects[$d].enabledMcpServers[]? // empty' "$HOME/.claude.json" 2>/dev/null)
CONNECTED_SRVS=$(cat "$MCP_CACHE" 2>/dev/null)
MCP_SRV_COUNT=$( {
  comm -23 <(echo "$CONNECTED_SRVS" | sed '/^$/d' | sort -u) <(echo "$DISABLED_SRVS" | sed '/^$/d' | sort -u)
  echo "$ENABLED_EXTRA_SRVS"
} | sed '/^$/d' | sort -u | wc -l | tr -d ' ' )
MCP_STR=""
if [ "$MCP_SRV_COUNT" -gt 1 ]; then
  MCP_STR="MCP ${MCP_SRV_COUNT}:${MCP_CALLS}"
fi

# Cost. .cost.total_cost_usd accumulates over the life of the claude process, so
# it survives /clear - but /clear starts a new session (new session_id +
# transcript), which is what every other segment here is scoped to. Recording the
# running total the first time a session_id is seen gives a baseline to subtract,
# yielding the cost of just the conversation on screen. That baseline is also the
# tell for whether a /clear has happened: it is 0 for the first session of a
# process and positive for any session started after one, so the per-session
# figure is only worth showing (alongside the process total) in the latter case.
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
SESSION_ID=$(echo "$input" | jq -r '.session_id // empty')
BASELINE=0
if [ -n "$SESSION_ID" ]; then
  COST_DIR="$HOME/.claude/.statusline-cost"
  BASE_FILE="$COST_DIR/$SESSION_ID"
  mkdir -p "$COST_DIR" 2>/dev/null
  BASELINE=$(cat "$BASE_FILE" 2>/dev/null)
  # A resumed session (--continue/--resume) restarts the process counter at 0,
  # leaving a stale baseline above it; fall back to 0 rather than going negative.
  if [ -z "$BASELINE" ] || awk -v c="$COST" -v b="$BASELINE" 'BEGIN{exit !(c < b)}'; then
    BASELINE=$(awk -v c="$COST" -v b="${BASELINE:-0}" 'BEGIN{print (c < b) ? 0 : c}')
    printf "%s" "$BASELINE" > "${BASE_FILE}.tmp" 2>/dev/null && mv "${BASE_FILE}.tmp" "$BASE_FILE" 2>/dev/null
    find "$COST_DIR" -type f -mtime +7 -delete 2>/dev/null &
    disown 2>/dev/null
  fi
fi
if awk -v b="${BASELINE:-0}" 'BEGIN{exit !(b > 0)}'; then
  SESSION_COST=$(awk -v c="$COST" -v b="$BASELINE" 'BEGIN{d = c - b; print (d > 0) ? d : 0}')
  COST_STR=$(printf "💰 \$%.2f (session \$%.2f)" "$COST" "$SESSION_COST")
else
  COST_STR=$(printf "💰 \$%.2f" "$COST")
fi

# Usage-credit / overage meter: how many dollars of paid credits this session
# has burned. The statusline payload has no explicit overage/credit flag
# (checked directly, even with credits enabled) - 100% used on a rate-limit
# window is the only observable proxy for "now drawing on paid credits instead
# of plan quota". So the meter is a two-state latch, persisted per session:
#
#   ACTIVE  - a window is maxed. Anchor .cost.total_cost_usd at the moment the
#             latch flips on, and show (accumulated + cost - anchor) as a loud
#             bold badge. Every dollar counted here is credit spend.
#   PAUSED  - the window has room again, so credits are no longer being drawn.
#             The stint's delta is folded into the accumulated total, the count
#             freezes, and the badge drops to plain text - but it stays on
#             screen for the rest of the session as a record of what was spent.
#
# Re-entering overage resumes counting on top of the accumulated total, so a
# session that bounces in and out of the limit shows one cumulative figure.
FIVEH_USED=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // 0')
SEVEND_USED=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // 0')
RESET='\033[0m'
CREDIT_HOT='\033[1;97;41m'   # bold white on red - counting, impossible to miss
CREDIT_COLD='\033[2;37m'     # dim grey - frozen total, still visible
CREDIT_STR=""
if [ -n "$SESSION_ID" ]; then
  CREDIT_DIR="$HOME/.claude/.statusline-credit"
  CREDIT_FILE="$CREDIT_DIR/$SESSION_ID"
  mkdir -p "$CREDIT_DIR" 2>/dev/null
  ACCUM=0; ANCHOR=0; ACTIVE=0
  [ -f "$CREDIT_FILE" ] && read -r ACCUM ANCHOR ACTIVE < "$CREDIT_FILE"
  ACCUM=${ACCUM:-0}; ANCHOR=${ANCHOR:-0}; ACTIVE=${ACTIVE:-0}
  save_credit() {
    printf "%s %s %s\n" "$1" "$2" "$3" > "${CREDIT_FILE}.tmp" 2>/dev/null \
      && mv "${CREDIT_FILE}.tmp" "$CREDIT_FILE" 2>/dev/null
    find "$CREDIT_DIR" -type f -mtime +7 -delete 2>/dev/null &
    disown 2>/dev/null
  }
  if awk -v a="$FIVEH_USED" -v b="$SEVEND_USED" 'BEGIN{exit !(a>=100 || b>=100)}'; then
    # A resumed session (--continue/--resume) restarts the process cost counter
    # at 0, stranding the anchor above it; re-anchor rather than going negative.
    if [ "$ACTIVE" != "1" ] || awk -v c="$COST" -v a="$ANCHOR" 'BEGIN{exit !(c < a)}'; then
      ANCHOR="$COST"; ACTIVE=1
      save_credit "$ACCUM" "$ANCHOR" "$ACTIVE"
    fi
    SPENT=$(awk -v acc="$ACCUM" -v c="$COST" -v a="$ANCHOR" 'BEGIN{d = acc + c - a; print (d > 0) ? d : 0}')
    CREDIT_STR=$(printf " ${CREDIT_HOT} \$%.2f CREDITS ${RESET}" "$SPENT")
  else
    if [ "$ACTIVE" = "1" ]; then
      ACCUM=$(awk -v acc="$ACCUM" -v c="$COST" -v a="$ANCHOR" 'BEGIN{d = acc + c - a; print (d > 0) ? d : 0}')
      ANCHOR=0; ACTIVE=0
      save_credit "$ACCUM" "$ANCHOR" "$ACTIVE"
    fi
    if awk -v acc="$ACCUM" 'BEGIN{exit !(acc > 0)}'; then
      CREDIT_STR=$(printf " ${CREDIT_COLD}\$%.2f credits${RESET}" "$ACCUM")
    fi
  fi
fi

OUT="[$MODEL] $BAR $PCT% (${USED_FMT}/${MAX_FMT})"
[ -n "$FIVEH_STR" ] && OUT="$OUT | $FIVEH_STR"
OUT="$OUT | $TOK_STR"
[ -n "$MCP_STR" ] && OUT="$OUT | $MCP_STR"
OUT="$OUT | $COST_STR"
echo -e "${OUT}${CREDIT_STR}"
