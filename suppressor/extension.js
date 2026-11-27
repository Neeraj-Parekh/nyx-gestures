/* Nyx native-swipe suppressor + workspace-move keybindings.
 *
 * Companion to the nyx-gestures DAEMON backend (libinput-gestures + nyx-keyd).
 * Two responsibilities, both fully reversible:
 *
 * 1. Disable GNOME's native swipe trackers so they cannot double-fire with the
 *    daemon (3F horizontal used to switch workspace AND tile).
 * 2. Own the super+shift+Up/Down workspace-move keybindings so they ship with
 *    the extension and replicate on any device, instead of depending on a
 *    separate setup script having been run.
 *
 * Keybinding direction (user mapping):
 *   super+shift+Down = ahead/next workspace  -> move-to-workspace-right
 *   super+shift+Up   = back/previous         -> move-to-workspace-left
 *
 * GNOME 50 note: use the HORIZONTAL actions (left/right), NOT up/down.
 * windowManager.js:_showWorkspaceSwitcher rejects vertical UP/DOWN moves when
 * dynamic workspaces use a horizontal (columns) layout (layout_rows === -1),
 * which silently dropped the chord even though `switch` with it worked.
 * Right = higher-index/ahead; Left = lower-index/back (verified live).
 */
import Gio from 'gi://Gio';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const WM_SCHEMA = 'org.gnome.desktop.wm.keybindings';
const BINDINGS = {
    // Include the legacy alt chords so enabling this extension never erases
    // bindings the setup script (or the user) assigned to the same key.
    'move-to-workspace-left':  ['<Super><Shift>Up', '<Alt><Shift>F7'],  // back/previous
    'move-to-workspace-right': ['<Super><Shift>Down', '<Alt>F11'],      // ahead/next
    // Clear the vertical variants and the old top/bottom-half snap chords so
    // none of them intercept super+shift+Up/Down (single owner per chord).
    'move-to-workspace-up':    [],
    'move-to-workspace-down':  [],
    'move-to-side-n':          [],
    'move-to-side-s':          [],
};

export default class NyxNativeSuppress {
    enable() {
        if (this._trackers && this._trackers.length) return;  // [] is truthy - check .length

        // --- native swipe trackers ---
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
            } catch (e) { console.warn('[nyx-suppress] tracker: ' + e.message); }
        }

        // --- workspace-move keybindings ---
        this._savedBindings = [];
        try {
            const settings = new Gio.Settings({schema_id: WM_SCHEMA});
            this._wmSettings = settings;
            for (const [key, value] of Object.entries(BINDINGS)) {
                const was = settings.get_strv(key);
                this._savedBindings.push({key, was});
                settings.set_strv(key, value);
            }
        } catch (e) { console.warn('[nyx-suppress] keybindings: ' + e.message); }

        console.log(`[nyx-suppress] disabled ${this._trackers.length} native swipe trackers; `
            + `set ${this._savedBindings.length} workspace keybindings`);
    }

    disable() {
        for (const s of this._trackers ?? []) {
            try { s.t.disconnect(s.id); s.t.enabled = s.was; } catch (e) {}
        }
        this._trackers = [];
        if (this._wmSettings) {
            for (const b of this._savedBindings ?? []) {
                try { this._wmSettings.set_strv(b.key, b.was); } catch (e) {}
            }
        }
        this._savedBindings = [];
        this._wmSettings = null;
        console.log('[nyx-suppress] restored native swipe trackers and keybindings');
    }
}
