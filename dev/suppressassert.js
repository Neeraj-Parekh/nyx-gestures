/* Regression test: the suppressor must re-disable BOTH native swipe trackers
 * on every enable(), including after a disable() in the same session.
 *
 * Bug caught (2026-11-25): enable() used `if (this._trackers) return;`, but
 * disable() leaves `_trackers = []` (truthy in JS), so re-enable returned early
 * and native gestures stayed live -> double-firing. Never shipped.
 *
 * SELF-CONTAINED: uses fake tracker objects injected into Main so the result
 * does not depend on whatever the rig's other extension does to the real
 * trackers (its notify hooks would otherwise fight the baseline). */
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import NyxNativeSuppress from '../nyx-native-suppress@nyx.local/extension.js';

function fakeTracker() {
    return {
        _enabled: true,
        _hooks: new Map(),
        _nextId: 1,
        get enabled() { return this._enabled; },
        set enabled(v) {
            this._enabled = v;
            for (const fn of this._hooks.values()) fn(this);
        },
        connect(sig, fn) { const id = this._nextId++; this._hooks.set(id, fn); return id; },
        disconnect(id) { this._hooks.delete(id); },
    };
}

export function run() {
    let fails = 0;
    const ck = (label, cond) => {
        console.log((cond ? 'SUPPRESS_ASSERT OK ' : 'SUPPRESS_ASSERT FAIL ') + label);
        if (!cond) fails++;
    };
    const both = (wm, ov, v) => wm.enabled === v && ov.enabled === v;
    const wm = fakeTracker();
    const ov = fakeTracker();
    // Save & replace the real tracker refs for the duration of this test.
    let savedWm, savedOv, hadWm = false, hadOv = false;
    try {
        const wa = Main.wm?._workspaceAnimation;
        if (wa) { hadWm = '_swipeTracker' in wa; savedWm = wa._swipeTracker; wa._swipeTracker = wm; }
        if (Main.overview) { hadOv = '_swipeTracker' in Main.overview; savedOv = Main.overview._swipeTracker; Main.overview._swipeTracker = ov; }

        ck('injected both trackers', both(wm, ov, true));
        const s = new NyxNativeSuppress();

        s.enable();
        ck('enable disables both', both(wm, ov, false));

        wm.enabled = true;  // simulate the shell re-enabling (workspaceAnimation.js:356,476)
        ov.enabled = true;
        ck('notify hook keeps both off', both(wm, ov, false));

        s.disable();
        ck('disable restores both', both(wm, ov, true));

        // THE REGRESSION: re-enable after disable in the same session.
        // With the bug, enable() early-returns and both stay true.
        s.enable();
        ck('re-enable re-disables both (empty-array bug)', both(wm, ov, false));
        s.disable();
        ck('cleanup after re-enable', both(wm, ov, true));
    } catch (e) {
        console.log('SUPPRESS_ASSERT THREW ' + e.message);
        fails++;
    } finally {
        const wa = Main.wm?._workspaceAnimation;
        if (wa) { if (hadWm) wa._swipeTracker = savedWm; else delete wa._swipeTracker; }
        if (Main.overview) { if (hadOv) Main.overview._swipeTracker = savedOv; else delete Main.overview._swipeTracker; }
    }
    console.log('SUPPRESS_ASSERT RESULT ' + (fails ? 'FAIL' : 'PASS'));
}
