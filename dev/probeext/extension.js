/* Test-only. Runs the API assertions against a real GNOME Shell 50 process and
 * prints FINAL_ASSERT. Lives in dev/ and is never packaged into the extension
 * ZIP - it must not ship, because a failing assert would be noise in a user's
 * session and the probe imports dev/apiprobe.js which is not in the payload.
 *
 * Why this exists rather than trusting node --check or a read of the docs:
 * every call in extension/extension.js was verified this way, and two of the
 * assumptions turned out to be wrong - Meta.Window has no toggle_fullscreen()
 * (it is make/unmake + a property) and Meta.GrabOp has no
 * WINDOW_FLAG_UNCONSTRAINED member despite it appearing in a quote of
 * mutter's keybindings.c. A missing method is a TypeError thrown from inside
 * a gesture handler, which silently kills the gesture, not the shell. */
/* Relative imports resolve against the extensions ROOT (the parent of this
 * extension's directory), not this directory - so './' is correct here because
 * testrig.sh copies apiprobe.js and selftest.js next to this file. */
import GLib from 'gi://GLib';
import {run} from './apiprobe.js';
import {runSelfTest} from './selftest.js';

export default class NyxApiProbeExtension {
    enable() {
        // Wait for the stage so global.stage and Main are fully built.
        GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 3, () => {
            run().then(runSelfTest).catch(e => {
                console.log(`FINAL_ASSERT FAILED: probe threw ${e.message}`);
            });
            return GLib.SOURCE_REMOVE;
        });
        // Loaded separately and second: statetest.js imports the extension under
        // test, and a failure there must not mask the API assertions above.
        GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 4, () => {
            import('./statetest.js')
                .then(m => m.run())
                .catch(e => console.log(`STATE_TEST FAILED to run: ${e.message}`));
            return GLib.SOURCE_REMOVE;
        });
        GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 5, () => {
            import('./logtest.js')
                .then(m => m.run())
                .catch(e => console.log(`LOG_TEST FAILED to run: ${e.message}`));
            return GLib.SOURCE_REMOVE;
        });
    }

    disable() {}
}
