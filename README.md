# nyx-gestures

Touchpad gestures for GNOME Wayland — multi-finger swipes and pinches that tile windows, switch workspaces, toggle fullscreen, show the desktop, and take screenshots.

## Architecture (important)

Two backends exist, but only one is recommended:

### Recommended: daemon + suppressor (what actually works)

- **`libinput-gestures` + `nyx-keyd` (daemon)** — reads the touchpad directly via libinput and injects the *real GNOME key chords* through a libei `RemoteDesktop` session. Works on any GNOME/Wayland version, no shell internals patched. This performs all the gesture actions.
- **`nyx-native-suppress` (extension)** — a tiny GNOME Shell extension that disables **only** GNOME's own native swipe trackers so they don't fire alongside the daemon. It handles no gestures and injects no keys. Without it, GNOME's native 3-finger workspace swipe fires at the same time as the daemon's tile, and 4-finger-up shows a workspace preview alongside fullscreen.

Why both: GNOME's native `SwipeTracker` and libinput-gestures both see the same physical gesture. The suppressor removes the native half; the daemon provides the action.

### Alternative: extension-only backend (`extension/`)

A pure-GJS handler using `get_gesture_motion_delta` (GNOME 45+ only). Kept for reference/testing. It requires the compositor to expose `Clutter.Event.get_gesture_motion_delta` (probed live, not guessed from version strings). Not the recommended path on this machine.

## Gesture map (daemon)

| Gesture | Action | Key chord |
|---|---|---|
| 3-finger swipe left / right | tile window to left / right **half** (resize) | `super+Left` / `super+Right` |
| 3-finger swipe up | app switcher | `super+Tab` |
| 3-finger swipe down | begin interactive resize (arrow keys, Esc) | `alt+F8` |
| 4-finger swipe left / right | switch workspace | `super+alt+Right` / `super+alt+Left` |
| 4-finger swipe up | toggle fullscreen | `alt+F9` |
| 4-finger swipe down | show desktop | `alt+F12` |
| 3-finger pinch out | screenshot (file + clipboard) | `nyshot full` |
| 3-finger pinch in | close window | `alt+F4` |
| 4-finger pinch out | screenshot picker | `nyshot gui` |
| 4-finger pinch in | show desktop | `alt+F12` |

## Install

See [`install.sh --help`](install.sh). `./install.sh` installs both parts (daemon + suppressor); `--backend=daemon` is the same, and `--backend=ext` is a deprecated alias with a warning.

One command installs both parts:

```bash
./install.sh            # installs daemon + suppressor (needs root for /usr/local)
```

Then **log out and back in once** so GNOME loads the suppressor (GJS caches extension modules per session; an enabled extension's code cannot be swapped live). `--backend=ext` is a deprecated alias for the same working combo — the old extension-only handler is experimental and is not installed by default.

Diagnose: `./install.sh --doctor` (read-only), `./lib/nyx-preflight.sh`, `./lib/nyx-preflight.sh --json`.

## Notes on fixes applied on the author's machine (2026-11-23)

- 3-finger horizontal originally used `super+shift+Left/Right` (`move-to-side-*`, which only *moves* a window). Changed to `super+Left/Right` (`toggle-tiled-*`, which actually **resizes** to half).
- The suppressor disables both native trackers: `Main.wm._workspaceAnimation._swipeTracker` (horizontal) and `Main.overview._swipeTracker` (vertical). Missing either causes double-actions (workspace switch with tile; workspace preview with fullscreen).
- Injector latency reduced (`nyx-keyd.py` sleeps 30ms→12ms, throttle 80ms→30ms).
- If GNOME logs `Disable GNOME Shell extensions after failure`, it sets `UserExtensionsEnabled=false` and silently disables *all* extensions. Re-enable with:
  `gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell --method org.freedesktop.DBus.Properties.Set org.gnome.Shell.Extensions UserExtensionsEnabled '<true>'`
- `B`: 4-finger-down show-desktop crashed once under heavy system swap (OOM, shell killed with signal 6). No code fix; keep system memory free.

## Tests (working tree only, not shipped)

`node dev/decisiontest.js libinput-gestures.conf` · `./testrig.sh` (isolated headless shell) · `./lib/nyx-preflight.sh`

## License

MIT — see [LICENSE](LICENSE).
