#!/bin/bash
# Build the shippable extension ZIP, following the extensions.gnome.org rules:
#   - ZIP contains ONLY files needed at runtime (metadata.json, extension.js,
#     gesture-map.js, LICENSE). Dev files such as selftest.js stay out.
#   - metadata.json carries no deprecated keys and no unnecessary ones.
#   - the ZIP is named so its top-level directory matches the uuid, which GNOME
#     requires or it refuses to load ("UUID ... does not match directory name").
#
# gesture-map.js IS a runtime file: extension.js imports it for the gesture ->
# action mapping, so omitting it produces an extension that fails to load at all.
#
# The build also runs the decision test, which cross-checks that mapping against
# libinput-gestures.conf. A build that shipped a mapping disagreeing with the
# daemon would silently reverse gestures for anyone migrating between backends.
#
# Usage: build-extension.sh [output-dir]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/dist}"
UUID="nyx-gestures@nyx.local"

command -v gnome-extensions >/dev/null || { echo "gnome-extensions not found" >&2; exit 1; }

VERSION="$(grep -o '"version-name": *"[^"]*"' "$HERE/extension/metadata.json" | cut -d'"' -f4)"
mkdir -p "$OUT"
ZIP="$OUT/${UUID}.shell-extension.zip"

rm -f "$ZIP"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# stage ONLY shippable files, under a directory named exactly as the uuid
mkdir -p "$STAGE/$UUID"
cp "$HERE/extension/metadata.json" "$HERE/extension/extension.js" \
   "$HERE/extension/gesture-map.js" "$STAGE/$UUID/"
cp "$HERE/extension/LICENSE" "$STAGE/$UUID/"

echo "--- contents to be shipped:"
( cd "$STAGE/$UUID" && find . -type f | sed 's|^\./|    |' )

( cd "$STAGE" && zip -qr "$ZIP" "$UUID" )

echo "--- built $ZIP"
unzip -l "$ZIP" | sed 's/^/    /'

# lint: catches undefined identifiers, which node --check cannot.
# This is not theoretical - a stray `s.done` (leftover from a rename) passed
# node --check and would have thrown a ReferenceError on every swipe.
echo "--- lint"
for f in extension/extension.js extension/gesture-map.js; do
    if command -v eslint >/dev/null 2>&1; then
        eslint "$HERE/$f" || {
            echo "    lint FAILED on $f - refusing to build" >&2; exit 1; }
    elif [ -x /tmp/lintenv/node_modules/.bin/eslint ]; then
        cp "$HERE/$f" /tmp/lintenv/check.js
        (cd /tmp/lintenv && ./node_modules/.bin/eslint check.js) || {
            echo "    lint FAILED on $f - refusing to build" >&2; exit 1; }
    else
        echo "    SKIPPED for $f: eslint not available (npm i -g eslint)"
    fi
done
command -v eslint >/dev/null || [ -x /tmp/lintenv/node_modules/.bin/eslint ] \
    && echo "    eslint clean"

# decision test: the gesture -> action mapping, cross-checked against the daemon
echo "--- decision test"
CONF="$HERE/libinput-gestures.conf"
[ -f "${HOME}/.config/libinput-gestures.conf" ] && CONF="$HOME/.config/libinput-gestures.conf"
node "$HERE/dev/decisiontest.js" "$CONF" | sed 's/^/  /' || {
    echo "    decision test FAILED - refusing to build" >&2; exit 1; }

# validation
echo "--- validation"
python3 - "$HERE/extension/metadata.json" "$STAGE/$UUID" <<'PY'
import json, sys, os, re
meta = json.load(open(sys.argv[1]))
dirname = os.path.basename(sys.argv[2])
errs = []
if meta['uuid'] != dirname:
    errs.append(f"uuid {meta['uuid']} != directory {dirname}")
if 'version' in meta:
    errs.append("deprecated 'version' key present")
if meta.get('session-modes') == ['user']:
    errs.append("session-modes should be dropped when only 'user' is used")
if not meta.get('url'):
    errs.append("url missing")
if not re.fullmatch(r'[a-zA-Z0-9 .]{1,16}', meta.get('version-name','')):
    errs.append("version-name must match [a-zA-Z0-9 .]{1,16}")
if 'gnome.org' in meta['uuid']:
    errs.append("uuid must not use gnome.org")
for k in ('uuid','name','description','shell-version'):
    if k not in meta:
        errs.append(f"missing required key {k}")
print("    metadata OK" if not errs else "    ERRORS:")
for e in errs:
    print("      -", e)
sys.exit(1 if errs else 0)
PY

if bash -n "$STAGE/$UUID/extension.js" 2>/dev/null; then :; fi
echo "    done"