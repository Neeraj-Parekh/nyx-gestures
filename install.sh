#!/bin/bash
# nyx-gestures installer - works on any GNOME/Wayland machine.
#
#   ./install.sh                 install the recommended daemon + suppressor setup
#   ./install.sh --backend=daemon same (kept for compatibility)
#   ./install.sh --backend=ext    deprecated alias: installs daemon + suppressor
#   ./install.sh --uninstall      remove everything this script installed
#   ./install.sh --status         report what is installed and what is running
#   ./install.sh --doctor         diagnose "my gesture does nothing", read-only
#
# The WORKING setup is two parts:
#   daemon      libinput-gestures + a libei key injector performs every gesture
#               action (tile, workspace, fullscreen, desktop, screenshots).
#               Works on any GNOME/Wayland version, any touchpad, ~32 MB / 2 procs.
#   suppressor  a tiny GNOME Shell extension (nyx-native-suppress@nyx.local)
#               disables ONLY GNOME's own native swipe trackers so they do not
#               double-fire alongside the daemon. No gesture handling, no key
#               injection, no system files patched. Without it, 3F horizontal
#               also switches workspace and 4F up also shows a workspace preview.
#
# The old extension-only backend (extension/) is experimental and is NOT installed
# by default; --backend=ext now installs the recommended daemon + suppressor combo
# with a warning. Neither path patches any system binary.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIBDIR=/usr/local/lib/nyx-gestures
BINDIR=/usr/local/bin
UNITDIR="${HOME}/.config/systemd/user"
UUID="nyx-gestures@nyx.local"
SUPPRESSOR_UUID="nyx-native-suppress@nyx.local"

BACKEND="auto"
ACTION="install"
for arg in "$@"; do
    case "$arg" in
        --backend=*) BACKEND="${arg#*=}" ;;
        --uninstall)  ACTION="uninstall" ;;
        --doctor)     ACTION="doctor" ;;
        --status)     ACTION="status" ;;
        --help|-h)    sed -n '2,25p' "$0"; exit 0 ;;
    esac
done

say()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- detection
detect() {
    say "==> Detecting environment"

    # The real capability probe lives in lib/nyx-preflight.sh. The old logic here
    # chose the extension backend by grepping the GNOME version against a range
    # in metadata.json, which is NOT what determines whether the extension works.
    # Measured on two real machines:
    #
    #   GNOME 50.1 / mutter 18 -> get_gesture_motion_delta PRESENT -> extension OK
    #   GNOME 42.9 / mutter 10 -> get_gesture_motion_delta ABSENT  -> all 8 swipes dead
    #
    # A version range would have shipped the extension to the second machine, where
    # every swipe silently does nothing. So we ask whether the API exists.
    if [ -r "$HERE/lib/nyx-preflight.sh" ]; then
        # shellcheck disable=SC1091
        . "$HERE/lib/nyx-preflight.sh"
        pf_report
        pf_verdict
        GNOME_VER=$(pf_gnome)
        SESSION=$(pf_session)
        MUTTER_ABI=$(pf_mutter_abi)
        API_OK=$(pf_api_support "$(pf_probe_api)")
        TOUCHPAD=$(pf_touchpad_name)
        say "==> Recommendation"
        printf '    %-22s %s\n' backend "$NYX_RECOMMEND"
        [ -n "${NYX_REASON:-}" ] && printf '    %-22s %s\n' notes "$NYX_REASON"

        # Hard stop: refuse to install a backend that provably cannot work here.
        if [ "$API_OK" != yes ] && [ "$BACKEND" = ext ]; then
            die "the extension requires Clutter's get_gesture_motion_delta, which
       this system does not provide (mutter ABI $MUTTER_ABI, GNOME $GNOME_VER).
       All 8 swipe gestures would silently do nothing.
       Use --backend=daemon, which works on any GNOME version."
        fi
        if [ "$TOUCHPAD" = none ]; then
            warn "no touchpad detected: installation will proceed, but no gesture
       can ever fire on this machine."
        fi
    else
        warn "lib/nyx-preflight.sh missing; falling back to a version-only check."
        GNOME_VER="$(gnome-shell --version 2>/dev/null | awk '{print $3}' || echo unknown)"
        SESSION="${XDG_SESSION_TYPE:-unknown}"
        API_OK=unknown
        MUTTER_ABI=unknown
    fi

    if [ "$BACKEND" = auto ]; then
        if [ "$API_OK" = yes ]; then
            BACKEND=ext
        else
            BACKEND=daemon
            warn "the extension is unavailable on this system; selecting the
       daemon backend instead - it works on any GNOME/Wayland version."
        fi
        say "    backend     : $BACKEND (auto-selected)"
    else
        say "    backend     : $BACKEND (forced)"
    fi

    MISSING=""
    for b in libinput-gestures; do
        command -v "$b" >/dev/null 2>&1 || MISSING="$MISSING $b"
    done
    [ -n "$MISSING" ] && warn "not installed yet:$MISSING (this script installs it)"

    if [ "$BACKEND" = daemon ] && command -v pf_missing_imports >/dev/null 2>&1; then
        mi=$(pf_missing_imports)
        [ -n "$mi" ] && say "    python deps: $mi -> will go into a private venv"
    fi
}

# ------------------------------------------------------------------- doctor
# Read-only. Answers "why did my gesture not fire?" without changing anything.
# Deliberately never writes settings or restarts anything, so it is safe to run
# on someone else's machine while they are mid-session.
do_doctor() {
    say "==> nyx-gestures doctor (read-only, changes nothing)"
    [ -r "$HERE/lib/nyx-preflight.sh" ] && { . "$HERE/lib/nyx-preflight.sh"; pf_report; }
    say ""

    say "==> Installed components"
    for c in nyx-key nyx-keyd nyshot libinput-gestures nyx-preflight; do
        printf '    %-22s %s\n' "$c" "$(command -v "$c" 2>/dev/null || echo 'not installed')"
    done
    printf '    %-22s %s\n' "suppressor enabled" \
        "$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null | grep -c "$SUPPRESSOR_UUID")"
    printf '    %-22s %s\n' "extensions globally on" \
        "$(gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell \
            --method org.freedesktop.DBus.Properties.Get org.gnome.Shell.Extensions \
            UserExtensionsEnabled 2>/dev/null | grep -qo true && echo yes || echo NO)"
    printf '    %-22s %s\n' "gestures in conf" \
        "$(grep -c '^gesture' "$HOME/.config/libinput-gestures.conf" 2>/dev/null || echo 0)"
    say ""

    say "==> Services"
    for s in libinput-gestures nyx-keyd; do
        printf '    %-22s %s\n' "$s" \
            "$(systemctl --user is-active "$s" 2>/dev/null || echo 'not installed')"
    done
    say ""

    say "==> Injection backend"
    if [ -x "${LIBDIR:-/usr/local/lib/nyx-gestures}/nyx-interp" ]; then
        printf '    %-22s %s\n' "resolved python" \
            "$("${LIBDIR}/nyx-interp" --check 2>&1 | head -1)"
    else
        printf '    %-22s %s\n' "resolved python" "nyx-interp not installed"
    fi
    say ""

    say "==> Extension log"
    LOGF="$HOME/.local/state/nyx-gestures/nyx.log"
    if [ -f "$LOGF" ]; then
        printf '    %-22s %s\n' "level" \
            "$(gsettings get org.gnome.shell.extensions.nyx-gestures level 2>/dev/null || echo 'unknown')"
        printf '    %-22s %s\n' "file" "$LOGF"
        say "    --- last 15 lines ---"
        tail -15 "$LOGF" | sed 's/^/    /'
        say ""
        say "    If a gesture is missing from this log, the compositor never"
        say "    delivered it. If it appears as 'declined', the gesture WAS"
        say "    recognised and the action itself could not run."
    else
        printf '    %-22s %s\n' "no log yet" "expected at $LOGF"
        say "    (only the extension backend writes this file)"
    fi
    say ""

    say "==> Recent service errors"
    for s in libinput-gestures nyx-keyd; do
        # `grep -c` on no matches exits 1, and `|| echo 0` then appends a second
        # line, so the count came out as "0\n0". Use `|| true` and let grep's
        # own count stand.
        n=$(journalctl --user -u "$s" --since '-1h' --no-pager 2>/dev/null \
            | grep -ciE 'traceback|importerror|not ready|cannot' || true)
        printf '    %-22s %s error lines in the last hour\n' "$s" "${n:-0}"
    done
}

# ------------------------------------------------------------------ status
do_status() {
    say "==> Status"
    say "    libinput-gestures : $(systemctl --user is-active libinput-gestures.service 2>/dev/null || echo 'not installed')"
    say "    nyx-keyd           : $(systemctl --user is-active nyx-keyd.service 2>/dev/null || echo 'not installed')"
    say "    suppressor         : $(gnome-extensions info "$SUPPRESSOR_UUID" 2>/dev/null | awk '/State:/{print $2}' || echo 'not installed')"
    say "    extensions on      : $(gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell \
            --method org.freedesktop.DBus.Properties.Get org.gnome.Shell.Extensions \
            UserExtensionsEnabled 2>/dev/null | grep -qo true && echo yes || echo NO)"
    if [ -f "${HOME}/.config/libinput-gestures.conf" ]; then
        say "    bindings           : $(grep -c '^gesture' "${HOME}/.config/libinput-gestures.conf")"
    fi
    say "    keys bound by us   :"
    nyx-gestures-setup 2>/dev/null | sed -n '/Current bindings/,$p' | sed 's/^/      /' || true
}

# --------------------------------------------------------------- uninstall
do_uninstall() {
    say "==> Disabling services"
    systemctl --user disable --now libinput-gestures.service 2>/dev/null || true
    systemctl --user disable --now nyx-keyd.service 2>/dev/null || true
    say "==> Disabling extensions"
    gnome-extensions disable "$UUID" 2>/dev/null || true
    gnome-extensions disable "$SUPPRESSOR_UUID" 2>/dev/null || true
    say "==> Removing files"
    rm -f "$BINDIR/nyx-key" "$BINDIR/nyx-keyd" "$BINDIR/nyshot" \
          "$BINDIR/nyx-gestures-setup" "$BINDIR/nyx-key-uninstall"
    rm -rf "$LIBDIR" "${HOME}/.local/share/gnome-shell/extensions/$UUID" \
           "${HOME}/.local/share/gnome-shell/extensions/$SUPPRESSOR_UUID"
    rm -f "${UNITDIR}/nyx-keyd.service"
    systemctl --user daemon-reload 2>/dev/null || true
    say "Done. Your gesture config was left in place:"
    say "    ~/.config/libinput-gestures.conf"
    say "Log out and back in to fully unload the extension."
}

# ----------------------------------------------------------------- install
install_daemon() {
    say "==> Installing the libei daemon backend"

    SUDO=""
    [ "$(id -u)" -ne 0 ] && [ ! -w "$LIBDIR" ] && SUDO="sudo"

    STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
    $SUDO mkdir -p "$LIBDIR" "$BINDIR"
    $SUDO install -m 644 "$HERE/VERSION" "$LIBDIR/VERSION" 2>/dev/null || true

    # ---- interpreter -----------------------------------------------------
    # The entry points are /bin/sh launchers that resolve an interpreter at
    # runtime (daemon/nyx-interp). Nothing bakes a venv path into a shebang any
    # more: such a path is only valid on the machine where install.sh ran, and
    # when it was wrong the failure surfaced as a bare ImportError from inside a
    # gesture handler rather than as "this interpreter is unusable".
    #
    # A package-private venv is still preferred for python-libei, because PEP 668
    # forbids pip-installing into the system interpreter on Debian/Ubuntu. But we
    # skip it entirely when the system python already satisfies every import, so
    # a machine with python-libei installed natively needs no venv at all.
    VENV="$LIBDIR/venv"
    NEED_VENV=1
    for py in /usr/bin/python3 /usr/local/bin/python3 python3; do
        resolved=$(command -v "$py" 2>/dev/null || true)
        if [ -n "$resolved" ] && \
           "$resolved" -c 'import libei.ei, libei.portal, evdev' 2>/dev/null; then
            say "    system python already provides libei/evdev ($resolved)"
            NEED_VENV=0
            break
        fi
    done
    if [ "$NEED_VENV" = 1 ]; then
        # --system-site-packages so the distribution's evdev (already built for
        # this interpreter) is visible. A venv on a *different* python cannot
        # load that C extension - the ABI trap noted in README.
        if [ ! -x "$VENV/bin/python" ]; then
            say "    creating self-contained venv at $VENV"
            $SUDO python3 -m venv --system-site-packages "$VENV" \
                || die "could not create venv"
        fi
        if ! "$VENV/bin/python" -c 'import libei.ei' 2>/dev/null; then
            say "    installing python-libei"
            $SUDO "$VENV/bin/pip" install --quiet --break-system-packages \
                python-libei || die "could not install python-libei"
        fi
        "$VENV/bin/python" -c 'import libei.ei, libei.portal, evdev' 2>/dev/null \
            || die "venv at $VENV cannot import libei/evdev"
    fi

    # ---- files -----------------------------------------------------------
    for f in nyx-interp nyx-key nyx-keyd; do
        cp "$HERE/daemon/$f" "$STAGE/$f"
        $SUDO install -m 755 "$STAGE/$f" "$LIBDIR/$f"
        $SUDO ln -sf "$LIBDIR/$f" "$BINDIR/$f"
    done
    for f in nyx-key.py nyx-keyd.py; do
        cp "$HERE/daemon/$f" "$STAGE/$f"
        $SUDO install -m 755 "$STAGE/$f" "$LIBDIR/$f"
    done
    $SUDO install -m 755 "$HERE/daemon/nyshot" "$LIBDIR/nyshot"
    $SUDO ln -sf "$LIBDIR/nyshot" "$BINDIR/nyshot"

    # Drop any cached interpreter so it is re-validated against what we just
    # installed, not a path remembered from a previous run. The cache lives in
    # the user's cache dir because these launchers run unprivileged.
    rm -f "${XDG_CACHE_HOME:-$HOME/.cache}/nyx-gestures/interpreter" "$LIBDIR/interpreter"

    # ---- verify, do not hope ---------------------------------------------
    RESOLVED=$("$LIBDIR/nyx-interp" --check) \
        || die "no usable Python interpreter after install"
    say "    interpreter: $RESOLVED"
    for f in nyx-interp nyx-key nyx-keyd; do
        sh -n "$LIBDIR/$f" || die "$f is not valid sh"
    done
    bash -n "$LIBDIR/nyshot" || die "nyshot is not valid bash"
    for f in nyx-key.py nyx-keyd.py; do
        "$RESOLVED" -c "import sys;compile(open(sys.argv[1]).read(),'x','exec')" \
            "$LIBDIR/$f" || die "$f is not valid Python"
    done
    # A launcher can parse perfectly and still fail at runtime, so actually run
    # one. With no arguments nyx-key prints usage and exits non-zero; a
    # Traceback would mean the launcher chain itself is broken.
    if "$BINDIR/nyx-key" 2>&1 | grep -q 'Traceback'; then
        die "nyx-key launcher raised an exception"
    fi
    say "    syntax + launcher smoke checks passed"

    mkdir -p "$UNITDIR"
    install -m 644 "$HERE/units/nyx-keyd.service" "$UNITDIR/nyx-keyd.service"
    if [ ! -f "$UNITDIR/libinput-gestures.service" ]; then
        install -m 644 "$HERE/units/libinput-gestures.service" \
            "$UNITDIR/libinput-gestures.service"
        say "    installed libinput-gestures.service"
    fi

    CONF="${HOME}/.config/libinput-gestures.conf"
    if [ ! -f "$CONF" ]; then
        mkdir -p "$(dirname "$CONF")"
        sed "s|/usr/local/bin/nyx-key|$BINDIR/nyx-key|g; \
             s|/usr/local/bin/nyshot|$BINDIR/nyshot|g" \
            "$HERE/libinput-gestures.conf" > "$CONF"
        say "    wrote $CONF"
    else
        say "    kept your existing $CONF"
    fi

    $SUDO install -m 755 "$HERE/nyx-gestures-setup" "$BINDIR/nyx-gestures-setup"
    $SUDO ln -sf "$BINDIR/nyx-gestures-setup" "$BINDIR/nyx-key-uninstall" 2>/dev/null || true

    systemctl --user daemon-reload
    systemctl --user enable --now nyx-keyd.service || warn "nyx-keyd failed to start"
    systemctl --user enable --now libinput-gestures.service || warn "libinput-gestures failed to start"

    say "==> Applying GNOME keybindings"
    "$BINDIR/nyx-gestures-setup" || warn "keybinding setup reported a problem"
}

install_suppressor() {
    say "==> Installing the native-swipe suppressor extension"
    DEST="${HOME}/.local/share/gnome-shell/extensions/$SUPPRESSOR_UUID"
    mkdir -p "$DEST"
    cp "$HERE/suppressor/metadata.json" "$HERE/suppressor/extension.js" "$DEST/"

    # Shipped metadata declares ["50"] (the hardware-verified version). Widen
    # the INSTALLED copy to this machine's major version if different, so GNOME
    # will load it; the shipped file stays honest about what was tested.
    if [ -n "${GNOME_VER:-}" ] && [ "$GNOME_VER" != 50 ]; then
        if grep -q '"50"' "$DEST/metadata.json" 2>/dev/null; then
            sed -i "s/\"shell-version\": *\[\"50\"\]/\"shell-version\": [\"$GNOME_VER\"]/" \
                "$DEST/metadata.json"
            say "    adapted shell-version to $GNOME_VER"
        fi
    fi

    # GNOME disables ALL extensions after a shell failure. If that happened,
    # gnome-extensions enable will silently refuse; re-enable them first.
    if ! gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell \
            --method org.freedesktop.DBus.Properties.Get org.gnome.Shell.Extensions \
            UserExtensionsEnabled 2>/dev/null | grep -q true; then
        gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell \
            --method org.freedesktop.DBus.Properties.Set org.gnome.Shell.Extensions \
            UserExtensionsEnabled '<true>' >/dev/null 2>&1 \
            && say "    re-enabled GNOME extensions (were globally disabled)"
    fi

    gnome-extensions enable "$SUPPRESSOR_UUID" 2>/dev/null \
        && say "    enabled $SUPPRESSOR_UUID" \
        || warn "could not enable (log out/in, then: gnome-extensions enable $SUPPRESSOR_UUID)"
    say ""
    say "IMPORTANT: log out and back in so GNOME Shell loads the suppressor."
    say "No system files are modified by this extension."
}

case "$ACTION" in
    status)    do_status ;;
    doctor)    do_doctor ;;
    uninstall) do_uninstall ;;
    install)   detect
               if [ "$BACKEND" = ext ]; then
                   warn "--backend=ext is deprecated (the extension-only handler is experimental)."
                   warn "Installing the recommended daemon + suppressor setup instead."
               fi
               install_daemon
               install_suppressor
               say ""
               say "Done. Log out and back in once, then verify with:  $0 --status" ;;
esac