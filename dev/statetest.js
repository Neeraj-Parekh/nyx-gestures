/* State-machine test for the extension's event handling, run inside the
 * headless GNOME Shell rig.
 *
 * Why fake events: Clutter.Event cannot be constructed from JS, but
 * _onSwipe/_onPinch only ever call type(), get_touchpad_gesture_finger_count(),
 * get_gesture_phase(), get_gesture_motion_delta() and get_gesture_pinch_scale().
 * A duck-typed object providing those is enough to drive the real handler code,
 * which means the threshold, axis-lock and state-reset logic can be tested
 * without a touchpad, a live session, or a logout.
 *
 * What this genuinely covers:
 *   - motion below AXIS_LOCK_THRESHOLD never fires
 *   - the axis is locked once, on the accumulated vector, and the other axis is
 *     then ignored (a diagonal swipe must not flap)
 *   - state is cleared on END *and* on CANCEL, so a cancelled swipe cannot leak
 *     deltas into the next gesture
 *   - a duplicate BEGIN does not reset a gesture mid-flight
 *   - a finger-count change mid-gesture resyncs instead of dropping everything
 *   - pinch direction: spreading fires the screenshot, closing fires window-close
 *
 * What it cannot cover: whether each GNOME action does the visually right thing.
 * That still needs a real session.
 */
import Clutter from 'gi://Clutter';
import NyxGesturesExtension from '../nyx-gestures@nyx.local/extension.js';

const STOP = Clutter.EVENT_STOP;
const PROPAGATE = Clutter.EVENT_PROPAGATE;
const B = Clutter.TouchpadGesturePhase.BEGIN;
const U = Clutter.TouchpadGesturePhase.UPDATE;
const E = Clutter.TouchpadGesturePhase.END;
const C = Clutter.TouchpadGesturePhase.CANCEL;

let failures = 0;
let checks = 0;

function check(label, actual, expected) {
    checks++;
    if (actual !== expected) {
        failures++;
        console.log(`  FAIL  ${label}: got ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`);
    }
}

function swipeEvt(fingers, phase, dx = 0, dy = 0) {
    return {
        type: () => Clutter.EventType.TOUCHPAD_SWIPE,
        get_touchpad_gesture_finger_count: () => fingers,
        get_gesture_phase: () => phase,
        get_gesture_motion_delta: () => [dx, dy],
        get_gesture_pinch_scale: () => 1.0,
    };
}

function pinchEvt(fingers, phase, scale) {
    return {
        type: () => Clutter.EventType.TOUCHPAD_PINCH,
        get_touchpad_gesture_finger_count: () => fingers,
        get_gesture_phase: () => phase,
        get_gesture_motion_delta: () => [0, 0],
        get_gesture_pinch_scale: () => scale,
    };
}

export function run() {
const ext = new NyxGesturesExtension();
ext._swipe = null;
ext._pinch = null;

console.log('STATE_TEST ===== 1. sub-threshold motion never fires =====');
ext._onSwipe(swipeEvt(3, B));
// 5 updates of 2 units = 10 total, below AXIS_LOCK_THRESHOLD (16).
for (let i = 0; i < 5; i++)
    check(`sub-threshold update ${i + 1} propagates`, ext._onSwipe(swipeEvt(3, U, 2, 0)), PROPAGATE);
check('no axis locked yet', ext._swipe.axis, null);
check('nothing fired', ext._swipe.done, false);

console.log('STATE_TEST ===== 2. large motion fires, and latches =====');
// Uses 3F swipe UP -> overview, not 3F swipe RIGHT -> tile. A headless shell has
// no windows, so tileFocused() legitimately declines and returns false; that is
// correct behaviour, but it makes it useless for asserting the latch. The
// overview toggle is one of the few actions that genuinely succeeds here.
//
// Consequence worth stating: "the action ran and succeeded" cannot be asserted
// headlessly for the window-dependent actions (tile, fullscreen, close, show
// desktop, resize). What IS asserted for those is that they are selected and
// invoked - covered by dev/decisiontest.js - and that the state machine around
// them behaves, which is what this file checks.
ext._onSwipe(swipeEvt(3, B));
for (let i = 0; i < 12; i++)
    ext._onSwipe(swipeEvt(3, U, 0, -10));
check('3F swipe up is handled', ext._swipe.done, true);
check('axis locked vertical', ext._swipe.axis, 'v');
// Further events must not re-run the action.
check('post-commit events stay STOP', ext._onSwipe(swipeEvt(3, U, 0, 10)), STOP);
check('still one gesture, not restarted', ext._swipe.done, true);
ext._onSwipe(swipeEvt(3, E));

console.log('STATE_TEST ===== 2b. bound gestures are claimed even when declined =====');
// Bug A: a declined 3F horizontal swipe must NOT propagate, or GNOME's native
// tracker switches workspace. With no window to tile the action declines, but
// the gesture is still claimed (done=true, STOP) so nothing else acts on it.
ext._onSwipe(swipeEvt(3, B));
for (let i = 0; i < 12; i++)
    ext._onSwipe(swipeEvt(3, U, 10, 0));
check('3F swipe right (tile) declines yet is claimed', ext._swipe.done, true);
check('declined bound gesture is swallowed, not propagated', ext._onSwipe(swipeEvt(3, U, 10, 0)), STOP);
ext._onSwipe(swipeEvt(3, E));

console.log('STATE_TEST ===== 3. state cleared on END and CANCEL =====');
ext._onSwipe(swipeEvt(3, E));
check('END clears swipe state', ext._swipe, null);
ext._onSwipe(swipeEvt(3, B));
ext._onSwipe(swipeEvt(3, U, 30, 0));
ext._onSwipe(swipeEvt(3, C));
check('CANCEL clears swipe state', ext._swipe, null);

console.log('STATE_TEST ===== 4. axis lock picks once and ignores the other axis =====');
ext._onSwipe(swipeEvt(4, B));
// Push mostly-horizontal past the lock threshold...
for (let i = 0; i < 10; i++)
    ext._onSwipe(swipeEvt(4, U, 6, 1));
check('axis locked to horizontal despite vertical drift', ext._swipe.axis, 'h');
// Now a large vertical push must NOT flip to the vertical action.
for (let i = 0; i < 40; i++)
    ext._onSwipe(swipeEvt(4, U, 0, 40));
check('vertical flood did not change the locked axis', ext._swipe.axis, 'h');
ext._onSwipe(swipeEvt(4, E));

console.log('STATE_TEST ===== 5. duplicate BEGIN is ignored =====');
ext._onSwipe(swipeEvt(3, B));
ext._onSwipe(swipeEvt(3, U, 12, 0));
const dxBefore = ext._swipe.dx;
ext._onSwipe(swipeEvt(3, B));
check('duplicate BEGIN preserved accumulated dx', ext._swipe.dx, dxBefore);

console.log('STATE_TEST ===== 6. finger-count change mid-gesture resyncs =====');
ext._onSwipe(swipeEvt(3, B));
for (let i = 0; i < 8; i++)
    ext._onSwipe(swipeEvt(3, U, 10, 0));
const beforeResync = ext._swipe.fingers;
ext._onSwipe(swipeEvt(4, U, 10, 0));
check('fingers resynced to the new count', ext._swipe.fingers, 4);
check('accumulated delta reset on resync', ext._swipe.dx, 0);
check('did not carry the old axis', ext._swipe.axis, null);
check('was not 3 before resync', beforeResync, 3);

console.log('STATE_TEST ===== 7. pinch direction =====');
// 3F pinch OUT (fingers spreading, scale > 1) -> screenshot.
ext._onPinch(pinchEvt(3, B));
ext._onPinch(pinchEvt(3, U, 1.0));   // baseline
check('3F pinch out handled', ext._onPinch(pinchEvt(3, U, 1.6)), STOP);
check('pinch out (scale>1) decided screenshot-full', ext._lastPinchAction, 'screenshot-full');
ext._onPinch(pinchEvt(3, E));

// 3F pinch IN (fingers together, scale < 1) -> close window, which declines in a
// headless shell because there is no focused window. Like any bound gesture it
// is now CLAIMED (STOP) even when declined, so it cannot fall through to native.
// That it maps to close-window and NOT screenshot is asserted by decisiontest.js
// (decidePinch), since both bound outcomes now return STOP.
ext._onPinch(pinchEvt(3, B));
ext._onPinch(pinchEvt(3, U, 1.0));
check('3F pinch in is claimed (bound), not propagated', ext._onPinch(pinchEvt(3, U, 0.6)), STOP);
check('pinch in (scale<1) decided close-window, not screenshot', ext._lastPinchAction, 'close-window');
ext._onPinch(pinchEvt(3, E));

console.log('STATE_TEST ===== 8. sub-threshold pinch ratio is ignored =====');
ext._onPinch(pinchEvt(3, B));
ext._onPinch(pinchEvt(3, U, 1.0));
check('1.05x spread below PINCH_THRESHOLD propagates',
    ext._onPinch(pinchEvt(3, U, 1.05)), PROPAGATE);
check('and did not latch', ext._pinch.done, false);
ext._onPinch(pinchEvt(3, E));

console.log('STATE_TEST ===== 9. 2-finger swipe is never consumed =====');
ext._onSwipe(swipeEvt(2, B));
let twoFinger = PROPAGATE;
for (let i = 0; i < 30; i++)
    twoFinger = ext._onSwipe(swipeEvt(2, U, 20, 0));
check('2-finger swipe always propagates (scroll must survive)', twoFinger, PROPAGATE);
check('2-finger swipe did not latch done', ext._swipe.done, false);

console.log(`STATE_TEST ${failures ? `FAILED: ${failures} of ${checks} checks` : `PASSED: all ${checks} checks`}`);
}
