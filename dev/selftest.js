/* Self-test: exercises every action path inside the real shell so we can see
 * which API calls actually work, without needing a physical touchpad.
 * Run by testrig.sh via dev/probeext/extension.js; never shipped. */

import Gio from 'gi://Gio';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

function t(label, fn) {
    let r;
    try { r = fn(); console.log(`SELFTEST ${label}: OK -> ${r}`); }
    catch (e) { console.log(`SELFTEST ${label}: THREW -> ${e.message}`); }
}

export function runSelfTest() {
    console.log('SELFTEST ===== beginning =====');
    const win = global.display.focus_window;

    // A headless shell has no windows at all, so every window-dependent call
    // below would throw "win is null" and bury the results that DO matter.
    // Say so once, then skip them, rather than printing a wall of THREW lines
    // that looks like a failure.
    const actors = global.get_window_actors?.() ?? [];
    if (!win || actors.length === 0) {
        console.log('SELFTEST no windows in this session - ' +
            'skipping window actions (tiling, fullscreen, resize, close).');
        console.log('SELFTEST these need a real session or dev/gesturesynth.c.');
    }

    t('global.get_window_actors', () => String(typeof global.get_window_actors));
    t('global.window_actors count', () => String(actors.length));

    if (win && actors.length > 0) {
        t('Meta.Window.allows_resize', () => String(typeof win.allows_resize === 'function'));
        t('get_work_area_all_monitors', () => {
            const a = win.get_work_area_all_monitors?.();
            return `areas=${a ? a.length : 'null'}`;
        });
        t('move_resize_frame present', () => String(typeof win.move_resize_frame === 'function'));
        t('TILE LEFT (real call)', () => {
            const area = win.get_work_area_all_monitors()[0];
            const half = Math.floor(area.width / 2);
            win.move_resize_frame(true, area.x, area.y, half, area.height);
            const r = win.get_frame_rect();
            return `w=${r.width} expect=${half} x=${r.x} expect=${area.x}`;
        });
        t('TILE RIGHT (real call)', () => {
            const area = win.get_work_area_all_monitors()[0];
            const half = Math.floor(area.width / 2);
            win.move_resize_frame(true, area.x + half, area.y, half, area.height);
            const r = win.get_frame_rect();
            return `w=${r.width} expect=${half} x=${r.x} expect=${area.x + half}`;
        });

        // ---- 4F swipe up: fullscreen (what alt+F9 does) ------------------
        t('fullscreen property readable', () => String(win.fullscreen));
        t('MAKE FULLSCREEN (real call)', () => {
            win.make_fullscreen();
            return `fullscreen now=${win.fullscreen}`;
        });
        t('UNMAKE FULLSCREEN (real call)', () => {
            win.unmake_fullscreen();
            return `fullscreen now=${win.fullscreen}`;
        });
        t('toggle_fullscreen absent (expected)', () =>
            String(typeof win.toggle_fullscreen));
        t('get_window_type (real call)', () => String(win.get_window_type()));

        // ---- 3F swipe down: begin interactive resize (what alt+F8 does) --
        t('allows_resize before grab', () => String(win.allows_resize()));
        t('BEGIN GRAB OP KEYBOARD_RESIZING (real call)', () => {
            // After this the compositor owns the keyboard until the user
            // presses Escape - identical to alt+F8. Note we deliberately do
            // NOT try to synthesise the Escape: Clutter 18's seat has no
            // notify_keyval (verified), and leaving a grab open here would
            // wedge the headless shell's keyboard for later tests. Since the
            // headless shell has no windows this never starts anyway; on a
            // real session the user's own Escape ends it.
            const r = win.begin_grab_op(Meta.GrabOp.KEYBOARD_RESIZING_UNKNOWN,
                null, global.get_current_time(), null);
            return `returned=${r} (keyboard now grabbed until user presses Escape)`;
        });
    }

    t('Shell.WindowTracker present', () => String(!!Shell.WindowTracker));
    t('actor meta_window all', () => {
        const a = actors[0];
        return a ? String(typeof a.meta_window) : 'no actors';
    });
    t('Main.wm._showTilePreview', () => String(typeof Main.wm._showTilePreview));
    t('Meta.MaximizeFlags', () => Object.keys(Meta.MaximizeFlags).join(','));
    // showDesktop (4F swipe down) filters on window type; verify both the
    // method and the enum member it compares against really exist.
    t('Meta.Window.get_window_type', () => String(typeof Meta.Window.prototype.get_window_type));
    t('Meta.WindowType.NORMAL', () => String(Meta.WindowType.NORMAL));

    // ---- 3F pinch out / 4F pinch out: screenshots -----------------------
    t('Main.screenshotUI present', () => String(!!Main.screenshotUI));
    t('Main.screenshotUI.open', () => String(typeof Main.screenshotUI?.open));
    t('Gio._promisify stage_to_content', () => {
        Gio._promisify(Shell.Screenshot.prototype, 'screenshot_stage_to_content');
        return 'ok';
    });
    t('composite_to_stream is static fn', () =>
        String(typeof Shell.Screenshot.composite_to_stream));
    t('St.Clipboard.get_default', () =>
        String(typeof St.Clipboard.get_default() === 'object'));

    console.log('SELFTEST ===== end =====');
}
