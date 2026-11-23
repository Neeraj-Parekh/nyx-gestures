/* Exhaustive test of the extension's gesture -> action mapping.
 *
 * Runs under plain node, NOT inside GNOME Shell. That is the whole point: the
 * mapping is the part of the extension that was previously only reachable by
 * performing real gestures on a real touchpad in a live session, which needs a
 * logout. gesture-map.js has no gi imports precisely so this can run here.
 *
 *   node dev/decisiontest.js
 *
 * Three things are checked:
 *   1. every (fingers, axis, direction) combination maps to the expected action,
 *      and unbound combinations return null rather than a wrong action;
 *   2. the dispatch table in extension.js and gesture-map.js agree - a missing
 *      key is a TypeError thrown mid-gesture, an extra key is unreachable code;
 *   3. the extension's bound gestures match the daemon's libinput-gestures.conf,
 *      so migrating between backends cannot silently change what a gesture does.
 */
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {dirname, join} from 'node:path';
import {
    decideSwipe, decidePinch, ALL_ACTIONS, boundSwipes, boundPinches,
} from '../extension/gesture-map.js';

const here = dirname(fileURLToPath(import.meta.url));
let failures = 0;
let checks = 0;

function check(label, actual, expected) {
    checks++;
    const a = JSON.stringify(actual);
    const e = JSON.stringify(expected);
    if (a !== e) {
        failures++;
        console.log(`  FAIL  ${label}\n          got      ${a}\n          expected ${e}`);
    }
}

function ok(label, cond) {
    checks++;
    if (!cond) {
        failures++;
        console.log(`  FAIL  ${label}`);
    }
}

console.log('DECISION_TEST ===== 1. swipe mapping =====');
// Note the 4F horizontal entries: they are CROSSED relative to GNOME's own
// 4-finger swipe. That is the hardware-confirmed preference recorded in
// libinput-gestures.conf, and section 4 below independently cross-checks it
// against that file, so the two cannot drift.
const SWIPE_EXPECT = {
    '3F h +': 'tile-right',
    '3F h -': 'tile-left',
    '3F v +': 'begin-resize',
    '3F v -': 'overview',
    '4F h +': 'workspace-left',
    '4F h -': 'workspace-right',
    '4F v +': 'show-desktop',
    '4F v -': 'fullscreen',
};
for (const fingers of [2, 3, 4, 5]) {
    for (const horizontal of [true, false]) {
        for (const positive of [true, false]) {
            const key = `${fingers}F ${horizontal ? 'h' : 'v'} ${positive ? '+' : '-'}`;
            const want = SWIPE_EXPECT[key] ?? null;
            check(`${key} -> ${want ?? 'null (unbound)'}`, decideSwipe(fingers, horizontal, positive), want);
        }
    }
}

console.log('DECISION_TEST ===== 2. pinch mapping =====');
const PINCH_EXPECT = {
    '3F out': 'screenshot-full',
    '3F in': 'close-window',
    '4F out': 'screenshot-picker',
    '4F in': 'show-desktop',
};
for (const fingers of [2, 3, 4, 5]) {
    for (const out of [true, false]) {
        const key = `${fingers}F ${out ? 'out' : 'in'}`;
        const want = PINCH_EXPECT[key] ?? null;
        check(`${key} -> ${want ?? 'null (unbound)'}`, decidePinch(fingers, out), want);
    }
}

console.log('DECISION_TEST ===== 3. dispatch table agreement =====');
const extSrc = readFileSync(join(here, '..', 'extension', 'extension.js'), 'utf8');
const tableBody = extSrc.match(/const ACTIONS = \{([\s\S]*?)\n\};/);
ok('ACTIONS table found in extension.js', !!tableBody);
const tableKeys = [...(tableBody?.[1] ?? '').matchAll(/'([a-z-]+)':/g)].map(m => m[1]);
check('ACTIONS keys match gesture-map ALL_ACTIONS', [...tableKeys].sort(),
    [...ALL_ACTIONS].sort());
ok('no duplicate keys in ACTIONS', new Set(tableKeys).size === tableKeys.length);

console.log('DECISION_TEST ===== 4. extension vs daemon config =====');
let conf = '';
try {
    conf = readFileSync(process.argv[2] ?? join(here, '..', 'libinput-gestures.conf'), 'utf8');
} catch {
    console.log('  SKIP  libinput-gestures.conf not found; pass its path as argv[2]');
}
if (conf) {
    // The daemon's chord -> GNOME action resolution, mirrored here so the two
    // backends can be compared by meaning rather than by keystroke.
    const MEANING = {
        'super+shift+Left': 'tile-left',
        'super+shift+Right': 'tile-right',
        'super+Tab': 'overview',
        'alt+F8': 'begin-resize',
        'super+alt+Right': 'workspace-right',
        'super+alt+Left': 'workspace-left',
        'alt+F9': 'fullscreen',
        'alt+F12': 'show-desktop',
        'alt+F4': 'close-window',
    };
    const daemon = {};
    for (const line of conf.split('\n')) {
        const m = line.match(/^gesture\s+(\S+)\s+(\S+)\s+(\d)\s+(?:env \S+ \S+ \S+ )?\S*\/(\S+)(?:\s+(\S+))?/);
        if (!m)
            continue;
        const [, kind, dirn, nf, bin, arg] = m;
        let action = null;
        if (bin === 'nyshot') {
            action = arg === 'full' ? 'screenshot-full' : arg === 'gui' ? 'screenshot-picker' : null;
        } else {
            action = MEANING[arg] ?? null;
        }
        if (action)
            daemon[`${nf}F ${kind} ${dirn}`] = action;
    }
    // Extension's own labels, in the same "NF kind dirn" form.
    const ext = {};
    for (const fingers of [3, 4]) {
        for (const horizontal of [true, false]) {
            for (const positive of [true, false]) {
                const dirn = horizontal ? (positive ? 'right' : 'left') : (positive ? 'down' : 'up');
                ext[`${fingers}F swipe ${dirn}`] = decideSwipe(fingers, horizontal, positive);
            }
        }
        for (const o of [true, false])
            ext[`${fingers}F pinch ${o ? 'out' : 'in'}`] = decidePinch(fingers, o);
    }
    const daemonKeys = Object.keys(daemon).sort();
    const extKeys = Object.keys(ext).sort();
    check('same set of bound gestures in both backends', extKeys, daemonKeys);
    for (const k of daemonKeys) {
        if (ext[k] !== daemon[k])
            check(`meaning of ${k}`, ext[k], daemon[k]);
    }
    console.log(`  compared ${daemonKeys.length} gesture meanings across both backends`);
}

console.log(`DECISION_TEST ${failures ? `FAILED: ${failures} of ${checks} checks` : `PASSED: all ${checks} checks`}`);
process.exit(failures ? 1 : 0);
