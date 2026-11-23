#!/bin/bash
# nyx-gestures installer - works on any GNOME/Wayland machine.
#
#   ./install.sh                 auto-detect and install the default backend
#   ./install.sh --backend=daemon force the libei daemon backend
#   ./install.sh --backend=ext    force the GNOME Shell extension backend
#   ./install.sh --uninstall      remove everything this script installed
#   ./install.sh --status         report what is installed and what is running
#   ./install.sh --doctor         diagnose "my gesture does nothing", read-only
#
# Backends:
#   daemon  libinput-gestures + a libei key injector. Works on any GNOME/Wayland
#           version and any touchpad, including ones whose native gestures we
#           cannot disable. Costs ~32 MB RAM across 2 processes.
#   ext     a GNOME Shell extension. 0 extra processes, gestures handled by the
#           compositor. Requires Clutter's get_gesture_motion_delta, which
#           arrived in Clutter 12 / mutter 12 (GNOME 45) - checked live, not
#           guessed from the version string. Requires a shell restart.
#
# Auto-selection prefers the extension when the required API is actually present,
# and falls back to the daemon otherwise. --backend=ext on a system without the
# API is refused rather than installed, because every swipe would silently fail.
#
# Neither backend patches any system binary.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIBDIR=/usr/local/lib/nyx-gestures
BINDIR=/usr/local/bin
UNITDIR="${HOME}/.config/systemd/user"
UUID="nyx-gestures@nyx.local"

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
    printf '    %-22s %s\n' "extension enabled" \
        "$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null | grep -c "$UUID")"
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
    say "    extension          : $(gnome-extensions info "$UUID" 2>/dev/null | awk '/State:/{print $2}' || echo 'not installed')"
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
    say "==> Disabling extension"
    gnome-extensions disable "$UUID" 2>/dev/null || true
    say "==> Removing files"
    rm -f "$BINDIR/nyx-key" "$BINDIR/nyx-keyd" "$BINDIR/nyshot" \
          "$BINDIR/nyx-gestures-setup" "$BINDIR/nyx-key-uninstall"
    rm -rf "$LIBDIR" "${HOME}/.local/share/gnome-shell/extensions/$UUID"
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

install_ext() {
    say "==> Installing the GNOME Shell extension backend"
    DEST="${HOME}/.local/share/gnome-shell/extensions/$UUID"
    mkdir -p "$DEST"
    # gesture-map.js is a runtime import of extension.js, not an optional extra:
    # omitting it makes the extension fail to load at all.
    cp "$HERE/extension/metadata.json" "$HERE/extension/extension.js" \
       "$HERE/extension/gesture-map.js" "$DEST/"

    # The shipped metadata declares only ["50"] because that is the ONLY version
    # this has been hardware-verified on. GNOME refuses to load an extension
    # whose shell-version does not include the running shell, so leaving it at 50
    # would make the installer say "supported" on a 46 machine and then fail to
    # load. Since the API probe above already proved the required Clutter methods
    # are present, widen the INSTALLED copy to this machine's version. The
    # shipped file stays honest about what was actually tested.
    if [ -n "${GNOME_VER:-}" ] && [ "$GNOME_VER" != 50 ]; then
        if grep -q '"50"' "$DEST/metadata.json" 2>/dev/null; then
            sed -i "s/\"shell-version\": *\[\"50\"\]/\"shell-version\": [\"$GNOME_VER\"]/" \
                "$DEST/metadata.json"
            say "    adapted shell-version to $GNOME_VER (API probe passed on this system)"
        fi
    fi

    # GSettings schema, installed per-user so no root is needed and the system
    # schema directory stays untouched. Without it the extension still loads but
    # every log-level lookup fails, which would silently leave the user with no
    # way to change verbosity.
    if [ -d "$HERE/schemas" ]; then
        SCHEMA_SRC="$HERE/schemas/org.gnome.shell.extensions.nyx-gestures.gschema.xml"
        if [ -f "$SCHEMA_SRC" ]; then
            mkdir -p "$HOME/.local/share/glib-2.0/schemas"
            install -m 644 "$SCHEMA_SRC" \
                "$HOME/.local/share/glib-2.0/schemas/"
            if command -v glib-compile-schemas >/dev/null 2>&1; then
                glib-compile-schemas "$HOME/.local/share/glib-2.0/schemas" 2>/dev/null \
                    && say "    installed GSettings schema (per-user, no root needed)" \
                    || warn "schema compile failed; the extension will fall back to \$NYX_LOG"
            else
                warn "glib-compile-schemas not found; log level stays at its default"
            fi
        fi
    fi

    # The logger and preflight are useful to the user after install, so ship
    # them into the same private libdir the daemon uses.
    LOGDIR="$LIBDIR"
    mkdir -p "$LOGDIR" 2>/dev/null || true
    if [ -w "$LOGDIR" ] || [ "$(id -u)" -eq 0 ]; then
        install -m 644 "$HERE/lib/nyx-log.sh" "$LOGDIR/nyx-log.sh" 2>/dev/null || true
        install -m 755 "$HERE/lib/nyx-preflight.sh" "$LOGDIR/nyx-preflight.sh" 2>/dev/null || true
        ln -sf "$LOGDIR/nyx-preflight.sh" "$BINDIR/nyx-preflight" 2>/dev/null || true
    else
        warn "cannot write $LOGDIR without root; skipping the nyx-preflight helper"
    fi

    gnome-extensions enable "$UUID" 2>/dev/null \
        && say "    enabled $UUID" \
        || warn "could not enable (log out and in, then: gnome-extensions enable $UUID)"
    say ""
    say "IMPORTANT: log out and back in so GNOME Shell loads it."
    say "No system files are modified by this backend."
}

case "$ACTION" in
    status)    do_status ;;
    doctor)    do_doctor ;;
    uninstall) do_uninstall ;;
    install)   detect
               if [ "$BACKEND" = ext ]; then install_ext; else install_daemon; fi
               say ""
               say "Done. Verify with:  $0 --status" ;;
esac