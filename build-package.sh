#!/bin/bash
# Build the distributable tarball for nyx-gestures.
#
# Ships ONLY what is needed to install and run. Deliberately excluded:
#   dev/       test harnesses, probes, the uinput synthesiser
#   dist/      previous builds
#   testrig.sh lint.sh build-extension.sh eslint.config.mjs
#
# Those live in the working tree, not the tarball: a friend installing this
# should not receive a headless GNOME rig and a C program that creates fake
# touchpads.
#
# Usage: build-package.sh [output-dir]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/dist}"
NAME="nyx-gestures"
STAMP=$(date +%Y%m%d)
TAR="$OUT/${NAME}-${STAMP}.tar.gz"

mkdir -p "$OUT"
rm -f "$TAR"
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
D="$S/$NAME"
mkdir -p "$D"

copy() { install -D -m 644 "$HERE/$1" "$D/$1"; }
copyx() { install -D -m 755 "$HERE/$1" "$D/$1"; }

# entry points and metadata
copyx install.sh
copy  README.md
copy  VERSION
copy  libinput-gestures.conf
copyx nyx-gestures-setup

# runtime libraries
copyx lib/nyx-log.sh
copyx lib/nyx-preflight.sh

# daemon backend
for f in nyx-interp nyx-key nyx-keyd nyx-key.py nyx-keyd.py nyshot; do
    copyx "daemon/$f"
done

# extension backend
for f in metadata.json extension.js gesture-map.js LICENSE; do
    copy "extension/$f"
done

# systemd units and the GSettings schema
for f in units/*.service units/*.timer; do
    [ -e "$HERE/$f" ] && copy "$f"
done
for f in schemas/*.gschema.xml; do
    [ -e "$HERE/$f" ] && copy "$f"
done

echo "--- package contents"
( cd "$S" && find . -type f | sort | sed 's|^\./|    |' )

# Sanity gate: the tarball must be able to detect a platform. Without lib/ the
# installer silently falls back to a version check, which is the bug this whole
# exercise exists to remove.
if [ ! -f "$D/lib/nyx-preflight.sh" ]; then
    echo "ERROR: lib/nyx-preflight.sh missing from the package" >&2
    exit 1
fi

# Verify the copied tree actually parses before shipping it.
for f in "$D"/daemon/nyx-interp "$D"/daemon/nyx-key "$D"/daemon/nyx-keyd; do
    sh -n "$f" || { echo "ERROR: $f is not valid sh" >&2; exit 1; }
done
bash -n "$D/daemon/nyshot" || { echo "ERROR: nyshot is not valid bash" >&2; exit 1; }
bash -n "$D/install.sh"     || { echo "ERROR: install.sh is not valid bash" >&2; exit 1; }
bash -n "$D/lib/nyx-log.sh" || { echo "ERROR: nyx-log.sh is not valid bash" >&2; exit 1; }
sh -n "$D/lib/nyx-preflight.sh" || { echo "ERROR: preflight is not valid sh" >&2; exit 1; }
if command -v glib-compile-schemas >/dev/null 2>&1 && compgen -G "$D/schemas/*.gschema.xml" >/dev/null; then
    glib-compile-schemas --strict --dry-run "$D/schemas" \
        || { echo "ERROR: schema does not compile" >&2; exit 1; }
fi

( cd "$S" && tar czf "$TAR" "$NAME" )

echo
echo "--- built $TAR"
ls -lh "$TAR" | awk '{print "    " $5 "  " $9}'
echo "    sha256: $(sha256sum "$TAR" | cut -c1-64)"
echo
echo "--- verify the tarball unpacks and runs on a clean copy"
V=$(mktemp -d)
tar xzf "$TAR" -C "$V"
( cd "$V/$NAME" && ./lib/nyx-preflight.sh >/dev/null 2>&1 ) \
    && echo "    preflight runs from the unpacked tarball" \
    || echo "    WARNING: preflight failed from the unpacked tarball"
( cd "$V/$NAME" && bash -n install.sh ) && echo "    install.sh parses"
rm -rf "$V"