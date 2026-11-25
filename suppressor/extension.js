/* Nyx native-swipe suppressor - disables BOTH GNOME native swipe trackers so
 * they cannot conflict with the nyx-gestures daemon backend. Handles no gestures
 * itself and injects no keys. Restores both trackers on disable.
 *
 * GNOME 50 has exactly two SwipeTrackers:
 *  - Main.wm._workspaceAnimation._swipeTracker : HORIZONTAL (3F/4F workspace switch)
 *  - Main.overview._swipeTracker              : VERTICAL   (3F/4F overview / workspace preview)
 * Both must be disabled: 3F horizontal hit the first (workspace switch instead of
 * tile), and 4F up hit the second (workspace preview alongside fullscreen).
 * The shell re-enables them, so notify::enabled hooks keep them off.
 */
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

export default class NyxNativeSuppress {
    enable() {
        if (this._trackers && this._trackers.length) return;
        this._trackers = [];
        const cands = [];
        try { const t = Main.wm?._workspaceAnimation?._swipeTracker; if (t) cands.push(t); } catch (e) {}
        try { const t = Main.overview?._swipeTracker; if (t) cands.push(t); } catch (e) {}
        for (const t of cands) {
            try {
                if (!('enabled' in t)) continue;
                const was = t.enabled;
                t.enabled = false;
                const id = t.connect('notify::enabled', o => { if (o.enabled) o.enabled = false; });
                this._trackers.push({t, was, id});
            } catch (e) { console.warn('[nyx-suppress] ' + e.message); }
        }
        console.log('[nyx-suppress] disabled ' + this._trackers.length + ' native swipe trackers');
    }
    disable() {
        for (const s of this._trackers ?? []) {
            try { s.t.disconnect(s.id); s.t.enabled = s.was; } catch (e) {}
        }
        this._trackers = [];
        console.log('[nyx-suppress] restored native swipe trackers');
    }
}
