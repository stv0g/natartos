#!/system/bin/sh
# natartos inject — restart dji_glasses with LD_PRELOAD + respawn
# Respawn up to MAX_CRASHES times within WINDOW_SEC, then give up.
MAX_CRASHES=5
WINDOW_SEC=120
LOG=/data/local/tmp/natartos_inject.log
PIDFILE=/data/local/tmp/natartos_inject.pid

log() { echo "$(date '+%H:%M:%S') $1" >> "$LOG"; }

# ── Single-instance guard ──
# Kill previous inject.sh + its dji_glasses before taking over.
if [ -f "$PIDFILE" ]; then
    OLD_PID=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        log "killing old inject pid=$OLD_PID"
        # Kill child dji_glasses first (PPID = old inject)
        for child in $(ps -A -o pid,ppid | while read cpid cppid; do [ "$cppid" = "$OLD_PID" ] && echo "$cpid"; done); do
            kill -9 "$child" 2>/dev/null
        done
        kill -9 "$OLD_PID" 2>/dev/null
        sleep 1
    fi
fi
echo $$ > "$PIDFILE"

sleep 3
rm -f /data/local/tmp/fb_shared
stop dji_glasses 2>/dev/null
log "stopped init service dji_glasses"
sleep 1
PID=$(pidof dji_glasses)
[ -n "$PID" ] && kill "$PID" && log "killed leftover pid=$PID"
sleep 1

build_preload() {
    P=/vendor/natartos/natartos_loader.so
    for so in /vendor/natartos/mods/*.so; do
        s=$(basename "$so")
        [ -f /vendor/natartos/enabled/"$s" ] && P="$P:$so"
    done
    echo "$P"
}

crash_count=0
last_reset=$(date +%s)

while true; do
    # Each fresh dji_glasses starts clean: drop runtime overlay flags a previous
    # session (or the respawn before this one) left behind. A stale fb_stop
    # otherwise makes the new overlay run cleanup→restart on every boot forever.
    rm -f /data/local/tmp/fb_stop /data/local/tmp/fb_override
    PRELOAD=$(build_preload)
    export LD_PRELOAD="$PRELOAD"
    log "start dji_glasses LD_PRELOAD=$PRELOAD"
    /system/bin/dji_glasses -g -f
    EXIT=$?
    log "exited code=$EXIT"

    # Intentional restart (overlay kicks this on app exit to repaint the UI) —
    # not a crash: respawn at once, don't touch the crash counter.
    if [ -f /data/local/tmp/natartos_restart ]; then
        rm -f /data/local/tmp/natartos_restart
        log "intentional restart (app exit)"
        continue
    fi

    now=$(date +%s)
    elapsed=$((now - last_reset))
    if [ "$elapsed" -ge "$WINDOW_SEC" ]; then
        crash_count=0
        last_reset=$now
    fi
    crash_count=$((crash_count + 1))

    if [ "$crash_count" -ge "$MAX_CRASHES" ]; then
        log "GIVE UP: $crash_count crashes in ${elapsed}s — restarting stock dji_glasses (no mods)"
        rm -f /data/local/tmp/fb_stop /data/local/tmp/fb_override
        # hand the UI back to init's stock service (no LD_PRELOAD) instead of
        # leaving the goggles without a UI until the next reboot
        start dji_glasses 2>/dev/null
        break
    fi

    log "respawn #$crash_count in 2s"
    sleep 2
done

rm -f "$PIDFILE"
