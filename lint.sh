#!/bin/bash
# Lint gate for the extension. Catches undefined identifiers and dead code,
# which `node --check` cannot. This exists because a stray `s.done` (leftover
# from a rename) passed every syntax check and would have thrown a
# ReferenceError on every committed swipe.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-$HERE/extension/extension.js}"
RUNNER=""
if command -v eslint >/dev/null 2>&1; then
    RUNNER="eslint"
elif [ -x /tmp/lintenv/node_modules/.bin/eslint ]; then
    RUNNER="/tmp/lintenv/node_modules/.bin/eslint"
    CFG_DIR="/tmp/lintenv"
fi

# syntax first
if node --check "$TARGET" 2>/dev/null; then
    echo "  syntax: OK"
else
    echo "  syntax: FAILED" >&2; exit 1
fi

if [ -n "$RUNNER" ]; then
    if [ "$RUNNER" = "eslint" ]; then
        (cd "$HERE" && eslint "$TARGET") || { echo "  lint: FAILED" >&2; exit 1; }
    else
        cp "$TARGET" /tmp/lintenv/check.js
        (cd "$CFG_DIR" && ./node_modules/.bin/eslint check.js) || {
            echo "  lint: FAILED" >&2; exit 1; }
    fi
    echo "  lint: clean (no-undef, no-unused-vars, no-redeclare, no-const-assign)"
else
    echo "  lint: SKIPPED - eslint not installed (npm i -g eslint)"
fi
