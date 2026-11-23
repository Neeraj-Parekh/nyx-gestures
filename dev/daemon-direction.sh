#!/bin/bash
# Determine libinput-gestures' OWN left/right/up/down convention for raw
# touchpad deltas, by running the real daemon against a virtual touchpad.
#
# Why this matters: the extension and this daemon must agree on what
# "swipe left" means, or migrating between them silently reverses every
# gesture. The extension currently negates deltas when natural-scroll is on
# (ported from GNOME's swipeTracker.js:188). The daemon is the path the user
# has already confirmed feels right, so its convention is the reference.
#
# SAFETY: the config's commands only append to a file. The virtual pad is the
# only thing that can fire, and the real touchpad is untouched.
set -uo pipefail

SYNTH="${SYNTH:-/tmp/gesturesynth}"
CONF=/tmp/nyx-lg-test.conf
RES=/tmp/nyx-lg-result.txt
LOG=/tmp/nyx-lg-debug.log
FIFO=/tmp/nyx-lg.fifo

cleanup() {
    for p in "${LG_PID:-}" "${SYN_PID:-}" "${SLEEP_PID:-}"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null
    done
    rm -f "$FIFO"
}
trap cleanup EXIT

[ -x "$SYNTH" ] || { echo "ERROR: build gesturesynth first" >&2; exit 1; }
: > "$RES"; : > "$LOG"

cat > "$CONF" <<EOF
# Every command is a no-op append. The label tells us which direction the
# daemon matched for a given physical finger movement.
gesture swipe left  3 echo L3 >> $RES
gesture swipe right 3 echo R3 >> $RES
gesture swipe up    3 echo U3 >> $RES
gesture swipe down  3 echo D3 >> $RES
gesture swipe left  4 echo L4 >> $RES
gesture swipe right 4 echo R4 >> $RES
gesture swipe up    4 echo U4 >> $RES
gesture swipe down  4 echo D4 >> $RES
gesture pinch in    3 echo PIN3 >> $RES
gesture pinch out   3 echo POUT3 >> $RES
EOF

rm -f "$FIFO"; mkfifo "$FIFO"
sleep 600 > "$FIFO" & SLEEP_PID=$!
"$SYNTH" serve < "$FIFO" 2>>"$LOG" & SYN_PID=$!

NODE=""
for _ in $(seq 1 60); do
    for ue in /sys/class/input/event*/device/uevent; do
        [ -r "$ue" ] || continue
        grep -q "NyxGestureSynthesizer" "$ue" 2>/dev/null && \
            { NODE="/dev/input/$(basename "$(dirname "$(dirname "$ue")")")"; break; }
    done
    [ -n "$NODE" ] && break
    sleep 0.25
done
[ -n "$NODE" ] || { echo "ABORT: no virtual pad" >&2; exit 1; }
echo "virtual pad: $NODE  -> starting daemon"
sleep 1

libinput-gestures -c "$CONF" -d > "$LOG.debug" 2>&1 & LG_PID=$!
sleep 4

for g in swipe3-left swipe3 swipe3-up swipe3-down swipe4-left swipe4 swipe4-up swipe4-down pinch-out3 pinch-in3; do
    echo "$g" > "$FIFO"
    for _ in $(seq 1 40); do grep -q "^DONE $g\$" "$LOG" && break; sleep 0.25; done
    sleep 0.6
done

echo quit > "$FIFO"
sleep 1
for p in "$SYN_PID" "$SLEEP_PID"; do kill "$p" 2>/dev/null; done
sleep 0.5
kill "$LG_PID" 2>/dev/null
sleep 0.5

echo
echo "=== physical finger movement  ->  label the daemon fired ==="
/mnt/20265E15265DEC72/study/CODE/linux_venv/bin/python - "$LOG" "$RES" <<'PY'
import re, sys
log, res = sys.argv[1], sys.argv[2]
# Recover the order gestures were synthesised by pairing DONE markers with the
# results accumulated since the previous one.
marks = [m.group(1) for m in re.finditer(r'^DONE (\S+)$', open(log).read(), re.M)]
fired = [l.strip() for l in open(res) if l.strip()]
NAME = {'swipe3-left':('3 fingers -> LEFT',  'L3'), 'swipe3':('3 fingers -> RIGHT', 'R3'),
        'swipe3-up':('3 fingers -> UP',    'U3'), 'swipe3-down':('3 fingers -> DOWN','D3'),
        'swipe4-left':('4 fingers -> LEFT',  'L4'), 'swipe4':('4 fingers -> RIGHT','R4'),
        'swipe4-up':('4 fingers -> UP',      'U4'), 'swipe4-down':('4 fingers -> DOWN','D4'),
        'pinch-out3':('pinch OUT','POUT3'), 'pinch-in3':('pinch IN','PIN3')}
i = 0
for m in marks:
    got = fired[i] if i < len(fired) else None
    i += 1 if got else 0
    want = NAME.get(m, (m, None))[1]
    ok = 'YES' if got == want else ('(nothing fired)' if got is None else f'no -> got {got}')
    print(f"  {NAME.get(m,(m,''))[0]:<20} daemon matched: {ok}")
PY
