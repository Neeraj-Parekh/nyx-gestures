#!/usr/bin/env python3
"""nyx-keyd - persistent key injector for GNOME/Wayland via libei.

Holding one RemoteDesktop portal session open removes the per-keystroke portal
handshake that cost ~0.5s. Listens on a unix socket; nyx-key sends chord
strings to it and expects an "OK"/"ERR" reply so it can fall back inline.

Critical implementation notes (learned the hard way):
  * start_emulating() is ASYNChronous, and this portal/mutter build NEVER emits
    DEVICE_START_EMULATING. Waiting for that event hangs forever. Start
    emulation once per session and pump the sender briefly instead.
  * Emulation must NOT be started/stopped per keystroke; racing it makes every
    key after the first fail with "device is not emulating".
  * device.keyboard_key(...).frame() returns the Device, not a frame object, so
    there is no errno to inspect. Detect revoked emulation via the
    DEVICE_STOP_EMULATING event instead.
"""
import os
import socket
import sys
import time

SOCK = os.path.expanduser("~/.cache/nyx-gestures/key.sock")
TOKEN_FILE = os.path.expanduser("~/.cache/nyx-gestures/libei.token")
RECONNECT_SECS = 5
# Self-heal a stale libei/GDBus connection (e.g. after a gnome-shell restart).
# A fresh process is the only reliable cure on this build: libei.portal caches
# GLib's shared session-bus connection, which goes stale after a compositor
# restart. Exit so systemd Restart=always restarts us with a fresh connection.
# Each attempt can block up to 30s (negotiate timeout), so 4 fails is ~2 min
# between restarts even if GNOME is genuinely unavailable (no tight loop).
MAX_CONNECT_FAILS = 4

from evdev import ecodes  # noqa: E402

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
    # Numeric keypad, as GNOME spells them ("<Super>KP_4"). evdev names them
    # without the underscore, so these must be aliased explicitly.
    "kp_0": "KEY_KP0", "kp_1": "KEY_KP1", "kp_2": "KEY_KP2",
    "kp_3": "KEY_KP3", "kp_4": "KEY_KP4", "kp_5": "KEY_KP5",
    "kp_6": "KEY_KP6", "kp_7": "KEY_KP7", "kp_8": "KEY_KP8",
    "kp_9": "KEY_KP9",
}

MODIFIERS = (29, 42, 56, 57, 58, 125, 126)


class NotEmulating(RuntimeError):
    "Emulation was revoked; rebuild the session"


# libei reports "device is not emulating" on stderr, not through any return
# value or event on this build. Without watching stderr we log "sent" while
# injecting nothing. So capture fd 2 and treat that message as a hard failure
# that forces a session rebuild.
_CAPTURED = []


def install_stderr_capture():
    """Duplicate this process's stderr and watch it for libei emulation errors."""
    try:
        r_fd, w_fd = os.pipe()
        saved = os.dup(2)
        os.dup2(w_fd, 2)
        os.close(w_fd)
    except OSError:
        return
    os.set_inheritable(r_fd, True)

    def reader():
        while True:
            try:
                chunk = os.read(r_fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            _CAPTURED.append(chunk.decode(errors="ignore"))
            # Mirror to the real stderr so journalctl still shows it.
            try:
                os.write(saved, chunk)
            except OSError:
                pass

    import threading
    threading.Thread(target=reader, daemon=True).start()


def check_emulation_error():
    """True if libei reported a non-emulating error since the last call."""
    text = "".join(_CAPTURED)
    _CAPTURED.clear()
    if "not emulating" in text:
        return True
    return False


def code_for(name):
    n = name.strip().lower().replace("-", "_").replace(" ", "_")
    if not n:
        return None
    const = ALIASES.get(n) or (n if n.startswith("KEY_") else "KEY_" + n.upper())
    v = getattr(ecodes, const, None)
    if isinstance(v, int):
        return v
    return int(n) if n.isdigit() else None


def open_device():
    """Return (session, ctx, device) with a resumed keyboard, or None."""
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
    return (session, ctx, device) if device else None


def start_emulation(device, ctx):
    """Start emulating and give the sender a dispatch cycle.

    We deliberately do NOT wait for DEVICE_START_EMULATING: this build never
    emits it. Pumping briefly is what actually flushes the request.
    """
    device.start_emulating()
    for _ in range(12):
        ctx.dispatch()
        time.sleep(0.008)


def drain(ctx):
    import libei.ei as ei
    ctx.dispatch()
    for ev in ctx.events:
        if getattr(ev, "event_type", None) is ei.EventType.DEVICE_STOP_EMULATING:
            raise NotEmulating("compositor revoked emulation")


def release_all(device, ctx=None):
    """Release every modifier unconditionally and REPORT failures.

    A dropped modifier key-up leaves super/alt logically held. When it finally
    releases, mutter reads a bare modifier tap: Super alone opens the overview,
    which is why a stuck Super turned unrelated gestures into the overview or a
    stray workspace switch. So we always release, and log when the compositor
    refuses, instead of silently swallowing the error.
    """
    failed = []
    for code in MODIFIERS:
        try:
            device.keyboard_key(code, False).frame()
        except Exception as e:
            failed.append(f"{code}:{e}")
    if failed and ctx is not None:
        # A frame may only surface its errno on the next dispatch.
        try:
            drain(ctx)
        except NotEmulating:
            raise
    return failed


def press(device, codes):
    """Send one chord, guaranteeing every key is released even on failure."""
    try:
        for c in codes[:-1]:
            device.keyboard_key(c, True).frame()
        last = codes[-1]
        device.keyboard_key(last, True).frame()
        time.sleep(0.012)
        device.keyboard_key(last, False).frame()
        for c in reversed(codes[:-1]):
            device.keyboard_key(c, False).frame()
    finally:
        # Unconditional: never leave a modifier held, whatever went wrong.
        for code in codes:
            try:
                device.keyboard_key(code, False).frame()
            except Exception:
                pass


def maybe_self_heal(fails):
    """Exit for a systemd restart after repeated connection failures.

    Called from every path that drops a session (open failure, emulation
    failure, revoked emulation on inject), so a session that never comes up
    heals instead of looping forever. The MAX_CONNECT_FAILS threshold itself
    rate-limits restarts (4 * up-to-30s negotiate ~= 2 min between restarts).
    Never called from the healthy injection path.
    """
    if fails >= MAX_CONNECT_FAILS:
        print("self-heal: stale portal connection; exiting for systemd restart",
              flush=True)
        sys.exit(1)  # systemd Restart=always gives us a fresh GDBus connection


def main():
    os.makedirs(os.path.dirname(SOCK), exist_ok=True)
    if os.path.exists(SOCK):
        os.unlink(SOCK)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK)
    srv.listen(8)
    os.chmod(SOCK, 0o600)
    print(f"nyx-keyd listening on {SOCK}", flush=True)
    install_stderr_capture()

    held = None
    last_send = 0.0
    connect_fails = 0
    while True:
        if held is None:
            try:
                held = list(open_device())
                connect_fails = 0
            except Exception as e:
                connect_fails += 1
                print(f"portal not ready ({e}); retry in {RECONNECT_SECS}s "
                      f"({connect_fails}/{MAX_CONNECT_FAILS})", flush=True)
                maybe_self_heal(connect_fails)
                time.sleep(RECONNECT_SECS)
                continue
            try:
                start_emulation(held[2], held[1])
                connect_fails = 0
                print("emulation active", flush=True)
            except Exception as e:
                connect_fails += 1
                print(f"emulation failed ({e}) "
                      f"({connect_fails}/{MAX_CONNECT_FAILS})", flush=True)
                maybe_self_heal(connect_fails)
                held = None
                time.sleep(RECONNECT_SECS)
                continue

        _session, ctx, device = held
        srv.settimeout(0.5)
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            try:
                drain(ctx)
            except NotEmulating:
                print("emulation revoked; rebuilding", flush=True)
                held = None
            continue
        except OSError:
            continue

        with conn:
            try:
                data = conn.recv(256).decode(errors="ignore").strip()
            except OSError:
                continue
            if not data:
                continue
            codes = [code_for(p) for p in data.split("+") if p.strip()]
            if not codes or any(c is None for c in codes):
                print(f"bad chord: {data!r}", flush=True)
                try:
                    conn.sendall(b"ERR")
                except OSError:
                    pass
                continue
            # Rapid back-to-back swipes can arrive within milliseconds. Give the
            # previous key event time to be consumed before sending the next.
            since = time.time() - last_send
            if since < 0.03:
                time.sleep(0.03 - since)
            try:
                check_emulation_error()   # discard anything stale
                press(device, codes)
                stuck = release_all(device, ctx)
                drain(ctx)
                if check_emulation_error():
                    raise NotEmulating("libei reported not emulating")
                if stuck:
                    print(f"WARNING: could not release {stuck} after {data!r}"
                          " - a modifier may be stuck (bare Super opens the"
                          " overview)", flush=True)
                last_send = time.time()
                connect_fails = 0
                print(f"sent {data}", flush=True)
                reply = b"OK"
            except NotEmulating as e:
                connect_fails += 1
                print(f"INJECT FAILED ({e}); rebuilding session "
                      f"({connect_fails}/{MAX_CONNECT_FAILS})", flush=True)
                maybe_self_heal(connect_fails)
                held = None
                reply = b"ERR"
                time.sleep(0.2)
            except Exception as e:
                connect_fails += 1
                print(f"INJECT FAILED ({e}); rebuilding session "
                      f"({connect_fails}/{MAX_CONNECT_FAILS})", flush=True)
                maybe_self_heal(connect_fails)
                held = None
                reply = b"ERR"
                time.sleep(0.2)
            try:
                conn.sendall(reply)
            except OSError:
                pass


if __name__ == "__main__":
    sys.exit(main())