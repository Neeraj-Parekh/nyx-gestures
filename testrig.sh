#!/bin/bash
# Isolated GNOME Shell test rig for nyx-gestures.
#
# HISTORY: two earlier versions of this script clobbered the real session's
# dconf database, because gsettings writes go through the running shared
# dconf-service and ignore HOME. Isolation is therefore NOT done with HOME -
# it uses a dedicated dconf profile registered at /etc/dconf/profile/nyxtest,
# which deliberately omits "user-db:user" (the real database).
#
# SAFETY: before and after the run we snapshot the real enabled-extensions and
# compare. Any difference is reported as a failure. This is a gate, not a
# comment.
#
# Usage: testrig.sh [seconds]
set -euo pipefail

SECS="${1:-40}"
SRC="$(cd "$(dirname "$0")" && pwd)"
UUID="nyx-gestures@nyx.local"
EXTDIR="$HOME/.local/share/gnome-shell/extensions/$UUID"
PROFILE=nyxtest
RIGLOG="$(mktemp /tmp/nyx-rig.XXXXXX.log)"
# NYX_KEEP_LOG=1 preserves the headless shell's full output for debugging.
trap '[ -n "${NYX_KEEP_LOG:-}" ] || rm -f "$RIGLOG"' EXIT

[ -f /etc/dconf/profile/$PROFILE ] || {
    echo "ERROR: /etc/dconf/profile/$PROFILE missing." >&2
    echo "       Without it this rig would write to your real dconf database." >&2
    exit 1
}

# ---- gate: snapshot the real database ------------------------------------
real_before="$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo '[]')"

# a stale marker makes GNOME skip extension loading entirely
rm -f /run/user/"$(id -u)"/gnome-shell-disable-extensions 2>/dev/null || true

mkdir -p "$EXTDIR"
# gesture-map.js is a runtime import of extension.js, not an optional extra:
# omitting it here would make the rig report an unrelated load failure.
cp "$SRC/extension/metadata.json" "$SRC/extension/extension.js" \
   "$SRC/extension/gesture-map.js" "$EXTDIR/"

# Second, test-only extension that asserts every API extension.js calls really
# exists in a real shell, then exercises the action paths. Without it the rig
# only proved the file loads, which is a much weaker claim: a missing method is
# a TypeError thrown inside a gesture handler and the gesture just silently
# does nothing.
PROBE_UUID="nyx-apiprobe@nyx.local"
PROBEDIR="$HOME/.local/share/gnome-shell/extensions/$PROBE_UUID"
mkdir -p "$PROBEDIR"
cp "$SRC/dev/probeext/metadata.json" "$SRC/dev/probeext/extension.js" "$PROBEDIR/"
cp "$SRC/dev/apiprobe.js" "$SRC/dev/selftest.js" "$SRC/dev/statetest.js" "$SRC/dev/logtest.js" "$PROBEDIR/"

# The ONLY write goes to the isolated profile.
DCONF_PROFILE="$PROFILE" gsettings set org.gnome.shell enabled-extensions \
    "['$UUID', '$PROBE_UUID']"

# ---- gate: prove the write was contained BEFORE booting a shell ----------
canary_leak="$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null)"
if printf '%s' "$canary_leak" | grep -q "$UUID"; then
    echo "ABORT: the enable leaked into the real session. Not running a shell." >&2
    echo "  real value: $canary_leak" >&2
    exit 1
fi
echo "--- gate passed: real session has no reference to $UUID"

env -i \
    HOME="$HOME" USER="$USER" LOGNAME="$USER" PATH="$PATH" \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
    LANG="${LANG:-C.UTF-8}" \
    DCONF_PROFILE="$PROFILE" \
    GNOME_SHELL_SESSION_MODE=user GSETTINGS_BACKEND=dconf \
    timeout "$SECS" dbus-run-session -- gnome-shell --headless \
    > "$RIGLOG" 2>&1 || true
echo "--- headless shell output of interest"
grep -E "FINAL_ASSERT|SELFTEST|STATE_TEST|LOG_TEST|nyx-gestures" "$RIGLOG" | sed 's/^/  /' || true

# ---- gate: prove nothing changed -----------------------------------------
real_after="$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo '[]')"
if [ "$real_before" = "$real_after" ]; then
    echo "--- PASS: real enabled-extensions unchanged"
else
    echo "--- FAIL: real enabled-extensions CHANGED" >&2
    echo "    before: $real_before" >&2
    echo "    after:  $real_after" >&2
    exit 1
fi

# ---- report ---------------------------------------------------------------
# The probe extension is rig-only scaffolding; it is not part of the product
# and must not be left behind to show up in a later `gnome-extensions list`.
rm -rf "$PROBEDIR"

echo "--- API assertions"
grep -E "FINAL_ASSERT" "$RIGLOG" 2>/dev/null | sed 's/^/  /' || true
grep -qE "FINAL_ASSERT ALL APIs PRESENT" "$RIGLOG" 2>/dev/null || {
    echo "--- FAIL: FINAL_ASSERT did not report success" >&2
    exit 1
}

# Gate the state-machine test too. It was passing silently once because the
# report filter only surfaced STATE_TEST lines, not the FAIL lines between them.
echo "--- state machine"
grep -E "STATE_TEST (PASSED|FAILED)" "$RIGLOG" 2>/dev/null | sed 's/^.*STATE_TEST/  STATE_TEST/' || true
grep -E "^.*FAIL  " "$RIGLOG" 2>/dev/null | sed 's/^.*FAIL  /    /' || true
grep -qE "STATE_TEST PASSED" "$RIGLOG" 2>/dev/null || {
    echo "--- FAIL: STATE_TEST did not report success" >&2
    exit 1
}

echo "--- logger"
grep -E "LOG_TEST (PASSED|FAILED)" "$RIGLOG" 2>/dev/null | sed 's/^.*LOG_TEST/  LOG_TEST/' || true
grep -qE "LOG_TEST PASSED" "$RIGLOG" 2>/dev/null || {
    echo "--- FAIL: LOG_TEST did not report success" >&2
    exit 1
}
