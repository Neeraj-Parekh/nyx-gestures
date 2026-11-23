/* Pure gesture -> action mapping for nyx-gestures.
 *
 * Deliberately contains NO gi:// imports and no Clutter references, so it can
 * be loaded by plain node and unit-tested outside a GNOME Shell process. That
 * matters because the alternative - a mapping buried inside the event handler -
 * can only be exercised by a real touchpad in a live session, which needs a
 * logout. dev/decisiontest.js drives this file exhaustively instead.
 *
 * Separating decision from effect is also why the handlers can now report a
 * distinct "the action ran but declined" (no window, window not resizable)
 * from "this gesture is not bound at all". Only the former should swallow the
 * event; the latter must be propagated so the compositor still sees it.
 */

/* Which action a completed swipe maps to.
 *
 *   fingers    3 or 4 (2 is scroll, not ours)
 *   horizontal axis locked to horizontal?
 *   positive   accumulated delta along that axis is positive. Horizontal
 *              positive = fingers moved RIGHT (dx>0). Vertical positive =
 *              fingers moved DOWN (dy>0): libinput/mutter report dy<0 for
 *              fingers moving UP, so 'up' actions are the NEGATIVE branch.
 *
 * Returns an action name, or null when the gesture is not bound.
 *
 * Direction semantics, verified on a virtual touchpad (dev/gesturesynth.c)
 * with libinput: fingers moved left  -> dx < 0, fingers moved up -> dy < 0.
 * Natural scrolling is NOT applied, because it is a scroll-axis display
 * convention and mutter passes gesture deltas through untouched. libinput-
 * gestures, the proven backend, likewise classifies direction as
 * `motion = 'left' if x < 0 else 'right'`.
 */
export function decideSwipe(fingers, horizontal, positive) {
    if (fingers === 3) {
        if (horizontal)
            return positive ? 'tile-right' : 'tile-left';
        return positive ? 'begin-resize' : 'overview';
    }
    if (fingers === 4) {
        if (horizontal)
            // CROSSED, deliberately, to match the daemon config and the
            // hardware-confirmed preference: swipe LEFT goes to the workspace
            // on the right. This is the opposite of GNOME's own 4-finger swipe,
            // so it reads like a bug - it is not. dev/decisiontest.js compares
            // this mapping against libinput-gestures.conf and fails if the two
            // backends ever disagree, which is how the straight (incorrect)
            // version of these two lines was caught.
            return positive ? 'workspace-left' : 'workspace-right';
        return positive ? 'show-desktop' : 'fullscreen';
    }
    return null;
}

/* Which action a completed pinch maps to.
 *
 *   fingers  3 or 4
 *   out      fingers spreading apart
 *
 * `out` comes from libinput's own definition: "The scale begins at 1.0, and if
 * e.g. the fingers moved together by 50% then the scale will become 0.5, if
 * they move twice as far apart as initially the scale becomes 2.0." mutter
 * forwards that value unclamped, so scale > 1 means spreading.
 *
 * 2-finger pinch is intentionally null: mutter 50 has no zoom API of any kind
 * (no meta_window_zoom in any maintained branch, no set_size, no compositor
 * scale-to-fit), so there is nothing correct to bind it to.
 */
export function decidePinch(fingers, out) {
    if (fingers === 3)
        return out ? 'screenshot-full' : 'close-window';
    if (fingers === 4)
        return out ? 'screenshot-picker' : 'show-desktop';
    return null;
}

/* Every action name the two functions above can return. Used by the test to
 * prove there are no unreachable entries in the dispatch table and no missing
 * ones, which is the failure mode that leaves a gesture silently unbound. */
export const ALL_ACTIONS = [
    'tile-left', 'tile-right', 'overview', 'begin-resize',
    'workspace-left', 'workspace-right', 'fullscreen', 'show-desktop',
    'screenshot-full', 'screenshot-picker', 'close-window',
];

/* The (fingers, direction) pairs that are bound, as readable strings. The test
 * cross-checks this against the daemon's libinput-gestures.conf so the two
 * backends cannot drift apart: migrating between them must not silently change
 * what a gesture means. */
export function boundSwipes() {
    const out = [];
    for (const fingers of [3, 4]) {
        for (const horizontal of [true, false]) {
            for (const positive of [true, false]) {
                const action = decideSwipe(fingers, horizontal, positive);
                if (action)
                    out.push(`${fingers}F swipe ${horizontal ? (positive ? 'right' : 'left') : (positive ? 'down' : 'up')}`);
            }
        }
    }
    return out;
}

export function boundPinches() {
    const out = [];
    for (const fingers of [3, 4]) {
        for (const out_ of [true, false]) {
            const action = decidePinch(fingers, out_);
            if (action)
                out.push(`${fingers}F pinch ${out_ ? 'out' : 'in'}`);
        }
    }
    return out;
}
