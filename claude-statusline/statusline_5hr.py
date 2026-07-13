#!/usr/bin/env python3
"""Compute this session's share of tokens used within the current rolling
5-hour rate-limit window, across all Claude Code sessions on this machine.

Reads the harness's statusline JSON from stdin (same shape statusline.sh
receives). Prints a single integer percentage (0-100) and exits. Prints
nothing (and exits 0) if it can't compute a meaningful value, so the caller
can just omit the segment.

Purely local: globs ~/.claude/projects/*/*.jsonl, parses timestamps and
usage fields already written by Claude Code. Never calls the Claude API.
"""
import json
import sys
import os
import glob
import time
from datetime import datetime, timezone

CACHE_PATH = os.path.expanduser("~/.claude/.statusline_5hr_cache.json")
CACHE_TTL_SECONDS = 30
WINDOW_SECONDS = 5 * 3600


def parse_ts(ts):
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except (ValueError, AttributeError):
        return None


def load_cache():
    try:
        with open(CACHE_PATH) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def save_cache(totals):
    try:
        with open(CACHE_PATH, "w") as f:
            json.dump({"computed_at": time.time(), "totals": totals}, f)
    except OSError:
        pass


def compute_window_start(harness_input, now):
    resets_at = (
        harness_input.get("rate_limits", {})
        .get("five_hour", {})
        .get("resets_at")
    )
    if isinstance(resets_at, (int, float)) and resets_at > 0:
        return resets_at - WINDOW_SECONDS
    return now - WINDOW_SECONDS


def usage_weight(usage):
    return (
        usage.get("input_tokens", 0)
        + usage.get("cache_creation_input_tokens", 0)
        + usage.get("cache_read_input_tokens", 0)
        + usage.get("output_tokens", 0)
    )


def scan_transcripts(window_start, now):
    totals = {}
    pattern = os.path.expanduser("~/.claude/projects/*/*.jsonl")
    for path in glob.glob(pattern):
        try:
            if os.path.getmtime(path) < window_start:
                continue
        except OSError:
            continue
        try:
            with open(path, "r", errors="ignore") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        entry = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if entry.get("type") != "assistant":
                        continue
                    message = entry.get("message")
                    if not isinstance(message, dict):
                        continue
                    usage = message.get("usage")
                    if not isinstance(usage, dict):
                        continue
                    ts = parse_ts(entry.get("timestamp"))
                    if ts is None or not (window_start <= ts <= now):
                        continue
                    session_id = entry.get("sessionId")
                    if not session_id:
                        continue
                    totals[session_id] = totals.get(session_id, 0) + usage_weight(usage)
        except OSError:
            continue
    return totals


def main():
    try:
        harness_input = json.load(sys.stdin)
    except json.JSONDecodeError:
        return

    session_id = harness_input.get("session_id")
    if not session_id:
        return

    now = time.time()

    # Cache holds the shared per-session totals scan, not a single session's
    # result — any concurrently-running session can reuse a fresh scan
    # instead of invalidating each other's cache (each session polls this
    # script independently, so a per-session cache key would thrash).
    cache = load_cache()
    if cache and now - cache.get("computed_at", 0) < CACHE_TTL_SECONDS:
        totals = cache.get("totals", {})
    else:
        window_start = compute_window_start(harness_input, now)
        totals = scan_transcripts(window_start, now)
        save_cache(totals)

    total_all = sum(totals.values())
    if total_all <= 0:
        return

    session_total = totals.get(session_id, 0)
    share = round(session_total / total_all * 100)
    print(share)


if __name__ == "__main__":
    main()
