#!/bin/bash

BATT_INFO=$(pmset -g batt)
PERCENTAGE=$(echo "$BATT_INFO" | grep -o '[0-9]*%' | head -1 | tr -d '%')
IS_DISCHARGING=$(echo "$BATT_INFO" | grep -c 'discharging')
LOCKFILE="/tmp/battery_warning_shown"

if [ "$IS_DISCHARGING" -gt 0 ] && [ "$PERCENTAGE" -le 2 ] && [ "$PERCENTAGE" -ge 1 ]; then
    if [ ! -f "$LOCKFILE" ]; then
        touch "$LOCKFILE"
        osascript -e 'display dialog "Plugin now! Battery is almost gone." with title "Battery Warning" buttons {"OK"} default button "OK"'
    fi
elif [ "$PERCENTAGE" -gt 20 ]; then
    rm -f "$LOCKFILE"
fi
