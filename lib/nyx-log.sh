#!/bin/bash
# nyx-log - one small leveled logger for the shell parts of this package.
#
# WHY THIS EXISTS: the daemon side (nyx-key, nyx-keyd, nyshot) prints errors to
# stderr, which under systemd means the journal. The extension side is different
# - it lives inside gnome-shell, where console.log goes to the journal only while
# the shell is running, and is invisible to a user who has never opened a
# terminal. So the extension gets its own file logger with levels, and both
# halves report the same way.
#
# Levels, in increasing severity. NYX_LOG is read from the environment:
#     debug   per-event tracing; far too noisy for normal use
#     info    lifecycle events (enabled, disabled, gesture fired)      [default]
#     warn    something degraded but gestures still work
#     error   a gesture could not be performed
#     off     silence everything
#
# Deliberately NOT logged at info: raw touchpad deltas, finger counts, axis-lock
# arithmetic, or per-event state transitions. Those are debug-only, because at
# info they would fire on every partial swipe and turn the file into noise. A log
# you cannot read is the same as no log.

NYX_LOG_FILE="${NYX_LOG_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/nyx-gestures/nyx.log}"
NYX_LOG_MAX_BYTES="${NYX_LOG_MAX_BYTES:-262144}"   # 256 KiB, rotated once

nyx_log_level_num() {
    case "$(printf '%s' "${1:-info}" | tr 'A-Z' 'a-z')" in
        debug) printf 10 ;; info) printf 20 ;; warn) printf 30 ;;
        error) printf 40 ;; off|quiet|none) printf 99 ;;
        *) printf 20 ;;
    esac
}

# Rotate before writing, keeping exactly one previous generation. Truncating is
# safer than unlinking: the file is ours, but a rotated name could collide with
# something else if the state dir is shared.
_nyx_rotate_if_needed() {
    local f="$1"
    [ -f "$f" ] || return 0
    local sz
    sz=$(wc -c < "$f" 2>/dev/null || echo 0)
    [ "${sz:-0}" -lt "$NYX_LOG_MAX_BYTES" ] && return 0
    mv -f "$f" "$f.1" 2>/dev/null || : > "$f" 2>/dev/null || true
}

# nyx_log LEVEL MESSAGE...
# Writes one line: ISO-8601 time, level, pid, message. Never fails the caller:
# logging must not be able to break a gesture.
nyx_log() {
    local level="$1"; shift
    local want have
    want=$(nyx_log_level_num "${NYX_LOG:-info}")
    have=$(nyx_log_level_num "$level")
    [ "$have" -lt "$want" ] && return 0
    [ "$want" -ge 99 ] && return 0

    local ts line
    ts=$(date -Is 2>/dev/null || printf 'unknown-time')
    line="$ts [$level] ($$) $*"

    local dir
    dir=$(dirname "$NYX_LOG_FILE")
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0
    [ -w "$dir" ] || return 0
    _nyx_rotate_if_needed "$NYX_LOG_FILE"
    printf '%s\n' "$line" >> "$NYX_LOG_FILE" 2>/dev/null || true

    # mirror warnings and errors to stderr so the journal shows them too
    case "$(printf '%s' "$level" | tr 'A-Z' 'a-z')" in
        warn|error) printf 'nyx-gestures: %s\n' "$*" >&2 ;;
    esac
    return 0
}

nyx_log_debug() { nyx_log debug "$@"; }
nyx_log_info()  { nyx_log info  "$@"; }
nyx_log_warn()  { nyx_log warn  "$@"; }
nyx_log_error() { nyx_log error "$@"; }

# nyx_log_init COMPONENT - call once at startup to record the environment that
# every later line will be interpreted against.
nyx_log_init() {
    local comp="${1:-nyx-gestures}"
    nyx_log_info "$comp starting"
    if [ "${NYX_VERBOSE_ENV:-0}" = 1 ]; then
        nyx_log_info "  session=${XDG_SESSION_TYPE:-unknown} display=${DISPLAY:-none} wayland=${WAYLAND_DISPLAY:-none}"
        nyx_log_info "  log file: $NYX_LOG_FILE (limit ${NYX_LOG_MAX_BYTES}B)"
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    # self-test: proves levelling and rotation actually behave
    set -uo pipefail
    NYX_LOG_FILE=/tmp/nyx-logtest.log
    rm -f "$NYX_LOG_FILE" "$NYX_LOG_FILE.1"
    export NYX_LOG=info NYX_LOG_MAX_BYTES=400
    nyx_log_info "first info line"
    nyx_log_debug "SHOULD NOT APPEAR at info level"
    nyx_log_warn "a warning"
    nyx_log_error "an error"
    for i in $(seq 1 40); do nyx_log_info "filler line $i padding padding padding"; done
    echo "--- rotated? ---"
    [ -f "$NYX_LOG_FILE.1" ] && echo "  yes, $NYX_LOG_FILE.1 exists" || echo "  NO"
    echo "--- debug suppressed at info? ---"
    grep -q SHOULD_NOT_APPEAR "$NYX_LOG_FILE" && echo "  LEAKED" || echo "  correctly suppressed"
    echo "--- levels present ---"
    sed 's/.*\[\([a-z]*\)\].*/\1/' "$NYX_LOG_FILE" | sort | uniq -c | sed 's/^/  /'
    echo "--- NYX_LOG=error hides info and warn? ---"
    : > "$NYX_LOG_FILE"
    ( NYX_LOG=error; nyx_log_info "hidden-info"; nyx_log_warn "hidden-warn"; nyx_log_error "shown-error" )
    grep -cE "hidden-info|hidden-warn" "$NYX_LOG_FILE" | sed 's/^/  hidden lines: /'
    grep -c "shown-error" "$NYX_LOG_FILE" | sed 's/^/  shown lines: /'
    echo "--- NYX_LOG=off silences everything? ---"
    : > "$NYX_LOG_FILE"
    ( NYX_LOG=off; nyx_log_error "should-be-nothing" )
    wc -l < "$NYX_LOG_FILE" | sed 's/^/  lines written: /'
    rm -f "$NYX_LOG_FILE" "$NYX_LOG_FILE.1"
fi