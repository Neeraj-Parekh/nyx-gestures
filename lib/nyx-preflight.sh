#!/bin/bash
# nyx-preflight - detect what this machine can actually run.
#
# Sourced by install.sh and nyx-gestures-setup. Also runnable standalone:
#     ./lib/nyx-preflight.sh          human-readable report
#     ./lib/nyx-preflight.sh --json   machine-readable, for scripting
#
# DESIGN RULE: never trust the distro version or the GNOME version alone.
# The thing that actually decides whether the extension works is whether the
# Clutter/Mutter API it calls EXISTS, and that does not track the release
# number. Verified on real hardware:
#
#   GNOME 50.1 / mutter 18 / Clutter 18  -> get_gesture_motion_delta PRESENT
#   GNOME 42.9 / mutter 10 / Clutter 10  -> get_gesture_motion_delta ABSENT
#
# GNOME 42 does have get_gesture_pinch_scale and get_touchpad_gesture_finger_count,
# but without get_gesture_motion_delta every swipe gesture is dead, so the
# extension must not be offered there. A version-range check in metadata.json
# would have shipped it and failed silently at runtime.

# --------------------------------------------------------------------- output
if [ "${NYX_JSON:-}" = 1 ]; then
    _pf_out() { printf '%s=%s\n' "$1" "$2"; }
else
    _pf_out() { printf '  %-22s %s\n' "$1" "$2"; }
fi

# --------------------------------------------------------------- session type
pf_session() {
    if [ -n "${XDG_SESSION_TYPE:-}" ]; then
        printf '%s' "$XDG_SESSION_TYPE"
    elif [ -n "${WAYLAND_DISPLAY:-}" ]; then
        printf 'wayland'
    elif [ -n "${DISPLAY:-}" ]; then
        printf 'x11'
    else
        printf 'unknown'
    fi
}

# ------------------------------------------------------------ gnome + mutter
pf_gnome() {
    command -v gnome-shell >/dev/null 2>&1 || { printf '0'; return; }
    gnome-shell --version 2>/dev/null | awk '{print $3}' | grep -E '^[0-9]+' || printf '0'
}

pf_mutter_abi() {
    # The numeric suffix on Meta-<N>.typelib is the mutter ABI version. GNOME 42
    # ships Meta-10, GNOME 50 ships Meta-18. This is a far better capability
    # proxy than the marketing version string.
    local d
    for d in /usr/lib/*/gnome-shell /usr/lib/gnome-shell \
             /usr/lib/*/mutter-* /usr/lib/mutter-*; do
        [ -d "$d" ] || continue
        local f
        f=$(ls "$d"/Meta-*.typelib 2>/dev/null | head -1)
        [ -n "$f" ] || continue
        basename "$f" | sed 's/^Meta-//; s/\.typelib$//'
        return
    done
    printf 'unknown'
}

# ------------------------------------------------- live capability probe
# Introspects the installed typelibs directly. This is the check that matters:
# it asks "does the API exist" rather than "what version is it".
pf_probe_api() {
    command -v gjs >/dev/null 2>&1 || { printf 'no-gjs'; return; }

    local mdir sdir paths=""
    mdir=$(ls -d /usr/lib/*/mutter-* 2>/dev/null | head -1)
    sdir=$(ls -d /usr/lib/gnome-shell /usr/lib/*/gnome-shell 2>/dev/null | head -1)
    [ -n "$mdir" ] && paths="$mdir"
    [ -n "$sdir" ] && paths="$paths:$sdir"

    cat > /tmp/.nyx-probe-$$.js <<'PROBE'
try {
    const need = ['get_gesture_motion_delta', 'get_gesture_phase',
                  'get_gesture_pinch_scale', 'get_touchpad_gesture_finger_count'];
    let found = {};
    for (const ns of [['Meta', null], ['Shell', null], ['Clutter', null], ['St', null]]) {
        try {
            const m = imports.gi[ns[0]];
            if (ns[0] === 'Meta' && !m.Window) continue;
            const proto = (ns[0] === 'Shell' ? m.Screenshot.prototype : m.Event.prototype);
            if (!proto) continue;
            const s = new Set();
            let o = proto;
            while (o && o !== Object.prototype) {
                for (const k of Object.getOwnPropertyNames(o)) s.add(k);
                o = Object.getPrototypeOf(o);
            }
            if (ns[0] === 'Clutter') for (const n of need) found[n] = s.has(n);
        } catch (e) { /* namespace absent on this platform */ }
    }
    print(JSON.stringify(found));
} catch (e) { print('{}'); }
PROBE

    local out
    out=$(GI_TYPELIB_PATH="$paths" LD_LIBRARY_PATH="$paths" \
          gjs "/tmp/.nyx-probe-$$.js" 2>/dev/null | tail -1)
    rm -f "/tmp/.nyx-probe-$$.js"
    [ -n "$out" ] || { printf 'probe-failed'; return; }
    printf '%s' "$out"
}

# Human summary of the API probe, reading the JSON with python if present.
pf_api_support() {
    local json="$1"
    case "$json" in
        *get_gesture_motion_delta*true*) printf 'yes' ;;
        *get_gesture_motion_delta*false*) printf 'partial' ;;
        probe-failed|no-gjs) printf 'unknown' ;;
        *) printf 'unknown' ;;
    esac
}

# ------------------------------------------------------------------ touchpad
# Worth knowing before install: a machine with no touchpad can install the
# package perfectly and still never fire a gesture.
# Detect the touchpad by PARSING /proc/bus/input/devices.
#
# Two earlier approaches were wrong, both verified on this machine:
#   1. grepping /sys/class/input/event*/device/uevent for ID_INPUT_TOUCHPAD -
#      that file does NOT contain ID_INPUT_* properties at all (udev writes
#      them, not the kernel), so this reported "no touchpad" on a laptop that
#      has one.
#   2. `udevadm info --query=property --name=/dev/input/eventN` - correct, but it
#      forks udevadm once per event node (20+ on a laptop) which is slow enough
#      to be noticeable, and it needs read access to the device node, so it
#      reports nothing for nodes the user cannot open.
# /proc/bus/input/devices is a single readable file, needs no privileges, and
# contains both the name and the handler list, which gives us the event node for
# the follow-up slot count.
#
# Emits TAB-separated: name <TAB> event-node. Empty output means no touchpad.
pf_touchpad() {
    [ -r /proc/bus/input/devices ] || { printf 'proc-unavailable'; return; }
    awk '
        /^N: Name=/ {
            name = $0
            sub(/^N: Name=/, "", name)
            gsub(/"/, "", name)
            next
        }
        # Must be a whole block ending in "Touchpad", not a substring match.
        # An ELAN touchpad exposes TWO nodes - "ELAN06FA... Mouse" and
        # "ELAN06FA... Touchpad" - and matching /ELAN/ picked the Mouse node,
        # which has no ABS_MT_SLOT axis at all.
        /^H: Handlers=/ {
            if (name ~ /[Tt]ouchpad$|[Tt]rackpad$/ || name ~ /Synapt.*[Tt]ouchpad$/) {
                for (i = 3; i <= NF; i++)
                    if ($i ~ /^event[0-9]+$/) { print name "\t" $i; exit }
            }
        }
    ' /proc/bus/input/devices | head -1
}

pf_touchpad_name() {
    local t; t=$(pf_touchpad)
    [ "$t" = "proc-unavailable" ] && { printf 'unknown'; return; }
    [ -z "$t" ] && { printf 'none'; return; }
    printf '%s' "${t%%	*}"
}

pf_touchpad_node() {
    local t; t=$(pf_touchpad)
    # libinput reports the full path ("/dev/input/eventN"); /proc gives a bare
    # "eventN". Comparing them directly always failed, which made the capability
    # lookup silently fall through to "unknown".
    local n; n="${t##*	}"
    case "$n" in
        event*) printf '/dev/input/%s' "$n" ;;
        *)      printf '%s' "$n" ;;
    esac
}

# Max simultaneous touch slots. 4-finger gestures are impossible below 4.
#
# Three sources were tried and two do not work on this kernel (7.0.0-38):
#   * sysfs abs47/max - the Touchpad node here exposes NO abs axes at all
#     (`ls /sys/class/input/event4/device | grep ^abs` is empty), so this always
#     came back unknown.
#   * `libinput debug-info` - prints nothing for this device.
# What does work is libinput's own device summary, which reports the gesture
# capability we actually care about. Slot count is not exposed there, so this
# reports the number of FINGERS the hardware is known to support from the
# gesture capability plus a conservative default, and says "4+" when it cannot
# tell. Reporting a wrong small number would wrongly disable 4-finger gestures,
# which is worse than admitting uncertainty.
pf_max_fingers() {
    local node caps
    node=$(pf_touchpad_node)
    [ -n "$node" ] || { printf '0'; return; }
    caps=$(libinput list-devices 2>/dev/null \
           | awk -v n="${node}" '
               /^Device:/ { if (seen) exit; inblock = 0; next }
               $1=="Kernel:" { want = ($2 == n); if (want) seen = 1; inblock = 0; next }
               want && /^[^ ]/ { inblock = 1; block = block " " $0; next }
               want && inblock { block = block " " $0 }
               END { print block }')
    case "$caps" in
        *gesture*) printf '4+' ;;   # gesture capable: at least 4 in practice
        *touch*)   printf 'unknown' ;;
        *)         printf 'unknown' ;;
    esac
}

# ------------------------------------------------------------------ backend
# Which injection backend will actually be used for key chords here.
pf_backend() {
    case "$(pf_session)" in
        x11)  printf 'xdotool' ;;
        wayland)
            # libei needs a RemoteDesktop portal session; nyx-keyd holds one open.
            if pgrep -f 'nyx-keyd\.py' >/dev/null 2>&1; then printf 'libei'
            else printf 'libei'   # still the plan; installer will try to start it
            fi
            ;;
        *) printf 'unknown' ;;
    esac
}

# --------------------------------------------------------------- interpreter
# Which python can import what the daemon backend needs. Mirrors
# daemon/nyx-interp so install-time detection and runtime resolution agree.
# Report a python that can import the daemon backend's dependencies, if any.
#
# Deliberately checks SYSTEM pythons explicitly rather than trusting whatever
# `python3` resolves to first. `command -v python3` finds a user's project venv
# ahead of /usr/bin/python3 when a venv is active (here it reported
# /mnt/.../linux_venv/bin/python3, which lacks evdev), so PATH order alone would
# have produced a wrong answer.
pf_python() {
    local c
    for c in /usr/bin/python3 /usr/local/bin/python3; do
        [ -x "$c" ] || continue
        if "$c" -c 'import libei.ei, libei.portal, evdev' >/dev/null 2>&1; then
            printf '%s' "$c"; return
        fi
    done
    # None satisfies everything; report the base interpreter so the installer
    # knows it must create the package venv.
    [ -x /usr/bin/python3 ] && { printf '/usr/bin/python3'; return; }
    printf 'none'
}

pf_missing_imports() {
    local c
    c=$(pf_python)
    [ "$c" = none ] && { printf 'python3'; return; }
    local missing=""
    "$c" -c 'import evdev'   >/dev/null 2>&1 || missing="$missing python-evdev"
    "$c" -c 'import libei.ei' >/dev/null 2>&1 || missing="$missing python-libei"
    printf '%s' "${missing# }"
}



pf_sudo() {
    # Can we write where we need to? Never prompt from inside a probe.
    [ "$(id -u)" -eq 0 ] && { printf 'root'; return; }
    command -v sudo >/dev/null 2>&1 || { printf 'no-sudo'; return; }
    sudo -n true 2>/dev/null && printf 'sudo-nopass' || printf 'sudo-needs-pass'
}

# ------------------------------------------------------------------- report
pf_report() {
    local session gnome abi api api_ok pad fingers py sudo_state
    session=$(pf_session); gnome=$(pf_gnome); abi=$(pf_mutter_abi)
    api=$(pf_probe_api); api_ok=$(pf_api_support "$api")
    pad=$(pf_touchpad_name); fingers=$(pf_max_fingers)
    py=$(pf_python); sudo_state=$(pf_sudo)

    if [ "${NYX_JSON:-}" = 1 ]; then
        _pf_out session "$session"
        _pf_out gnome "$gnome"
        _pf_out mutter_abi "$abi"
        _pf_out api_support "$api_ok"
        _pf_out touchpad "$pad"
        _pf_out touch_slots "$fingers"
        _pf_out injection_backend "$(pf_backend)"
        _pf_out python "$py"
        _pf_out sudo "$sudo_state"
        _pf_out missing_imports "$(pf_missing_imports)"
        return
    fi

    say "==> Environment"
    _pf_out "distribution" "$(. /etc/os-release 2>/dev/null && printf '%s' "$PRETTY_NAME")"
    _pf_out "kernel" "$(uname -r)"
    _pf_out "GNOME Shell" "$gnome"
    _pf_out "mutter ABI" "$abi"
    _pf_out "session type" "$session"
    _pf_out "injection backend" "$(pf_backend)"
    _pf_out "API support" "$api_ok"
    _pf_out "touchpad" "$pad"
    _pf_out "touch slots" "$fingers"
    _pf_out "python3" "$py"
    _pf_out "privileges" "$sudo_state"
    local mi; mi=$(pf_missing_imports)
    [ -n "$mi" ] && _pf_out "missing python" "$mi"
}

# ------------------------------------------------------------------ verdict
# Prints one of: ok-extension, ok-daemon, unsupported. Sets NYX_RECOMMEND.
pf_verdict() {
    local api api_ok pad fingers abi
    api=$(pf_probe_api); api_ok=$(pf_api_support "$api")
    pad=$(pf_touchpad_name); fingers=$(pf_max_fingers); abi=$(pf_mutter_abi)

    NYX_RECOMMEND=daemon
    NYX_REASON=""

    case "$api_ok" in
        yes) ;;
        partial)
            NYX_REASON="Clutter lacks get_gesture_motion_delta (mutter $abi): all swipe gestures would be dead."
            ;;
        *)
            NYX_REASON="could not verify the required Clutter/Mutter APIs."
            ;;
    esac

    if [ "$pad" = none ]; then
        NYX_REASON="$NYX_REASON No touchpad detected: gestures will never fire."
    fi
    if printf "%s" "$fingers" | grep -qE "^[0-3]$"; then
        NYX_REASON="$NYX_REASON Touchpad reports $fingers slots: 4-finger gestures unavailable."
    fi
    [ "$(pf_session)" = x11 ] && \
        NYX_REASON="$NYX_REASON X11 session: compositor keybindings are reachable, but GNOME screen recording is unavailable."

    if [ "$api_ok" = yes ] && [ "$pad" != none ]; then
        NYX_RECOMMEND=extension
        [ -n "$NYX_REASON" ] && NYX_REASON="$NYX_REASON "
        NYX_REASON="both backends are viable; the extension avoids two extra processes."
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -uo pipefail
    say()  { printf '%s\n' "$*"; }
    [ "${1:-}" = "--json" ] && export NYX_JSON=1
    pf_report
    pf_verdict
    if [ -n "${NYX_JSON:-}" ]; then
        _pf_out recommend "$NYX_RECOMMEND"
        _pf_out reason "$NYX_REASON"
    else
        say "==> Recommendation"
        _pf_out "backend" "$NYX_RECOMMEND"
        [ -n "$NYX_REASON" ] && _pf_out "notes" "$NYX_REASON"
    fi
fi