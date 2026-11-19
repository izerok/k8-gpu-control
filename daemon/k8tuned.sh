#!/bin/bash
# k8tuned — root helper for K8 Tune.
# Reads /Users/Shared/K8Tune/state.plist (written by the GUI) and applies the
# nullarc GPU clock policy through the driver's debug sysctls:
#   debug.phx_pm_mode     1 = driver auto range
#   debug.phx_pm_gfx_max  GFX ceiling in MHz (800..2600)
#
# Also implements the optional load governor: with `auto = true` the ceiling is
# stepped down while WindowServer/CPU load stays high, and stepped back up after
# a quiet period. This is thermal management, not fan-RPM control: the K8 fan is
# driven by the BIOS/EC from firmware sensors.

STATE_DIR=/Users/Shared/K8Tune
STATE=$STATE_DIR/state.plist
LOG=/var/log/k8tune.log

mkdir -p "$STATE_DIR" 2>/dev/null
chmod 777 "$STATE_DIR" 2>/dev/null

last_target=""
last_profile=""
cur=0
high=0
low=0

while true; do
    profile=balanced
    cap=1200
    auto=false
    if [ -f "$STATE" ]; then
        p=$(/usr/libexec/PlistBuddy -c "Print :profile" "$STATE" 2>/dev/null)
        [ -n "$p" ] && profile=$p
        c=$(/usr/libexec/PlistBuddy -c "Print :cap_mhz" "$STATE" 2>/dev/null)
        [ -n "$c" ] && cap=$c
        a=$(/usr/libexec/PlistBuddy -c "Print :auto" "$STATE" 2>/dev/null)
        [ -n "$a" ] && auto=$a
    fi

    case "$profile" in
        silent)      base=800 ;;
        eco)         base=1000 ;;
        balanced)    base=1200 ;;
        performance) base=1600 ;;
        max)         base=2600 ;;
        auto)        base=2600; auto=true ;;
        custom)      base=$cap ;;
        *)           base=1200 ;;
    esac
    case "$base" in ''|*[!0-9]*) base=1200 ;; esac
    [ "$base" -lt 800 ]  && base=800
    [ "$base" -gt 2600 ] && base=2600

    if [ "$profile" != "$last_profile" ]; then
        cur=$base
        last_profile=$profile
        high=0
        low=0
    fi

    if [ "$auto" = "true" ]; then
        # Load proxy: WindowServer CPU% + 1-minute load average (8-core box).
        ws=$(ps -Ao pcpu,comm 2>/dev/null | awk '/WindowServer/{printf "%d", $1; exit}')
        [ -z "$ws" ] && ws=0
        la=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
        [ -z "$la" ] && la=0

        highload=0
        awk -v w="$ws" -v l="$la" 'BEGIN{exit !(w>60 || l>8)}' && highload=1

        if [ "$highload" = 1 ]; then
            high=$((high+1)); low=0
        else
            high=0; low=$((low+1))
        fi

        # Sustained ~30 s high -> step down 200 MHz (floor 1200: below this the UI gets laggy).
        if [ "$high" -ge 15 ]; then
            if [ "$cur" -gt 1200 ]; then
                cur=$((cur-200))
                [ "$cur" -lt 1200 ] && cur=1200
            fi
            high=0
        fi

        # Sustained ~60 s quiet -> step back up toward the tier ceiling.
        if [ "$low" -ge 30 ]; then
            if [ "$cur" -lt "$base" ]; then
                cur=$((cur+200))
                [ "$cur" -gt "$base" ] && cur=$base
            fi
            low=0
        fi
        target=$cur
    else
        target=$base
    fi

    if [ "$target" != "$last_target" ]; then
        sysctl -w debug.phx_pm_mode=1 >/dev/null 2>&1
        sysctl -w debug.phx_pm_gfx_max="$target" >/dev/null 2>&1
        echo "$(date '+%F %T') profile=$profile auto=$auto cap=$target ws=$ws la=$la" >> "$LOG"
        last_target=$target
    fi

    sleep 2
done
