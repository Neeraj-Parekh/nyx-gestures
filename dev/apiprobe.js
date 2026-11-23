import Clutter from 'gi://Clutter';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

export async function run() {
    const missing = [];
    const setOf = (proto) => {
        const s = new Set(); let o = proto;
        while (o && o !== Object.prototype) {
            for (const k of Object.getOwnPropertyNames(o)) s.add(k);
            o = Object.getPrototypeOf(o);
        }
        return s;
    };
    const want = {
        'Clutter.Event': ['get_touchpad_gesture_finger_count', 'get_gesture_phase',
                          'get_gesture_motion_delta', 'get_gesture_pinch_scale'],
        'Meta.Window': ['move_resize_frame', 'get_work_area_all_monitors',
                        'get_frame_rect', 'allows_resize', 'is_maximized',
                        'maximize', 'unmaximize', 'minimize', 'can_close', 'delete',
                        // 3F swipe down = begin-resize (what alt+F8 calls)
                        'begin_grab_op',
                        // 4F swipe up = fullscreen (alt+F9). There is NO
                        // toggle_fullscreen(); this pair plus the property is it.
                        'make_fullscreen', 'unmake_fullscreen',
                        // 4F swipe down = show-desktop filters normal windows
                        'get_window_type'],
        'Shell.Screenshot': ['screenshot_stage_to_content'],
    };
    const protos = {'Clutter.Event': Clutter.Event.prototype, 'Meta.Window': Meta.Window.prototype,
                    'Shell.Screenshot': Shell.Screenshot.prototype};
    for (const [cls, ms] of Object.entries(want))
        for (const m of ms)
            if (!setOf(protos[cls]).has(m)) missing.push(`${cls}.${m}`);
    // properties used directly
    // find_property lives on the CLASS, not the prototype.
    if (!Meta.Window.find_property?.('minimized'))
        missing.push('Meta.Window.minimized (property)');
    if (!Meta.Window.find_property?.('fullscreen'))
        missing.push('Meta.Window.fullscreen (property)');
    // static, not on the prototype
    if (typeof Shell.Screenshot?.composite_to_stream !== 'function')
        missing.push('Shell.Screenshot.composite_to_stream (static)');
    if (!Meta.GrabOp?.KEYBOARD_RESIZING_UNKNOWN)
        missing.push('Meta.GrabOp.KEYBOARD_RESIZING_UNKNOWN');
    // showDesktop skips non-normal windows; assert the enum member it compares.
    if (Meta.WindowType?.NORMAL === undefined)
        missing.push('Meta.WindowType.NORMAL');
    // Guard against the flag we were told to use: it is NOT in mutter 18 and
    // OR-ing it in would throw. Assert its absence stays true.
    if (Meta.GrabOp?.WINDOW_FLAG_UNCONSTRAINED)
        missing.push('WARN: Meta.GrabOp.WINDOW_FLAG_UNCONSTRAINED now exists - recheck resize call');
    // 4F pinch out = screenshot picker
    if (!Main.screenshotUI) missing.push('Main.screenshotUI');
    else if (typeof Main.screenshotUI.open !== 'function')
        missing.push('Main.screenshotUI.open');
    // Native swipe trackers we disable for bug A (guarded in enable()). Assert
    // they exist on this shell so the suppression is known to be effective.
    if (!Main.wm?._workspaceAnimation?._swipeTracker)
        missing.push('Main.wm._workspaceAnimation._swipeTracker');
    if (!Main.overview?._swipeTracker)
        missing.push('Main.overview._swipeTracker');
    if (typeof St.Clipboard.get_default !== 'function') missing.push('St.Clipboard.get_default');
    // Shell.Screenshot rejects concurrent ops; nothing to assert statically,
    // but confirm it can actually be constructed (i.e. is not abstract).
    try { new Shell.Screenshot(); } catch (e) { missing.push('new Shell.Screenshot(): ' + e.message); }
    try {
        const id = global.stage.connect('captured-event::touchpad', () => Clutter.EVENT_PROPAGATE);
        global.stage.disconnect(id);
    } catch { missing.push('signal captured-event::touchpad'); }
    if (typeof global.get_window_actors !== 'function') missing.push('global.get_window_actors');
    if (!global.workspace_manager) missing.push('global.workspace_manager');
    if (!Shell.ActionMode?.NORMAL) missing.push('Shell.ActionMode.NORMAL');
    if (!Meta.MaximizeFlags?.BOTH) missing.push('Meta.MaximizeFlags.BOTH');
    // Note: natural-scroll is deliberately NOT read any more. It was read to
    // negate gesture deltas, which measurements showed was wrong for gestures
    // (see the sign handling comment in _onSwipe). Asserting a setting we no
    // longer use would only give false confidence.
    console.log('FINAL_ASSERT ' + (missing.length ? `FAILED: ${missing.join(', ')}` : 'ALL APIs PRESENT'));
}
