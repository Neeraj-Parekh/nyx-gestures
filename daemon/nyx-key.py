#!/usr/bin/env python3
"""nyx-key - inject a key chord into the focused window.

Backend is chosen from the session type:

    X11          -> xdotool (native, no portal, no daemon)
    Wayland      -> libei over the XDG RemoteDesktop portal, via the nyx-keyd
                    daemon if it is running, else an inline session.

Why not ydotool on Wayland: mutter drops /dev/uinput key events, so ydotool
types plain characters but never delivers modifier chords or F-keys. libei is
the only supported injection route under Wayland.

Usage: nyx-key super+alt+Left
Env:   NYX_INJECT_BACKEND=xdotool|libei   force a backend
"""
import os
import socket
import sys

SOCK = os.path.expanduser("~/.cache/nyx-gestures/key.sock")
TOKEN_FILE = os.path.expanduser("~/.cache/nyx-gestures/libei.token")

ALIASES = {
    "super": "KEY_LEFTMETA", "meta": "KEY_LEFTMETA", "win": "KEY_LEFTMETA",
    "cmd": "KEY_LEFTMETA", "alt": "KEY_LEFTALT", "ctrl": "KEY_LEFTCTRL",
    "shift": "KEY_LEFTSHIFT", "tab": "KEY_TAB", "esc": "KEY_ESC",
    "escape": "KEY_ESC", "enter": "KEY_ENTER", "return": "KEY_ENTER",
    "space": "KEY_SPACE", "backspace": "KEY_BACKSPACE",
    "delete": "KEY_DELETE", "del": "KEY_DELETE", "insert": "KEY_INSERT",
    "home": "KEY_HOME", "end": "KEY_END", "pageup": "KEY_PAGEUP",
    "pagedown": "KEY_PAGEDOWN", "pgup": "KEY_PAGEUP", "pgdn": "KEY_PAGEDOWN",
    "up": "KEY_UP", "down": "KEY_DOWN", "left": "KEY_LEFT",
    "right": "KEY_RIGHT", "printscreen": "KEY_SYSRQ", "sysrq": "KEY_SYSRQ",
    "print": "KEY_SYSRQ", "menu": "KEY_COMPOSE", "pause": "KEY_PAUSE",
    "kp_add": "KEY_KPPLUS", "kp_plus": "KEY_KPPLUS", "kpadd": "KEY_KPPLUS",
    "kp_subtract": "KEY_KPMINUS", "kpsubtract": "KEY_KPMINUS",
    "kp_divide": "KEY_KPSLASH", "kp_multiply": "KEY_KPASTERISK",
    "scrolllock": "KEY_SCROLLLOCK",
}


def session_backend():
    forced = os.environ.get("NYX_INJECT_BACKEND", "").strip().lower()
    if forced in ("xdotool", "libei"):
        return forced
    stype = os.environ.get("XDG_SESSION_TYPE", "").strip().lower()
    if stype == "x11":
        return "xdotool"
    if os.environ.get("WAYLAND_DISPLAY") or stype == "wayland":
        return "libei"
    # No session hint: libei still works under XWayland via the portal.
    return "libei"


def send_via_daemon(chord):
    """True only if the daemon confirmed the send. False => try the fallback."""
    if not os.path.exists(SOCK):
        return False
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(10)
        s.connect(SOCK)
        s.sendall(chord.encode())
        try:
            s.shutdown(socket.SHUT_WR)
        except OSError:
            pass
        reply = b""
        while len(reply) < 4:
            chunk = s.recv(4 - len(reply))
            if not chunk:
                break
            reply += chunk
        s.close()
        return reply == b"OK"
    except OSError:
        return False


def via_xdotool(chord):
    import subprocess
    return subprocess.call(["xdotool", "key", "--clearmodifiers", chord]) == 0


def code_for(name):
    from evdev import ecodes
    n = name.strip().lower().replace("-", "_").replace(" ", "_")
    if not n:
        return None
    const = ALIASES.get(n) or (n if n.startswith("KEY_") else "KEY_" + n.upper())
    v = getattr(ecodes, const, None)
    if isinstance(v, int):
        return v
    return int(n) if n.isdigit() else None


def via_libei_inline(chord):
    """No daemon: negotiate a portal session just for this chord."""
    import time
    import libei.ei as ei
    from libei.portal import RemoteDesktopSession, PersistMode, DeviceType

    token = None
    try:
        with open(TOKEN_FILE) as f:
            token = f.read().strip() or None
    except OSError:
        pass

    session = RemoteDesktopSession.negotiate(
        devices=DeviceType.KEYBOARD,
        persist_mode=PersistMode.UNTIL_REVOKED,
        restore_token=token,
        timeout=30.0,
    )
    new_token = getattr(session, "restore_token", None)
    if new_token and new_token != token:
        os.makedirs(os.path.dirname(TOKEN_FILE), exist_ok=True)
        with open(TOKEN_FILE, "w") as f:
            f.write(new_token)
        os.chmod(TOKEN_FILE, 0o600)

    ctx = ei.Context(ei.Sender.create_for_fd(session.eis_fd))
    device = None
    deadline = time.time() + 12
    while device is None and time.time() < deadline:
        ctx.dispatch()
        for ev in ctx.events:
            if ev.event_type is ei.EventType.SEAT_ADDED:
                ev.seat.bind((ei.DeviceCapability.KEYBOARD,))
            elif ev.event_type is ei.EventType.DEVICE_RESUMED:
                if "KEYBOARD" in {c.name for c in ev.device.capabilities}:
                    device = ev.device
                    break
        if device is None:
            time.sleep(0.05)
    if device is None:
        print("nyx-key: no keyboard device from portal", file=sys.stderr)
        return 1

    codes = [code_for(p) for p in chord.split("+") if p.strip()]
    if not codes or any(c is None for c in codes):
        return 2

    device.start_emulating()
    for _ in range(12):          # let the sender flush start_emulating
        ctx.dispatch()
        time.sleep(0.008)
    for c in codes[:-1]:
        device.keyboard_key(c, True).frame()
    last = codes[-1]
    device.keyboard_key(last, True).frame()
    time.sleep(0.03)
    device.keyboard_key(last, False).frame()
    for c in reversed(codes[:-1]):
        device.keyboard_key(c, False).frame()
    for _ in range(6):
        ctx.dispatch()
    device.stop_emulating()
    return 0


def main():
    if len(sys.argv) < 2:
        print("usage: nyx-key super+alt+Left", file=sys.stderr)
        return 2
    chord = sys.argv[1].strip()
    if not chord:
        return 2

    backend = session_backend()

    if backend == "xdotool":
        return 0 if via_xdotool(chord) else 1

    if send_via_daemon(chord):
        return 0
    # Daemon missing or refused: fall back inline, then to xdotool on X11.
    try:
        if via_libei_inline(chord) == 0:
            return 0
    except Exception as e:
        print(f"nyx-key: libei inline failed: {e}", file=sys.stderr)
    if os.environ.get("XDG_SESSION_TYPE", "").lower() == "x11":
        return 0 if via_xdotool(chord) else 1
    return 1


if __name__ == "__main__":
    sys.exit(main())