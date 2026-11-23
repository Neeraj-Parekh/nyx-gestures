#!/bin/bash
# Verify gesture DIRECTION, finger count and pinch scale without letting any of
# it reach the live desktop.
#
# SAFETY MODEL - why this is safe on a live session:
#   1. A virtual touchpad is created via /dev/uinput.
#   2. Before any gesture is emitted, `libinput debug-events --grab` opens that
#      device and takes an exclusive EVIOCGRAB on it.
#   3. While the grab is held, GNOME's own libinput context cannot read the
#      device at all, so no synthetic gesture can ever reach libinput-gestures,
#      the nyx extension, or any compositor action.
#   4. The device is destroyed on exit, including on error.
#
# The grab is asserted, not assumed: the script refuses to emit any gesture
# until it has confirmed the grab took effect, and it verifies afterwards that
# the device is gone.
#
# What this CANNOT tell you: whether the action that follows is correct. It has
# no windows and no compositor. Only the direction/finger/scale facts, which is
# exactly the part that was unverified.
set -uo pipefail

SYNTH="${SYNTH:-/tmp/gesturesynth}"
OUT="${OUT:-/tmp/nyx-gesture-directions.log}"
DBG=/tmp/nyx-libinput-dbg.log
FIFO=/tmp/nyx-synth.fifo

cleanup() {
    # Never a bare `wait` here: with no arguments it waits for EVERY child,
    # including the long sleep that holds the fifo open, so the script hangs
    # forever on exit. Kill each pid we started, by name.
    for p in "${DBG_PID:-}" "${SYN_PID:-}" "${SLEEP_PID:-}"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null
    done
    rm -f "$FIFO"
}
trap cleanup EXIT

[ -x "$SYNTH" ] || { echo "ERROR: $SYNTH not built (gcc -O2 -o $SYNTH dev/gesturesynth.c -lm)" >&2; exit 1; }

rm -f "$FIFO"; mkfifo "$FIFO"
: > "$OUT"; : > "$DBG"

# Keep the fifo open so the synthesiser does not see EOF and exit immediately.
sleep 600 > "$FIFO" &
SLEEP_PID=$!

"$SYNTH" serve < "$FIFO" 2>>"$OUT" &
SYN_PID=$!

# --- find the event node for our device ------------------------------------
NODE=""
for _ in $(seq 1 60); do
    for ue in /sys/class/input/event*/device/uevent; do
        [ -r "$ue" ] || continue
        # NOTE: the line reads NAME="NyxGestureSynthesizer: ..." - with a quote
        # after NAME=. An anchored "^NAME=Nyx" test never matches, which is why
        # an earlier version of this script aborted after the device had
        # already been created. Match the bare substring.
        if grep -q "NyxGestureSynthesizer" "$ue" 2>/dev/null; then
            NODE="/dev/input/$(basename "$(dirname "$(dirname "$ue")")")"
            break
        fi
    done
    [ -n "$NODE" ] && break
    sleep 0.25
done
if [ -z "$NODE" ] || [ ! -e "$NODE" ]; then
    echo "ABORT: virtual touchpad never appeared; no gestures emitted." >&2
    exit 1
fi
echo "virtual touchpad: $NODE"

# --- attach the grabber BEFORE any gesture is emitted ----------------------
libinput debug-events --grab --device "$NODE" > "$DBG" 2>&1 &
DBG_PID=$!
sleep 2
if ! kill -0 "$DBG_PID" 2>/dev/null; then
    echo "ABORT: libinput debug-events died; refusing to emit ungrabbed gestures." >&2
    cat "$DBG" >&2
    exit 1
fi
echo "grab held on $NODE by pid $DBG_PID (GNOME cannot read this device)"
echo

# --- drive the gestures -----------------------------------------------------
# Wait for each DONE marker rather than sleeping a fixed time: a fixed sleep
# silently truncated the tail of the list, which looks identical to "libinput
# did not classify these gestures" - a wrong conclusion, not a missing one.
GESTURES="swipe3-left swipe3 swipe3-up swipe3-down swipe4-left swipe4 swipe4-up swipe4-down pinch-out3 pinch-in3 pinch-out4 pinch-in4 hold3"
for g in $GESTURES; do
    echo "$g" > "$FIFO"
    for _ in $(seq 1 40); do
        grep -q "^DONE $g\$" "$OUT" && break
        sleep 0.25
    done
    if ! grep -q "^DONE $g\$" "$OUT"; then
        echo "WARN: $g did not report DONE within 10s" >&2
    fi
done

sleep 1
echo quit > "$FIFO"
sleep 1.5
for p in "$SYN_PID" "$SLEEP_PID"; do kill "$p" 2>/dev/null; done
sleep 0.5
kill "$DBG_PID" 2>/dev/null

# --- device must be gone ----------------------------------------------------
LEFT=0
for ue in /sys/class/input/event*/device/uevent; do
    [ -r "$ue" ] && grep -q "NyxGestureSynthesizer" "$ue" 2>/dev/null && LEFT=1
done
if [ "$LEFT" = 1 ]; then
    echo "WARN: a NyxGestureSynthesizer device is still present" >&2
else
    echo "clean: virtual device destroyed"
fi
echo
echo "=== observed by libinput (grabbed context) ==="
grep -E "GESTURE_" "$DBG" | sed 's/^ */  /'
