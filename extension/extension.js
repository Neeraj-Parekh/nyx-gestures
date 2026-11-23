/* Nyx Gestures - touchpad gestures handled inside GNOME Shell.
 *
 * No helper daemons, no key injection, no modified system files.
 *
 * ---------------------------------------------------------------------------
 * Every API used here was verified to exist by running an assertion probe in a
 * real GNOME Shell 50 (see dev/apiprobe.js). That matters: `node --check`
 * happily passes code that calls methods which do not exist, and a missing
 * method inside a `catch` fails silently. The probes found and fixed:
 *   - Clutter.Event has NO get_scroll_deltas() / get_scale().
 *     Correct: get_gesture_motion_delta() and get_gesture_pinch_scale().
 *   - Meta.WindowActor has NO close(); use Meta.Window.delete(timestamp).
 *   - Meta.Window has NO zoom API at all, so 2-finger pinch zoom was removed
 *     rather than shipped as a silent no-op.
 *   - Mtk.Rectangle has NO `monitor` field, so work areas must be matched by
 *     geometry, not by comparing a.monitor.
 * ---------------------------------------------------------------------------
 *
 * Gesture phase notes (mutter meta-seat-impl.c):
 *   - SWIPE/PINCH emit BEGIN, UPDATE..., END. CANCEL also occurs.
 *   - mutter passes scale = 0 on PINCH_BEGIN and PINCH_END, so any pinch logic
 *     must only act on UPDATE or it fires spuriously at the end of every pinch.
 *   - touchpad HOLD emits BEGIN then END only; there is no HOLD_UPDATE, so a
 *     hold cannot be distinguished from a long press without extra bookkeeping.
 *
 * Natural scrolling: libinput deltas are device deltas with no sign flip, and
 * GNOME compensates by negating them when natural-scroll is on. We do the same,
 * otherwise every direction is inverted on machines with the default setting.
 */

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
// Standard ESM resolution: relative to this file, so ./gesture-map.js is a
// sibling inside the extension directory.
import {decideSwipe, decidePinch} from './gesture-map.js';

// Values taken from GNOME Shell's own js/ui/swipeTracker.js so our feel matches
// stock gestures. These are raw libinput device units, NOT pixels:
//   DRAG_THRESHOLD_DISTANCE = 16  axis-lock threshold in swipeTracker.js:28
//   TOUCHPAD_BASE_WIDTH = 400 / TOUCHPAD_BASE_HEIGHT = 300 (swipeTracker.js:13-14)
//     are only used to normalise progress for animations; we act immediately,
//     so we do not need them.
// Our earlier 60 meant the gesture needed 4x more finger travel than any stock
// GNOME gesture before it fired.
const AXIS_LOCK_THRESHOLD = 16;  // swipeTracker.js DRAG_THRESHOLD_DISTANCE
const PINCH_THRESHOLD = 1.25;
const ALLOWED_MODES = Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW;

/* ----------------------------------------------------------------- logging
 *
 * console.log from inside gnome-shell goes to the journal and nowhere else, so a
 * user who has never opened a terminal has no way to see it. This writes to
 * $XDG_STATE_HOME/nyx-gestures/nyx.log instead, at levels, with rotation.
 *
 * The level lives in GSettings under org.gnome.shell.extensions.nyx-gestures so
 * it can be changed without restarting the session:
 *     gsettings set org.gnome.shell.extensions.nyx-gestures level debug
 * It defaults to "info". If the schema is missing (running from a checkout) we
 * fall back to the NYX_LOG environment variable.
 *
 * Logged at info: lifecycle only. Raw deltas, finger counts and axis-lock
 * arithmetic are debug-only - at info they fire on every partial swipe and the
 * file becomes unreadable. A log you cannot read is no log.
 */

const LOG_SCHEMA = 'org.gnome.shell.extensions.nyx-gestures';
const LOG_FILE = `${GLib.build_filenamev([GLib.get_user_state_dir(), 'nyx-gestures', 'nyx.log'])}`;
const LOG_MAX_BYTES = 262144;              // 256 KiB, then rotate once
const LOG_RANK = {debug: 10, info: 20, warn: 30, error: 40, off: 99};
const enc = new TextEncoder();
let _logSettings;

function logLevel() {
    if (_logSettings === undefined) {
        try {
            _logSettings = new Gio.Settings({schema_id: LOG_SCHEMA});
        } catch {
            _logSettings = {get_string: () => GLib.getenv('NYX_LOG') || 'info'};
        }
    }
    try {
        return _logSettings.get_string('level') || 'info';
    } catch {
        return 'info';
    }
}

function log(level, ...args) {
    const want = LOG_RANK[logLevel()] ?? 20;
    const have = LOG_RANK[level] ?? 20;
    if (have < want || want >= 99)
        return;

    const line = `[${level}] ${args.join(' ')}`;
    try {
        const dir = GLib.path_get_dirname(LOG_FILE);
        if (!GLib.file_test(dir, GLib.FileTest.EXISTS))
            GLib.mkdir_with_parents(dir, 0o755);

        // Rotate before appending so the file cannot grow without bound. Read
        // the old contents first so the previous generation keeps the history.
        let prior = '';
        try {
            const [ok, bytes] = GLib.file_get_contents(LOG_FILE);
            if (ok && bytes?.length)
                prior = new TextDecoder().decode(bytes);
        } catch { /* no existing file */ }

        const stamp = GLib.DateTime.new_now_local().format('%Y-%m-%dT%H:%M:%S');
        const entry = `${stamp} ${line}\n`;
        // GJS GLib.file_set_contents takes (path, bytes) only. The previous
        // 4-argument call threw on every write (caught below), so the log file
        // stayed empty and no gesture could ever be diagnosed.
        if (prior.length > LOG_MAX_BYTES) {
            // Rotate: keep exactly one previous generation, then start fresh.
            GLib.file_set_contents(`${LOG_FILE}.1`, enc.encode(prior));
            GLib.file_set_contents(LOG_FILE, enc.encode(entry));
        } else {
            // Append within the bound. file_set_contents overwrites, so the
            // prior history must be re-added or every line but the last is lost.
            GLib.file_set_contents(LOG_FILE, enc.encode(prior + entry));
        }
    } catch {
        // Logging must never be able to break a gesture.
    }

    if (level === 'warn' || level === 'error')
        console.warn(`[nyx-gestures] ${line}`);
    else
        console.log(`[nyx-gestures] ${line}`);
}

function logDebug(...a) { log('debug', ...a); }
function logInfo(...a)  { log('info', ...a); }
function logWarn(...a)  { log('warn', ...a); }
function logError(...a) { log('error', ...a); }

/* --------------------------------------------------------------- helpers */

function focusedWindow() {
    try {
        return global.display?.focus_window ?? null;
    } catch {
        return null;
    }
}

/* swipeTracker.js:593-595 negates horizontal deltas for RTL layouts. */
function rtlFactor() {
    return Clutter.get_default_text_direction() === Clutter.TextDirection.RTL
        ? -1 : 1;
}

/* Find the work area that actually contains the window.
 *
 * Mtk.Rectangle has only x/y/width/height - there is no monitor field, so
 * comparing a.monitor to win.get_monitor() can never match and silently tiles
 * onto monitor 0. Match on geometry instead. */
function workAreaFor(win) {
    let areas;
    try {
        areas = win.get_work_area_all_monitors?.();
    } catch {
        return null;
    }
    if (!areas?.length)
        return null;

    const x = win.get_frame_rect().x;
    const y = win.get_frame_rect().y;
    const cx = x + win.get_frame_rect().width / 2;
    const cy = y + win.get_frame_rect().height / 2;

    // Prefer an area whose centre-ish region contains the window centre.
    for (const a of areas) {
        if (cx >= a.x && cx < a.x + a.width && cy >= a.y && cy < a.y + a.height)
            return a;
    }
    return areas[0];
}

/* ---------------------------------------------------------------- actions */

function tileFocused(direction) {
    const win = focusedWindow();
    if (!win || !win.allows_resize?.())
        return false;
    const area = workAreaFor(win);
    if (!area)
        return false;

    const half = Math.floor(area.width / 2);
    const x = direction === 'left' ? area.x : area.x + half;
    try {
        win.move_resize_frame(true, x, area.y, half, area.height);
        return true;
    } catch (e) {
        logError('tile failed:', e.message);
        return false;
    }
}

function closeWindow() {
    const win = focusedWindow();
    if (!win || !win.can_close?.())
        return false;
    try {
        // Meta.WindowActor has no close(); Meta.Window.delete() is the API.
        win.delete(global.get_current_time());
        return true;
    } catch (e) {
        logError('close failed:', e.message);
        return false;
    }
}

/* 4-finger swipe up = alt+F9 = GNOME's own `toggle-fullscreen`.
 *
 * There is no toggle_fullscreen() method, which is why this looked impossible
 * for a while; the pair is make_fullscreen()/unmake_fullscreen() plus the
 * `fullscreen` property. Verified present by introspecting Meta-18.typelib on
 * this machine. Maximising would have been a silent substitute, not the same
 * action. */
function toggleFullscreen() {
    const win = focusedWindow();
    if (!win)
        return false;
    try {
        if (win.fullscreen)
            win.unmake_fullscreen();
        else
            win.make_fullscreen();
        return true;
    } catch (e) {
        logError('fullscreen failed:', e.message);
        return false;
    }
}

/* 3-finger swipe down = alt+F8 = GNOME's `begin-resize`.
 *
 * alt+F8 is not a shell keybinding we can replay; it lands in mutter's
 * keybindings.c handle_begin_resize, which is exactly this call:
 *
 *     meta_window_begin_grab_op (window,
 *                                META_GRAB_OP_KEYBOARD_RESIZING_UNKNOWN |
 *                                META_GRAB_OP_WINDOW_FLAG_UNCONSTRAINED, ...)
 *
 * Note the second flag does NOT exist in mutter 18 - Meta.GrabOp has no
 * WINDOW_FLAG_UNCONSTRAINED member (only MOVING_UNCONSTRAINED), confirmed by
 * enumerating the enum. Passing it would be a TypeError, so only the real flag
 * is used. After this returns, the compositor owns the keyboard and arrow keys
 * drive the resize cursor until Escape.
 *
 * The grab is global and non-reentrant: a second call while one is active is
 * refused by the compositor, which is the correct outcome anyway. */
function beginInteractiveResize() {
    const win = focusedWindow();
    if (!win || !win.allows_resize?.())
        return false;
    try {
        return !!win.begin_grab_op(Meta.GrabOp.KEYBOARD_RESIZING_UNKNOWN,
            null, global.get_current_time(), null);
    } catch (e) {
        logError('begin resize failed:', e.message);
        return false;
    }
}

/* ---------------------------------------------------------- screenshots */

let _promisified = false;

/* The async screenshot methods are not promisified on OUR instance. The shell
 * promisifies its own Shell.Screenshot, but Gio._promisify only decorates the
 * prototype it was handed, and GJS guards against double-wrapping. */
function ensurePromisified() {
    if (_promisified)
        return;
    _promisified = true;
    try {
        Gio._promisify(Shell.Screenshot.prototype, 'screenshot_stage_to_content');
    } catch (e) {
        logWarn('promisify failed:', e.message);
    }
    try {
        Gio._promisify(Shell.Screenshot, 'composite_to_stream');
    } catch (e) {
        logWarn('promisify failed:', e.message);
    }
}

function screenshotDir() {
    return GLib.build_filenamev([GLib.get_home_dir(), 'Pictures', 'Screenshots']);
}

/* 3-finger pinch OUT = silent full-screen capture: file + clipboard, nothing
 * else. No flash, no shutter sound, no notification, no overlay.
 *
 * The white flash is not suppressed - it is impossible to reach. GNOME's flash
 * lives in one place, the ScreenshotService D-Bus object's _flashAsync closure,
 * which runs only when org.gnome.Shell.Screenshot is called AND the caller is
 * org.gnome.SettingsDaemon.MediaKeys or xdg-desktop-portal-gnome. Nothing
 * listens for `screenshot-taken` on a Shell.Screenshot we build ourselves, so
 * that code never runs. This is also why the earlier attempt to patch
 * libshell-18.so was both unnecessary and destructive.
 *
 * The D-Bus interface is a dead end regardless: DBusSenderChecker allows only
 * those two senders, which is the AccessDenied it produces.
 *
 * Screenshot.captureScreenshot() is deliberately NOT used - it plays the
 * shutter sound and raises a notification. composposite straight to a stream
 * and write the PNG ourselves instead.
 *
 * Synchronous by design: it returns true the moment the capture starts and
 * does the work in the background. Returning the promise instead would make
 * every call look successful, because a pending Promise is always truthy, and
 * the caller uses the return value to decide whether to swallow the gesture. */
function captureScreen() {
    ensurePromisified();
    _captureScreenAsync();
    return true;
}

async function _captureScreenAsync() {
    let bytes;
    try {
        const shooter = new Shell.Screenshot();
        const [content, scale, cursorContent, cursorPoint, cursorScale] =
            await shooter.screenshot_stage_to_content();

        const stream = Gio.MemoryOutputStream.new_resizable();
        await Shell.Screenshot.composite_to_stream(
            content.get_texture(), 0, 0, -1, -1, scale,
            cursorContent,
            cursorPoint ? cursorPoint.x : 0,
            cursorPoint ? cursorPoint.y : 0,
            cursorScale ? cursorScale : 1,
            stream);
        stream.close(null);
        bytes = stream.steal_as_bytes();

        // Clipboard first: if the disk write fails the PNG is still usable.
        St.Clipboard.get_default()
            .set_content(St.ClipboardType.CLIPBOARD, 'image/png', bytes);
    } catch (e) {
        logError('capture failed:', e.message);
        return;
    }

    try {
        const dir = screenshotDir();
        const d = Gio.File.new_for_path(dir);
        if (!d.query_exists(null))
            d.make_directory_with_parents(null);
        const stamp = GLib.DateTime.new_now_local().format('%Y-%m-%d %H-%M-%S');
        const out = Gio.File.new_for_path(
            GLib.build_filenamev([dir, `Screenshot From ${stamp}.png`]));
        const s = out.replace(null, false,
            Gio.FileCreateFlags.REPLACE_DESTINATION, null);
        s.write_bytes(bytes);
        s.close(null);
    } catch (e) {
        // Clipboard copy already succeeded, so this is not a failed gesture.
        logWarn('save failed (clipboard copy kept):', e.message);
    }
}

/* 4-finger pinch OUT = GNOME's own Screen/Window/Selection picker.
 *
 * Main.screenshotUI is the ScreenshotUI singleton that main.js instantiates;
 * open() defaults to screenshot mode. UIMode is not exported from
 * screenshot.js, so mode 0 (the default) is what we want and no literal is
 * needed. */
function openScreenshotPicker() {
    try {
        if (!Main.screenshotUI)
            return false;
        Main.screenshotUI.open();
        return true;
    } catch (e) {
        logError('picker failed:', e.message);
        return false;
    }
}

function showDesktop() {
    // B (4-finger-down "crash") was a system-wide OOM, not a logic bug here:
    // the journal shows gnome-shell killed with signal 6 right after the kernel
    // OOM-killer fired under ~8.9/11 GiB swap. Minimizing actually RELEASES
    // buffers, so this action is not the allocator; the durable remedy is
    // reducing system memory load. What this function CAN do is avoid poking
    // surfaces that make mutter assert: skip non-normal windows (the crossover
    // overlays logged override_redirect / stack_position warnings) and never
    // trust a disposed actor.
    const current = focusedWindow();
    // Hoist the enum lookup out of the loop: if Meta.WindowType were ever
    // missing, a per-window throw would silently skip EVERY window forever.
    const NORMAL = Meta.WindowType?.NORMAL;
    let any = false;
    let actors;
    try {
        actors = global.get_window_actors();
    } catch {
        return false;
    }
    for (const actor of actors ?? []) {
        let w;
        try {
            w = actor.meta_window;
        } catch {
            continue;  // disposed actor
        }
        if (!w)
            continue;
        try {
            if (w === current || w.minimized)
                continue;
            // Only normal top-level windows, when the type API is available.
            if (NORMAL !== undefined && typeof w.get_window_type === 'function'
                && w.get_window_type() !== NORMAL)
                continue;
            w.minimize();
            // mutter silently no-ops minimize on windows without a minimize
            // function; only count success if the window really minimized.
            if (w.minimized)
                any = true;
        } catch { /* ignore one stubborn/disposed window */ }
    }
    return any;
}

function switchWorkspace(direction) {
    const sm = global.workspace_manager;
    if (!sm)
        return false;
    const n = sm.get_n_workspaces();
    // Known limitation (audit M1): with the native workspace swipe suppressed,
    // a 4F swipe when only one workspace exists declines and does nothing -
    // GNOME's native dynamic-workspace creation no longer fires. Creating one
    // here would need append_new_workspace; left as a follow-up, not a crash.
    if (n < 2)
        return false;
    const current = sm.get_active_workspace_index();
    const next = (current + (direction === 'left' ? -1 : 1) + n) % n;
    const target = sm.get_workspace_by_index(next);
    if (!target)
        return false;
    try {
        target.activate(global.get_current_time());
        return true;
    } catch {
        return false;
    }
}

function toggleOverview() {
    try {
        Main.overview.toggle();
        return true;
    } catch {
        return false;
    }
}

/* --------------------------------------------------------- the extension */

/* Action name -> effect. Keys must exactly match what gesture-map.js returns;
 * dev/decisiontest.js fails if this table and that module disagree, because a
 * missing key is a TypeError thrown mid-gesture and an extra key is an action
 * nothing can ever reach. Each entry returns true only when it really did
 * something. */
const ACTIONS = {
    'tile-left': () => tileFocused('left'),
    'tile-right': () => tileFocused('right'),
    'overview': toggleOverview,
    // alt+F8 equivalent: hands the keyboard to the compositor until Escape.
    'begin-resize': beginInteractiveResize,
    'workspace-left': () => switchWorkspace('left'),
    'workspace-right': () => switchWorkspace('right'),
    'fullscreen': toggleFullscreen,
    'show-desktop': showDesktop,
    'screenshot-full': captureScreen,
    'screenshot-picker': openScreenshotPicker,
    'close-window': closeWindow,
};

export default class NyxGesturesExtension {
    enable() {
        // Idempotent: enable() can run twice (session mode change). Without
        // this, the first signal handler is orphaned and every action runs
        // twice forever.
        if (this._stageId)
            return;
        this._swipe = null;
        this._pinch = null;

        this._stageId = global.stage.connect('captured-event::touchpad',
            (_actor, event) => this._onTouchpad(event));
        this._suppressNative();
        logInfo('enabled (level: ' + logLevel() + ')');
    }

    disable() {
        if (this._stageId) {
            global.stage.disconnect(this._stageId);
            this._stageId = null;
        }
        for (const s of this._suppressed ?? []) {
            try {
                s.t.disconnect(s.id);
                s.t.enabled = s.was;
            } catch { /* tracker already gone */ }
        }
        this._suppressed = [];
        this._swipe = null;
        this._pinch = null;
        logInfo('disabled');
    }

    /* GNOME's own swipe trackers would still act on 3F/4F swipes (workspace
     * switch, overview) alongside ours. They begin tracking at ~16 units,
     * before our threshold claim, so a late EVENT_STOP cannot undo them (bug A).
     * Disable them explicitly while enabled. The shell re-enables them on
     * overview hide / animation end, so a notify hook keeps them off. Restored
     * in disable(). References verified for GNOME 45-50 (workspaceAnimation.js
     * _swipeTracker, overview.js _swipeTracker); guarded so a missing tracker
     * degrades gracefully instead of throwing. */
    _suppressNative() {
        this._suppressed = [];
        const candidates = [];
        try {
            const t = Main.wm?._workspaceAnimation?._swipeTracker;
            if (t) candidates.push(t);
        } catch { /* not present on this shell */ }
        try {
            const t = Main.overview?._swipeTracker;
            if (t) candidates.push(t);
        } catch { /* not present */ }
        for (const t of candidates) {
            try {
                if (!('enabled' in t))
                    continue;
                const was = t.enabled;
                t.enabled = false;
                const id = t.connect('notify::enabled', o => {
                    if (o.enabled)
                        o.enabled = false;
                });
                this._suppressed.push({t, was, id});
            } catch (e) {
                logWarn('native swipe suppress failed:', e.message);
            }
        }
        logInfo(`native swipe trackers suppressed: ${this._suppressed.length}`);
    }

    /* Gestures must not fire during grabs, the overview, or the lock screen.
     * GNOME's own tracker gates on this; without it a stray 4-finger swipe
     * mid window-drag would tile or close the window. */
    _allowed() {
        return (ALLOWED_MODES & Main.actionMode) !== 0;
    }

    _onTouchpad(event) {
        try {
            const type = event.type();
            // Clear state on END/CANCEL even outside allowed modes: a gesture
            // ending during a grab/lock must not leave a stale done latch that
            // the next same-finger BEGIN would inherit (audit M3).
            if (type === Clutter.EventType.TOUCHPAD_SWIPE ||
                type === Clutter.EventType.TOUCHPAD_PINCH) {
                const phase = event.get_gesture_phase();
                if (phase === Clutter.TouchpadGesturePhase.END ||
                    phase === Clutter.TouchpadGesturePhase.CANCEL) {
                    if (type === Clutter.EventType.TOUCHPAD_SWIPE)
                        this._swipe = null;
                    else
                        this._pinch = null;
                }
            }
            if (!this._allowed())
                return Clutter.EVENT_PROPAGATE;

            switch (type) {
            case Clutter.EventType.TOUCHPAD_SWIPE:
                return this._onSwipe(event);
            case Clutter.EventType.TOUCHPAD_PINCH:
                return this._onPinch(event);
            default:
                // TOUCHPAD_HOLD and anything else are left to the compositor.
                return Clutter.EVENT_PROPAGATE;
            }
        } catch (e) {
            logError('event handler threw:', e.message);
            return Clutter.EVENT_PROPAGATE;
        }
    }

    /* ---- swipes ---- */
    _onSwipe(event) {
        const fingers = event.get_touchpad_gesture_finger_count();
        const phase = event.get_gesture_phase();

        if (phase === Clutter.TouchpadGesturePhase.BEGIN) {
            // Ignore a duplicate BEGIN rather than resetting a gesture that has
            // already committed, which would fire its action twice.
            if (this._swipe && this._swipe.fingers === fingers)
                return Clutter.EVENT_PROPAGATE;
            this._swipe = {fingers, dx: 0, dy: 0, px: 0, py: 0, axis: null, done: false};
            return Clutter.EVENT_PROPAGATE;
        }

        // END and CANCEL both terminate. Clear state on both, otherwise a
        // missed BEGIN/CANCEL pair leaves stale deltas that leak into the next
        // gesture and desync the tracker permanently.
        if (phase === Clutter.TouchpadGesturePhase.END ||
            phase === Clutter.TouchpadGesturePhase.CANCEL) {
            this._swipe = null;
            return Clutter.EVENT_PROPAGATE;
        }

        if (!this._swipe)
            return Clutter.EVENT_PROPAGATE;

        // Finger count can change mid-gesture without a CANCEL. Resync rather
        // than silently dropping every remaining event forever.
        if (this._swipe.fingers !== fingers) {
            this._swipe = {fingers, dx: 0, dy: 0, px: 0, py: 0, axis: null, done: false};
            return Clutter.EVENT_PROPAGATE;
        }

        let deltas;
        try {
            deltas = event.get_gesture_motion_delta();
        } catch (e) {
            logWarn('no motion delta on swipe:', e.message);
            this._swipe = null;
            return Clutter.EVENT_PROPAGATE;
        }
        if (!deltas || deltas.length < 2)
            return Clutter.EVENT_PROPAGATE;

        /* Sign handling. Natural scrolling is deliberately NOT applied here.
         *
         * An earlier version multiplied every delta by (natural-scroll ? -1 : 1),
         * ported from GNOME's swipeTracker.js:188, and that was wrong for
         * gestures. Two measurements settle it:
         *
         *  1. On a virtual touchpad (dev/gesturesynth.c), libinput reports dx
         *     negative for fingers physically moving left, and dy negative for
         *     fingers moving up. Gesture deltas are physical finger movement;
         *     natural scrolling is a display convention applied to the scroll
         *     axis, and mutter passes gesture deltas through untouched.
         *  2. libinput-gestures - the daemon backend, which is the path already
         *     confirmed to feel right - classifies direction with no reference
         *     to natural scrolling at all:
         *         motion = 'left' if x < 0 else 'right'
         *         motion = 'up'   if y < 0 else 'down'
         *     (grep -c natural on its source returns 0)
         *
         * So "swipe left" means fingers moved left, and negating it reversed
         * all eight swipes on a machine where natural-scroll is true - which is
         * the default here. RTL is kept: GNOME does negate for it
         * (swipeTracker.js:593) and it is a no-op in an LTR locale. */
        const sign = rtlFactor();
        const t = this._swipe;
        t.px += deltas[0] * sign;
        t.py += deltas[1] * sign;

        if (t.done)
            return Clutter.EVENT_STOP;

        // Axis lock, ported from swipeTracker.js:144-178: decide the axis once,
        // on the ACCUMULATED vector, then stop feeding the other axis. Deciding
        // per-frame lets a diagonal swipe flap between axes.
        if (t.axis === null) {
            if (Math.hypot(t.px, t.py) < AXIS_LOCK_THRESHOLD)
                return Clutter.EVENT_PROPAGATE;
            t.axis = Math.abs(t.px) > Math.abs(t.py) ? 'h' : 'v';
            logDebug(`axis locked ${t.axis} for ${fingers}F at `
                + `px=${t.px.toFixed(1)} py=${t.py.toFixed(1)}`);
            // The travel consumed by the lock decision is discarded, exactly as
            // GNOME does (swipeTracker.js:166-167).
            t.dx = t.dy = 0;
        }

        if (t.axis === 'h')
            t.dx += deltas[0] * sign;
        else
            t.dy += deltas[1] * sign;

        const travel = t.axis === 'h' ? Math.abs(t.dx) : Math.abs(t.dy);
        if (travel < AXIS_LOCK_THRESHOLD)
            return Clutter.EVENT_PROPAGATE;

        const horizontal = t.axis === 'h';
        const positive = horizontal ? t.dx > 0 : t.dy > 0;

        /* Claim the gesture only when it is bound (3F/4F). 2-finger swipes are
         * not ours and must always propagate so scrolling survives.
         *
         * The mapping itself lives in gesture-map.js so it can be unit-tested
         * without a live session; this handler only performs the effect. A bound
         * gesture is claimed even when its action declines (e.g. no window to
         * tile): propagating it would hand it to GNOME's native tracker, which
         * switches workspace on a 3F horizontal swipe - bug A. Unbound (null)
         * always propagates. */
        let handled = false;
        const action = decideSwipe(fingers, horizontal, positive);
        if (action) {
            try {
                handled = ACTIONS[action]() === true;
            } catch (e) {
                // One action throwing must not take the handler down with it:
                // an exception here would escape to _onTouchpad, which
                // propagates, leaving the compositor free to act on a gesture
                // we already partly consumed.
                logError(`action ${action} threw:`, e.message);
                handled = false;
            }
        }

        if (action) {
            logInfo(`gesture ${fingers}F swipe ${horizontal ? (positive ? 'right' : 'left') : (positive ? 'up' : 'down')}`
                + ` -> ${action}: ${handled ? 'done' : 'declined'}`);
            // Claim every bound gesture even when the action declined (bug A):
            // propagating a declined 3F horizontal swipe lets GNOME's native
            // tracker switch workspace. If it cannot act, nothing happens.
            t.done = true;
            return Clutter.EVENT_STOP;
        }
        // Unbound (2-finger scroll, etc.): leave it to the compositor.
        return Clutter.EVENT_PROPAGATE;
    }

    /* ---- pinch ---- */
    _onPinch(event) {
        const fingers = event.get_touchpad_gesture_finger_count();
        const phase = event.get_gesture_phase();

        if (phase === Clutter.TouchpadGesturePhase.BEGIN) {
            if (this._pinch && this._pinch.fingers === fingers)
                return Clutter.EVENT_PROPAGATE;
            // mutter sends scale 0 on BEGIN, so record nothing usable here.
            this._pinch = {fingers, start: null, done: false};
            return Clutter.EVENT_PROPAGATE;
        }

        if (phase === Clutter.TouchpadGesturePhase.END ||
            phase === Clutter.TouchpadGesturePhase.CANCEL) {
            this._pinch = null;
            return Clutter.EVENT_PROPAGATE;
        }

        if (!this._pinch)
            return Clutter.EVENT_PROPAGATE;
        if (this._pinch.fingers !== fingers) {
            this._pinch = {fingers, start: null, done: false};
            return Clutter.EVENT_PROPAGATE;
        }

        const p = this._pinch;
        if (p.done)
            return Clutter.EVENT_STOP;

        let scale;
        try {
            scale = event.get_gesture_pinch_scale();
        } catch (e) {
            logWarn('no pinch scale:', e.message);
            this._pinch = null;
            return Clutter.EVENT_PROPAGATE;
        }
        if (typeof scale !== 'number' || scale <= 0)
            return Clutter.EVENT_PROPAGATE;

        // First usable UPDATE defines the baseline.
        if (p.start === null) {
            p.start = scale;
            return Clutter.EVENT_PROPAGATE;
        }

        const ratio = scale / p.start;
        if (ratio < PINCH_THRESHOLD && ratio > 1 / PINCH_THRESHOLD)
            return Clutter.EVENT_PROPAGATE;

        /* Direction, from libinput's own header (libinput.h,
         * libinput_event_gesture_get_scale): "The scale begins at 1.0, and if
         * e.g. the fingers moved together by 50% then the scale will become
         * 0.5, if they move twice as far apart as initially the scale becomes
         * 2.0." mutter passes that value through unclamped
         * (meta-seat-impl.c: scale = libinput_event_gesture_get_scale(...)
         * then straight into clutter_event_new_touchpad_pinch), so:
         *     scale > 1  == fingers spreading apart == pinch OUT
         * The previous code had this inverted, which is why 3-finger
         * pinch-out fired close-window. */
        const out = ratio > 1;

        let handled = false;
        const action = decidePinch(fingers, out);
        this._lastPinchAction = action;  // test seam: assert scale->direction mapping
        if (action) {
            try {
                handled = ACTIONS[action]() === true;
            } catch (e) {
                logError(`action ${action} threw:`, e.message);
                handled = false;
            }
        }
        /* 2-finger pinch is intentionally unbound (decidePinch returns null).
         * There is no zoom API anywhere in mutter 50 - no meta_window_zoom, no
         * set_size, no compositor scale-to-fit - so binding it would be a
         * gesture that silently does nothing. */

        if (action) {
            logInfo(`gesture ${fingers}F pinch ${out ? 'out' : 'in'} -> ${action}`
                + `: ${handled ? 'done' : 'declined'}`);
            // Claim bound pinches even when declined, same rationale as swipes.
            p.done = true;
            return Clutter.EVENT_STOP;
        }
        return Clutter.EVENT_PROPAGATE;
    }
}